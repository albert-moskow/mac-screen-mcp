import importlib.util
import unittest

spec = importlib.util.spec_from_file_location("server", "server.py")
server = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(server)


class ScreenConsentTest(unittest.TestCase):
    def setUp(self):
        server.revoke_access()

    def test_capture_requires_consent(self):
        with self.assertRaises(PermissionError):
            server.capture_screen()

    def test_revoke_disables_capture(self):
        server.SESSION_STATE.update(approved=True, expires_at=server.time.time() + 30, reason="test")
        server.revoke_access()
        with self.assertRaises(PermissionError):
            server.capture_screen()

    def test_expired_consent_is_cleared(self):
        server.SESSION_STATE.update(approved=True, expires_at=server.time.time() - 1, reason="test")
        self.assertFalse(server.has_active_consent())
        self.assertFalse(server.SESSION_STATE["approved"])


if __name__ == "__main__":
    unittest.main()
