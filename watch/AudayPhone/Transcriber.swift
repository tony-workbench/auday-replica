import AudayKit
import AVFoundation
import Foundation
import Observation
import Speech
import UIKit

/// One stretch of speech in a recording, in seconds from its start.
struct Segment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    /// My voice recognition: "Me", "Me*" or nil, and the scores behind it.
    var me: String? = nil
    var whole: Double? = nil
    var best: Double? = nil
}

/// The languages Auday's "Local efficient" mode lists.
enum TranscriptionLanguage: String, CaseIterable, Codable {
    case mandarin, cantonese, english, japanese, korean

    var name: String { rawValue.capitalized }

    /// Model language codes (SenseVoice, Whisper): zh, yue, en, ja, ko.
    var code: String {
        switch self {
        case .mandarin: "zh"
        case .cantonese: "yue"
        case .english: "en"
        case .japanese: "ja"
        case .korean: "ko"
        }
    }

    init?(code: String?) {
        guard let code, let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    var locale: Locale {
        switch self {
        case .mandarin: Locale(identifier: "zh-CN")
        case .cantonese: Locale(identifier: "yue-CN")
        case .english: Locale(identifier: "en-US")
        case .japanese: Locale(identifier: "ja-JP")
        case .korean: Locale(identifier: "ko-KR")
        }
    }

    /// The first of the phone's preferred languages that is on the list, else Mandarin.
    static var preferred: TranscriptionLanguage {
        for id in Locale.preferredLanguages {
            if id.hasPrefix("yue") || id.hasPrefix("zh-HK") { return .cantonese }
            if id.hasPrefix("zh") { return .mandarin }
            if id.hasPrefix("en") { return .english }
            if id.hasPrefix("ja") { return .japanese }
            if id.hasPrefix("ko") { return .korean }
        }
        return .mandarin
    }
}

/// On-device transcription: every recording the watch sends is transcribed on this iPhone, one at
/// a time, oldest first, with SenseVoice (Local efficient) or Whisper (Local accurate), and Apple's
/// speech model (SpeechAnalyzer) until SenseVoice is downloaded. Nothing leaves the phone. The
/// result is kept with the recording in the day log.
@MainActor @Observable
final class LocalTranscriber {
    private(set) var status: String?
    private(set) var busy = false
    /// When the recording now being transcribed started to be worked on (shown as elapsed time).
    private(set) var startedAt: Date?
    /// The last finished recording, e.g. "Transcribed 16:20 · 9 lines", so a result never just vanishes.
    private(set) var lastResult: String?

    /// The engine the current mode uses.
    var engineName: String {
        if Self.mode == .accurate, AppDelegate.whisper.ready { return "Whisper small (compressed)" }
        if Self.mode == .efficient, SenseVoiceLocal.ready { return "SenseVoice" }
        return "Apple speech (\(OutputLanguage.primary.transcription.name))"
    }

    /// One recording through the chosen engine: segments, the language it heard, and the engine's name.
    @available(iOS 26, *)
    private func transcribe(_ url: URL, runner: inout SenseVoiceRunner?) async throws -> ([Segment], String?, String) {
        if Self.mode == .accurate, AppDelegate.whisper.ready {
            let (segments, language) = try await AppDelegate.whisper.transcribe(url)
            return (segments, language, "Whisper small (compressed)")
        }
        // Local efficient is SenseVoice, as Auday's; Apple's speech model only until it is downloaded.
        if Self.mode == .efficient, !SenseVoiceLocal.ready, AppDelegate.senseVoice.downloading == nil {
            Task { await AppDelegate.senseVoice.download(wifiOnly: true) }
        }
        if Self.mode == .efficient, SenseVoiceLocal.ready {
            if runner == nil { runner = try await Task.detached { try SenseVoiceRunner() }.value }
            let model = runner!
            let (segments, language) = try await Task.detached(priority: .utility) { try model.transcribe(url) }.value
            return (segments, language, "SenseVoice")
        }
        // Settings › Language: the primary language first, then the second one when the
        // primary heard nothing (the user may have spoken the other language).
        var language = OutputLanguage.primary.transcription
        var segments = try await Self.transcribe(url, language: language)
        if segments.isEmpty, let second = OutputLanguage.secondary?.transcription, second != language {
            language = second
            segments = (try? await Self.transcribe(url, language: second)) ?? []
        }
        return (segments, language.code, "Apple speech (\(language.name))")
    }
    private let log: DayLog

    init(log: DayLog) { self.log = log }

