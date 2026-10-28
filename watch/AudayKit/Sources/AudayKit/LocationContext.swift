import Foundation

/// Watch places turned into Auday's `locationContext` labels, with the rules of app/location.py so
/// the iPhone and the Mac give the AI the same places. Items are cut at the
/// 5-minute clock grid, the hour and the audio-fragment boundaries; each carries the samples
/// around it as evidence; only the place name and times go to the AI, never coordinates.
public enum LocationContext {
    public struct Label: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var name: String?
        public var confidence: String
        public var evidenceStart: Date
        public var evidenceEnd: Date
    }

    static let grid: TimeInterval = 300, join: TimeInterval = 300, tail: TimeInterval = 60
    static let before: TimeInterval = 120, after: TimeInterval = 60, poorAccuracy = 100.0

    public static func labels(_ samples: [PlaceSample], start: Date, end: Date, cuts: [Date] = [],
                              calendar: Calendar = .current) -> [Label] {
        let sorted = samples.sorted { $0.time < $1.time }
        var runs: [[PlaceSample]] = []
        for s in sorted {
            if let last = runs.last?.last, s.time.timeIntervalSince(last.time) <= join { runs[runs.count - 1].append(s) }
            else { runs.append([s]) }
        }
        var out: [Label] = []
        for run in runs {
            let a = max(run[0].time, start), b = min(run[run.count - 1].time.addingTimeInterval(tail), end)
            guard a < b else { continue }
            // Grid ticks after a; a lone sample's minute is cut only at the hour.
            var ticks: [Date] = []
            var tick = Date(timeIntervalSince1970: (a.timeIntervalSince1970 / grid).rounded(.down) * grid + grid)
            while tick < b {
                if run.count > 1 || calendar.component(.minute, from: tick) == 0 { ticks.append(tick) }
                tick.addTimeInterval(grid)
            }
            let points = Array(Set([a, b] + ticks + cuts.filter { a < $0 && $0 < b })).sorted()
            for (s, e) in zip(points, points.dropFirst()) {
                var evidence = run.filter { $0.time >= s.addingTimeInterval(-before) && $0.time <= e.addingTimeInterval(after) }
                if evidence.isEmpty, let near = run.min(by: { abs($0.time.timeIntervalSince(s)) < abs($1.time.timeIntervalSince(s)) }) {
                    evidence = [near]
                }
                let accuracy = evidence.map(\.accuracy).sorted()[evidence.count / 2]
                let names = evidence.compactMap(\.name)
                // Most common name; ties go to the one seen first, as Python's Counter.most_common.
                let name = names.max { a, b in
                    let (ca, cb) = (names.filter { $0 == a }.count, names.filter { $0 == b }.count)
                    return ca != cb ? ca < cb : names.firstIndex(of: a)! > names.firstIndex(of: b)!
                }
                out.append(Label(start: s, end: e, name: name,
                                 confidence: evidence.count < 2 || accuracy > poorAccuracy ? "low" : "medium",
                                 evidenceStart: evidence[0].time, evidenceEnd: evidence[evidence.count - 1].time))
            }
        }
        return out
    }
}
