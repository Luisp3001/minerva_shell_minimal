import io
import threading
import unittest
import urllib.error
from unittest import mock

from backend.core import gemini_engine
from backend.core.gemini_engine import (
    MAX_SSE_EVENT_CHARS,
    MAX_TOOL_CALLS_PER_RESPONSE,
    _StreamCancelled,
    _iter_sse_data,
    _sanitize_history,
)
from backend import tools as backend_tools
from backend.tools.registry import ToolRegistry


class GeminiProtocolTests(unittest.TestCase):
    class _NeverCancelled:
        @staticmethod
        def is_set():
            return False

        @staticmethod
        def wait(_timeout):
            return False

    def test_sse_parser_combines_data_lines_and_ignores_comments(self):
        response = iter([
            b": heartbeat\n",
            b"data: {\"hello\":\n",
            b"data: \"world\"}\n",
            b"\n",
            b"data: [DONE]\n",
            b"\n",
        ])

        self.assertEqual(
            list(_iter_sse_data(response)),
            ['{"hello":\n"world"}', "[DONE]"],
        )

    def test_sse_reader_bounds_each_line_before_parsing(self):
        response = io.BytesIO(b"data: " + b"x" * MAX_SSE_EVENT_CHARS)

        with self.assertRaisesRegex(ValueError, "línea SSE"):
            list(_iter_sse_data(response))

    def test_sse_reader_observes_cancellation_on_heartbeat(self):
        cancelled = threading.Event()
        cancelled.set()

        with self.assertRaises(_StreamCancelled):
            list(_iter_sse_data(iter([b": heartbeat\n"]), cancel_event=cancelled))

    def test_history_drops_orphan_tool_messages(self):
        history = [
            {"role": "tool", "tool_call_id": "orphan", "content": "bad"},
            {
                "role": "assistant",
                "tool_calls": [{"id": "valid"}],
                "content": None,
            },
            {"role": "tool", "tool_call_id": "valid", "content": "ok"},
        ]

        sanitized = _sanitize_history(history)

        self.assertEqual(len(sanitized), 2)
        self.assertEqual(sanitized[-1]["name"], "run_command")

    def test_tool_call_limit_is_small_and_explicit(self):
        self.assertGreater(MAX_TOOL_CALLS_PER_RESPONSE, 0)
        self.assertLessEqual(MAX_TOOL_CALLS_PER_RESPONSE, 32)

    def test_gemini_retries_a_transient_network_failure(self):
        response = io.BytesIO(
            b'data: {"choices":[{"delta":{"content":"ok"},'
            b'"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n'
        )
        events = []
        with (
            mock.patch.object(
                gemini_engine.urllib.request,
                "urlopen",
                side_effect=[urllib.error.URLError("temporary"), response],
            ) as urlopen,
            mock.patch.object(gemini_engine, "get_relevant_tools", return_value=[]),
            mock.patch.object(gemini_engine, "emit", side_effect=events.append),
            mock.patch.object(gemini_engine, "VOICE_AVAILABLE", False),
        ):
            gemini_engine.do_chat_gemini(
                [{"role": "user", "content": "hello"}],
                api_key="test-key",
                cancel_event=self._NeverCancelled(),
                request_id="retry-test",
            )

        self.assertEqual(urlopen.call_count, 2)
        self.assertEqual(events[-1]["type"], "done")
        self.assertEqual(events[-1]["full_response"], "ok")
        self.assertEqual(events[-1]["request_id"], "retry-test")


class ToolRegistryTests(unittest.TestCase):
    def setUp(self):
        self.registry = ToolRegistry([
            {
                "type": "function",
                "function": {
                    "name": "sample",
                    "description": "sample",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "count": {
                                "type": "integer",
                                "minimum": 1,
                                "maximum": 3,
                            },
                        },
                        "required": ["count"],
                        "additionalProperties": False,
                    },
                },
            },
        ])
        self.registry.register("sample")(
            lambda args, _context: args["count"]
        )

    def test_registry_validates_types_ranges_and_unknown_fields(self):
        self.assertIn("integer", self.registry.dispatch("sample", {"count": True}, {}))
        self.assertIn("máximo", self.registry.dispatch("sample", {"count": 4}, {}))
        self.assertIn(
            "no permitidos",
            self.registry.dispatch("sample", {"count": 1, "extra": 2}, {}),
        )
        self.assertEqual(self.registry.dispatch("sample", {"count": 2}, {}), 2)


class ToolSelectionTests(unittest.TestCase):
    def test_word_request_always_exposes_native_docx_tools(self):
        collection = mock.Mock()
        collection.query.return_value = {"ids": [["web_search"]]}

        with mock.patch.object(
            backend_tools,
            "_ensure_tool_collection",
            return_value=collection,
        ):
            selected = backend_tools.get_relevant_tools(
                "Crea un informe de Word",
                top_k=1,
            )

        names = {tool["function"]["name"] for tool in selected}
        self.assertIn("create_docx", names)
        self.assertIn("modify_docx", names)


if __name__ == "__main__":
    unittest.main()
