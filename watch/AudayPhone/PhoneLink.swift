import AudayKit
import Foundation
import WatchConnectivity

/// Receives fragments and marks from the watch and files them in the outbox for the uploader.
/// WatchConnectivity deletes a received file when the delegate method returns, so it is moved
/// right there, on the delegate's queue.
final class PhoneLink: NSObject, WCSessionDelegate {
    private let outbox: Outbox
    private let received: @Sendable () -> Void

    init(outbox: Outbox, received: @escaping @Sendable () -> Void) {
        self.outbox = outbox
        self.received = received
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Self.heard()
        receive(metadata: file.metadata ?? [:], audio: file.fileURL)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Self.heard()
        receive(userInfo: userInfo)
    }

    /// The watch's recorder status: {"recording": Bool, "pendingSince": seconds since 1970 (start
    /// of the audio not yet handed over), "pendingSeconds": finished audio still queued on the
    /// watch}. Your Watch shows it as "Awaiting sync", as Auday does.
    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Self.heard()
        UserDefaults.standard.set(context["recording"] as? Bool ?? false, forKey: "watchRecording")
        UserDefaults.standard.set(context["pendingSince"] as? Double ?? 0, forKey: "watchPendingSince")
        UserDefaults.standard.set(context["pendingSeconds"] as? Double ?? 0, forKey: "watchPendingSeconds")
        Self.changed()
    }

    /// Seconds of audio on the watch not yet on this iPhone (0 until the watch reports).
    static var awaitingOnWatch: Double {
        let d = UserDefaults.standard
        let queued = d.double(forKey: "watchPendingSeconds")
        let since = d.double(forKey: "watchPendingSince")
        let open = d.bool(forKey: "watchRecording") && since > 0 ? max(0, Date().timeIntervalSince1970 - since) : 0
        return queued + open
    }

    /// When the watch was last heard from. A watch app installed straight onto the watch (or
    /// right after this app is reinstalled) can read as "not installed" although its files arrive.
    static func heard() { UserDefaults.standard.set(Date(), forKey: "watchLastHeard") }
    static var heardRecently: Bool {
        guard let last = UserDefaults.standard.object(forKey: "watchLastHeard") as? Date else { return false }
        return Date().timeIntervalSince(last) < 20 * 60
    }

    /// Files a fragment from the watch (also used by the DEBUG inbox in the simulator).
    func receive(metadata: [String: Any], audio: URL) {
        guard let fragment = Fragment(metadata: metadata) else { return }
        try? outbox.add(fragment, audio: audio)
        DayLog.keepAudio(of: fragment, from: outbox.audioURL(for: fragment))
        let places = Self.locationData ? fragment.places : []
        Task { @MainActor in
            AppDelegate.dayLog.add(fragment)
            await AppDelegate.places.add(places)
            await AppDelegate.voice.upgradeIfNeeded()    // without waiting for a relaunch
            await AppDelegate.transcriber.run()
            await AppDelegate.voice.relabel()
            await AppDelegate.pipeline.run()
        }
        if !fragment.places.isEmpty && Self.locationData {
            try? outbox.add(PlaceBatch(fragment: fragment))
        }
        received()
    }

    func receive(userInfo: [String: Any]) {
        guard let mark = Mark(userInfo: userInfo) else { return }
        try? outbox.add(mark)
        Task { @MainActor in AppDelegate.dayLog.add(mark) }
        received()
    }

    /// Auday's "Location data" switch. The watch only notes positions while it is on.
    static var locationData: Bool {
        get { UserDefaults.standard.object(forKey: "locationData") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "locationData") }
    }

    func sendLocationData() {
        guard WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(["locationData": Self.locationData])
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        sendLocationData()
        Self.changed()
    }

    /// Posted when pairing, installation or reachability changes, so Your Watch refreshes.
    static let stateChanged = Notification.Name("watchStateChanged")
    private static func changed() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: stateChanged, object: nil) }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable { Self.heard() }
        Self.changed()
    }
    func sessionWatchStateDidChange(_ session: WCSession) { Self.changed() }

    /// "Manually sync now": the watch cuts the fragment it is recording and sends everything
    /// waiting. Asked directly while the watch app is open, otherwise queued for the watch.
    /// `done(true)` once the watch answered (or the request was queued).
    func requestSync(done: @escaping @Sendable (Bool) -> Void) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled || session.isReachable || Self.heardRecently else { done(false); return }
        if session.isReachable {
            session.sendMessage(["sync": true], replyHandler: { _ in done(true) }) { _ in
                session.transferUserInfo(["sync": true])
                done(true)
            }
        } else {
            session.transferUserInfo(["sync": true])
            done(true)
        }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()          // the user switched to another watch
    }
}
