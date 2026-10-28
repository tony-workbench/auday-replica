"""Replaceable LLM providers (stdlib HTTP only) plus a replay cassette for tests/evals.

Every provider implements complete(system, user) -> Completion. Callers parse JSON;
`complete_json` retries once with the validation error appended.
"""

import hashlib
import json
import os
import re
import urllib.request
from dataclasses import dataclass

import jsonschema

from . import net, secrets

_CJK = re.compile(r"[぀-ヿ㐀-鿿가-힯]")


def estimate_tokens(text):
    """Rough count: ~1 token per CJK character, ~4 characters per token otherwise."""
    cjk = len(_CJK.findall(text))
    return cjk + (len(text) - cjk + 3) // 4


@dataclass
class Completion:
    text: str
    input_tokens: int
    output_tokens: int
    estimated: bool = False


class Usage:
    def __init__(self):
        self.calls = self.input_tokens = self.output_tokens = 0
        self.estimated = False

    def add(self, completion):
        self.calls += 1
        self.input_tokens += completion.input_tokens
        self.output_tokens += completion.output_tokens
        self.estimated |= completion.estimated

    def as_dict(self):
        return {"calls": self.calls, "input_tokens": self.input_tokens,
                "output_tokens": self.output_tokens, "estimated": self.estimated}


def _post(url, body, headers, timeout=120):
    request = urllib.request.Request(url, json.dumps(body).encode(),
                                     {"Content-Type": "application/json", **headers})
    with net.urlopen(request, timeout) as response:
        return json.load(response)


def _get(url, headers, timeout=30):
    request = urllib.request.Request(url, headers={"User-Agent": "auday-replica", **headers})
    with net.urlopen(request, timeout) as response:
        return json.load(response)


def list_models(provider, *, base_url="", api_key=""):
    """Model IDs the configured service offers."""
    if provider == "gemini":
        data = _get("https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000",
                    {"x-goog-api-key": api_key})
        return sorted(m["name"].removeprefix("models/") for m in data.get("models", [])
                      if "generateContent" in m.get("supportedGenerationMethods", ["generateContent"]))
    if provider == "anthropic":
        base = (base_url if "anthropic" in base_url else "https://api.anthropic.com").rstrip("/")
        data = _get(f"{base}/v1/models", {"x-api-key": api_key, "anthropic-version": "2023-06-01"})
        return sorted(m["id"] for m in data.get("data", []))
    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    data = _get(base_url.rstrip("/") + "/models", headers)
    return sorted(m["id"] for m in data.get("data", []))


class AnthropicProvider:
    def __init__(self, model="claude-haiku-5-5", api_key=None, base_url=None, max_tokens=2048):
        self.model, self.max_tokens = model, max_tokens
        self.api_key = api_key or os.environ["ANTHROPIC_API_KEY"]
        self.base_url = (base_url or os.environ.get("ANTHROPIC_BASE_URL") or "https://api.anthropic.com").rstrip("/")

    def complete(self, system, user):
        data = _post(f"{self.base_url}/v1/messages",
                     {"model": self.model, "max_tokens": self.max_tokens, "temperature": 0,
                      "system": system, "messages": [{"role": "user", "content": user}]},
                     {"x-api-key": self.api_key, "anthropic-version": "2023-06-01"})
        text = "".join(block.get("text", "") for block in data["content"])
        return Completion(text, data["usage"]["input_tokens"], data["usage"]["output_tokens"])


class OpenAICompatibleProvider:
    """OpenAI, Ollama, llama.cpp server, vLLM, DeepSeek, Qwen... (chat/completions)."""

    def __init__(self, model, base_url="https://api.openai.com/v1", api_key=None,
                 system_prefix="", max_tokens=1500, timeout=300):
        self.model, self.base_url = model, base_url.rstrip("/")
        self.api_key = api_key or os.environ.get("OPENAI_API_KEY", "")
        # e.g. "/no_think\n" turns off SmolLM3 / Qwen3 reasoning traces.
        self.system_prefix, self.max_tokens, self.timeout = system_prefix, max_tokens, timeout

    def complete(self, system, user):
        data = _post(f"{self.base_url}/chat/completions",
                     {"model": self.model, "temperature": 0, "max_tokens": self.max_tokens,
                      "response_format": {"type": "json_object"},
                      "messages": [{"role": "system", "content": self.system_prefix + system},
                                   {"role": "user", "content": user}]},
                     {"Authorization": f"Bearer {self.api_key}"} if self.api_key else {},
                     timeout=self.timeout)
        usage = data.get("usage") or {}
        return Completion(data["choices"][0]["message"]["content"],
                          usage.get("prompt_tokens", 0), usage.get("completion_tokens", 0))


