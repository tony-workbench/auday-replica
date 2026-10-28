"""API keys are stored encrypted in auday.sqlite and read back as plain text."""

import json
import sqlite3
import tempfile
import unittest

from helpers import transcript  # noqa: F401  (adds the repo root to sys.path)

from app.core import App


class SecretTests(unittest.TestCase):
    def test_keys_are_encrypted_at_rest(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            app.update_settings({"api_key": "sk-test-1234567890", "asr_api_key": "dg-abc"})
            raw = json.loads(sqlite3.connect(f"{tmp}/auday.sqlite").execute(
                "SELECT value FROM metadata WHERE key='settings'").fetchone()[0])
            self.assertTrue(raw["api_key"].startswith("enc:v1:"))
            self.assertNotIn("sk-test", json.dumps(raw))
            self.assertEqual(app.settings()["api_key"], "sk-test-1234567890")
            self.assertEqual(App(tmp).settings()["asr_api_key"], "dg-abc")      # same key file, new process
            self.assertTrue(app.public_settings()["api_key"].endswith("7890"))

    def test_plain_keys_from_before_are_sealed(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = App(tmp)
            with app.db:
                app.db.execute("INSERT OR REPLACE INTO metadata VALUES('settings', ?)", (json.dumps({"api_key": "old-plain"}),))
            self.assertEqual(app.settings()["api_key"], "old-plain")
            raw = app.db.execute("SELECT value FROM metadata WHERE key='settings'").fetchone()[0]
            self.assertNotIn("old-plain", raw)


if __name__ == "__main__":
    unittest.main()
