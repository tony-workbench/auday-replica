import AudayKit
import Foundation

/// The Health samples HealthSync reads, kept on this iPhone so the hour summaries and Highlights
/// made here get the same body context the Mac builds (AudayKit.Body, from app/health.py).
/// 16 days are kept, since the personal baseline looks back 14 days.
@MainActor
final class HealthLog {
    private(set) var samples: Body.Samples = [:]
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("health-samples.json")
    private static let keep: TimeInterval = 16 * 24 * 3600

    init() {
        samples = (try? JSONDecoder().decode(Body.Samples.self, from: Data(contentsOf: file))) ?? [:]
    }

    func add(_ kind: String, _ new: [HealthSample]) {
        guard !new.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-Self.keep)
        var seen = Set<String>()
        samples[kind] = (samples[kind, default: []] + new)
            .filter { $0.end >= cutoff && seen.insert("\($0.start.timeIntervalSince1970)-\($0.end.timeIntervalSince1970)").inserted }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        try? JSONEncoder().encode(samples).write(to: file, options: .atomic)
    }
}
