import Accelerate
import Foundation

/// My voice recognition, the iPhone half of app/speaker.py: same features, enrolment rules and
/// Me / Me* thresholds, so both sides label a snippet alike. The embedding (WeSpeaker ResNet34
/// CN-Celeb) runs in the iPhone app.
public enum Voice {
    public static let sampleRate = 16000
    public static let modelFile = "cnceleb_resnet34_LM.onnx"
    public static let modelURL = URL(string: "https://huggingface.co/Wespeaker/wespeaker-cnceleb-resnet34-LM/resolve/main/" + modelFile)!
    public static let modelSHA256 = "e7584940aeac8d5512d875e58ce6c09ba4ddad65d8128e1dac0d93aadd087ebb"

    public static let meScore = 0.42
    /// The Mac uses (0.395, 6 s) (speaker.MIXED["auday"]). The phone uses 3 s: in real recordings
    /// many of the owner's short lines lasted 4-5 s, and at 3 s no one else's lines were added.
    public static let mixed = (score: 0.395, seconds: 3.0)
    public static let minSeconds = 3.0
    public static let minEnrolSeconds = 6.0
    public static let calibrationMargin = 0.10
    public static let meCap = 0.60
    public static let voicedRMS: Float = 0.01
    /// Enrolment keeps quieter frames too. Measured on a real phone and watch: 0.01 kept 14 of 45 s
    /// and 0.003 kept 29 s, raising the owner's watch speech score from 0.40 to 0.51.
    public static let enrolVoicedRMS: Float = 0.003
    public static let window = 1.5, hop = 0.75

    /// The audio without its quiet 100 ms frames (speaker.voiced_audio).
    public static func voiced(_ audio: [Float], rms: Float = voicedRMS) -> [Float] {
        let frame = sampleRate / 10
        var out: [Float] = []
        var i = 0
        while i + frame <= audio.count {
            let slice = Array(audio[i..<i + frame])
            var ms: Float = 0
            vDSP_measqv(slice, 1, &ms, vDSP_Length(frame))
            if sqrt(ms) >= rms { out += slice }
            i += frame
        }
        return out
    }

    /// Kaldi-style 80-bin log mel filterbank, 25 ms / 10 ms, povey window, mean-normalised
    /// (speaker.fbank). Rows are frames. nil under 25 ms of audio.
    public static func fbank(_ audio: [Float]) -> [[Float]]? {
        let flen = 400, shift = 160, nfft = 512, bins = nfft / 2 + 1
        guard audio.count >= flen else { return nil }
        let n = 1 + (audio.count - flen) / shift
        let window = (0..<flen).map { pow(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(flen - 1)), 0.85) }
        let bank = melBank(nfft: nfft)
        var feats = [[Float]](repeating: [Float](repeating: 0, count: 80), count: n)
        var real = [Double](repeating: 0, count: nfft), imag = [Double](repeating: 0, count: nfft)
        var power = [Double](repeating: 0, count: bins)
        let fft = vDSP.DFT(count: nfft, direction: .forward, transformType: .complexComplex, ofType: Double.self)!
        for f in 0..<n {
            var frame = (0..<flen).map { Double(audio[f * shift + $0]) * 32768 }
            let mean = frame.reduce(0, +) / Double(flen)
            frame = frame.map { $0 - mean }
            var emphasized = frame
            for k in stride(from: flen - 1, to: 0, by: -1) { emphasized[k] = frame[k] - 0.97 * frame[k - 1] }
            for k in 0..<nfft { real[k] = k < flen ? emphasized[k] * window[k] : 0; imag[k] = 0 }
            var outReal = [Double](repeating: 0, count: nfft), outImag = [Double](repeating: 0, count: nfft)
            fft.transform(inputReal: real, inputImaginary: imag, outputReal: &outReal, outputImaginary: &outImag)
            for k in 0..<bins { power[k] = outReal[k] * outReal[k] + outImag[k] * outImag[k] }
            for m in 0..<80 {
                var energy = 0.0
                for (k, w) in bank[m] { energy += power[k] * w }
                feats[f][m] = Float(log(max(energy, Double.ulpOfOne)))
            }
        }
        for m in 0..<80 {
            let mean = feats.reduce(0) { $0 + $1[m] } / Float(n)
            for f in 0..<n { feats[f][m] -= mean }
        }
        return feats
    }

    /// Per mel filter, its non-zero (bin, weight) pairs.
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

    /// Cosine of two unit vectors.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return Double(dot)
    }

    public static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        return norm > 0 ? v.map { $0 / norm } : v
    }

    public struct Thresholds: Codable, Equatable, Sendable {
        public var me: Double
        public var mixed: Double
        public init(me: Double, mixed: Double) { self.me = me; self.mixed = mixed }
    }

    /// "Me", "Me*" or nil (speaker.Voiceprint.label, auday mode).
    public static func label(whole: Double?, best: Double?, seconds: Double, thresholds: Thresholds? = nil) -> String? {
        guard seconds >= minSeconds else { return nil }
        if let whole, whole >= (thresholds?.me ?? meScore) { return "Me" }
        let threshold = max(mixed.score, thresholds?.mixed ?? mixed.score)
        // Me*: part of it is the owner (a window), or all of it nearly reaches Me.
        if seconds >= mixed.seconds, (best ?? -1) >= threshold || (whole ?? -1) >= threshold { return "Me*" }
        return nil
    }

    /// A snippet in the middle of the owner's own conversation: at least 3 s, a score of at least
    /// 0.30, and within 90 s of a snippet already labelled (labels chain). In real recordings the
    /// owner's lines between labelled ones scored 0.25-0.38 while other speakers stayed lower, and
    /// at a floor of 0.30 none of 410 lines by others was pulled in.
    public static let context = (score: 0.30, seconds: 3.0, within: 90.0)

    /// Labels after the context pass: unlabelled snippets near labelled ones become Me*.
    public static func extendByContext(_ snippets: [(start: Double, seconds: Double, whole: Double?, label: String?)]) -> [String?] {
        var labels = snippets.map(\.label)
        var changed = true
        while changed {
            changed = false
            let anchors = snippets.indices.filter { labels[$0] != nil }.map { snippets[$0].start }
            for i in snippets.indices where labels[i] == nil {
                let s = snippets[i]
                guard s.seconds >= context.seconds, let whole = s.whole, whole >= context.score,
                      anchors.contains(where: { abs($0 - s.start) <= context.within }) else { continue }
                labels[i] = "Me*"
                changed = true
            }
        }
        return labels
    }

    /// Thresholds from the owner's own archive once there are 50 scored snippets (speaker.calibrate).
    public static func calibrate(_ scores: [(whole: Double?, best: Double?)]) -> Thresholds? {
        let wholes = scores.compactMap(\.whole).sorted(), windows = scores.compactMap(\.best).sorted()
        guard wholes.count >= 50 else { return nil }
        func quantile(_ xs: [Double], _ q: Double) -> Double { xs[min(xs.count - 1, Int(q * Double(xs.count)))] }
        let me = min(meCap, max(meScore, quantile(wholes, 0.90) + calibrationMargin))
        let mixedT = windows.isEmpty ? mixed.score : min(me, max(mixed.score, quantile(windows, 0.90) + calibrationMargin / 2))
        return Thresholds(me: me, mixed: mixedT)
    }
}
