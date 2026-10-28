"""API keys come from the environment first, then the private keys file; a missing key is a clear error."""

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import helpers  # noqa: F401  (puts the repo on sys.path)

from memengine import llm, secrets


class SecretsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.file = Path(self.tmp.name) / "keys.env"
        self.file.write_text('# private\nexport GEMINI_API_KEY="from-file"  # comment\nOTHER=x\n')

    def tearDown(self):
        self.tmp.cleanup()

    def env(self, **values):
        return mock.patch.dict(os.environ, {"AUDAY_SECRETS": str(self.file), **values}, clear=True)

    def test_reads_the_private_file_when_not_in_the_environment(self):
        with self.env():
            self.assertEqual(secrets.get("GEMINI_API_KEY"), "from-file")
            self.assertEqual(llm.GeminiProvider().api_key, "from-file")

    def test_environment_wins_and_missing_key_is_none(self):
        with self.env(GEMINI_API_KEY="from-env"):
            self.assertEqual(secrets.get("GEMINI_API_KEY"), "from-env")
        with self.env():
            self.assertIsNone(secrets.get("NOPE"))

    def test_no_key_anywhere_is_a_clear_error(self):
        with mock.patch.dict(os.environ, {"AUDAY_SECRETS": str(self.file) + ".missing"}, clear=True):
            with self.assertRaises(ValueError):
                llm.GeminiProvider()


if __name__ == "__main__":
    unittest.main()
