import Foundation

/// A position the watch noted while recording (about every 2 minutes, as Auday's watch does).
public struct PlaceSample: Codable, Equatable, Sendable {
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    /// Horizontal accuracy in metres.
    public var accuracy: Double
    /// "Place · Street" from Apple's reverse geocoder, named on the iPhone; nil = unresolved.
    public var name: String?

    public init(time: Date, latitude: Double, longitude: Double, accuracy: Double, name: String? = nil) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.name = name
    }

    /// WatchConnectivity metadata holds property-list values only.
    var plist: [Double] { [time.timeIntervalSince1970, latitude, longitude, accuracy] }

    init?(plist: [Double]) {
        guard plist.count == 4 else { return nil }
        self.init(time: Date(timeIntervalSince1970: plist[0]), latitude: plist[1], longitude: plist[2], accuracy: plist[3])
    }
}

/// The places of one fragment, queued on the phone after the fragment itself.
public struct PlaceBatch: Codable, Equatable, Sendable {
    public var id: String
    public var session: String
    public var samples: [PlaceSample]
    /// Naming was tried (with or without a result); only then is the batch uploaded.
    public var resolved: Bool

    public init(fragment: Fragment) {
        id = fragment.id + "-places"
        session = fragment.session
        samples = fragment.places
        resolved = false
    }

    public var start: Date { samples.first?.time ?? .distantPast }
}

public enum PlaceNaming {
    public static let pollInterval: TimeInterval = 120
    /// The phone asks the geocoder only when every sample of a fragment stays this close to their
    /// centre (the wearer stayed put). Auday leaves ~60% of its places unresolved; this rule is a
    /// guess at why, not verified.
    public static let stayRadius: Double = 150

    /// Centre of the samples when they all lie within `stayRadius` of it, else nil.
    public static func stay(_ samples: [PlaceSample]) -> (latitude: Double, longitude: Double)? {
        guard !samples.isEmpty else { return nil }
        let lat = samples.map(\.latitude).reduce(0, +) / Double(samples.count)
        let lon = samples.map(\.longitude).reduce(0, +) / Double(samples.count)
        let far = samples.contains { metres(lat, lon, $0.latitude, $0.longitude) > stayRadius }
        return far ? nil : (lat, lon)
    }

    /// "Place · Street", the format of Auday's names. Drops a street equal to the place.
    public static func label(place: String?, street: String?) -> String? {
        let parts = [place, street].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = parts.first else { return nil }
        return parts.count > 1 && parts[1] != first ? "\(first) · \(parts[1])" : first
    }

    /// Auday keeps a name only for a real place (a point or area of interest, e.g. "City University");
    /// a bare street address stays unresolved. `name` is the geocoder's name for the spot,
    /// `addressLine` the first line of its address ("100 Main St"), `isPlace` whether the
    /// geocoder marked it a point of interest. The street is shown without its house number.
    public static func placeLabel(name: String?, addressLine: String?, isPlace: Bool) -> String? {
        let name = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let line = addressLine?.trimmingCharacters(in: .whitespaces) ?? ""
        let street = line.replacingOccurrences(of: #"^\d+[A-Za-z]?(-\d+)?\s+"#, with: "", options: .regularExpression)
        let looksLikeAddress = name.isEmpty || name == line || name == street
            || name.range(of: #"^\d+[A-Za-z]?(-\d+)?\s"#, options: .regularExpression) != nil
        guard isPlace || !looksLikeAddress else { return nil }
        return label(place: name, street: street.isEmpty ? nil : street)
    }

    /// Haversine distance in metres.
    public static func metres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}
