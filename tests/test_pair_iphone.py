"""The Mac side of Connect to your Mac: the upload token it hands the iPhone."""

import os
import stat
import tempfile
import unittest

from helpers import transcript  # noqa: F401  (adds the repo root to sys.path)

from app import pair_iphone


class PairIphoneTests(unittest.TestCase):
    def test_token_is_made_once_and_kept_private(self):
        with tempfile.TemporaryDirectory() as folder:
            token = pair_iphone.load_token(folder)
            self.assertEqual(len(token), 32)
            self.assertEqual(pair_iphone.load_token(folder), token)
            mode = os.stat(os.path.join(folder, "lan-token")).st_mode
            self.assertEqual(stat.S_IMODE(mode), 0o600)

    def test_errors_are_explained(self):
        for code in ("awaiting_phone_or_wrong_password", "mac_unreachable", "token_refused"):
            self.assertIn(code, pair_iphone.ERRORS)


if __name__ == "__main__":
    unittest.main()
