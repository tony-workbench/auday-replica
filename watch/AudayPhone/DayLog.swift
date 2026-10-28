import AudayKit
import Foundation
import Observation

/// Everything the watch recorded, kept on this iPhone: one entry per fragment (with its audio in
/// Application Support/Audio and, once transcribed, its transcript) and per mark. Days, the hour
/// pages and the transcriber read it; the Mac, when connected, only gets a copy.
@MainActor @Observable
final class DayLog {
    struct Entry: Codable, Equatable {
        enum Status: String, Codable { case waiting, done, silent, failed }

        var id: String
        var start: Date
        var duration: TimeInterval
        var mark = false
        var ext: String?
        var status: Status?
        var segments: [Segment]?
        var language: TranscriptionLanguage?
        var failure: String?

        var text: String { (segments ?? []).map(\.text).joined(separator: " ") }

        init(id: String, start: Date, duration: TimeInterval, mark: Bool = false, ext: String? = nil) {
            self.id = id
            self.start = start
            self.duration = duration
            self.mark = mark
            self.ext = ext
            self.status = mark ? nil : .waiting
        }
    }

    private(set) var entries: [Entry] = []
    private let file: URL
    static let audioFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Audio")

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = support.appendingPathComponent("DayLog.json")
        try? FileManager.default.createDirectory(at: Self.audioFolder, withIntermediateDirectories: true)
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
        removeWhisperCaptions()
    }

    /// One-time cleanup: transcripts made before Whisper's output was cleaned lose their "[MUSIC]" and
    /// "(footsteps)" captions and lines in scripts nobody spoke; a recording left with no speech
    /// becomes silent.
    private func removeWhisperCaptions() {
        guard !UserDefaults.standard.bool(forKey: "whisperCaptionsRemoved2") else { return }
        for i in entries.indices {
            guard let segments = entries[i].segments else { continue }
            let kept = segments.compactMap { s -> Segment? in
                guard let text = WhisperText.clean(s.text) else { return nil }
                var s = s
                s.text = text
                return s
            }
            guard kept != segments else { continue }
            entries[i].segments = kept
            if kept.isEmpty, entries[i].status == .done { entries[i].status = .silent }
        }
        save()
        UserDefaults.standard.set(true, forKey: "whisperCaptionsRemoved2")
    }

    /// Auday's "Keep original audio" setting, in days; 0 keeps it forever. Transcripts and summaries always stay.
    static var keepAudioDays: Int {
        get { UserDefaults.standard.integer(forKey: "keepAudioDays") }
        set { UserDefaults.standard.set(newValue, forKey: "keepAudioDays") }
    }

    static var audioBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: audioFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Deletes the audio of recordings older than "Keep original audio" allows, or of all of them.
    /// A recording still waiting for transcription keeps its audio; the log and text stay.
    @discardableResult
    func pruneAudio(all: Bool = false) -> Int {
        let days = Self.keepAudioDays
        guard all || days > 0 else { return 0 }
        let cutoff = all ? Date.distantFuture : Date().addingTimeInterval(-Double(days) * 86400)
        var removed = 0
        for entry in entries where !entry.mark && entry.start < cutoff && (entry.status ?? .waiting) != .waiting {
            if (try? FileManager.default.removeItem(at: Self.audioURL(for: entry))) != nil { removed += 1 }
        }
        return removed
    }

    static func audioURL(for entry: Entry) -> URL {
        audioFolder.appendingPathComponent("\(entry.id).\(entry.ext ?? "caf")")
    }

    /// Keeps the fragment's audio next to the log (a hard link to the outbox copy, so it costs no
    /// extra space and survives the upload to the Mac). Safe to call from any thread.
    nonisolated static func keepAudio(of fragment: Fragment, from url: URL) {
        let target = audioFolder.appendingPathComponent("\(fragment.id).\(fragment.ext)")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        if (try? FileManager.default.linkItem(at: url, to: target)) == nil {
            try? FileManager.default.copyItem(at: url, to: target)
        }
    }

    func add(_ fragment: Fragment) {
        add(Entry(id: fragment.id, start: fragment.start, duration: fragment.duration, ext: fragment.ext))
    }

    func add(_ mark: Mark) {
        add(Entry(id: mark.id, start: mark.start, duration: 0, mark: true))
    }

    private func add(_ entry: Entry) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries = (entries + [entry]).sorted { $0.start < $1.start }
        save()
    }

    /// Marks waiting recordings whose audio is missing (e.g. received before this iPhone kept audio) as failed.
    func markMissingAudio() {
        var changed = false
        for i in entries.indices where !entries[i].mark && (entries[i].status ?? .waiting) == .waiting
            && !FileManager.default.fileExists(atPath: Self.audioURL(for: entries[i]).path) {
            entries[i].status = .failed
            entries[i].failure = "The audio of this recording is not on this iPhone."
            changed = true
        }
        if changed { save() }
    }

    /// Recordings whose audio is here and that have no transcript yet, oldest first.
    func untranscribed() -> [Entry] {
        entries.filter {
            !$0.mark && ($0.status ?? .waiting) == .waiting
                && FileManager.default.fileExists(atPath: Self.audioURL(for: $0).path)
        }
    }

    func setTranscript(_ id: String, segments: [Segment], language: TranscriptionLanguage) {
        update(id) {
            $0.segments = segments
            $0.language = language
            $0.status = segments.isEmpty ? .silent : .done
            $0.failure = nil
        }
    }

    func setFailed(_ id: String, reason: String) {
        update(id) {
            $0.status = .failed
            $0.failure = reason
        }
    }

    func setSegments(_ id: String, _ segments: [Segment]) {
        update(id) { $0.segments = segments }
    }

    /// Writes Me / Me* onto every scored snippet.
    func applyVoiceLabels(_ label: (Segment) -> String?) {
        for i in entries.indices {
            guard var segments = entries[i].segments else { continue }
            for k in segments.indices { segments[k].me = label(segments[k]) }
            entries[i].segments = segments
        }
        save()
    }

    /// A second pass over each recording's labels, which sees its neighbours (Voice.extendByContext).
    func extendVoiceLabels(_ extend: ([Segment]) -> [String?]) {
        for i in entries.indices {
            guard var segments = entries[i].segments else { continue }
            let labels = extend(segments)
            for k in segments.indices { segments[k].me = labels[k] }
            entries[i].segments = segments
        }
        save()
    }

    func clearVoiceLabels() {
        for i in entries.indices {
            guard var segments = entries[i].segments else { continue }
            for k in segments.indices { segments[k].me = nil; segments[k].whole = nil; segments[k].best = nil }
            entries[i].segments = segments
        }
        save()
    }

    /// Queues these recordings to be transcribed again, with the mode now chosen in Settings.
    func retranscribe(_ ids: [String]) {
        for i in entries.indices where ids.contains(entries[i].id) && !entries[i].mark {
            entries[i].status = .waiting
            entries[i].failure = nil
        }
        save()
    }

    func retryFailed() {
        for i in entries.indices where entries[i].status == .failed { entries[i].status = .waiting }
        save()
    }

    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
        save()
    }

    private func save() {
        try? JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }

    func entries(on day: Date, calendar: Calendar = .current) -> [Entry] {
        entries.filter { calendar.isDate($0.start, inSameDayAs: day) }
    }

    /// Days with at least one recording, newest first.
    func days(calendar: Calendar = .current) -> [Date] {
        Array(Set(entries.filter { !$0.mark }.map { calendar.startOfDay(for: $0.start) })).sorted(by: >)
    }
}
