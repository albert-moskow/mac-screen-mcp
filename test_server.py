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

    def test_click_prefers_exact_button_over_outer_container(self):
        server.SESSION_STATE.update(approved=True, expires_at=server.time.time() + 30, reason="test")
        captured = {}
        orig = server.run_chrome_js
        try:
            def fake_run(js):
                captured["js"] = js
                return "CLICKED: Продолжить"
            server.run_chrome_js = fake_run
            res = server.click_chrome_element("Продолжить")
            self.assertEqual(res, "CLICKED: Продолжить")
            self.assertIn("exact[exact.length - 1] || partial[0]", captured["js"])
        finally:
            server.run_chrome_js = orig


if __name__ == "__main__":
    unittest.main()
