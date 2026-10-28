"""Owner voiceprint: enrol from a short clean reading, then label each transcript snippet.

Auday enrols the owner with "three readings, about 45 seconds" on the phone and labels its
snippets "Me" (the owner's speech) or "Me*" (includes the owner's voice and may include other
speakers); unlabelled snippets have no confirmed speaker. Its request to the model carries only
`"me": 1`, for both Me and Me*. See docs/AUDAY_OBSERVATIONS.md.

We embed audio with WeSpeaker ResNet34 trained on CN-Celeb (ONNX, CPU) and compare with the
enrolment centroid. Thresholds were fitted on 600+ snippets that Auday itself labelled: with
them our Me matched 7 of Auday's 13 Me (the 6 misses are near-silent or 1-2 s fragments) and
never fired on the 586 snippets Auday left unlabelled. Auday's Me* could not be reproduced from
voice scores (about half score like other speakers), so our Me* stays conservative.
The scores depend on the model and on the microphones (phone enrolment vs watch recording).
"""

import hashlib
import threading
from pathlib import Path

import numpy as np

from memengine import net

SR = 16000
MODEL_FILE = "cnceleb_resnet34_LM.onnx"
MODEL_URL = "https://huggingface.co/Wespeaker/wespeaker-cnceleb-resnet34-LM/resolve/main/" + MODEL_FILE
MODEL_SHA256 = "e7584940aeac8d5512d875e58ce6c09ba4ddad65d8128e1dac0d93aadd087ebb"

ME_SCORE = 0.42        # whole-snippet cosine to the enrolment centroid
# Me* ("contains the owner"). On Auday it appears only on long snippets (6-15 s, median 14 s) and its
# scores look like everyone else's: a long snippet gets many chances for one sub-window to resemble
# the owner, and most of its Me* were false (lectures during which the user was silent). The "auday" mode
# reproduces that rate and length profile; "improved" asks for a clearly owner-like window.
MIXED = {"auday": (0.395, 6.0), "improved": (0.45, 3.0)}   # (best 1.5 s window score, minimum seconds)
MIN_SECONDS = 3.0      # shorter snippets are never labelled
MIN_ENROL_SECONDS = 6.0
CALIBRATION_MARGIN = 0.10
ME_CAP = 0.60
VOICED_RMS = 0.01      # 100 ms frames quieter than this are not used for enrolment


def voiced_audio(audio):
    """The audio with its quiet 100 ms frames removed."""
    hop = SR // 10
    frames = [audio[i:i + hop] for i in range(0, len(audio) - hop + 1, hop)]
    keep = [f for f in frames if float(np.sqrt(np.mean(f ** 2))) >= VOICED_RMS]
    return np.concatenate(keep) if keep else np.zeros(0, dtype=np.float32)
WINDOW, HOP = 1.5, 0.75

_lock = threading.Lock()
_sessions = {}


def ensure_model(directory):
    """Download the speaker model once and verify its hash."""
    path = Path(directory) / "wespeaker" / MODEL_FILE
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        partial = path.with_suffix(".part")
        net.download(MODEL_URL, partial)
        digest = hashlib.sha256(partial.read_bytes()).hexdigest()
        if digest != MODEL_SHA256:
            partial.unlink()
            raise ValueError(f"The downloaded speaker model failed its hash check (got {digest}).")
        partial.rename(path)
    return path


def _session(model_path):
    with _lock:
        if model_path not in _sessions:
            import onnxruntime
            _sessions[model_path] = onnxruntime.InferenceSession(str(model_path))
        return _sessions[model_path]


