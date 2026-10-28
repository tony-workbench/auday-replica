"""Auday's third transcription mode, "Cloud & self-hosted": your own API key, or a speech service
on your network. Two wire formats cover it:

- "openai": POST {base}/audio/transcriptions (multipart, response_format=verbose_json). OpenAI,
  Groq and most self-hosted Whisper servers (faster-whisper-server, whisper.cpp server, LocalAI)
  speak it; DashScope's OpenAI-compatible mode serves Qwen's ASR models.
- "deepgram": POST https://api.deepgram.com/v1/listen with the raw audio. Auday suggests Nova-3
  for mixed languages other than Chinese (language=multi).

Results come back as timed segments; long ones are split to Auday's 15 s snippets on word
boundaries where the service gives word times. Only the audio of this recording is sent.
"""

import json
import uuid
import urllib.request

from memengine import net

MAX_SNIPPET = 15.0


def _post(url, body, headers, timeout=600):
    request = urllib.request.Request(url, data=body, headers={"User-Agent": "auday-replica", **headers})
    with net.urlopen(request, timeout) as response:
        return json.loads(response.read())


def multipart(fields, file_field, filename, data, mime="audio/wav"):
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'
                 f"Content-Type: {mime}\r\n\r\n".encode() + data + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def split_words(words, start_key="start", end_key="end", text_key="word"):
    """[{start, end, word}] -> <=15 s snippets cut between words."""
    out, current = [], []
    for word in words:
        if current and word[end_key] - current[0][start_key] > MAX_SNIPPET:
            out.append(current)
            current = []
        current.append(word)
    if current:
        out.append(current)
    joiner = lambda ws: "".join(w[text_key] if not w[text_key][:1].isascii() else " " + w[text_key] for w in ws)
    return [{"start": round(ws[0][start_key], 2), "end": round(ws[-1][end_key], 2), "text": joiner(ws).strip()}
            for ws in out]


def parse_openai(data):
    """verbose_json -> (language, snippets)."""
    segments = data.get("segments") or [{"start": 0, "end": data.get("duration", 0), "text": data.get("text", "")}]
    out = []
    for seg in segments:
        text = seg.get("text", "").strip()
        if not text:
            continue
        out.append({"start": round(seg["start"], 2), "end": round(seg["end"], 2), "text": text})
    return data.get("language") or "unknown", out


def parse_deepgram(data):
    """Deepgram /v1/listen with utterances=true -> (language, snippets)."""
    results = data.get("results", {})
    out = []
    for utt in results.get("utterances") or []:
        words = utt.get("words") or []
        if words and utt["end"] - utt["start"] > MAX_SNIPPET:
            out += split_words(words, text_key="punctuated_word" if "punctuated_word" in words[0] else "word")
        elif utt.get("transcript", "").strip():
            out.append({"start": round(utt["start"], 2), "end": round(utt["end"], 2), "text": utt["transcript"].strip()})
    channel = (results.get("channels") or [{}])[0]
    return channel.get("detected_language") or "unknown", out


def transcribe(wav_path, *, kind, base_url, api_key, model, language=None):
    data = open(wav_path, "rb").read()
    if kind == "deepgram":
        query = f"model={model or 'nova-3'}&smart_format=true&utterances=true&language={language or 'multi'}"
        url = (base_url.rstrip("/") or "https://api.deepgram.com/v1") + "/listen?" + query
        return parse_deepgram(_post(url, data, {"Authorization": f"Token {api_key}", "Content-Type": "audio/wav"}))
    fields = {"model": model or "whisper-1", "response_format": "verbose_json"}
    if language:
        fields["language"] = language
    body, content_type = multipart(fields, "file", "audio.wav", data)
    headers = {"Content-Type": content_type}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    return parse_openai(_post(base_url.rstrip("/") + "/audio/transcriptions", body, headers))
