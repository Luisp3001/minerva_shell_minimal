import queue
import time
import unittest
from unittest import mock

import main
from backend.core.job_manager import job_mgr
from backend.tools import get_system_prompt


class CommandExecutionTests(unittest.TestCase):
    def _wait_for_worker(self, job_id: str, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                event = main.msg_queue.get(timeout=0.2)
            except queue.Empty:
                continue
            if (
                isinstance(event, dict)
                and event.get("type") == "_internal_cmd_done"
                and event.get("job_id") == job_id
            ):
                return
        self.fail(f"El worker del job {job_id} no terminó a tiempo")

    def _start(self, command: str):
        job = job_mgr.create("integration-call", command, is_sudo=False)
        claimed = job_mgr.claim(job.job_id, expected_sudo=False)
        self.assertIsNotNone(claimed)
        main._start_command(claimed)
        return job

    def test_command_completes_and_captures_output(self):
        with mock.patch.object(main, "emit"):
            job = self._start("printf minerva-async")
            self._wait_for_worker(job.job_id)

        snapshot = job_mgr.get(job.job_id)
        self.assertEqual(snapshot.status, "completed")
        self.assertEqual(snapshot.returncode, 0)
        self.assertEqual(snapshot.output, "minerva-async")

    def test_command_cancellation_terminates_process_group(self):
        started_at = time.monotonic()
        with mock.patch.object(main, "emit"):
            job = self._start("sleep 10")
            job_mgr.cancel(job.job_id)
            self._wait_for_worker(job.job_id)

        snapshot = job_mgr.get(job.job_id)
        self.assertEqual(snapshot.status, "cancelled")
        self.assertLess(time.monotonic() - started_at, 5.0)


class CoordinatorValidationTests(unittest.TestCase):
    def test_chat_accepts_and_normalizes_jarvis_personality(self):
        context = main._parse_chat_message({
            "type": "chat",
            "message": "hello",
            "history": [],
            "settings": {"personality": "JARVIS"},
        })

        self.assertEqual(context.settings["personality"], "jarvis")

    def test_chat_rejects_unknown_personality(self):
        with self.assertRaisesRegex(ValueError, "minerva o jarvis"):
            main._parse_chat_message({
                "type": "chat",
                "message": "hello",
                "history": [],
                "settings": {"personality": "ultron"},
            })

    def test_personality_prompts_have_distinct_identities(self):
        minerva_prompt = get_system_prompt("minerva")
        jarvis_prompt = get_system_prompt("jarvis")

        self.assertIn("Eres Minerva", minerva_prompt)
        self.assertIn("Eres JARVIS", jarvis_prompt)
        self.assertIn("señor", jarvis_prompt)
        self.assertNotIn("Eres Minerva", jarvis_prompt)

    def test_voice_manager_switches_wake_word_with_personality(self):
        main.voice_mgr.set_wake_word("jarvis")
        self.assertEqual(main.voice_mgr.wake_word, "jarvis")
        main.voice_mgr.set_wake_word("minerva")
        self.assertEqual(main.voice_mgr.wake_word, "minerva")

    def test_chat_rejects_unknown_settings(self):
        with self.assertRaisesRegex(ValueError, "desconocidos"):
            main._parse_chat_message({
                "type": "chat",
                "message": "hello",
                "history": [],
                "settings": {"unexpected_secret": "value"},
            })

    def test_chat_rejects_structured_api_key(self):
        with self.assertRaisesRegex(ValueError, "debe ser texto"):
            main._parse_chat_message({
                "type": "chat",
                "message": "hello",
                "history": [],
                "settings": {"gemini_api_key": {"nested": "value"}},
            })


if __name__ == "__main__":
    unittest.main()
