import AudayKit
import AVFoundation
import CryptoKit
import Foundation
import Observation
import OnnxRuntimeBindings

/// My voice recognition on the iPhone, as app/speaker.py does it on the Mac: the WeSpeaker
/// ResNet34 CN-Celeb model (downloaded once, hash-checked) embeds 16 kHz audio; the enrolment
/// centroid comes from three readings; each transcript snippet is labelled Me, Me* or nothing.
@MainActor @Observable
final class VoiceModel {
    struct Saved: Codable {
        var centroid: [Float]
        var enrolledAt: Date
        var thresholds: Voice.Thresholds?
        /// Learned from readings passed through the watch's codec (see enroll).
        var watchCodec: Bool? = nil
        /// The enrolment the archive was last fully scored against; a relabel cut short (the app
        /// reinstalled or killed) leaves old scores, which the next run notices and redoes.
        var scoredFor: Date? = nil
    }

    private(set) var saved: Saved?
    private(set) var downloading: Double?          // 0…1 while the model downloads
    private(set) var status: String?
    private(set) var busy = false
    private let log: DayLog
    private let file: URL
    nonisolated static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("wespeaker")
    nonisolated static var modelPath: URL { folder.appendingPathComponent(Voice.modelFile) }

    init(log: DayLog) {
        self.log = log
        file = Self.folder.appendingPathComponent("voiceprint.json")
        saved = try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
    }

    var enrolled: Bool { saved != nil }