    static var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "autoTranscribe") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoTranscribe") }
    }

    /// Settings › Transcription mode: Local efficient (SenseVoice) or Local accurate (Whisper).
    enum Mode: String { case efficient, accurate }
    static var mode: Mode {
        get { UserDefaults.standard.string(forKey: "transcriptionMode").flatMap(Mode.init) ?? .efficient }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "transcriptionMode") }
    }

    static var language: TranscriptionLanguage {
        get { UserDefaults.standard.string(forKey: "transcriptionLanguage").flatMap(TranscriptionLanguage.init) ?? .preferred }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "transcriptionLanguage") }
    }

    var pending: Int { log.untranscribed().count }

    /// Transcribes what is waiting; `force` runs even with Automatic transcription off.
    func run(force: Bool = false) async {
        guard !busy, force || Self.automatic else { return }
        guard #available(iOS 26, *) else {
            status = "Local transcription needs iOS 26 or later."
            return
        }
        // Local accurate waits for its model instead of quietly using another engine.
        if Self.mode == .accurate, !AppDelegate.whisper.ready {
            if AppDelegate.whisper.downloading == nil { Task { await AppDelegate.whisper.download() } }
            status = "Waiting for Whisper to download."
            return
        }
        busy = true
        defer { busy = false }
        var authorized = false
        var runner: SenseVoiceRunner?
        while let entry = log.untranscribed().first {
            let url = DayLog.audioURL(for: entry)
            status = "Transcribing \(Format.english("HH:mm", entry.start))…"
            startedAt = Date()
            defer { startedAt = nil }
            var run = TranscriptionLog.Run(recording: entry.id, recordedAt: entry.start, seconds: entry.duration,
                                           engine: "", started: Date(), result: "failed")
            do {
                // A file the watch never closed has its sound but no packet table: nothing can read
                // it, so it is marked failed at once instead of holding up the queue.
                guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { throw TranscriptionError.unreadable }
                var (segments, language, engine) = try await transcribe(url, runner: &runner)
                for i in segments.indices { segments[i].text = Stutter.fix(segments[i].text, isWord: Self.isEnglishWord) }
                log.setTranscript(entry.id, segments: segments, language: TranscriptionLanguage(code: language) ?? OutputLanguage.primary.transcription)
                run.engine = engine
                run.result = segments.isEmpty ? "silent" : "done"
                run.lines = segments.count
                run.language = language
                run.ended = Date()
                AppDelegate.transcriptions.add(run)
                lastResult = "Transcribed \(Format.english("HH:mm", entry.start)) · " + (segments.isEmpty ? "no speech" : Format.plural(segments.count, "line"))
            } catch {
                // The speech model may need permission the first time; ask once, then retry.
                if !authorized, SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                    authorized = true
                    _ = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
                    continue
                }
                log.setFailed(entry.id, reason: error.localizedDescription)
                run.engine = engineName
                run.error = error.localizedDescription
                run.ended = Date()
                AppDelegate.transcriptions.add(run)
                status = "Could not transcribe \(Format.english("HH:mm", entry.start)): \(error.localizedDescription)"
                continue
            }
        }
        if status?.hasPrefix("Could not") != true { status = nil }
    }

    /// iOS's English dictionary, for repairing stuttered English words (Stutter).
    private static let checker = UITextChecker()
    static func isEnglishWord(_ word: String) -> Bool {
        checker.rangeOfMisspelledWord(in: word, range: NSRange(location: 0, length: (word as NSString).length),
                                      startingAt: 0, wrap: false, language: "en_US").location == NSNotFound
    }

    @available(iOS 26, *)
    nonisolated static func transcribe(_ url: URL, language: TranscriptionLanguage) async throws -> [Segment] {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.locale) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                           attributeOptions: [.audioTimeRange])
            return try await analyze(url, module: module, results: module.results) {
                Segment(start: $0.range.start.seconds, end: $0.range.end.seconds, text: String($0.text.characters))
            }
        }
        // Languages the long-form model lacks (Cantonese on some phones) fall back to dictation.
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: language.locale) {
            let module = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
            return try await analyze(url, module: module, results: module.results) {
                Segment(start: $0.range.start.seconds, end: $0.range.end.seconds, text: String($0.text.characters))
            }
        }
        throw TranscriptionError.unsupported(language.name)
    }

    @available(iOS 26, *)
    nonisolated private static func analyze<Results: AsyncSequence & Sendable>(
        _ url: URL, module: any SpeechModule, results: Results, segment: @escaping @Sendable (Results.Element) -> Segment
    ) async throws -> [Segment] where Results.Element: Sendable {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()      // the language model, once
        }
        let file = try AVAudioFile(forReading: url)
        var best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: file.processingFormat)
        if best == nil { best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) }
        guard let format = best else {
            let state = await AssetInventory.status(forModules: [module])
            throw TranscriptionError.noModel("\(state)")
        }
        let input = try convert(file, to: format)
        let analyzer = SpeechAnalyzer(modules: [module])
        let collect = Task {
            var out: [Segment] = []
            for try await result in results {
                let s = segment(result)
                if !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(s) }
            }
            return out
        }
        if let end = try await analyzer.analyzeSequence(input) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }

    /// The watch's AAC fragment as PCM buffers in the format the speech model takes (one second
    /// of source audio per buffer).
    @available(iOS 26, *)
    nonisolated private static func convert(_ file: AVAudioFile, to format: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        let source = file.processingFormat
        guard let converter = AVAudioConverter(from: source, to: format) else { throw TranscriptionError.unsupported("This audio") }
        let chunk = AVAudioFrameCount(source.sampleRate)
        var buffers: [AnalyzerInput] = []
        while file.framePosition < file.length {
            guard let read = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk) else { break }
            try file.read(into: read, frameCount: chunk)
            if read.frameLength == 0 { break }
            let capacity = AVAudioFrameCount(Double(read.frameLength) * format.sampleRate / source.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return read
            }
            if let error { throw error }
            if out.frameLength > 0 { buffers.append(AnalyzerInput(buffer: out)) }
        }
        return AsyncStream { continuation in
            for buffer in buffers { continuation.yield(buffer) }
            continuation.finish()
        }
    }

    enum TranscriptionError: LocalizedError {
        case unsupported(String)
        case noModel(String)
        case unreadable
        var errorDescription: String? {
            switch self {
            case .unsupported(let name): "\(name) is not available for on-device transcription on this iPhone."
            case .noModel(let state): "The on-device speech model is not ready (\(state))."
            case .unreadable: "This recording cannot be read: the watch did not finish saving it."
            }
        }
    }
}
