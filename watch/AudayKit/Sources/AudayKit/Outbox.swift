import Foundation

/// A folder of items waiting to be sent: on the watch, finished fragments until the phone has them;
/// on the phone, fragments, marks, places and Health samples until the Mac has them. Each item is
/// `<id>.json` (plus `<id>.<ext>` for audio), so the queue survives the app being killed. Only file
/// operations, so it can be used from the WatchConnectivity delegate queue.
public final class Outbox: @unchecked Sendable {
    public enum Item: Equatable, Sendable {
        case fragment(Fragment)
        case mark(Mark)
        case places(PlaceBatch)
        case health(HealthBatch)

        public var id: String {
            switch self {
            case .fragment(let f): return f.id
            case .mark(let m): return m.id
            case .places(let p): return p.id
            case .health(let h): return h.id
            }
        }

        public var start: Date {
            switch self {
            case .fragment(let f): return f.start
            case .mark(let m): return m.start
            case .places(let p): return p.start
            case .health(let h): return h.start
            }
        }
    }

    private struct Envelope: Codable {
        var fragment: Fragment?
        var mark: Mark?
        var places: PlaceBatch?
        var health: HealthBatch?
    }

    public let folder: URL
    private let files = FileManager.default

    public init(folder: URL) throws {
        self.folder = folder
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Moves `audio` into the outbox. The JSON is written last, so a half-added item is never listed.
    public func add(_ fragment: Fragment, audio: URL) throws {
        let target = audioURL(for: fragment)
        try? files.removeItem(at: target)
        try files.moveItem(at: audio, to: target)
        try write(Envelope(fragment: fragment), id: fragment.id)
    }

    public func add(_ mark: Mark) throws {
        try write(Envelope(mark: mark), id: mark.id)
    }

    /// Adds or replaces (after naming) a batch of places.
    public func add(_ places: PlaceBatch) throws {
        try write(Envelope(places: places), id: places.id)
    }

    public func add(_ health: HealthBatch) throws {
        try write(Envelope(health: health), id: health.id)
    }

    public func audioURL(for fragment: Fragment) -> URL {
        folder.appendingPathComponent("\(fragment.id).\(fragment.ext)")
    }

    /// Oldest first.
    public func items() -> [Item] {
        let names = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return names.filter { $0.hasSuffix(".json") }.compactMap { name -> Item? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
                  let envelope = try? decoder.decode(Envelope.self, from: data) else { return nil }
            if let fragment = envelope.fragment { return .fragment(fragment) }
            if let places = envelope.places { return .places(places) }
            if let health = envelope.health { return .health(health) }
            return envelope.mark.map(Item.mark)
        }.sorted { $0.start < $1.start }
    }

    public func fragments() -> [Fragment] {
        items().compactMap { if case .fragment(let f) = $0 { return f } else { return nil } }
    }

    public func remove(_ item: Item) {
        if case .fragment(let fragment) = item { try? files.removeItem(at: audioURL(for: fragment)) }
        try? files.removeItem(at: folder.appendingPathComponent("\(item.id).json"))
    }

    /// Keeps an item the server refused out of the queue without deleting the recording.
    public func park(_ item: Item, in other: Outbox) {
        if case .fragment(let fragment) = item {
            try? other.add(fragment, audio: audioURL(for: fragment))
        } else if case .mark(let mark) = item {
            try? other.add(mark)
        } else if case .places(let places) = item {
            try? other.add(places)
        } else if case .health(let health) = item {
            try? other.add(health)
        }
        remove(item)
    }

    private func write(_ envelope: Envelope, id: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(envelope)
        try data.write(to: folder.appendingPathComponent("\(id).json"), options: .atomic)
    }
}
