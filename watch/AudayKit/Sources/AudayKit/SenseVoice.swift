import Accelerate
import Foundation

/// Auday's "Local efficient" transcription, SenseVoice Small, as the Mac runs it through sherpa-onnx
/// (app/transcribe.py): the front end (Kaldi fbank with a Hamming window, frame stacking, CMVN),
/// greedy CTC decoding, Silero VAD speech pieces and the 15 s snippets Auday stores. The ONNX
/// models run in the iPhone app; this part is plain Swift, tested on the Mac.
public enum SenseVoice {
    public static let sampleRate = 16000
    public static let featureSize = 560            // 80 mel bins × 7 stacked frames
    public static let maxSnippet = 15.0            // seconds, as Auday
    public static let mergeGap = 3.0               // app/transcribe.SV_MERGE_GAP
    /// Language ids in the model's metadata; 0 lets the model detect the language.
    public static let languageIDs = ["auto": 0, "zh": 3, "en": 4, "yue": 7, "ja": 11, "ko": 12]
    public static let withITN: Int32 = 14

    /// 80-bin log mel filterbank, 25 ms / 10 ms frames, Kaldi pre-emphasis, Hamming window,
    /// samples scaled to 16-bit range (the model's normalize_samples = 0). Row-major, frames × 80.
    public static func fbank(_ audio: [Float]) -> (values: [Float], frames: Int) {
        let flen = 400, shift = 160, nfft = 512, bins = nfft / 2 + 1
        guard audio.count >= flen else { return ([], 0) }
        let n = 1 + (audio.count - flen) / shift
        let window = (0..<flen).map { 0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(flen - 1)) }
        let bank = melBank(nfft: nfft)
        var out = [Float](repeating: 0, count: n * 80)
        var real = [Double](repeating: 0, count: nfft), imag = [Double](repeating: 0, count: nfft)
        var outReal = [Double](repeating: 0, count: nfft), outImag = [Double](repeating: 0, count: nfft)
        var power = [Double](repeating: 0, count: bins)
        let fft = vDSP.DFT(count: nfft, direction: .forward, transformType: .complexComplex, ofType: Double.self)!
        var frame = [Double](repeating: 0, count: flen)
        for f in 0..<n {
            var mean = 0.0
            for k in 0..<flen { frame[k] = Double(audio[f * shift + k]) * 32768; mean += frame[k] }
            mean /= Double(flen)
            for k in 0..<flen { frame[k] -= mean }
            // Kaldi: x[0] - 0.97 x[0], then x[k] - 0.97 x[k-1]
            real[0] = (frame[0] - 0.97 * frame[0]) * window[0]
            for k in 1..<flen { real[k] = (frame[k] - 0.97 * frame[k - 1]) * window[k] }
            for k in flen..<nfft { real[k] = 0 }
            for k in 0..<nfft { imag[k] = 0 }
            fft.transform(inputReal: real, inputImaginary: imag, outputReal: &outReal, outputImaginary: &outImag)
            for k in 0..<bins { power[k] = outReal[k] * outReal[k] + outImag[k] * outImag[k] }
            for m in 0..<80 {
                var energy = 0.0
                for (k, w) in bank[m] { energy += power[k] * w }
                out[f * 80 + m] = Float(log(max(energy, Double(Float.ulpOfOne))))
            }
        }
        return (out, n)
    }

    /// Stacks 7 frames every 6 (no padding, as sherpa-onnx) and applies the model's CMVN.
    public static func features(_ audio: [Float], negMean: [Float], invStd: [Float]) -> (values: [Float], frames: Int) {
        let (fb, n) = fbank(audio)
        let m = 7, step = 6
        guard n >= m else { return ([], 0) }
        let frames = (n - m) / step + 1
        var out = [Float](repeating: 0, count: frames * featureSize)
        for i in 0..<frames {
            let src = i * step * 80
            for j in 0..<featureSize {
                out[i * featureSize + j] = (fb[src + j] + negMean[j]) * invStd[j]
            }
        }
        return (out, frames)
    }

    /// Greedy CTC over logits (frames × vocab, row-major). The first four frames carry the
    /// language, emotion, event and text-normalisation tags; the rest is the text.
    public static func decode(_ logits: [Float], frames: Int, vocab: Int, tokens: [String])
        -> (text: String, language: String, emotion: String, event: String) {
        var ids = [Int](repeating: 0, count: frames)
        logits.withUnsafeBufferPointer { p in
            for t in 0..<frames {
                var best: Float = 0
                var index: vDSP_Length = 0
                vDSP_maxvi(p.baseAddress! + t * vocab, 1, &best, &index, vDSP_Length(vocab))
                ids[t] = Int(index)
            }
        }
        func tag(_ i: Int) -> String { ids.indices.contains(i) && tokens.indices.contains(ids[i]) ? tokens[ids[i]] : "" }
        var pieces: [String] = []
        var previous = -1
        for id in ids.dropFirst(4) {
            if id != previous && id != 0 && tokens.indices.contains(id) { pieces.append(tokens[id]) }
            previous = id
        }
        let text = pieces.joined().replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
        return (text, tag(0), tag(1), tag(2))
    }

    /// Silero speech pieces from per-512-sample probabilities, as faster-whisper's
    /// get_speech_timestamps with app/transcribe.SV_VAD (threshold 0.35, 1000 ms silence, 400 ms pad).
    public static func speech(probabilities: [Float], length: Int, threshold: Float = 0.35,
                              minSilenceMs: Int = 1000, padMs: Int = 400) -> [(Int, Int)] {
        let window = 512
        let negThreshold = max(threshold - 0.15, 0.01)
        let minSilence = sampleRate * minSilenceMs / 1000
        let pad = sampleRate * padMs / 1000
        var speeches: [(Int, Int)] = []
        var triggered = false
        var start = 0, tempEnd = 0
        for (i, p) in probabilities.enumerated() {
            let at = window * i
            if p >= threshold && tempEnd != 0 { tempEnd = 0 }
            if p >= threshold && !triggered { triggered = true; start = at; continue }
            if p < negThreshold && triggered {
                if tempEnd == 0 { tempEnd = at }
                if at - tempEnd < minSilence { continue }
                if tempEnd - start > 0 { speeches.append((start, tempEnd)) }
                triggered = false
                tempEnd = 0
            }
        }
        if triggered && length - start > 0 { speeches.append((start, length)) }
        for i in speeches.indices {
            if i == 0 { speeches[i].0 = max(0, speeches[i].0 - pad) }
            if i != speeches.count - 1 {
                let silence = speeches[i + 1].0 - speeches[i].1
                if silence < 2 * pad {
                    speeches[i].1 += silence / 2
                    speeches[i + 1].0 = max(0, speeches[i + 1].0 - silence / 2)
                } else {
                    speeches[i].1 = min(length, speeches[i].1 + pad)
                    speeches[i + 1].0 = max(0, speeches[i + 1].0 - pad)
                }
            } else {
                speeches[i].1 = min(length, speeches[i].1 + pad)
            }
        }
        return speeches
    }

    /// Speech pieces merged into Auday-like snippets: joined across pauses up to `mergeGap`
    /// while the snippet stays within 15 s; longer speech is split into 15 s parts.
    public static func snippets(_ pieces: [(Int, Int)]) -> [(Int, Int)] {
        let maxLen = Int(maxSnippet * Double(sampleRate)), gap = Int(mergeGap * Double(sampleRate))
        var out: [(Int, Int)] = []
        for (s, e) in pieces {
            var start = s
            while e - start > maxLen { out.append((start, start + maxLen)); start += maxLen }
            if let last = out.last, start - last.1 <= gap, e - last.0 <= maxLen {
                out[out.count - 1].1 = e
            } else {
                out.append((start, e))
            }
        }
        return out
    }

    /// A snippet worth keeping: not empty and not only punctuation.
    public static func keeps(_ text: String) -> Bool {
        !text.isEmpty && !text.allSatisfy { "。，,.?？!！ ".contains($0) }
    }

    private static func melBank(nfft: Int) -> [[(Int, Double)]] {
        func mel(_ f: Double) -> Double { 1127 * log(1 + f / 700) }
        let low = mel(20), high = mel(Double(sampleRate) / 2)
        let centers = (0..<82).map { low + (high - low) * Double($0) / 81 }
        let bins = (0...(nfft / 2)).map { mel(Double($0) * Double(sampleRate) / Double(nfft)) }
        return (0..<80).map { m in
            let (l, c, h) = (centers[m], centers[m + 1], centers[m + 2])
            return bins.enumerated().compactMap { k, b in
                let w = max(0, min((b - l) / (c - l), (h - b) / (h - c)))
                return w > 0 ? (k, w) : nil
            }
        }
    }
}
