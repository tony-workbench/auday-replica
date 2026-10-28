import Foundation

/// Requests to the replica's Mac server (app/server.py).
public enum ReplicaAPI {
    /// "192.168.1.10:8765" or "http://mac.local:8765/" → http://192.168.1.10:8765
    public static func serverURL(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    /// The server files transcripts by the local wall-clock hour in this string, so it carries the
    /// local offset ("2026-10-26T11:09:33-07:00"), never "Z".
    public static func iso(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// POST /api/audio?start=…&ext=aac&session=…&fragment=…  — the body is the audio file (ADTS AAC,
    /// or CAF from older watch builds), sent with `uploadTask(with:fromFile:)`.
    public static func upload(_ fragment: Fragment, server: URL, token: String?, timeZone: TimeZone = .current) -> URLRequest {
        var components = URLComponents(url: server.appendingPathComponent("api/audio"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start", value: iso(fragment.start, timeZone: timeZone)),
            URLQueryItem(name: "ext", value: fragment.ext),
            URLQueryItem(name: "session", value: fragment.session),
            URLQueryItem(name: "fragment", value: fragment.id),
        ]
        // "+" in the offset would read as a space on the server.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(fragment.ext == "caf" ? "audio/x-caf" : "audio/aac", forHTTPHeaderField: "Content-Type")
        authorize(&request, token: token)
        return request
    }

    /// POST /api/marks {"start": …}  (app/core.py add_mark)
    public static func mark(_ mark: Mark, server: URL, token: String?, timeZone: TimeZone = .current) -> (URLRequest, Data) {
        var request = URLRequest(url: server.appendingPathComponent("api/marks"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, token: token)
        let body = try! JSONSerialization.data(withJSONObject: ["start": iso(mark.start, timeZone: timeZone)])
        return (request, body)
    }

    /// POST /api/places {"session": …, "places": [{"t", "lat", "lon", "accuracy", "name"}]}
    /// (app/core.py add_places). Coordinates go only to the user's own Mac.
    public static func places(_ batch: PlaceBatch, server: URL, token: String?, timeZone: TimeZone = .current) -> (URLRequest, Data) {
        var request = URLRequest(url: server.appendingPathComponent("api/places"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, token: token)
        let places: [[String: Any]] = batch.samples.map { sample in
            var item: [String: Any] = ["t": iso(sample.time, timeZone: timeZone), "lat": sample.latitude,
                                       "lon": sample.longitude, "accuracy": sample.accuracy]
            if let name = sample.name { item["name"] = name }
            return item
        }
        let body = try! JSONSerialization.data(withJSONObject: ["session": batch.session, "places": places],
                                               options: [.sortedKeys])
        return (request, body)
    }

    /// POST /api/health/samples {"samples": {kind: [[start, end, value], ...]}} (app/core.py sync_health).
    public static func health(_ batch: HealthBatch, server: URL, token: String?, timeZone: TimeZone = .current) -> (URLRequest, Data) {
        var request = URLRequest(url: server.appendingPathComponent("api/health/samples"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, token: token)
        let samples = batch.samples.mapValues { rows in
            rows.map { [iso($0.start, timeZone: timeZone), iso($0.end, timeZone: timeZone), $0.value] as [Any] }
        }
        let body = try! JSONSerialization.data(withJSONObject: ["samples": samples], options: [.sortedKeys])
        return (request, body)
    }

    /// GET /api/status, for "Check connection".
    public static func status(server: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: server.appendingPathComponent("api/status"))
        authorize(&request, token: token)
        return request
    }

    static func authorize(_ request: inout URLRequest, token: String?) {
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    public enum Outcome: Equatable { case done, retry, giveUp }

    /// 2xx: stored (or already stored). 400 or 422: the server rejected this item, so retrying cannot help.
    /// Anything else, including no answer at all, is retried.
    public static func outcome(status: Int?) -> Outcome {
        switch status {
        case .some(200..<300): return .done
        case .some(400), .some(422): return .giveUp      // refused, or audio that cannot be read
        default: return .retry
        }
    }

    /// Seconds to wait after the n-th consecutive failure: 5, 10, 20 … at most 5 minutes.
    public static func retryDelay(afterFailures n: Int) -> TimeInterval {
        min(300, 5 * pow(2, Double(max(0, n - 1))))
    }
}
