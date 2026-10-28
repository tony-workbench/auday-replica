import AudayKit
import Foundation
import Observation
import WatchConnectivity

/// Hands finished fragments to the iPhone with `transferFile` every 15 minutes (as Auday's watch
/// syncs) and on "Sync now". A fragment stays in the watch's outbox until the transfer finishes.
@MainActor @Observable
final class WatchLink: NSObject, WCSessionDelegate {
    static let syncInterval: TimeInterval = 15 * 60

    private(set) var phone = "Connecting…"
    private(set) var awaiting: [Fragment] = []
    private(set) var lastSync: Date?
    /// Fragments being handed to the iPhone right now.
    private(set) var sending = 0
    /// When the iPhone last took a fragment, and why the last hand-over failed, for the sync page.
    private(set) var lastDelivered = UserDefaults.standard.object(forKey: "lastDelivered") as? Date
    private(set) var syncProblem: String?
    /// "Sync now" from the iPhone: the recorder cuts the current fragment so it goes too. Set by
    /// the app; without it only filed fragments go.
    var syncRequested: (() -> Void)?
    /// Start of the fragment being recorded (nil when not recording). With the finished fragments
    /// still waiting, it goes to the iPhone as application context, so Your Watch › Awaiting sync
    /// counts up each second, as Auday's does.
    var recordingSince: Date? {
        didSet { publishPending() }
    }
    private(set) var today: RecordedToday
    /// The iPhone's "Location data" switch, sent as application context.
    private(set) var locationData = UserDefaults.standard.object(forKey: "locationData") as? Bool ?? true

    private let outbox: Outbox
    private var timer: Timer?
    private static let todayKey = "recordedToday"

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        outbox = try! Outbox(folder: support.appendingPathComponent("Outbox"))
        today = UserDefaults.standard.data(forKey: Self.todayKey)
            .flatMap { try? JSONDecoder().decode(RecordedToday.self, from: $0) } ?? RecordedToday()
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        restartTimer()
        refresh()
    }

    private func delivered() {
        syncProblem = nil
        lastDelivered = Date()
        UserDefaults.standard.set(lastDelivered, forKey: "lastDelivered")
    }

    /// The 15-minute count starts over after every sync, as on Auday's watch.
    private func restartTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.syncInterval, repeats: true) { _ in
            Task { @MainActor in self.syncNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var recordedToday: TimeInterval { today.seconds(on: Date()) }

    func enqueue(_ fragment: Fragment, audio: URL) {
        do {
            try outbox.add(fragment, audio: audio)
        } catch {
            try? FileManager.default.removeItem(at: audio)
            return
        }
        today.add(fragment.duration, startedAt: fragment.start)
        UserDefaults.standard.set(try? JSONEncoder().encode(today), forKey: Self.todayKey)
        refresh()
    }

    /// Marks are tiny: WatchConnectivity queues them itself and delivers them in order.
    func send(_ mark: Mark) {
        WCSession.default.transferUserInfo(mark.userInfo)
    }

    func syncNow() {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        let sending = Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?["id"] as? String })
        for fragment in outbox.fragments() where !sending.contains(fragment.id) {
            session.transferFile(outbox.audioURL(for: fragment), metadata: fragment.metadata)
        }
        lastSync = Date()
        restartTimer()
        refresh()
        // Nothing left to send: everything is on the iPhone as of now.
        if awaiting.isEmpty && self.sending == 0 { delivered() }
    }

    private func publishPending() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let pending = awaiting.reduce(0) { $0 + $1.duration }
        try? WCSession.default.updateApplicationContext([
            "recording": recordingSince != nil,
            "pendingSince": (recordingSince ?? Date()).timeIntervalSince1970,
            "pendingSeconds": pending,
        ])
    }

    private func refresh() {
        defer { publishPending() }        // after enqueue, sync, transfer done, activation
        awaiting = outbox.fragments()
        let session = WCSession.default
        sending = session.activationState == .activated ? session.outstandingFileTransfers.count : 0
        if !WCSession.isSupported() || session.activationState != .activated {
            phone = "Connecting…"
        } else if !session.isCompanionAppInstalled {
            phone = "Install the iPhone app"
        } else {
            phone = session.isReachable ? "iPhone connected" : "iPhone not nearby"
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.refresh()
            self.syncNow()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let on = context["locationData"] as? Bool else { return }
        Task { @MainActor in
            self.locationData = on
            UserDefaults.standard.set(on, forKey: "locationData")
        }
    }

    // "Manually sync now" on the iPhone: a message while this app is running, or user info that
    // waits for the next time it runs.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(["ok": true])
        if message["sync"] != nil { Task { @MainActor in self.syncFromPhone() } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["sync"] != nil { Task { @MainActor in self.syncFromPhone() } }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo["sync"] != nil { Task { @MainActor in self.syncFromPhone() } }
    }

    private func syncFromPhone() {
        DiagLog.note("sync asked by iPhone")
        if let syncRequested { syncRequested() } else { syncNow() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let metadata = fileTransfer.file.metadata ?? [:]
        Task { @MainActor in
            // On error the fragment stays in the outbox and goes again with the next sync.
            if let error {
                self.syncProblem = error.localizedDescription
            } else if let fragment = Fragment(metadata: metadata) {
                self.outbox.remove(.fragment(fragment))
                self.delivered()
            }
            self.refresh()
        }
    }
}
