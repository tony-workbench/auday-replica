import Foundation

/// New HealthKit samples, read directly on the iPhone as Auday does (no export).
/// Kinds match app/health.py: hr, hrv, steps, effort, rest, sleep, workout.
public struct HealthSample: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var value: Double

    public init(start: Date, end: Date, value: Double) {
        self.start = start
        self.end = end
        self.value = value
    }
}

public struct HealthBatch: Codable, Equatable, Sendable {
    public static let kinds = ["hr", "hrv", "steps", "effort", "rest", "sleep", "workout"]
    /// Keeps one upload a reasonable size; the first sync reads two weeks for the personal baseline.
    public static let maxSamples = 5_000

    public var id: String
    public var samples: [String: [HealthSample]]

    public init(id: String = "health-" + UUID().uuidString, samples: [String: [HealthSample]]) {
        self.id = id
        self.samples = samples
    }

    public var count: Int { samples.values.reduce(0) { $0 + $1.count } }
    public var start: Date { samples.values.flatMap { $0.map(\.start) }.min() ?? .distantPast }

    /// Splits samples of one kind into batches of at most `maxSamples`.
    public static func batches(kind: String, _ samples: [HealthSample]) -> [HealthBatch] {
        stride(from: 0, to: samples.count, by: maxSamples).map {
            HealthBatch(samples: [kind: Array(samples[$0..<min($0 + maxSamples, samples.count)])])
        }
    }
}
