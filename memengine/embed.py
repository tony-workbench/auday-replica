"""Embedders. Vectors are stored as float16 like the Auday desktop skill
(scripts/semantic_search.py: EmbeddingGemma 300M, 768-d, float16, cosine).

HashEmbedder is a dependency-free offline default (character n-grams, works for CJK).
It is lexical, not semantic: cross-language matches rely on the normalized English
`key` produced at extraction time. For real semantics, run EmbeddingGemma
behind an OpenAI-compatible /v1/embeddings server, e.g. llama.cpp's llama-server,
and use HTTPEmbedder.
"""

import hashlib
import json
import re
import urllib.request

import numpy as np

from . import net

_CJK = re.compile(r"[぀-ヿ㐀-鿿가-힯]")
_WORD = re.compile(r"[a-z0-9]+")


def features(text):
    text = text.lower()
    feats = []
    cjk = "".join(_CJK.findall(text))
    feats += [cjk[i:i + n] for n in (1, 2) for i in range(len(cjk) - n + 1)]
    words = _WORD.findall(text)
    feats += words + [a + " " + b for a, b in zip(words, words[1:])]
    return feats


class HashEmbedder:
    name = "hash-ngram-768"

    def __init__(self, dim=768):
        self.dim = dim

    def embed(self, texts):
        out = np.zeros((len(texts), self.dim), dtype=np.float32)
        for row, text in enumerate(texts):
            for feat in features(text):
                digest = hashlib.blake2b(feat.encode(), digest_size=8).digest()
                index = int.from_bytes(digest[:4], "little") % self.dim
                sign = 1.0 if digest[4] & 1 else -1.0
                out[row, index] += sign * (2.0 if " " in feat or len(feat) > 1 else 1.0)
        norms = np.linalg.norm(out, axis=1, keepdims=True)
        return out / np.where(norms == 0, 1, norms)


class HTTPEmbedder:
    """OpenAI-compatible embeddings endpoint (llama-server, Ollama, vLLM, OpenAI...)."""

    def __init__(self, url, model, api_key=None, timeout=60):
        self.url, self.model, self.api_key, self.timeout = url, model, api_key, timeout
        self.name = f"http:{model}"

    def embed(self, texts):
        body = json.dumps({"model": self.model, "input": list(texts)}).encode()
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        request = urllib.request.Request(self.url, body, headers)
        with net.urlopen(request, self.timeout) as response:
            data = json.load(response)["data"]
        vectors = np.array([item["embedding"] for item in sorted(data, key=lambda d: d["index"])],
                           dtype=np.float32)
        return vectors / np.linalg.norm(vectors, axis=1, keepdims=True)


def to_blob(vector):
    return np.asarray(vector, dtype=np.float16).tobytes()


def from_blob(blob):
    return np.frombuffer(blob, dtype=np.float16).astype(np.float32)


def lexical_overlap(query, text):
    """Share of the query's features that also appear in the text (0..1); used next to cosine."""
    q = set(features(query))
    return len(q & set(features(text))) / len(q) if q else 0.0
