import Foundation

/// Body context from Health samples, with the rules of app/health.py: walking from step cadence,
/// elevated heart rate against the resting rate, stress from an elevated episode over a minute while
/// not active, "Feeling good" from a calm sedentary run, and heart-rate / HRV statistics per recorded
/// range. Samples are keyed by `HealthBatch.kinds`. All intervals are low-confidence, as in Auday.
public enum Body {
    public static let gap: TimeInterval = 5 * 60
    static let episodeGap: TimeInterval = 10 * 60
    static let stressAfter: TimeInterval = 60
    static let tail: TimeInterval = 5 * 60
    static let walkCadence = 40.0          // steps per minute
    static let walkMin: TimeInterval = 60
    static let activeEffort = 3.0, sedentaryEffort = 2.0
    static let baselineDays = 14, baselineMinDays = 2, baselineMinReadings = 10
    static let recovery: TimeInterval = 30 * 60
    /// Replica rule, stricter than Auday (app/health.py): a raised heart rate while walking or in
    /// the 10 minutes after (2 before) is the walk itself, not stress or a separate label.
    static let walkBefore: TimeInterval = 2 * 60, walkAfter: TimeInterval = 10 * 60
    static let stressHR = 1.15, stressHRV = 0.85
    static let freshHRV: TimeInterval = 2 * 3600

    public static let labels = ["heartRateElevated": "Heart rate elevated", "walking": "Walking",
                                "stressElevated": "High stress", "stressLow": "Feeling good"]
    /// What a Highlight's chip says for each state.
    public static let chips = ["heartRateElevated": "Elevated heart rate", "walking": "Walk",
                               "stressElevated": "High stress", "stressLow": "Feeling good"]

    public typealias Samples = [String: [HealthSample]]

    public struct Interval: Equatable, Sendable {
        public var kind: String
        public var confidence = "low"
        public var start: Date
        public var end: Date
        public var evidenceStart: Date
        public var evidenceEnd: Date
        public var observedStart: Date
        public var observedEnd: Date
        public var motionContext: String?

        public var label: String { Body.labels[kind] ?? kind }

        /// The label as Auday sends it in bodyContext.
        public func json(_ iso: ISO8601DateFormatter) -> [String: Any] {
            var item: [String: Any] = ["kind": kind, "label": label, "confidence": confidence, "isEstimate": true,
                                       "scope": "interval", "start": iso.string(from: start), "end": iso.string(from: end),
                                       "evidenceStart": iso.string(from: evidenceStart), "evidenceEnd": iso.string(from: evidenceEnd),
                                       "observedStart": iso.string(from: observedStart), "observedEnd": iso.string(from: observedEnd)]
            if let motionContext { item["motionContext"] = motionContext }
            return item
        }
    }

    public struct Statistic: Equatable, Sendable {
        public var metric: String
        public var unit: String
        public var start: Date
        public var end: Date
        public var observedStart: Date
        public var observedEnd: Date
        public var average: Double
        public var minimum: Double
        public var maximum: Double
        public var sampleCount: Int

        public func json(_ iso: ISO8601DateFormatter) -> [String: Any] {
            ["metric": metric, "unit": unit, "start": iso.string(from: start), "end": iso.string(from: end),
             "observedStart": iso.string(from: observedStart), "observedEnd": iso.string(from: observedEnd),
             "average": average, "minimum": minimum, "maximum": maximum, "sampleCount": sampleCount]
        }
    }

    // MARK: rules

    static func resting(_ s: Samples, at: Date) -> Double {
        var best: Double?
        for r in s["rest", default: []] where r.start <= at { best = r.value }
        return best ?? 60
    }

    static func walking(_ s: Samples) -> [(Date, Date)] {
        var spans: [(Date, Date)] = []
        for r in s["steps", default: []] {
            let seconds = r.end.timeIntervalSince(r.start)
            guard seconds >= walkMin, r.value / (seconds / 60) >= walkCadence else { continue }
            if let last = spans.last, r.start.timeIntervalSince(last.1) < gap {
                spans[spans.count - 1].1 = max(last.1, r.end)
            } else {
                spans.append((r.start, r.end))
            }
        }
        return spans
    }

