import Foundation

/// Auday's watch stores audio in fragments of at most 15 minutes, counted from the start of the
/// recording and also cut at every clock hour: 11:09:33 → 11:24:33 → 11:39:33 → 11:54:33 → 12:00.
/// After a clock-hour cut the next fragment again runs up to 15 minutes from its own start.
public enum FragmentClock {
    public static let maxLength: TimeInterval = 15 * 60

    public static func end(of start: Date, calendar: Calendar = .current) -> Date {
        let cap = start.addingTimeInterval(maxLength)
        guard let hourEnd = calendar.dateInterval(of: .hour, for: start)?.end else { return cap }
        return min(cap, hourEnd)
    }
}

/// One finished audio fragment on its way from the watch to the Mac.
public struct Fragment: Codable, Equatable, Sendable {
    /// Unique per fragment; the server stores a retried upload only once.
    public var id: String
    /// A new session starts when the user taps start, and after a call or other interruption.
    public var session: String
    public var start: Date
    public var duration: TimeInterval
    public var ext: String
    /// Positions noted during this fragment (empty when Location data is off).
    public var places: [PlaceSample]

    public init(id: String = UUID().uuidString, session: String, start: Date, duration: TimeInterval, ext: String = "caf",
                places: [PlaceSample] = []) {
        self.id = id
        self.session = session
        self.start = start
        self.duration = duration
        self.ext = ext
        self.places = places
    }

    private enum CodingKeys: String, CodingKey { case id, session, start, duration, ext, places }

    /// Outbox items written before places existed still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), session: try c.decode(String.self, forKey: .session),
                  start: try c.decode(Date.self, forKey: .start), duration: try c.decode(Double.self, forKey: .duration),
                  ext: try c.decode(String.self, forKey: .ext),
                  places: try c.decodeIfPresent([PlaceSample].self, forKey: .places) ?? [])
    }

    /// WatchConnectivity metadata: property-list values only.
    public var metadata: [String: Any] {
        ["kind": "fragment", "id": id, "session": session, "start": start.timeIntervalSince1970,
         "duration": duration, "ext": ext, "places": places.map(\.plist)]
    }

    public init?(metadata: [String: Any]) {
        guard metadata["kind"] as? String == "fragment", let id = metadata["id"] as? String,
              let session = metadata["session"] as? String, let start = metadata["start"] as? Double
        else { return nil }
        self.init(id: id, session: session, start: Date(timeIntervalSince1970: start),
                  duration: metadata["duration"] as? Double ?? 0, ext: metadata["ext"] as? String ?? "caf",
                  places: (metadata["places"] as? [[Double]] ?? []).compactMap(PlaceSample.init(plist:)))
    }
}

/// "Mark this moment".
public struct Mark: Codable, Equatable, Sendable {
    public var id: String
    public var start: Date

    public init(id: String = UUID().uuidString, start: Date) {
        self.id = id
        self.start = start
    }

    public var userInfo: [String: Any] { ["kind": "mark", "id": id, "start": start.timeIntervalSince1970] }

    public init?(userInfo: [String: Any]) {
        guard userInfo["kind"] as? String == "mark", let id = userInfo["id"] as? String,
              let start = userInfo["start"] as? Double else { return nil }
        self.init(id: id, start: Date(timeIntervalSince1970: start))
    }
}

/// "TODAY, TOGETHER 6h 19m": seconds recorded on the current local day.
public struct RecordedToday: Codable, Equatable, Sendable {
    public private(set) var day: String
    public private(set) var seconds: TimeInterval

    public init(day: String = "", seconds: TimeInterval = 0) {
        self.day = day
        self.seconds = seconds
    }

    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Fragments never cross a clock hour, so never midnight either: each counts toward its start's day.
    public mutating func add(_ duration: TimeInterval, startedAt start: Date, calendar: Calendar = .current) {
        let key = Self.dayKey(start, calendar: calendar)
        if key != day {
            day = key
            seconds = 0
        }
        seconds += duration
    }

    public func seconds(on date: Date, calendar: Calendar = .current) -> TimeInterval {
        Self.dayKey(date, calendar: calendar) == day ? seconds : 0
    }

    public static func format(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