def fbank(audio):
    """Kaldi-style 80-bin log mel filterbank (25 ms / 10 ms, povey window), mean-normalised."""
    x = audio.astype(np.float64) * 32768.0
    flen, shift, nfft = 400, 160, 512
    if len(x) < flen:
        return None
    n = 1 + (len(x) - flen) // shift
    frames = np.stack([x[i * shift:i * shift + flen] for i in range(n)])
    frames -= frames.mean(axis=1, keepdims=True)
    frames = np.concatenate([frames[:, :1], frames[:, 1:] - 0.97 * frames[:, :-1]], axis=1)
    frames *= np.power(0.5 - 0.5 * np.cos(2 * np.pi * np.arange(flen) / (flen - 1)), 0.85)
    power = np.abs(np.fft.rfft(frames, nfft)) ** 2
    mel = lambda f: 1127 * np.log(1 + f / 700.0)
    centers = np.linspace(mel(20), mel(SR / 2), 82)
    bins = mel(np.arange(nfft // 2 + 1) * SR / nfft)
    bank = np.zeros((80, nfft // 2 + 1))
    for m in range(80):
        low, mid, high = centers[m:m + 3]
        bank[m] = np.clip(np.minimum((bins - low) / (mid - low), (high - bins) / (high - mid)), 0, None)
    feats = np.log(np.maximum(power @ bank.T, np.finfo(float).eps))
    return (feats - feats.mean(axis=0)).astype(np.float32)


class Voiceprint:
    def __init__(self, model_path, centroid=None):
        self.model_path, self.centroid = str(model_path), centroid

    def embed(self, audio):
        feats = fbank(audio)
        if feats is None or len(feats) < 50:      # under ~0.5 s of audio
            return None
        vector = _session(self.model_path).run(None, {"feats": feats[None]})[0][0]
        return vector / np.linalg.norm(vector)

    def enroll(self, audio, part_seconds=15):
        """Average the embeddings of ~15 s parts (Auday: three readings, ~45 s). Quiet stretches are
        dropped first: pauses and near-silent clips pull every later score up (seen when enrolling
        from Auday's own owner labels, two of which were near-silent '.' snippets)."""
        voiced = voiced_audio(audio)
        if len(voiced) < MIN_ENROL_SECONDS * SR:
            raise ValueError(f"Need at least {MIN_ENROL_SECONDS:.0f} s of clear speech to enrol your voice.")
        step = int(part_seconds * SR)
        parts = [self.embed(voiced[i:i + step]) for i in range(0, max(1, len(voiced) - step // 3), step)]
        parts = [p for p in parts if p is not None]
        if not parts:
            raise ValueError("The enrolment recording is too short.")
        centroid = np.mean(parts, axis=0)
        self.centroid = centroid / np.linalg.norm(centroid)
        return self.centroid

    def save(self, path):
        np.save(path, self.centroid)

    @classmethod
    def load(cls, model_path, path):
        return cls(model_path, np.load(path))

    def score(self, audio):
        """(whole-snippet score, best window score) against the enrolment centroid."""
        whole = self.embed(audio)
        if whole is None:
            return None, None
        win, hop = int(WINDOW * SR), int(HOP * SR)
        windows = [self.embed(audio[i:i + win]) for i in range(0, max(1, len(audio) - hop), hop)]
        best = max((float(w @ self.centroid) for w in windows if w is not None), default=None)
        return float(whole @ self.centroid), best

    def label(self, audio, mode="auday", thresholds=None):
        """'Me', 'Me*' or None for one snippet of 16 kHz mono audio. `thresholds` ({"me", "mixed"})
        come from calibrate() on the owner's own archive; without them the defaults apply."""
        if self.centroid is None or len(audio) < MIN_SECONDS * SR:
            return None
        whole, best = self.score(audio)
        me_score = (thresholds or {}).get("me", ME_SCORE)
        if whole is not None and whole >= me_score:
            return "Me"
        threshold, seconds = MIXED.get(mode, MIXED["auday"])
        threshold = max(threshold, (thresholds or {}).get("mixed", threshold))
        if best is not None and best >= threshold and len(audio) >= seconds * SR:
            return "Me*"
        return None


def me_field(label, mode="auday"):
    """What the model is told. Auday sends me:1 for both Me and Me*; the improved mode keeps
    Me* distinct so mixed snippets are not read as the owner's own words."""
    if label == "Me" or (label == "Me*" and mode == "auday"):
        return 1
    if label == "Me*":
        return "mixed"
    return None


def calibrate(scores, mode="auday"):
    """Thresholds from the owner's own recordings. Most snippets in an all-day archive are other
    people, so the 90th percentile marks how close strangers get on this device (owner speech is
    usually under 10% of snippets and sits above it); the owner must clear it by a margin. Kept
    between the defaults and an upper cap. Same-device enrolment scores far higher than
    cross-device, which is why one fixed line cannot fit both (measured: same-device owner
    0.62-0.93, lecturer at most 0.49, 90th percentile 0.44; cross-device owner 0.50-0.57)."""
    wholes = sorted(w for w, _ in scores if w is not None)
    windows = sorted(b for _, b in scores if b is not None)
    if len(wholes) < 50:
        return {}
    quantile = lambda xs, q: xs[min(len(xs) - 1, int(q * len(xs)))]
    me = min(ME_CAP, max(ME_SCORE, quantile(wholes, 0.90) + CALIBRATION_MARGIN))
    mixed_default = MIXED.get(mode, MIXED["auday"])[0]
    mixed = min(me, max(mixed_default, quantile(windows, 0.90) + CALIBRATION_MARGIN / 2))
    return {"me": me, "mixed": mixed}
