"""Settings secrets (AI and speech API keys, the workflow password) encrypted at rest.

Auday keeps its API key encrypted on the phone; the replica's iPhone app uses the Keychain. On the
Mac the settings live in auday.sqlite, so the secret fields are stored as AES-GCM ciphertext
("enc:v1:<base64 nonce+ciphertext>") and the 32-byte key sits next to the database in
secret.key (owner read/write only). A copied or exported database then carries no usable key.
"""

import base64
import os
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PREFIX = "enc:v1:"


class SecretBox:
    def __init__(self, data_dir):
        path = Path(data_dir) / "secret.key"
        if not path.exists():
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as out:
                out.write(AESGCM.generate_key(bit_length=256))
        self._aes = AESGCM(path.read_bytes())

    def seal(self, text):
        if not text or text.startswith(PREFIX):
            return text
        nonce = os.urandom(12)
        return PREFIX + base64.b64encode(nonce + self._aes.encrypt(nonce, text.encode(), b"auday-settings")).decode()

    def open(self, value):
        if not value or not value.startswith(PREFIX):
            return value            # plain value from before encryption; sealed on the next save
        raw = base64.b64decode(value[len(PREFIX):])
        return self._aes.decrypt(raw[:12], raw[12:], b"auday-settings").decode()