    /// Auday's "Voice recognition" switch: off keeps the profile but stops marking your words.
    nonisolated static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "voiceRecognition") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceRecognition") }
    }

    // MARK: model

    /// Downloads the speaker model once and checks its SHA-256 (speaker.ensure_model).
    func ensureModel() async throws {
        if FileManager.default.fileExists(atPath: Self.modelPath.path) { return }
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        downloading = 0
        defer { downloading = nil }
        let (bytes, response) = try await URLSession.shared.bytes(from: Voice.modelURL)
        let total = max(1, Double(response.expectedContentLength))
        var data = Data()
        data.reserveCapacity(Int(total))
        var last = 0.0
        for try await byte in bytes {
            data.append(byte)
            let progress = Double(data.count) / total
            if progress - last > 0.01 { downloading = progress; last = progress }
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == Voice.modelSHA256 else { throw VoiceError.hash }
        try data.write(to: Self.modelPath, options: .atomic)
    }

    // MARK: enrolment

    /// Three readings → centroid (speaker.Voiceprint.enroll): quiet frames out, at least 6 s of
    /// voiced speech, ~15 s parts averaged.
    func enroll(readings: [URL]) async throws {
        busy = true
        defer { busy = false; status = nil }     // also when learning fails
        status = "Getting the voice model…"
        try await ensureModel()
        status = "Learning your voice…"
        let urls = readings
        let centroid = try await Task.detached(priority: .userInitiated) {
            // The readings are made on the phone, the recordings on the watch. Passing the readings
            // through the watch's codec first (AAC, ~32 kbps) narrows that gap: on the owner's own
            // watch speech the score went from 0.40 to 0.61, other voices stayed low.
            let audio = try urls.flatMap { try Embedder.throughWatchCodec($0) }
            let voiced = Voice.voiced(audio, rms: Voice.enrolVoicedRMS)
            guard Double(voiced.count) >= Voice.minEnrolSeconds * Double(Voice.sampleRate) else { throw VoiceError.tooShort }
            let embedder = try Embedder()
            let step = 15 * Voice.sampleRate
            var parts: [[Float]] = []
            var i = 0
            while i < max(1, voiced.count - step / 3) {
                if let v = try embedder.embed(Array(voiced[i..<min(voiced.count, i + step)])) { parts.append(v) }
                i += step
            }
            guard !parts.isEmpty else { throw VoiceError.tooShort }
            var mean = [Float](repeating: 0, count: parts[0].count)
            for p in parts { for k in mean.indices { mean[k] += p[k] / Float(parts.count) } }
            return Voice.normalized(mean)
        }.value
        saved = Saved(centroid: centroid, enrolledAt: Date(), thresholds: nil, watchCodec: true)
        persist()
        status = nil
        // Ready now; marking the archive takes minutes and runs on its own, showing its progress.
        Task { await relabel(all: true) }
    }

    /// A voiceprint learned before the codec step is learned again from the readings still on the
    /// phone, so the user need not read again.
    func upgradeIfNeeded() async {
        guard let saved, !busy else { return }
        if saved.watchCodec == true {
            if saved.scoredFor != saved.enrolledAt { await relabel(all: true) }
            return
        }
        let files = (0..<6).map { FileManager.default.temporaryDirectory.appendingPathComponent("voice-reading-\($0).wav") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard files.count >= 3 else { return }
        try? await enroll(readings: files)
    }

    func remove() {
        saved = nil
        try? FileManager.default.removeItem(at: file)
        log.clearVoiceLabels()
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let saved { try? JSONEncoder().encode(saved).write(to: file, options: .atomic) }
    }

    // MARK: labelling

    /// Scores snippets that have no score yet (or all of them after enrolment), recalibrates the
    /// thresholds on the archive, and writes Me / Me* onto every snippet.
    func relabel(all: Bool = false) async {
        guard Self.enabled, let centroid = saved?.centroid, FileManager.default.fileExists(atPath: Self.modelPath.path), !busy || all else { return }
        busy = true
        defer { busy = false; status = nil }
        let todo = log.entries.filter { !$0.mark && $0.status == .done && (all || ($0.segments ?? []).contains { $0.whole == nil && $0.end - $0.start >= Voice.minSeconds }) }
        // One model session for the whole run: loading the 25 MB model for every recording made a
        // day's relabel take about ten minutes.
        let shared = await Task.detached(priority: .utility) { try? Embedder() }.value
        let enrolment = saved?.enrolledAt
        for (n, entry) in todo.enumerated() {
            status = "Finding your voice in your recordings · \(n + 1) of \(todo.count)"
            let url = DayLog.audioURL(for: entry)
            guard FileManager.default.fileExists(atPath: url.path), let segments = entry.segments else { continue }
            let scored = await Task.detached(priority: .utility) { () -> [Segment] in
                guard let audio = try? Embedder.load16k(url), let embedder = shared else { return segments }
                return segments.map { seg in
                    var seg = seg
                    guard seg.end - seg.start >= Voice.minSeconds else { return seg }
                    let a = max(0, Int(seg.start * Double(Voice.sampleRate))), b = min(audio.count, Int(seg.end * Double(Voice.sampleRate)))
                    guard b > a else { return seg }
                    let slice = Array(audio[a..<b])
                    (seg.whole, seg.best) = embedder.score(slice, centroid: centroid)
                    return seg
                }
            }.value
            log.setSegments(entry.id, scored)
        }
        // Fixed thresholds, not Voice.calibrate. The Mac calibrates from the archive because it
        // enrols and records on the same device (the owner scores 0.62-0.93). Here enrolment is on
        // the phone and recordings come from the watch, where the owner scores only 0.56-0.64, and
        // calibration put the line above most of the owner's own words.
        // Measured on the owner's confirmed lines and 410 lines of other speakers: Me at 0.48 finds
        // about half of the owner's lines and none of the others; the context pass adds a few more.
        // Others' whole-snippet scores reach 0.466, so Me* needs 0.50 here, not Auday's 0.395.
        let thresholds: Voice.Thresholds? = saved?.watchCodec == true ? Voice.Thresholds(me: 0.48, mixed: 0.50) : nil
        saved?.thresholds = thresholds
        if all, saved?.enrolledAt == enrolment { saved?.scoredFor = enrolment }
        persist()
        log.applyVoiceLabels { seg in
            Voice.label(whole: seg.whole, best: seg.best, seconds: seg.end - seg.start, thresholds: thresholds)
        }
        log.extendVoiceLabels { segments in
            Voice.extendByContext(segments.map { (start: $0.start, seconds: $0.end - $0.start, whole: $0.whole, label: $0.me) })
        }
    }

    enum VoiceError: LocalizedError {
        case hash, tooShort, model
        var errorDescription: String? {
            switch self {
            case .hash: "The downloaded voice model did not match its checksum. Try again."
            case .tooShort: "Need at least 6 seconds of clear speech. Read a little louder or longer."
            case .model: "The voice model could not be loaded."
            }
        }
    }
}

/// Runs the speaker model. Not tied to the main actor; make one per batch of work.
final class Embedder {
    private static let env = try? ORTEnv(loggingLevel: .warning)
    private let session: ORTSession
    private let output: String

    init() throws {
        guard let env = Self.env else { throw VoiceModel.VoiceError.model }
        session = try ORTSession(env: env, modelPath: VoiceModel.modelPath.path, sessionOptions: nil)
        output = try session.outputNames().first ?? "embs"
    }

    /// Unit-length embedding, or nil under ~0.5 s of audio (speaker.Voiceprint.embed).
    func embed(_ audio: [Float]) throws -> [Float]? {
        guard let feats = Voice.fbank(audio), feats.count >= 50 else { return nil }
        var flat = feats.flatMap { $0 }
        let data = NSMutableData(bytes: &flat, length: flat.count * MemoryLayout<Float>.size)
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, NSNumber(value: feats.count), 80])
        let outputs = try session.run(withInputs: ["feats": input], outputNames: [output], runOptions: nil)
        guard let value = outputs[output] else { return nil }
        let raw = try value.tensorData() as Data
        let vector = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return Voice.normalized(vector)
    }

    /// (whole-snippet score, best 1.5 s window score) against the centroid (speaker.Voiceprint.score).
    func score(_ audio: [Float], centroid: [Float]) -> (Double?, Double?) {
        guard let whole = try? embed(audio) else { return (nil, nil) }
        let win = Int(Voice.window * Double(Voice.sampleRate)), hop = Int(Voice.hop * Double(Voice.sampleRate))
        var best: Double?
        var i = 0
        while i < max(1, audio.count - hop) {
            if let w = try? embed(Array(audio[i..<min(audio.count, i + win)])) {
                best = max(best ?? -1, Voice.cosine(w, centroid))
            }
            i += hop
        }
        return (Voice.cosine(whole, centroid), best)
    }

    /// A reading as the watch would deliver it: encoded as AAC at ~32 kbps like the watch's
    /// fragments, then decoded to 16 kHz.
    static func throughWatchCodec(_ url: URL) throws -> [Float] {
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        let encoded = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aac")
        defer { try? FileManager.default.removeItem(at: encoded) }
        do {
            let output = try AVAudioFile(forWriting: encoded, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 32_000,
            ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { throw VoiceModel.VoiceError.model }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        }   // the encoder finishes the file when `output` goes away
        return try load16k(encoded)
    }

    /// Any audio file → 16 kHz mono Float samples.
    static func load16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Voice.sampleRate), channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw VoiceModel.VoiceError.model }
        var out: [Float] = []
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate)
        while file.framePosition < file.length {
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { break }
            try file.read(into: input, frameCount: chunk)
            if input.frameLength == 0 { break }
            let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1024
            guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
            var fed = false
            var error: NSError?
            converter.convert(to: buffer, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            if let samples = buffer.floatChannelData?[0] {
                out.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            }
        }
        return out
    }
}
