import AudayKit
import CoreLocation
import Foundation
import Observation

/// Notes a position about every 2 minutes while capturing, as Auday's watch does when Location
/// data is on. Approximate accuracy is enough for "Place · Street" and saves battery.
@MainActor @Observable
final class PlaceSampler: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// For the sync page: whether the user allowed location, and when the last position came in.
    private(set) var allowed: CLAuthorizationStatus = .notDetermined
    private(set) var lastFix: Date?
    private var timer: Timer?
    private var samples: [PlaceSample] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Setting this without "location" in UIBackgroundModes is a fatal error.
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        manager.allowsBackgroundLocationUpdates = modes.contains("location")
        allowed = manager.authorizationStatus
    }

    /// Asks for permission while the user is looking at the app, not first when recording starts.
    func askIfNeeded() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func start() {
        guard timer == nil else { return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        // Started while the user is in the app, continuous updates keep coming with the screen
        // off and in the background; one-shot requests made from the background can be refused.
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        manager.allowsBackgroundLocationUpdates = modes.contains("location")
        manager.startUpdatingLocation()
        DiagLog.note("places start, background=\(manager.allowsBackgroundLocationUpdates)")
        let timer = Timer(timeInterval: PlaceNaming.pollInterval, repeats: true) { _ in
            Task { @MainActor in self.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Every 2 minutes: note the latest position, also when standing still and no update came.
    private func sample() {
        guard let location = manager.location, location.horizontalAccuracy >= 0,
              Date().timeIntervalSince(location.timestamp) < PlaceNaming.pollInterval * 2 else {
            DiagLog.note("place: no recent fix, asking once")
            manager.requestLocation()
            return
        }
        add(location, at: Date())
    }

    private func add(_ location: CLLocation, at time: Date) {
        samples.append(PlaceSample(time: time, latitude: location.coordinate.latitude,
                                   longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy))
        lastFix = time
        DiagLog.note("place sampled ±\(Int(location.horizontalAccuracy)) m")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        manager.stopUpdatingLocation()
    }

    /// The samples noted before `end`, removed from the buffer. The Mac files places by their own
    /// time, so a fix that arrives after its fragment was filed just travels with the next one.
    func take(before end: Date) -> [PlaceSample] {
        let taken = samples.filter { $0.time < end }
        samples.removeAll { $0.time < end }
        return taken
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Continuous updates only refresh manager.location; the 2-minute timer takes the samples.
        // A fix answering the timer's one-off request is taken right away.
        guard let last = locations.last(where: { $0.horizontalAccuracy >= 0 }) else { return }
        Task { @MainActor in
            if self.lastFix.map({ Date().timeIntervalSince($0) > PlaceNaming.pollInterval * 1.5 }) ?? true {
                self.add(last, at: last.timestamp)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix this time (indoors, permission off); the next sample tries again.
        DiagLog.note("place failed \((error as NSError).code)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.allowed = status }
    }
}
