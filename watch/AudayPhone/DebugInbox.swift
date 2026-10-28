#if DEBUG
import Foundation
import HealthKit
import notify

/// Simulator stand-in for the watch (DEBUG builds only): files dropped in Documents/DebugInbox
/// are handed to PhoneLink exactly as WatchConnectivity would hand them over.
///   <name>.json  the watch's metadata (Fragment.metadata) with <name>.<ext> next to it,
///                or a mark's userInfo (Mark.userInfo),
///                or {"kind": "health-seed", "hr": [[start, end, bpm]], "steps": [[start, end, count]]}
///                (epoch seconds): writes these samples to the simulator's Health, then runs HealthSync.
///                Writing needs NSHealthUpdateUsageDescription, which only a test build's Info.plist gets.
/// Read at launch, when the app comes forward, and on the Darwin notification `notification`:
///   xcrun simctl spawn booted notifyutil -p auday-replica.debug-inbox
enum DebugInbox {
    static let notification = "auday-replica.debug-inbox"

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DebugInbox")
    }

    static func listen(_ link: PhoneLink) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var token: Int32 = 0
        notify_register_dispatch(notification, &token, .main) { _ in drain(link) }
        drain(link)
    }

    static func drain(_ link: PhoneLink) {
        let files = FileManager.default
        let names = ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for name in names {
            let json = folder.appendingPathComponent(name)
            defer { try? files.removeItem(at: json) }
            guard let data = try? Data(contentsOf: json),
                  let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if info["kind"] as? String == "mark" {
                link.receive(userInfo: info)
            } else if info["kind"] as? String == "health-seed" {
                Task { @MainActor in
                    await seedHealth(info)
                    await AppDelegate.health.run()
                }
            } else {
                let audio = json.deletingPathExtension().appendingPathExtension(info["ext"] as? String ?? "caf")
                link.receive(metadata: info, audio: audio)
            }
        }
    }

    private static let store = HKHealthStore()

    @MainActor
    private static func seedHealth(_ info: [String: Any]) async {
        guard Bundle.main.object(forInfoDictionaryKey: "NSHealthUpdateUsageDescription") != nil else {
            return NSLog("DebugInbox: health-seed needs NSHealthUpdateUsageDescription in a test build's Info.plist")
        }
        let kinds: [(key: String, type: HKQuantityType, unit: HKUnit)] = [
            ("hr", HKQuantityType(.heartRate), HKUnit.count().unitDivided(by: .minute())),
            ("steps", HKQuantityType(.stepCount), .count()),
        ]
        try? await store.requestAuthorization(toShare: Set<HKSampleType>(kinds.map(\.type)), read: [])
        let samples = kinds.flatMap { kind in
            (info[kind.key] as? [[Double]] ?? []).map {
                HKQuantitySample(type: kind.type, quantity: HKQuantity(unit: kind.unit, doubleValue: $0[2]),
                                 start: Date(timeIntervalSince1970: $0[0]), end: Date(timeIntervalSince1970: $0[1]))
            }
        }
        do {
            try await store.save(samples)
            NSLog("DebugInbox: saved %d Health samples", samples.count)
        } catch {
            NSLog("DebugInbox: Health save failed: %@", error.localizedDescription)
        }
    }
}
#endif
