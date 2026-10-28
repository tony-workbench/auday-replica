import AudayKit
import Foundation
import Network
import Observation

/// Uploads the outbox to the Mac: fragments to POST /api/audio (or, with "All text", their
/// transcripts to POST /api/transcripts), marks to POST /api/marks, places
/// (named first, when the wearer stayed put) to POST /api/places, Health samples to
/// POST /api/health/samples.
/// A background URLSession carries the uploads while the app is suspended. Failed items are
/// retried with backoff, and right away when the network comes back; an item the server refuses
/// (400, or 422 for audio it cannot read) is parked in Failed instead of being retried forever.
@MainActor @Observable
final class Uploader: NSObject, URLSessionDataDelegate {
    static let sessionID = "auday-replica.upload"

    private(set) var waiting: [Outbox.Item] = []
    private(set) var failedCount = 0
    private(set) var lastResult = "Nothing uploaded yet"
    /// When the Mac last took something ("Last read" on Connect to your workflow).
    private(set) var lastUploaded = UserDefaults.standard.object(forKey: "lastUploaded") as? Date
    private(set) var connection: String?

    var serverText: String
    var token: String

    let outbox: Outbox
    private let failed: Outbox
    private var session: URLSession!
    private var inFlight: Set<String> = []
    private var failures: [String: Int] = [:]
    private var notBefore: [String: Date] = [:]
    private var retryTimer: Timer?
    private var naming: Set<String> = []
    private let path = NWPathMonitor()
    var backgroundEventsDone: (() -> Void)?

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        outbox = try! Outbox(folder: support.appendingPathComponent("Outbox"))
        failed = try! Outbox(folder: support.appendingPathComponent("Failed"))
        serverText = UserDefaults.standard.string(forKey: "server") ?? ""
        token = Keychain.token ?? ""
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        session.getAllTasks { tasks in
            let ids = tasks.compactMap(\.taskDescription)
            Task { @MainActor in
                self.inFlight.formUnion(ids)
                self.pump()
            }
        }
        path.pathUpdateHandler = { update in
            guard update.status == .satisfied else { return }
            Task { @MainActor in
                self.notBefore.removeAll()
                self.pump()
            }
        }
        path.start(queue: .main)
    }

    var server: URL? { ReplicaAPI.serverURL(from: serverText) }

    /// Saves the address and token, then tries everything again with them.
    func saveSettings() {
        UserDefaults.standard.set(serverText, forKey: "server")
        Keychain.token = token
        retryNow()
    }

    /// Starts an upload for every item that is neither in flight nor waiting out a backoff.
    func pump() {
        waiting = outbox.items()
        failedCount = failed.items().count
        guard let server else { return }
        let now = Date()
        for item in waiting where !inFlight.contains(item.id) && (notBefore[item.id] ?? .distantPast) <= now {
            let task: URLSessionUploadTask
            switch item {
            case .fragment(let fragment) where MacLink.scope == .text:
                // "All text": the Mac gets the transcript made on this iPhone, not the audio.
                guard let entry = AppDelegate.dayLog.entries.first(where: { $0.id == fragment.id }) else { continue }
                switch entry.status ?? .waiting {
                case .waiting: continue
                case .silent, .failed:
                    outbox.remove(item)
                    continue
                case .done: break
                }
                var request = URLRequest(url: server.appendingPathComponent("api/transcripts"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                let segments = (entry.segments ?? []).map { ["speaker": "unknown", "text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }
                let body = try! JSONSerialization.data(withJSONObject: ["start": ReplicaAPI.iso(fragment.start), "segments": segments])
                guard let file = bodyFile(body, id: fragment.id) else { continue }
                task = session.uploadTask(with: request, fromFile: file)
            case .fragment(let fragment):
                task = session.uploadTask(with: ReplicaAPI.upload(fragment, server: server, token: token),
                                          fromFile: outbox.audioURL(for: fragment))
            case .mark(let mark):
                // Background sessions upload only from files.
                let (request, body) = ReplicaAPI.mark(mark, server: server, token: token)
                guard let file = bodyFile(body, id: mark.id) else { continue }
                task = session.uploadTask(with: request, fromFile: file)
            case .places(let batch):
                guard batch.resolved else {
                    name(batch)
                    continue
                }
                let (request, body) = ReplicaAPI.places(batch, server: server, token: token)
                guard let file = bodyFile(body, id: batch.id) else { continue }
                task = session.uploadTask(with: request, fromFile: file)
            case .health(let batch):
                let (request, body) = ReplicaAPI.health(batch, server: server, token: token)
                guard let file = bodyFile(body, id: batch.id) else { continue }
                task = session.uploadTask(with: request, fromFile: file)
            }
            task.taskDescription = item.id
            inFlight.insert(item.id)
            task.resume()
        }
        scheduleRetry()
    }

    private func bodyFile(_ body: Data, id: String) -> URL? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).json")
        return (try? body.write(to: file)) != nil ? file : nil
    }

    /// Asks the geocoder once per batch, only when its samples stay within PlaceNaming.stayRadius;
    /// otherwise the places stay unresolved, as most of Auday's do.
    private func name(_ batch: PlaceBatch) {
        guard !naming.contains(batch.id) else { return }
        naming.insert(batch.id)
        Task {
            var named = batch
            if let centre = PlaceNaming.stay(batch.samples),
               let name = await Geocoder.name(latitude: centre.latitude, longitude: centre.longitude) {
                for i in named.samples.indices { named.samples[i].name = name }
            }
            named.resolved = true
            try? outbox.add(named)
            naming.remove(batch.id)
            pump()
        }
    }

    /// Drops backoffs and tries everything now ("Upload now").
    func retryNow() {
        notBefore.removeAll()
        pump()
    }

    func checkConnection() async {
        guard let server else {
            connection = "Enter the Mac's address first"
            return
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: ReplicaAPI.status(server: server, token: token))
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: connection = "Connected to the replica"
            case 401: connection = "Wrong or missing token"
            case let code: connection = "Server returned \(code.map(String.init) ?? "?")"
            }
        } catch {
            connection = error.localizedDescription
        }
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        guard let next = notBefore.values.filter({ $0 > Date() }).min() else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSinceNow + 0.5, repeats: false) { _ in
            Task { @MainActor in self.pump() }
        }
    }

    private func finished(id: String, status: Int?, error: Error?) {
        inFlight.remove(id)
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("\(id).json"))
        guard let item = outbox.items().first(where: { $0.id == id }) else { return pump() }
        let when = ReplicaAPI.iso(item.start).prefix(19).suffix(8)
        switch ReplicaAPI.outcome(status: error == nil ? status : nil) {
        case .done:
            outbox.remove(item)
            failures[id] = nil
            notBefore[id] = nil
            lastResult = "Uploaded \(when)"
            lastUploaded = Date()
            UserDefaults.standard.set(lastUploaded, forKey: "lastUploaded")
        case .giveUp:
            outbox.park(item, in: failed)
            lastResult = "The server rejected the upload from \(when); kept in Failed"
        case .retry:
            let n = (failures[id] ?? 0) + 1
            failures[id] = n
            notBefore[id] = Date().addingTimeInterval(ReplicaAPI.retryDelay(afterFailures: n))
            lastResult = "Will retry \(when): " + (error?.localizedDescription ?? "server returned \(status ?? 0)")
        }
        pump()
    }

    // MARK: URLSession delegate (delegate queue is main)

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskDescription ?? ""
        let status = (task.response as? HTTPURLResponse)?.statusCode
        MainActor.assumeIsolated { finished(id: id, status: status, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            backgroundEventsDone?()
            backgroundEventsDone = nil
        }
    }
}

/// Secrets kept in this app's Keychain: the Mac server's token (`--token`), the pairing password
/// and the AI key.
enum Keychain {
    static var aiKey: String? {
        get { read("auday-replica.ai-key") }
        set { write("auday-replica.ai-key", newValue) }
    }


    static var pairPassword: String? {
        get { read("auday-replica.pair-password") }
        set { write("auday-replica.pair-password", newValue) }
    }

    static var token: String? {
        get { read("auday-replica.token") }
        set { write("auday-replica.token", newValue) }
    }

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private static func read(_ service: String) -> String? {
        var result: AnyObject?
        var lookup = query(service)
        lookup[kSecReturnData as String] = true
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ service: String, _ value: String?) {
        SecItemDelete(query(service) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = query(service)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
