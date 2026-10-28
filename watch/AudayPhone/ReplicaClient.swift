import AudayKit
import Foundation

/// One hour of a day, from the Mac (GET /api/day) or, before a Mac is connected, from what the
/// watch sent this iPhone.
struct DayHour: Identifiable, Equatable {
    var hour: Int
    var recordedSeconds: Double = 0
    var quiet = false
    var pendingAudio = 0
    var transcripts = 0
    var highlights = 0
    var marks = 0
    var title: String?          // the hour summary's title (Auday's shortNote)
    var firstText: String?
    var density: Int?           // information density 0–100
    var state: String?
    var onPhone = false         // recorded, not transcribed yet
    var failed = false          // transcription failed (Settings › Transcription › Transcribe now)
    var id: Int { hour }

    var captured: Bool { transcripts > 0 || onPhone || pendingAudio > 0 }

    var densityLabel: String? {
        density.map { $0 < 34 ? "Low information" : $0 < 67 ? "Medium information" : "High information" }
    }
}

struct DayData: Equatable {
    struct Reflection: Equatable {
        var id: String
        var title: String
        var highlights: Int?
    }

    var date: String
    var hours: [DayHour]
    var reflection: Reflection?
    var fromMac: Bool

    var recordedSeconds: Double { hours.reduce(0) { $0 + $1.recordedSeconds } }
}

/// Reads the replica's API on the Mac with the saved address and token.
@MainActor
final class ReplicaClient {
    let uploader: Uploader

    init(uploader: Uploader) { self.uploader = uploader }

    var connected: Bool { uploader.server != nil }

    func json(_ path: String) async throws -> Any {
        guard let server = uploader.server else { throw URLError(.cannotConnectToHost) }
        var request = URLRequest(url: URL(string: "api/" + path, relativeTo: server.appendingPathComponent("/"))!)
        request.timeoutInterval = 10
        if !uploader.token.isEmpty { request.setValue("Bearer \(uploader.token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONSerialization.jsonObject(with: data)
    }

    func dates() async throws -> [String] {
        (try await json("dates") as? [String: Any])?["dates"] as? [String] ?? []
    }

    func day(_ date: String) async throws -> DayData {
        let body = try await json("day?date=" + date) as? [String: Any] ?? [:]
        let hours = (body["hours"] as? [[String: Any]] ?? []).map { x -> DayHour in
            let transcripts = x["transcripts"] as? [[String: Any]] ?? []
            let summary = x["summary"] as? [String: Any]
            return DayHour(hour: x["hour"] as? Int ?? 0,
                           recordedSeconds: (x["recordedSeconds"] as? NSNumber)?.doubleValue ?? 0,
                           quiet: x["quiet"] as? Bool ?? false,
                           pendingAudio: x["pendingAudio"] as? Int ?? 0,
                           transcripts: transcripts.count,
                           highlights: (x["highlights"] as? [Any])?.count ?? 0,
                           marks: (x["marks"] as? [Any])?.count ?? 0,
                           title: summary?["title"] as? String,
                           firstText: transcripts.first?["text"] as? String,
                           density: (summary?["informationDensity"] as? NSNumber)?.intValue,
                           state: x["state"] as? String)
        }
        var reflection: DayData.Reflection?
        if let r = body["reflection"] as? [String: Any], let id = r["id"] as? String {
            reflection = .init(id: id, title: r["title"] as? String ?? "",
                               highlights: (r["stats"] as? [String: Any])?["highlights"] as? Int)
        }
        return DayData(date: date, hours: hours, reflection: reflection, fromMac: true)
    }

    /// The day as this iPhone knows it: the watch's recordings and marks, with the transcripts
    /// made on this iPhone.
    static func local(_ date: String, log: DayLog) -> DayData {
        guard let day = Format.ymd.date(from: date) else { return DayData(date: date, hours: [], fromMac: false) }
        var byHour: [Int: DayHour] = [:]
        var silent: [Int: Int] = [:]
        for entry in log.entries(on: day) {
            let hour = Calendar.current.component(.hour, from: entry.start)
            var x = byHour[hour] ?? DayHour(hour: hour)
            if entry.mark {
                x.marks += 1
            } else {
                x.recordedSeconds += entry.duration
                switch entry.status ?? .waiting {
                case .done:
                    x.transcripts += 1
                    if x.firstText == nil { x.firstText = entry.text }
                case .silent: silent[hour, default: 0] += 1
                case .waiting: x.onPhone = true
                case .failed:
                    x.onPhone = true
                    x.failed = true
                }
            }
            byHour[hour] = x
        }
        for (hour, n) in silent where n > 0 {
            if var x = byHour[hour], x.transcripts == 0, !x.onPhone { x.quiet = true; byHour[hour] = x }
        }
        return DayData(date: date, hours: byHour.values.sorted { $0.hour < $1.hour }, fromMac: false)
    }
}
