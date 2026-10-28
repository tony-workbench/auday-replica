import AVFoundation
import Foundation

/// One hour's export, as Auday's: Notes (Markdown) and Audio, each its own file.
/// Notes: summary, Things to note, each Highlight, then the transcript with Me / Me* labels.
/// Audio: the hour's recordings joined, starting at the first second actually recorded.
@MainActor
enum HourExport {
    static func baseName(_ date: String, _ hour: Int) -> String {
        "Auday_\(date)_\(String(format: "%02d00-%02d00", hour, (hour + 1) % 24))"
    }

    static func notes(date: String, hour: Int, summary: HourSummary?, highlights: [Highlight], entries: [DayLog.Entry]) -> URL? {
        let day = Format.ymd.date(from: date) ?? Date()
        let range = "\(Format.hour(hour))–\(Format.hour(hour + 1))"
        var md = "# Auday · \(Format.english("MMMM d, yyyy", day)) · \(range)\n\n"
        if let summary {
            md += "## Summary\n\n\(summary.text)\n\n"
            if !summary.title.isEmpty { md += "\(summary.title)\n\n" }
            if let attention = summary.attention, !attention.isEmpty {
                md += "## Things to note\n\n" + attention.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
            }
        }
        if !highlights.isEmpty {
            md += "## Highlights\n\n"
            for h in highlights {
                md += "### \(Format.english("HH:mm", h.start))–\(Format.english("HH:mm", h.end)) · \(h.title)\n\n"
                if !h.reading.isEmpty { md += "\(h.reading)\n\n" }
                if let attention = h.attention, !attention.isEmpty {
                    md += attention.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
                }
            }
        }
        md += "## Transcript\n\n\(Format.english("MMMM d, yyyy", day)) · \(range) · \(TimeZone.current.identifier)\n"
        md += "Speaker labels: “Me” is the recording owner's speech; “Me*” includes the owner's voice and may include other speakers. Unlabeled text has no confirmed speaker.\n\n"
        for entry in entries where !entry.mark {
            for seg in entry.segments ?? [] {
                let label = VoiceModel.enabled ? seg.me.map { "\($0): " } ?? "" : ""
                md += "[\(Format.english("HH:mm", entry.start.addingTimeInterval(seg.start)))] \(label)\(seg.text)\n\n"
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(baseName(date, hour) + "_Notes.md")
        return (try? md.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    /// The hour's recordings in order, joined into one AAC file (.m4a).
    static func audio(date: String, hour: Int, entries: [DayLog.Entry]) async -> URL? {
        let files = entries.filter { !$0.mark }.sorted { $0.start < $1.start }
            .map { DayLog.audioURL(for: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return nil }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var at = CMTime.zero
        for file in files {
            let asset = AVURLAsset(url: file)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration) else { continue }
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: at)
            at = at + duration
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(baseName(date, hour) + "_Audio.m4a")
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        do { try await session.export(to: url, as: .m4a) } catch { return nil }
        return url
    }
}
