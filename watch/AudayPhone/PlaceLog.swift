import AudayKit
import Foundation
import Observation

/// Where the watch was while recording, kept on this iPhone (Application Support/places.json), so
/// the iPhone's own hour summaries and Highlights know the place, as Auday's do. Named here with
/// Apple's geocoder when the wearer stayed put; coordinates never go to the AI.
@MainActor @Observable
final class PlaceLog {
    private(set) var samples: [PlaceSample] = []
    private let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("places.json")

    init() {
        samples = (try? JSONDecoder().decode([PlaceSample].self, from: Data(contentsOf: file))) ?? []
    }

    /// One fragment's places: named when they all lie within PlaceNaming.stayRadius.
    func add(_ new: [PlaceSample]) async {
        guard !new.isEmpty else { return }
        var named = new
        if let centre = PlaceNaming.stay(new),
           let name = await Geocoder.name(latitude: centre.latitude, longitude: centre.longitude) {
            for i in named.indices { named[i].name = name }
        }
        samples = (samples + named).sorted { $0.time < $1.time }
        try? JSONEncoder().encode(samples).write(to: file, options: .atomic)
    }

    /// Auday's locationContext labels for [start, end), cut at the recordings' starts.
    func labels(from start: Date, to end: Date, cuts: [Date] = []) -> [LocationContext.Label] {
        let near = samples.filter { $0.time >= start.addingTimeInterval(-600) && $0.time < end.addingTimeInterval(120) }
        return LocationContext.labels(near, start: start, end: end, cuts: cuts)
    }
}
