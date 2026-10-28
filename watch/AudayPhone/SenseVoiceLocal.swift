import AudayKit
import CryptoKit
import Foundation
import Observation
import OnnxRuntimeBindings

/// Auday's "Local efficient" transcription: SenseVoice Small (int8) on this iPhone, the same model
/// and front end the Mac runs (app/transcribe.py). Silero VAD finds speech, speech is cut into
/// Auday-like snippets of at most 15 s, and each snippet is decoded on its own. The model (about
/// 240 MB) is downloaded once and hash-checked; the VAD ships with the app.
@MainActor @Observable
final class SenseVoiceLocal {
    static let sizeLabel = "about 240 MB"
    private static let base = URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/")!
    private static let files = [("model.int8.onnx", "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"),
                                ("tokens.txt", "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc")]
    nonisolated static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sensevoice")

    private(set) var downloading: Double?
    private(set) var problem: String?

    nonisolated static var ready: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.0).path) }
    }
    var ready: Bool { Self.ready }

    /// Downloads the model and its tokens once, checking each file's SHA-256. `wifiOnly` is for
    /// the automatic start, so 240 MB never goes over mobile data unasked.
    func download(wifiOnly: Bool = false) async {
        guard downloading == nil, !Self.ready else { return }
        problem = nil
        downloading = 0
        defer { downloading = nil }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            for (index, (name, sha)) in Self.files.enumerated() {
                let target = Self.folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) { continue }
                let config = URLSessionConfiguration.default
                config.allowsExpensiveNetworkAccess = !wifiOnly
                config.allowsConstrainedNetworkAccess = !wifiOnly
                let (temp, _) = try await URLSession(configuration: config).download(from: Self.base.appendingPathComponent(name),
                                                                      delegate: Progress(index: index) { [weak self] p in
                    Task { @MainActor in self?.downloading = p }
                })
                let digest = try SHA256.hash(data: Data(contentsOf: temp, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
                guard digest == sha else { try? FileManager.default.removeItem(at: temp); throw Failure.hash }
                try FileManager.default.moveItem(at: temp, to: target)
            }
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
            problem = "No internet connection. SenseVoice (\(Self.sizeLabel)) needs a one-time download; connect and try again."
        } catch {
            problem = error.localizedDescription
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.folder)
    }

    enum Failure: LocalizedError {
        case hash, model
        var errorDescription: String? {
            switch self {
            case .hash: "The downloaded SenseVoice model did not match its checksum. Try again."
            case .model: "The SenseVoice model could not be loaded."
            }
        }
    }

    /// Download progress for the big model file (the tokens file is tiny).
    private final class Progress: NSObject, URLSessionDownloadDelegate {
        let index: Int
        let report: (Double) -> Void
        init(index: Int, report: @escaping (Double) -> Void) { self.index = index; self.report = report }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard index == 0, totalBytesExpectedToWrite > 0 else { return }
            report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }
}

/// Runs Silero VAD and SenseVoice. Not tied to the main actor; make one per batch of work.
final class SenseVoiceRunner {
    private static let env = try? ORTEnv(loggingLevel: .warning)
    private let model: ORTSession
    private let vadEncoder: ORTSession
    private let vadDecoder: ORTSession
    private let tokens: [String]
    private let negMean: [Float]
    private let invStd: [Float]