    static func motion(_ s: Samples, _ walks: [(Date, Date)], at: Date) -> String {
        if s["sleep", default: []].contains(where: { $0.start <= at && at <= $0.end }) { return "asleep" }
        if s["workout", default: []].contains(where: { $0.start <= at && at <= $0.end.addingTimeInterval(recovery) }) {
            return "recovering"
        }
        if walks.contains(where: { $0.0 <= at && at <= $0.1 }) { return "active" }
        for r in s["effort", default: []] where r.start <= at && at <= r.end {
            return r.value >= activeEffort ? "active" : r.value <= sedentaryEffort ? "sedentary" : "unknown"
        }
        return "unknown"
    }

    /// Median of calm readings over the 14 days before `at`'s day, once at least 2 of those days
    /// have 10 readings each.
    static func baseline(_ s: Samples, _ kind: String, at: Date, walks: [(Date, Date)] = [],
                         calendar: Calendar = .current) -> Double? {
        let day = calendar.startOfDay(for: at)
        let from = calendar.date(byAdding: .day, value: -baselineDays, to: day)!
        var values: [Double] = []
        var perDay: [Date: Int] = [:]
        for r in s[kind, default: []] where r.start >= from && r.start < day {
            if kind == "hr" && !["sedentary", "unknown"].contains(motion(s, walks, at: r.start)) { continue }
            values.append(r.value)
            perDay[calendar.startOfDay(for: r.start), default: 0] += 1
        }
        guard perDay.values.filter({ $0 >= baselineMinReadings }).count >= baselineMinDays else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    static func hrvLow(_ s: Samples, at: Date, base: Double?) -> Bool? {
        let recent = s["hrv", default: []].filter { $0.start >= at.addingTimeInterval(-freshHRV) && $0.start <= at }
        guard let base, let last = recent.last else { return nil }
        return last.value < base * stressHRV
    }

    struct Row {
        var time: Date
        var bpm: Double
        var context: String
        var state: String
    }

    static func interval(_ kind: String, _ run: [Row], next: Date?, observedFrom: Date? = nil) -> Interval {
        let first = run[0].time, last = run[run.count - 1].time
        let end = next.map { min(last.addingTimeInterval(tail), $0) } ?? last.addingTimeInterval(tail)
        return Interval(kind: kind, start: first, end: end, evidenceStart: first, evidenceEnd: end,
                        observedStart: observedFrom ?? first, observedEnd: last,
                        motionContext: kind == "heartRateElevated" ? run[0].context : nil)
    }

    static func nearWalk(_ walks: [(Date, Date)], _ start: Date, _ end: Date) -> Bool {
        walks.contains { $0.0.addingTimeInterval(-walkBefore) < end && start < $0.1.addingTimeInterval(walkAfter) }
    }

    static func stressConfidence(_ s: Samples, _ walks: [(Date, Date)], _ run: [Row], calendar: Calendar) -> String? {
        let at = run[0].time
        guard let hrBase = baseline(s, "hr", at: at, walks: walks, calendar: calendar) else { return "low" }
        if run.map(\.bpm).max()! <= hrBase * stressHR { return nil }
        let hrv = hrvLow(s, at: at, base: baseline(s, "hrv", at: at, calendar: calendar))
        return hrv == false ? nil : "medium"
    }

    /// All derived intervals, sorted by start.
    public static func context(_ samples: Samples, calendar: Calendar = .current) -> [Interval] {
        var s = samples
        for key in s.keys { s[key]!.sort { ($0.start, $0.end) < ($1.start, $1.end) } }
        let walks = walking(s)
        var out = walks.map { Interval(kind: "walking", start: $0.0, end: $0.1, evidenceStart: $0.0, evidenceEnd: $0.1,
                                       observedStart: $0.0, observedEnd: $0.1) }
        let rows: [Row] = s["hr", default: []].map { r in
            let rest = resting(s, at: r.start)
            let context = motion(s, walks, at: r.start)
            let limit = rest * (context == "sedentary" ? 1.2 : 1.25)
            let state = r.value > limit ? "high" : context == "sedentary" && r.value < rest ? "low" : "normal"
            return Row(time: r.start, bpm: r.value, context: context, state: state)
        }
        var episodeStart: Date?, episodeLast: Date?
        for (state, kind) in [("high", "heartRateElevated"), ("low", "stressLow")] {
            var run: [Row] = []
            for row in rows.map(Optional.some) + [nil] {
                if let row, row.state == state, run.isEmpty || row.time.timeIntervalSince(run[run.count - 1].time) < gap {
                    run.append(row)
                    continue
                }
                if !run.isEmpty {
                    let next = row?.time
                    if kind == "heartRateElevated" {
                        let elevated = interval(kind, run, next: next)
                        out.append(elevated)
                        if episodeLast == nil || run[0].time.timeIntervalSince(episodeLast!) > episodeGap {
                            episodeStart = run[0].time
                        }
                        episodeLast = run[run.count - 1].time
                        let late = run.filter { $0.time.timeIntervalSince(episodeStart!) >= stressAfter }
                        if !late.isEmpty, ["sedentary", "unknown"].contains(run[0].context),
                           !nearWalk(walks, late[0].time, elevated.evidenceEnd) {   // never active, asleep, recovering or walking
                            var stress = interval("stressElevated", late, next: next, observedFrom: episodeStart)
                            stress.end = elevated.evidenceEnd
                            stress.evidenceEnd = elevated.evidenceEnd
                            if let confidence = stressConfidence(s, walks, late, calendar: calendar) {
                                stress.confidence = confidence
                                out.append(stress)
                            }
                        }
                    } else if run.count >= 2 {
                        out.append(interval(kind, Array(run.dropFirst()), next: next, observedFrom: run[0].time))
                    }
                }
                run = (row?.state == state) ? [row!] : []
            }
        }
        return foldIntoWalks(out, walks: walks).sorted { ($0.start, $0.kind) < ($1.start, $1.kind) }
    }

    /// Replica rule (app/health._fold_into_walks): a raised heart rate just before, during or
    /// after a walk is part of the walk. It gets no label of its own and the walk is stretched over
    /// it (measured from the walk's own steps, so stretches do not chain); overlapping walks become
    /// one; High stress inside a walk is dropped.
    static func foldIntoWalks(_ items: [Interval], walks: [(Date, Date)]) -> [Interval] {
        func near(_ i: Interval, _ w: (Date, Date)) -> Bool {
            w.0.addingTimeInterval(-walkBefore) < i.end && i.start < w.1.addingTimeInterval(walkAfter)
        }
        func cover(_ w: inout Interval, _ i: Interval) {
            w.start = min(w.start, i.start); w.end = max(w.end, i.end)
            w.evidenceStart = min(w.evidenceStart, i.evidenceStart); w.evidenceEnd = max(w.evidenceEnd, i.evidenceEnd)
            w.observedStart = min(w.observedStart, i.observedStart); w.observedEnd = max(w.observedEnd, i.observedEnd)
        }
        var walkItems = items.filter { $0.kind == "walking" }
        for (n, w) in walks.enumerated() where walkItems.indices.contains(n) {
            for i in items where i.kind == "heartRateElevated" && near(i, w) { cover(&walkItems[n], i) }
        }
        var merged: [Interval] = []
        for w in walkItems.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, w.start <= last.end { cover(&merged[merged.count - 1], w) } else { merged.append(w) }
        }
        let rest = items.filter { i in
            i.kind != "walking"
                && !(i.kind == "heartRateElevated" && walks.contains { near(i, $0) })
                && !(i.kind == "stressElevated" && merged.contains { $0.start < i.end && i.start < $0.end })
        }
        return merged + rest
    }

    /// healthStatistics for one recorded range.
    public static func statistics(_ s: Samples, from start: Date, to end: Date) -> [Statistic] {
        [("hr", "heartRate", "bpm"), ("hrv", "hrvSDNN", "ms")].compactMap { kind, metric, unit in
            let values = s[kind, default: []].filter { $0.start >= start && $0.start < end }.sorted { $0.start < $1.start }
            guard let first = values.first, let last = values.last else { return nil }
            let nums = values.map(\.value)
            return Statistic(metric: metric, unit: unit, start: start, end: end, observedStart: first.start,
                             observedEnd: last.start, average: nums.reduce(0, +) / Double(nums.count),
                             minimum: nums.min()!, maximum: nums.max()!, sampleCount: nums.count)
        }
    }

    /// Intervals overlapping [start, end), clipped to it as Auday does at hour and fragment edges.
    public static func within(_ intervals: [Interval], from start: Date, to end: Date) -> [Interval] {
        intervals.filter { $0.start < end && $0.end > start }.map {
            var item = $0
            item.start = max(item.start, start)
            item.end = min(item.end, end)
            return item
        }
    }
}
