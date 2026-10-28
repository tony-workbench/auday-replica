import AudayKit
import Foundation
import HealthKit
import Observation

/// Reads new Health samples straight from HealthKit, as Auday does, keeps them
/// on this iPhone for its own hour summaries (HealthLog), and queues them for the Mac's
/// POST /api/health/samples. Anchored queries return only what is new since the
/// last read; an anchor is saved only once its samples are safely in the outbox. Runs at launch,
/// when the app comes forward, and whenever the watch hands over a fragment (every 15 minutes
/// while recording), so the Mac has the body data for each recorded hour.
@MainActor @Observable
final class HealthSync {
    private(set) var lastResult: String?

    /// Auday's "Body data" switch.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "bodyData") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "bodyData") }
    }

    /// The first read goes back 15 days: app/health.py builds a personal baseline from up to
    /// 14 preceding days.
    static let history: TimeInterval = 15 * 24 * 3600

    private let store = HKHealthStore()
    let log = HealthLog()
    private let outbox: Outbox
    private let queued: () -> Void
    private var running = false

    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    private static let quantities: [(kind: String, type: HKQuantityType, unit: HKUnit)] = [
        ("hr", HKQuantityType(.heartRate), bpm),
        ("hrv", HKQuantityType(.heartRateVariabilitySDNN), .secondUnit(with: .milli)),
        ("steps", HKQuantityType(.stepCount), .count()),
        ("effort", HKQuantityType(.physicalEffort), HKUnit(from: "kcal/hr·kg")),
        ("rest", HKQuantityType(.restingHeartRate), bpm),
    ]
    private static let sleep = HKCategoryType(.sleepAnalysis)

    init(outbox: Outbox, queued: @escaping () -> Void) {
        self.outbox = outbox
        self.queued = queued
    }

    func run() async {
        guard Self.enabled, HKHealthStore.isHealthDataAvailable(), !running else { return }
        running = true
        defer { running = false }
        var read: Set<HKObjectType> = [Self.sleep, HKObjectType.workoutType()]
        Self.quantities.forEach { read.insert($0.type) }
        do {
            try await store.requestAuthorization(toShare: [], read: read)
        } catch {
            lastResult = "Health access unavailable: \(error.localizedDescription)"
            return
        }
        let predicate = HKQuery.predicateForSamples(withStart: Self.since(), end: nil)
        var added = 0
        do {
            // One-time backfill: samples read before this iPhone kept its own copy went only to the
            // Mac, so read the history again for the local log.
            if !UserDefaults.standard.bool(forKey: "healthLogSeeded") {
                try await seed(Date().addingTimeInterval(-Self.history))
                UserDefaults.standard.set(true, forKey: "healthLogSeeded")
            }
            for (kind, type, unit) in Self.quantities {
                let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)],
                                                                 anchor: Self.anchor(kind))
                let result = try await descriptor.result(for: store)
                added += try queue(kind, result.addedSamples.map {
                    HealthSample(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit))
                }, anchor: result.newAnchor)
            }
            let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
            let sleeps = HKAnchoredObjectQueryDescriptor(predicates: [.categorySample(type: Self.sleep, predicate: predicate)],
                                                         anchor: Self.anchor("sleep"))
            let sleepResult = try await sleeps.result(for: store)
            added += try queue("sleep", sleepResult.addedSamples.filter { asleep.contains($0.value) }.map {
                HealthSample(start: $0.startDate, end: $0.endDate, value: 1)
            }, anchor: sleepResult.newAnchor)
            let workouts = HKAnchoredObjectQueryDescriptor(predicates: [.workout(predicate)], anchor: Self.anchor("workout"))
            let workoutResult = try await workouts.result(for: store)
            added += try queue("workout", workoutResult.addedSamples.map {
                HealthSample(start: $0.startDate, end: $0.endDate, value: 1)
            }, anchor: workoutResult.newAnchor)
            lastResult = "Read \(added) new Health samples at \(ReplicaAPI.iso(Date()).prefix(16).suffix(5))"
        } catch {
            // Health data is unreadable while the phone is locked; the next run picks up from the last anchor.
            lastResult = "Health read paused: \(error.localizedDescription)"
        }
        if added > 0 { queued() }
    }

    private func seed(_ since: Date) async throws {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil)
        for (kind, type, unit) in Self.quantities {
            let query = HKSampleQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)], sortDescriptors: [])
            log.add(kind, try await query.result(for: store).map {
                HealthSample(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit))
            })
        }
        let asleep = Set(HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue))
        let sleeps = HKSampleQueryDescriptor(predicates: [.categorySample(type: Self.sleep, predicate: predicate)], sortDescriptors: [])
        log.add("sleep", try await sleeps.result(for: store).filter { asleep.contains($0.value) }.map {
            HealthSample(start: $0.startDate, end: $0.endDate, value: 1)
        })
        let workouts = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [])
        log.add("workout", try await workouts.result(for: store).map { HealthSample(start: $0.startDate, end: $0.endDate, value: 1) })
    }

    private func queue(_ kind: String, _ samples: [HealthSample], anchor: HKQueryAnchor) throws -> Int {
        log.add(kind, samples)
        for batch in HealthBatch.batches(kind: kind, samples) {
            try outbox.add(batch)
        }
        Self.save(anchor, kind)
        return samples.count
    }

    private static func since() -> Date {
        if let first = UserDefaults.standard.object(forKey: "healthSince") as? Date { return first }
        let first = Date().addingTimeInterval(-history)
        UserDefaults.standard.set(first, forKey: "healthSince")
        return first
    }

    private static func anchor(_ kind: String) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: "healthAnchor." + kind) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private static func save(_ anchor: HKQueryAnchor, _ kind: String) {
        let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        UserDefaults.standard.set(data, forKey: "healthAnchor." + kind)
    }
}
