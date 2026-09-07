import os
import pathlib
import stat
import tempfile
import types
import unittest
import zipfile
from unittest import mock

from backend.core import memory
from backend.core.config import HOME
from backend.core.io import is_safe_path, safe_session_environment
from backend.tools import filesystem
from backend.tools.filesystem import (
    tool_create_docx,
    tool_modify_docx,
    tool_read_file,
    tool_read_pdf,
    tool_write_file,
)


class PathSecurityTests(unittest.TestCase):
    def test_child_environment_omits_application_secrets(self):
        with mock.patch.dict(
            os.environ,
            {
                "DATABASE_URL": "postgresql://secret",
                "GEMINI_API_KEY": "secret-api-key",
                "WAYLAND_DISPLAY": "wayland-test",
            },
        ):
            environment = safe_session_environment()

        self.assertNotIn("DATABASE_URL", environment)
        self.assertNotIn("GEMINI_API_KEY", environment)
        self.assertEqual(environment["WAYLAND_DISPLAY"], "wayland-test")

    def test_prefix_sibling_is_rejected(self):
        self.assertFalse(is_safe_path(HOME + "_sibling/secret"))

    def test_home_child_is_allowed(self):
        self.assertTrue(is_safe_path(str(pathlib.Path(HOME) / "Documents")))

    def test_create_without_overwrite_is_atomic(self):
        workspace = pathlib.Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(dir=workspace) as temp_dir:
            target = pathlib.Path(temp_dir) / "example.txt"
            created = tool_write_file(str(target), "first")
            refused = tool_write_file(str(target), "second")

            self.assertIn("creado", created)
            self.assertIn("ya existe", refused)
            self.assertEqual(target.read_text(), "first")

    def test_read_file_enforces_two_hundred_line_chunks(self):
        workspace = pathlib.Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(dir=workspace) as temp_dir:
            target = pathlib.Path(temp_dir) / "large.txt"
            target.write_text("".join(f"line {i}\n" for i in range(400)))

            result = tool_read_file(str(target), 1, 10000)

            self.assertIn("200: line 199", result)
            self.assertNotIn("201: line 200", result)
            self.assertIn("Continúa en línea 201", result)

    def test_symlink_cannot_escape_home(self):
        workspace = pathlib.Path(__file__).resolve().parent
        with (
            tempfile.TemporaryDirectory(dir=workspace) as inside,
            tempfile.TemporaryDirectory(dir="/tmp") as outside,
        ):
            link = pathlib.Path(inside) / "outside"
            link.symlink_to(outside, target_is_directory=True)

            result = tool_write_file(str(link / "escape.txt"), "blocked")

            self.assertIn("Acceso denegado", result)
            self.assertFalse((pathlib.Path(outside) / "escape.txt").exists())

    def test_document_readers_reject_mismatched_extensions(self):
        workspace = pathlib.Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(dir=workspace) as temp_dir:
            target = pathlib.Path(temp_dir) / "not-a-pdf.txt"
            target.write_text("plain text")

            result = tool_read_pdf(str(target))

            self.assertIn("extensión permitida", result)

    def test_modify_docx_rejects_invalid_ooxml_container(self):
        workspace = pathlib.Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(dir=workspace) as temp_dir:
            target = pathlib.Path(temp_dir) / "invalid.docx"
            target.write_text("not a zip")

            result = tool_modify_docx(str(target), "new paragraph")

            self.assertIn("OOXML válido", result)

    def test_create_docx_does_not_overwrite_a_racing_file(self):
        workspace = pathlib.Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(dir=workspace) as temp_dir:
            target = pathlib.Path(temp_dir) / "document.docx"

            def fake_pandoc(arguments, **_kwargs):
                if "--to=json" in arguments:
                    _kwargs["stdout"].write(
                        b'{"pandoc-api-version":[1,23],"meta":{},"blocks":[]}'
                    )
                    return types.SimpleNamespace(returncode=0)
                output_index = arguments.index("--output") + 1
                pathlib.Path(arguments[output_index]).write_bytes(b"generated")
                target.write_text("created concurrently")
                return types.SimpleNamespace(returncode=0)

            with (
                mock.patch.object(
                    filesystem.shutil,
                    "which",
                    return_value="/usr/bin/pandoc",
                ),
                mock.patch.object(
                    filesystem.subprocess,
                    "run",
                    side_effect=fake_pandoc,
                ),
            ):
                result = tool_create_docx(str(target), "# Title")

            self.assertIn("apareció durante la conversión", result)
            self.assertEqual(target.read_text(), "created concurrently")

    @unittest.skipUnless(filesystem.shutil.which("pandoc"), "pandoc no instalado")
    def test_create_docx_uses_sandboxed_pandoc_successfully(self):
        workspace = pathlib.Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(dir=workspace) as temp_dir:
            target = pathlib.Path(temp_dir) / "document.docx"

            result = tool_create_docx(
                target.as_posix(),
                "# Safe document\n\n![secret](/etc/passwd)",
            )

            self.assertIn("creado exitosamente", result)
            self.assertIsNone(filesystem._validate_document_container(target))
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            with zipfile.ZipFile(target) as document:
                expanded = b"".join(
                    document.read(name)
                    for name in document.namelist()
                )
            self.assertNotIn(b"/etc/passwd", expanded)


class MemorySecurityTests(unittest.TestCase):
    def test_memory_files_are_private_and_sections_are_validated(self):
        workspace = pathlib.Path(__file__).resolve().parent
        original = (
            memory.MEMORY_DIR,
            memory.USER_PROFILE_FILE,
            memory.PREFERENCES_FILE,
        )
        with tempfile.TemporaryDirectory(dir=workspace) as temp_dir:
            memory.MEMORY_DIR = temp_dir
            memory.USER_PROFILE_FILE = str(pathlib.Path(temp_dir) / "profile.md")
            memory.PREFERENCES_FILE = str(
                pathlib.Path(temp_dir) / "preferences.md"
            )
            try:
                result = memory.update_memory_section(
                    "profile",
                    "Proyecto",
                    "Minerva",
                )
                invalid = memory.update_memory_section(
                    "profile",
                    "sección\ninyectada",
                    "dato",
                )
                mode = stat.S_IMODE(
                    pathlib.Path(memory.USER_PROFILE_FILE).stat().st_mode
                )
                self.assertIn("actualizada", result)
                self.assertIn("inválido", invalid)
                self.assertEqual(mode, 0o600)
            finally:
                (
                    memory.MEMORY_DIR,
                    memory.USER_PROFILE_FILE,
                    memory.PREFERENCES_FILE,
                ) = original


if __name__ == "__main__":
    unittest.main()
