import threading
import time
import unittest
from unittest import mock

from backend.tools import spotify
from backend.tools.spotify import SpotifyManager


class SpotifyTokenTests(unittest.TestCase):
    @staticmethod
    def _manager_with_valid_token():
        manager = SpotifyManager.__new__(SpotifyManager)
        manager._lock = threading.RLock()
        manager._refresh_lock = threading.Lock()
        manager.access_token = "valid"
        manager.refresh_token = "refresh"
        manager.token_expiry = time.time() + 3600
        manager._last_refresh_error = ""
        return manager

    def test_expired_access_token_without_refresh_is_rejected(self):
        manager = SpotifyManager.__new__(SpotifyManager)
        manager._lock = threading.RLock()
        manager._refresh_lock = threading.Lock()
        manager.access_token = "expired"
        manager.refresh_token = None
        manager.token_expiry = time.time() - 10

        self.assertEqual(manager._get_valid_token(), "")

    def test_api_rejects_non_object_json(self):
        manager = self._manager_with_valid_token()
        response = mock.MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b"[]"

        with mock.patch.object(
            spotify.urllib.request,
            "urlopen",
            return_value=response,
        ):
            result = manager._api_request("GET", "/me")

        self.assertIn("inválida", result["error"])


if __name__ == "__main__":
    unittest.main()
