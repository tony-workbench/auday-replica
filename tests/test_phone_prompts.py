"""The iPhone's AI pipeline must send the same prompts as app/auday_mode.py."""

import sys
import unittest
from pathlib import Path

from helpers import transcript  # noqa: F401  (adds the repo root to sys.path)

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import gen_phone_prompts  # noqa: E402


class PhonePromptTests(unittest.TestCase):
    def test_swift_prompts_are_up_to_date(self):
        self.assertEqual(gen_phone_prompts.TARGET.read_text(), gen_phone_prompts.render(),
                         "run: .venv/bin/python scripts/gen_phone_prompts.py")

    def test_swift_literal_keeps_the_text(self):
        text = 'Line one with "quotes" and \\ backslash.\n\nLine three.'
        literal = gen_phone_prompts.swift_string(text)
        body = literal.removeprefix('#"""\n').removesuffix('\n    """#')
        self.assertEqual("\n".join(line[4:] if line else "" for line in body.split("\n")), text)


if __name__ == "__main__":
    unittest.main()
