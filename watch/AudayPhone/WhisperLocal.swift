import AudayKit
import Foundation
import Observation
import WhisperKit

/// Auday's "Local accurate" transcription: Whisper on this iPhone (Core ML, through WhisperKit).
/// Quality first, slower and heavier than Local efficient. The model is downloaded once, when the
/// user picks this mode, and can be deleted again.
@MainActor @Observable
final class WhisperLocal {
    /// The compressed Whisper small (WhisperKit's pick for A15-class iPhones): much faster than the
    /// full 500 MB model with about the same accuracy.
    static let variant = "openai_whisper-small_216MB"
    static let sizeLabel = "about 216 MB"

    private(set) var downloading: Double?          // 0…1 while the model downloads
    private(set) var problem: String?
    /// True while Core ML compiles the model for this iPhone: the first time only, a few minutes.
    private(set) var preparing = false
    /// 0…1 while the model loads: estimated from how long the last load took on this iPhone.
    private(set) var loading: Double?
    /// 0…1 while a recording is transcribed.
    private(set) var transcribing: Double?
    private var kit: WhisperKit?

    init() {
        // Delete an older full-size model download; only the compressed one is used.
        if let path = UserDefaults.standard.string(forKey: "whisperFolder"), !path.hasSuffix(Self.variant) {
            try? FileManager.default.removeItem(atPath: path)
            UserDefaults.standard.removeObject(forKey: "whisperFolder")
            UserDefaults.standard.removeObject(forKey: "whisperLoadSeconds")
            UserDefaults.standard.removeObject(forKey: "whisperPrewarmed")
        }
    }

    nonisolated static let downloadBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("whisperkit")

    /// Where the downloaded model lives, once it is complete.
    var folder: URL? {
        guard let path = UserDefaults.standard.string(forKey: "whisperFolder") else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var ready: Bool { folder != nil }

    /// iPhone 15 or later (A16 and newer) runs it comfortably; older phones work but slowly.
    static var recommendedDevice: Bool {
        var info = utsname()
        uname(&info)
        let id = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard id.hasPrefix("iPhone"), let major = Int(id.dropFirst(6).split(separator: ",").first ?? "") else { return true }
        return major >= 15          // A16 and newer (iPhone15,x onwards); the iPhone 14 is iPhone14,7
    }

    func download() async {
        guard downloading == nil else { return }
        problem = nil
        downloading = 0
        defer { downloading = nil }
        do {
            try FileManager.default.createDirectory(at: Self.downloadBase, withIntermediateDirectories: true)
            let url = try await WhisperKit.download(variant: Self.variant, downloadBase: Self.downloadBase) { progress in
                Task { @MainActor in self.downloading = progress.fractionCompleted }
            }
            UserDefaults.standard.set(url.path, forKey: "whisperFolder")
            downloading = nil
            try await prepare()
            Task { await AppDelegate.transcriber.run() }
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(error.code) {
            problem = "No internet connection. The Whisper model (\(Self.sizeLabel)) needs a one-time download; connect and try again."
        } catch {
            problem = error.localizedDescription
        }
    }

    func remove() {
        kit = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        UserDefaults.standard.removeObject(forKey: "whisperFolder")
        UserDefaults.standard.removeObject(forKey: "whisperLoadSeconds")
        UserDefaults.standard.removeObject(forKey: "whisperPrewarmed")
    }

    /// Loads the model. The first time Core ML compiles it for this iPhone's Neural Engine (prewarm,
    /// a few minutes); that is cached, so later launches only load it.
    func prepare() async throws {
        guard kit == nil, let folder else { return }
        let first = !UserDefaults.standard.bool(forKey: "whisperPrewarmed")
        let expected = UserDefaults.standard.object(forKey: "whisperLoadSeconds") as? Double ?? (first ? 240 : 30)
        preparing = first
        loading = 0
        let start = Date()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                // Creeps towards 95 % so it never shows done too early.
                loading = min(0.95, Date().timeIntervalSince(start) / expected)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { ticker.cancel(); preparing = false; loading = nil }
        kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, prewarm: first, load: true, download: false))
        UserDefaults.standard.set(true, forKey: "whisperPrewarmed")
        UserDefaults.standard.set(Date().timeIntervalSince(start), forKey: "whisperLoadSeconds")
    }

    /// Whisper's code for a language (Whisper small has no separate Cantonese).
    private static func code(_ language: TranscriptionLanguage) -> String {
        language == .cantonese ? "zh" : language.code
    }

    /// One recording as segments (seconds from its start), in Settings › Language's first language,
    /// or the second one when Whisper hears that more. Never any other language: free detection
    /// across Whisper's 99 languages turned quiet stretches into Sinhala and emoji.
    func transcribe(_ url: URL) async throws -> (segments: [Segment], language: String?) {
        guard folder != nil else { throw LocalTranscriber.TranscriptionError.noModel("Whisper model not downloaded") }
        try await prepare()
        guard let kit else { return ([], nil) }
        var language = OutputLanguage.primary.transcription
        if let second = OutputLanguage.secondary?.transcription, Self.code(second) != Self.code(language),
           let probs = try? await kit.detectLanguage(audioPath: url.path).langProbs,
           (probs[Self.code(second)] ?? -.infinity) > (probs[Self.code(language)] ?? -.infinity) {
            language = second
        }
        let options = DecodingOptions(task: .transcribe, language: Self.code(language), detectLanguage: false,
                                      skipSpecialTokens: true, chunkingStrategy: .vad)
        transcribing = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                transcribing = kit.progress.fractionCompleted
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { ticker.cancel(); transcribing = nil }
        let results: [TranscriptionResult] = try await kit.transcribe(audioPath: url.path, decodeOptions: options)
        let segments = results.flatMap(\.segments).compactMap { s -> Segment? in
            // Whisper's own "no speech" rule, per segment: likely silence and a low-confidence guess.
            if (s.noSpeechProb > 0.6 && s.avgLogprob < -1) || s.compressionRatio > 2.4 { return nil }
            // Speech only: no "[MUSIC]" or "(footsteps)" captions, no invented "Thanks for watching".
            guard let text = WhisperText.clean(s.text, doubtsSpeech: s.noSpeechProb > 0.3) else { return nil }
            return Segment(start: Double(s.start), end: Double(s.end), text: text)
        }
        return (segments, language.code)
    }
}
