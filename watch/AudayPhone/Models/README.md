# Bundled model files

- `silero_encoder_v5.onnx`, `silero_decoder_v5.onnx`: Silero VAD v5 (MIT, snakers4/silero-vad), the
  split files faster-whisper ships and app/transcribe.py uses.
- `sensevoice_cmvn.json`: the `neg_mean` / `inv_stddev` metadata of the SenseVoice Small int8 model
  (sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17). The model itself is downloaded on the iPhone.