    init() throws {
        guard let env = Self.env,
              let encoder = Bundle.main.path(forResource: "silero_encoder_v5", ofType: "onnx"),
              let decoder = Bundle.main.path(forResource: "silero_decoder_v5", ofType: "onnx"),
              let cmvnURL = Bundle.main.url(forResource: "sensevoice_cmvn", withExtension: "json") else { throw SenseVoiceLocal.Failure.model }
        model = try ORTSession(env: env, modelPath: SenseVoiceLocal.folder.appendingPathComponent("model.int8.onnx").path, sessionOptions: nil)
        vadEncoder = try ORTSession(env: env, modelPath: encoder, sessionOptions: nil)
        vadDecoder = try ORTSession(env: env, modelPath: decoder, sessionOptions: nil)
        let text = try String(contentsOf: SenseVoiceLocal.folder.appendingPathComponent("tokens.txt"), encoding: .utf8)
        tokens = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: " ").dropLast().joined(separator: " ")
        }
        let cmvn = try JSONDecoder().decode([String: [Float]].self, from: Data(contentsOf: cmvnURL))
        negMean = cmvn["neg_mean"] ?? []
        invStd = cmvn["inv_stddev"] ?? []
    }

    /// One recording as Auday-like snippets (seconds from its start).
    func transcribe(_ url: URL) throws -> (segments: [Segment], language: String?) {
        let audio = try Embedder.load16k(url)
        let sr = SenseVoice.sampleRate
        // Silero runs in 30 s windows, as the Mac does (VAD_WINDOW): a whole-hour pass adapts to steady noise.
        var pieces: [(Int, Int)] = []
        let step = 30 * sr
        var offset = 0
        while offset < audio.count {
            let window = Array(audio[offset..<min(audio.count, offset + step)])
            let probs = try speechProbabilities(window)
            pieces += SenseVoice.speech(probabilities: probs, length: window.count).map { ($0.0 + offset, $0.1 + offset) }
            offset += step
        }
        var out: [Segment] = []
        var languages: [String: Int] = [:]
        for (start, end) in SenseVoice.snippets(pieces) {
            let (text, language) = try decode(Array(audio[start..<end]))
            if SenseVoice.keeps(text) {
                out.append(Segment(start: Double(start) / Double(sr), end: Double(end) / Double(sr), text: text))
                languages[language, default: 0] += 1
            }
        }
        return (out, languages.max { $0.value < $1.value }?.key)
    }

    private func decode(_ audio: [Float]) throws -> (String, String) {
        var (x, frames) = SenseVoice.features(audio, negMean: negMean, invStd: invStd)
        guard frames > 0 else { return ("", "") }
        let input = try ORTValue(tensorData: NSMutableData(bytes: &x, length: x.count * 4), elementType: .float,
                                 shape: [1, NSNumber(value: frames), NSNumber(value: SenseVoice.featureSize)])
        var length = Int32(frames), language = Int32(0), itn = SenseVoice.withITN
        func scalar(_ v: inout Int32) throws -> ORTValue {
            try ORTValue(tensorData: NSMutableData(bytes: &v, length: 4), elementType: .int32, shape: [1])
        }
        let outputs = try model.run(withInputs: ["x": input, "x_length": try scalar(&length),
                                                  "language": try scalar(&language), "text_norm": try scalar(&itn)],
                                    outputNames: ["logits"], runOptions: nil)
        guard let value = outputs["logits"] else { return ("", "") }
        let shape = try value.tensorTypeAndShapeInfo().shape.map(\.intValue)
        let raw = try value.tensorData() as Data
        let logits = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let r = SenseVoice.decode(logits, frames: shape[1], vocab: shape[2], tokens: tokens)
        return (r.text, r.language.trimmingCharacters(in: CharacterSet(charactersIn: "<|>")))
    }

    /// Silero v5 speech probability per 512 samples (faster-whisper's SileroVADModel): each chunk
    /// carries the previous chunk's last 64 samples as context; the decoder keeps a running state.
    private func speechProbabilities(_ audio: [Float]) throws -> [Float] {
        let chunk = 512, context = 64
        let padded = audio + [Float](repeating: 0, count: chunk - audio.count % chunk)
        let count = padded.count / chunk
        var batch = [Float](repeating: 0, count: count * (chunk + context))
        for i in 0..<count {
            let row = i * (chunk + context)
            if i > 0 {          // the previous chunk's last 64 samples; the first chunk gets zeros
                for k in 0..<context { batch[row + k] = padded[i * chunk - context + k] }
            }
            for k in 0..<chunk { batch[row + context + k] = padded[i * chunk + k] }
        }
        let input = try ORTValue(tensorData: NSMutableData(bytes: &batch, length: batch.count * 4), elementType: .float,
                                 shape: [NSNumber(value: count), NSNumber(value: chunk + context)])
        let encoderOut = try vadEncoder.outputNames().first ?? "90"
        let encoded = try vadEncoder.run(withInputs: ["input": input], outputNames: [encoderOut], runOptions: nil)
        guard let encodedValue = encoded[encoderOut] else { return [] }
        let features = (try encodedValue.tensorData() as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let names = try vadDecoder.outputNames()
        let probName = names.first { $0 == "38" } ?? names[0], stateName = names.first { $0 == "35" } ?? names[1]
        var state = [Float](repeating: 0, count: 2 * 128)
        var probs: [Float] = []
        probs.reserveCapacity(count)
        for i in 0..<count {
            var window = Array(features[(i * 128)..<((i + 1) * 128)])
            let w = try ORTValue(tensorData: NSMutableData(bytes: &window, length: 128 * 4), elementType: .float, shape: [1, 128])
            let s = try ORTValue(tensorData: NSMutableData(bytes: &state, length: state.count * 4), elementType: .float, shape: [2, 1, 128])
            let out = try vadDecoder.run(withInputs: ["input": w, "state": s], outputNames: [probName, stateName], runOptions: nil)
            guard let p = out[probName], let next = out[stateName] else { break }
            probs.append((try p.tensorData() as Data).withUnsafeBytes { $0.bindMemory(to: Float.self)[0] })
            state = (try next.tensorData() as Data).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        return probs
    }
}
