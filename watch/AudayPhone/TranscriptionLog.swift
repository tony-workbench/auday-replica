import Foundation
import Observation

/// What happened to each recording's transcription, kept on this iPhone
/// (Application Support/transcriptions.json, newest last, the last 300 runs).
@MainActor @Observable
final class TranscriptionLog {
    struct Run: Codable, Identifiable {
        var id = UUID()
        var recording: String          // DayLog entry id
        var recordedAt: Date
        var seconds: Double            // length of the recording
        var engine: String             // "SenseVoice", "Whisper small", "Apple speech (english)"
        var started: Date
        var ended: Date?
        var result: String             // "done", "silent", "failed"
        var lines = 0
        var language: String?          // as the model detected it
        var error: String?
    }

    private(set) var runs: [Run] = []
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("transcriptions.json")

    init() {
        runs = (try? JSONDecoder().decode([Run].self, from: Data(contentsOf: file))) ?? []
    }

    func add(_ run: Run) {
        runs.append(run)
        if runs.count > 300 { runs.removeFirst(runs.count - 300) }
        try? JSONEncoder().encode(runs).write(to: file, options: .atomic)
    }
}