class GeminiProvider:
    def __init__(self, model="gemini-2.5-flash", api_key=None, temperature=0):
        self.model, self.api_key = model, api_key or secrets.get("GEMINI_API_KEY")
        if not self.api_key:
            raise ValueError("No Gemini API key: set it in Settings or in " + str(secrets.env_file()))
        self.temperature = temperature   # None = provider default (Auday sends no temperature)

    def complete(self, system, user):
        url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent"
        data = _post(url, {"systemInstruction": {"parts": [{"text": system}]},
                           "contents": [{"role": "user", "parts": [{"text": user}]}],
                           "generationConfig": {"responseMimeType": "application/json",
                                                **({} if self.temperature is None
                                                   else {"temperature": self.temperature})}},
                     {"x-goog-api-key": self.api_key})
        text = "".join(p.get("text", "") for p in data["candidates"][0]["content"]["parts"])
        usage = data.get("usageMetadata", {})
        return Completion(text, usage.get("promptTokenCount", 0), usage.get("candidatesTokenCount", 0))


class PendingResponse(Exception):
    """Raised by ReplayProvider when the cassette lacks an answer for a prompt."""


def prompt_key(system, user):
    return hashlib.sha256(f"{system}\n\x00\n{user}".encode()).hexdigest()[:24]


class ReplayProvider:
    """Answers from a JSON cassette {key: response_text}. An unknown prompt is added to
    `pending` (if given) and raises PendingResponse, so it can be answered later and the
    answer merged into the cassette."""

    def __init__(self, cassette_path, pending=None):
        self.cassette_path = cassette_path
        self.cassette = {}
        if os.path.exists(cassette_path):
            with open(cassette_path, encoding="utf-8") as handle:
                self.cassette = json.load(handle)
        self.pending = pending if pending is not None else None

    def complete(self, system, user):
        key = prompt_key(system, user)
        if key not in self.cassette:
            if self.pending is not None:
                self.pending[key] = {"system": system, "user": user}
            raise PendingResponse(key)
        text = self.cassette[key]
        return Completion(text, estimate_tokens(system) + estimate_tokens(user),
                          estimate_tokens(text), estimated=True)


class ScriptedProvider:
    """Deterministic test double: a function (system, user) -> response text."""

    def __init__(self, fn):
        self.fn = fn
        self.calls = []

    def complete(self, system, user):
        self.calls.append((system, user))
        text = self.fn(system, user)
        if not isinstance(text, str):
            text = json.dumps(text, ensure_ascii=False)
        return Completion(text, estimate_tokens(system) + estimate_tokens(user),
                          estimate_tokens(text), estimated=True)


def parse_json(text):
    text = text.strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.S)
    if fence:
        text = fence.group(1).strip()
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < start:
        raise ValueError("no JSON object in model output")
    return json.loads(text[start:end + 1])


def complete_json(provider, system, user, schema, usage=None, retries=1):
    """Call the model, parse and validate JSON. Retries with the error message appended."""
    prompt = user
    for attempt in range(retries + 1):
        completion = provider.complete(system, prompt)
        if usage is not None:
            usage.add(completion)
        try:
            value = parse_json(completion.text)
            jsonschema.validate(value, schema)
            return value
        except (ValueError, jsonschema.ValidationError) as error:
            if attempt == retries:
                raise
            message = getattr(error, "message", str(error))
            prompt = (f"{user}\n\nYour previous reply was invalid ({message[:300]}). "
                      "Reply again with ONLY one JSON object that matches the schema.")
