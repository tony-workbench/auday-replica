import AudayKit
import Foundation
import Observation
import UIKit

/// Auday's hourly and daily AI pipeline, run on this iPhone with the user's own provider (AI
/// settings). The prompts are app/auday_mode.py's, matched to what a real Auday device sends:
///   hour  → Summary (shortNote, summary, attention, memory candidates, density), Highlight
///           selection, then one interpretation per Highlight;
///   day   → overview (cover sentence and summary), Reflection, and the memory review that turns
///           the day's candidates into Review items.
@MainActor @Observable
final class Pipeline {
    private(set) var busy = false
    private(set) var status: String?
    private let log: DayLog
    private let store: LocalStore

    init(log: DayLog, store: LocalStore) {
        self.log = log
        self.store = store
    }

    // MARK: prompts (PipelinePrompts.swift, generated from app/auday_mode.py)

    static let outputRules = "Return only one valid JSON object with the requested fields: no markdown fences, reasoning or extra text."

    /// Everything generated is in the primary language. The second language only helps
    /// transcription; what was said in it is translated like any other (app/auday_mode._language_rule).
    static func languageRule() -> String {
        let primary = OutputLanguage.primary.englishName
        let also = OutputLanguage.secondary.map { " (including what the user said in \($0.englishName))" } ?? ""
        return "The user's primary language is \(primary). Write all generated text in \(primary), translating speech in any other language\(also); only proper names and technical terms may keep their original form. Never translate IDs, JSON keys or schema values."
    }

    private func ask(_ task: String, _ user: String) async throws -> [String: Any] {
        let system = [task, PipelinePrompts.dataRules, Self.languageRule(), Self.outputRules].joined(separator: "\n\n")
        let text = try await AIClient.complete([.init(role: "system", content: system), .init(role: "user", content: user)], json: true)
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.components(separatedBy: "\n").dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}") { body = String(body[start...end]) }
        guard let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any] else {
            throw AIClient.Failure.http(0, "The AI did not return JSON.")
        }
        return object
    }

    // MARK: hours

    struct Snippet {
        var id: String
        var time: Date
        var text: String
        var me = false

        /// One snippet as the model sees it; `"me": 1` for Me and Me*, as Auday sends.
        var json: String {
            let text = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
            return "{\"id\":\"\(id)\",\"time\":\"\(Format.english("HH:mm:ss", time))\",\"text\":\(text)\(me ? ",\"me\":1" : "")}"
        }
    }

    private func snippets(_ date: String, _ hour: Int) -> [Snippet] {
        guard let day = Format.ymd.date(from: date) else { return [] }
        var out: [Snippet] = []
        for entry in log.entries(on: day) where !entry.mark && entry.status == .done
            && Calendar.current.component(.hour, from: entry.start) == hour {
            for seg in entry.segments ?? [] {
                out.append(Snippet(id: "T\(out.count + 1)", time: entry.start.addingTimeInterval(seg.start), text: seg.text,
                                   me: VoiceModel.enabled && seg.me != nil))
            }
        }
        return out
    }

    /// Hours that have ended, are fully transcribed, have speech and no summary yet.
    func hoursToSummarize() -> [(String, Int)] {
        var due: [String: Set<Int>] = [:]
        var blocked: [String: Set<Int>] = [:]
        let now = Date()
        for entry in log.entries where !entry.mark {
            let date = Format.ymd.string(from: entry.start), hour = Calendar.current.component(.hour, from: entry.start)
            guard let end = Calendar.current.dateInterval(of: .hour, for: entry.start)?.end, end < now else { continue }
            switch entry.status ?? .waiting {
            case .done: due[date, default: []].insert(hour)
            case .waiting: blocked[date, default: []].insert(hour)
            default: break
            }
        }
        return due.flatMap { date, hours in hours.map { (date, $0) } }
            .filter { !(blocked[$0.0]?.contains($0.1) ?? false) && store.summary($0.0, $0.1) == nil }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }

    func summarize(_ date: String, _ hour: Int) async throws {
        let snips = snippets(date, hour)
        guard !snips.isEmpty else { return }
        let lines = snips.map(\.json).joined(separator: "\n")
        let marks = log.entries.filter { $0.mark && Format.ymd.string(from: $0.start) == date && Calendar.current.component(.hour, from: $0.start) == hour }
        let markText = marks.isEmpty ? "" : "\n<marks>\n" + marks.map { Format.english("HH:mm:ss", $0.start) }.joined(separator: "\n") + "\n</marks>"
        let places = hourPlaces(date, hour)
        let body = hourBody(date, hour)
        let request = "<hour>\(date) \(Format.hour(hour))–\(Format.hour(hour + 1))</hour>\n<snippets>\n\(lines)\n</snippets>\(markText)"
            + recordedContext(places, body, snips)

        status = "Summarizing \(Format.hour(hour))…"
        let s = try await ask(PipelinePrompts.summaryTask, request + "\n<final_task>\(PipelinePrompts.final["summary"]!)</final_task>")
        let memoryPoints = (s["memoryPoints"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        let summary = HourSummary(date: date, hour: hour, title: s["shortNote"] as? String ?? "", text: s["summary"] as? String ?? "",
                                  density: (s["informationDensity"] as? NSNumber)?.intValue,
                                  attention: s["attentionPoints"] as? [String] ?? [], memoryPoints: memoryPoints, updated: Date())

        status = "Choosing Highlights for \(Format.hour(hour))…"
        let picked = (try await ask(PipelinePrompts.highlightTask, request + "\n<final_task>\(PipelinePrompts.final["select"]!)</final_task>"))["highlights"] as? [[String: Any]] ?? []
        var highlights: [Highlight] = []
        for (n, h) in picked.prefix(8).enumerated() {
            guard let a = snips.firstIndex(where: { $0.id == h["startSourceID"] as? String }),
                  let b = snips.firstIndex(where: { $0.id == h["endSourceID"] as? String }), a <= b else { continue }
            let window = snips[max(0, a - 2)...min(snips.count - 1, b + 2)]
            let context = window.map(\.json).joined(separator: "\n")
            let title = h["title"] as? String ?? ""
            status = "Reading a Highlight at \(Format.english("HH:mm", snips[a].time))…"
            let i = try await ask(PipelinePrompts.interpretTask, "<highlight>\(title)\nfrom \(snips[a].id) to \(snips[b].id)</highlight>\n<snippets>\n\(context)\n</snippets>\n<final_task>\(PipelinePrompts.final["interpret"]!)</final_task>")
            let end = snips.indices.contains(b + 1) ? snips[b + 1].time : snips[b].time.addingTimeInterval(5)
            let marked = marks.contains { $0.start >= snips[a].time && $0.start <= end }
            // Chips: Conversation, then body states, then (as in Auday) the place from locationContext (📍) last.
            var signals = [Signal(kind: .conversation, label: "Conversation")]
            // Body states overlapping the Highlight, each once (app/auday_mode.signal_chips).
            for state in body.intervals where state.start <= end && state.end >= snips[a].time {
                guard let label = Body.chips[state.kind], !signals.contains(where: { $0.label == label }) else { continue }
                signals.append(Signal(kind: Self.chipKind[state.kind] ?? .other, label: label))
            }
            if let place = places.first(where: { $0.name != nil && $0.start < end && $0.end > snips[a].time })?.name {
                signals.append(Signal(kind: .place, label: place))
            }
            highlights.append(Highlight(id: "hl-\(date)-\(hour)-\(n)", start: snips[a].time, end: end, title: title,
                                        reading: i["interpretation"] as? String ?? h["reason"] as? String ?? "",
                                        signals: signals, marked: marked,
                                        attention: i["attentionPoints"] as? [String] ?? []))
        }
        store.change { c in
            c.summaries.removeAll { $0.date == date && $0.hour == hour }
            c.summaries.append(summary)
            c.highlights.removeAll { Format.ymd.string(from: $0.start) == date && Calendar.current.component(.hour, from: $0.start) == hour }
            c.highlights += highlights
        }
    }

    /// The watch's places in this hour, as Auday's locationContext.
    private func hourPlaces(_ date: String, _ hour: Int) -> [LocationContext.Label] {
        guard PhoneLink.locationData, let day = Format.ymd.date(from: date),
              let start = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { return [] }
        let cuts = log.entries(on: day).filter { !$0.mark }.map(\.start)
        return AppDelegate.places.labels(from: start, to: start.addingTimeInterval(3600), cuts: cuts)
    }

    static let chipKind: [String: Signal.Kind] = ["heartRateElevated": .heart, "stressElevated": .stress, "walking": .walk]

    /// Body context for the hour from the Health samples on this iPhone, as the Mac builds it
    /// (app/core.body_for): states clipped to the hour, heart-rate and HRV statistics per recording.
    private func hourBody(_ date: String, _ hour: Int) -> (intervals: [Body.Interval], stats: [Body.Statistic]) {
        guard HealthSync.enabled, let day = Format.ymd.date(from: date),
              let start = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { return ([], []) }
        let samples = AppDelegate.health.log.samples
        guard !samples.isEmpty else { return ([], []) }
        let end = start.addingTimeInterval(3600)
        let recorded = log.entries(on: day).filter { !$0.mark && $0.start < end && $0.start.addingTimeInterval($0.duration) > start }
        let stats = recorded.flatMap {
            Body.statistics(samples, from: max($0.start, start), to: min($0.start.addingTimeInterval($0.duration), end))
        }
        return (Body.within(Body.context(samples), from: start, to: end), stats)
    }

    /// <recorded_context_data> with the body states and heart-rate statistics, and the places
    /// (name, times, confidence; never coordinates) with the snippets each one covers, as the Mac
    /// sends it (app/auday_mode.recorded_context).
    private func recordedContext(_ places: [LocationContext.Label], _ body: (intervals: [Body.Interval], stats: [Body.Statistic]),
                                 _ snips: [Snippet]) -> String {
        guard !places.isEmpty || !body.intervals.isEmpty || !body.stats.isEmpty else { return "" }
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        let items: [[String: Any]] = places.map { p in
            var label: [String: Any] = ["confidence": p.confidence, "start": iso.string(from: p.start), "end": iso.string(from: p.end),
                                        "evidenceStart": iso.string(from: p.evidenceStart), "evidenceEnd": iso.string(from: p.evidenceEnd),
                                        "isApproximate": true, "nameSource": p.name == nil ? "unresolved" : "appleGeocoder"]
            if let name = p.name { label["name"] = name }
            return ["label": label, "sourceIDs": snips.filter { $0.time >= p.start && $0.time < p.end }.map(\.id)]
        }
        let data = try! JSONSerialization.data(withJSONObject: [
            "bodyContext": body.intervals.map { ["label": $0.json(iso)] },
            "healthStatistics": body.stats.map { $0.json(iso) },
            "locationContext": items,
        ], options: [.sortedKeys])
        return "\n<recorded_context_data>\n\(String(decoding: data, as: UTF8.self))\n</recorded_context_data>"
    }

    // MARK: day

    func reflect(_ date: String) async throws {
        let summaries = store.contents.summaries.filter { $0.date == date }.sorted { $0.hour < $1.hour }
        guard !summaries.isEmpty else { throw AIClient.Failure.http(0, "No hours of this day have been summarized yet.") }
        let highlights = store.highlights(date)
        let hours = summaries.map { "[\(Format.hour($0.hour))] \($0.title)\n\($0.text)" }.joined(separator: "\n\n")
        let cards = highlights.map { "[\(Format.english("HH:mm", $0.start))] \($0.title): \($0.reading)" }.joined(separator: "\n")
        let input = "<day>\(date)</day>\n<hour_summaries>\n\(hours)\n</hour_summaries>\n<highlights>\n\(cards)\n</highlights>"
        status = "Writing the daily overview…"
        let o = try await ask(PipelinePrompts.overviewTask, input + "\n<final_task>\(PipelinePrompts.final["overview"]!)</final_task>")
        let summary = o["summary"] as? String ?? ""
        status = "Writing the Reflection…"
        let r = try await ask(PipelinePrompts.reflectionTask, input + "\n<daily_summary>\(summary)</daily_summary>\n<final_task>\(PipelinePrompts.final["reflection"]!)</final_task>")

        // Memory review: the day's candidates become Review items, once per day as in Auday. A
        // second run for the same day (a resumed run) keeps that day's memories
        // instead of adding the same claim again in other words.
        let candidates = summaries.flatMap { $0.memoryPoints ?? [] }
        let chosenBefore = store.contents.memories.contains { $0.sourceDate == date }
        var memoryIDs: [String] = []
        if !candidates.isEmpty && !chosenBefore {
            status = "Choosing memories…"
            let list = candidates.enumerated().map { "{\"id\":\"m\($0.offset + 1)\",\"text\":\(json($0.element))}" }.joined(separator: "\n")
            let saved = store.memories(.saved).map { "- \($0.content)" }.joined(separator: "\n")
            let m = try await ask(PipelinePrompts.reviewTask, "<candidates>\n\(list)\n</candidates>\n<saved_profile>\n\(saved)\n</saved_profile>\n<final_task>Return the selected memories as JSON.</final_task>")
            let picked = (m["memories"] as? [[String: Any]] ?? []).filter {
                ["attribute", "state", "majorChange"].contains($0["kind"] as? String ?? "") && ($0["ownership"] as? String) == "clear"
            }
            let now = Date()
            var new: [Memory] = []
            for (n, item) in picked.prefix(12).enumerated() {
                guard let text = item["text"] as? String, !text.isEmpty else { continue }
                if store.contents.memories.contains(where: { $0.content == text }) { continue }
                let id = "mem-\(date)-\(n)-\(Int(now.timeIntervalSince1970))"
                new.append(Memory(id: id, content: text, status: .review, addedAt: now, sourceDate: date))
                memoryIDs.append(id)
            }
            store.change { $0.memories += new }
        }
        let reflection = Reflection(date: date, title: o["sentence"] as? String ?? "", summary: summary,
                                    text: r["reflection"] as? String ?? "",
                                    memoryIDs: memoryIDs.isEmpty
                                        ? (store.reflection(date)?.memoryIDs ?? store.contents.memories.filter { $0.sourceDate == date }.map(\.id))
                                        : memoryIDs,
                                    updatedAt: Date())
        store.change { c in
            c.reflections.removeAll { $0.date == date }
            c.reflections.append(reflection)
        }
    }

    /// Unreviewed memories are saved after 5 days, as in Auday.
    private func autoSave() {
        let cutoff = Date().addingTimeInterval(-5 * 86400)
        for m in store.memories(.review) where m.addedAt < cutoff { store.setMemory(m.id, status: .saved) }
    }

    /// Runs what is due: summaries for finished hours, then the due reflection.
    func run() async {
        guard !busy, AIConfig.configured else { return }
        busy = true
        defer { busy = false; status = nil }
        autoSave()
        if AIConfig.automaticHighlights {
            for (date, hour) in hoursToSummarize() {
                do { try await summarize(date, hour) } catch { status = error.localizedDescription; return }
            }
        }
        // Reflections are written only here, once per day (00:00 closes yesterday; 21:00 closes today).
        if AIConfig.dailyReflection, let day = Self.dayClosed(by: AIConfig.reflectionTime),
           store.reflection(day) == nil && store.contents.summaries.contains(where: { $0.date == day }) {
            try? await reflect(day)
        }
    }

    /// The day closed by the latest Reflection Time that has passed.
    static func dayClosed(by time: Date, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        guard var moment = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) else { return nil }
        if moment > now { moment = moment.addingTimeInterval(-86400) }
        return Format.ymd.string(from: moment.addingTimeInterval(-1))
    }

    /// Hours summarized before the voice profile existed saw no "me" snippets, so they got no
    /// memory points (those need a clear owner). They are redone once.
    func staleHours(_ date: String) -> [Int] {
        guard let enrolled = AppDelegate.voice.saved?.enrolledAt, VoiceModel.enabled else { return [] }
        return store.contents.summaries.filter { $0.date == date && ($0.updated ?? .distantPast) < enrolled }.map(\.hour).sorted()
    }

    /// The last "Generate" error, in plain words; interruptions are not errors.
    private(set) var problem: String?
    /// True while a generation waits for the app to come back after iOS suspended it.
    private(set) var paused = false
    /// A day whose generation has not finished. It is picked up whenever the app is opened, so a
    /// run always ends with a reflection; the hours already redone are not redone.
    static var pendingDay: String? {
        get { UserDefaults.standard.string(forKey: "pendingReflection") }
        set { UserDefaults.standard.set(newValue, forKey: "pendingReflection") }
    }

    /// Writes a day's reflection ("Generate"): summarizes the day's remaining and stale hours,
    /// then the reflection. A run that is cut off is resumed later.
    func generate(_ date: String) async throws {
        guard !busy else { return }
        busy = true
        paused = false
        problem = nil
        Self.pendingDay = date
        UIApplication.shared.isIdleTimerDisabled = true          // the screen does not lock mid-run
        let background = UIApplication.shared.beginBackgroundTask(withName: "Daily reflection") {}
        defer {
            busy = false; status = nil
            UIApplication.shared.isIdleTimerDisabled = false
            UIApplication.shared.endBackgroundTask(background)
        }
        do {
            // Hours three at a time, each retried through network hiccups.
            let hours = hoursToSummarize().filter { $0.0 == date }.map(\.1) + staleHours(date)
            var failed: [(Int, String)] = []
            for chunk in stride(from: 0, to: hours.count, by: 3).map({ Array(hours[$0..<min($0 + 3, hours.count)]) }) {
                try await withThrowingTaskGroup(of: (Int, String?).self) { group in
                    for hour in chunk {
                        group.addTask { @MainActor in
                            do { try await self.retrying { try await self.summarize(date, hour) }; return (hour, nil) }
                            catch let error where Self.interrupted(error) { throw error }
                            catch { return (hour, Self.explain(error)) }
                        }
                    }
                    for try await (hour, error) in group { if let error { failed.append((hour, error)) } }
                }
            }
            try await retrying { try await self.reflect(date) }
            Self.pendingDay = nil
            if !failed.isEmpty {
                problem = "Reflection written. These hours kept their earlier summary: "
                    + failed.map { "\(Format.hour($0.0)) (\($0.1))" }.joined(separator: "; ")
            }
        } catch where Self.interrupted(error) {
            paused = true                     // not an error: it continues when the app is open again
        } catch {
            problem = Self.explain(error)
            Self.pendingDay = nil
            throw error
        }
    }

    /// Network hiccups are retried (2 s, 5 s, 15 s) while the app is open.
    private func retrying(_ step: @escaping () async throws -> Void) async throws {
        var wait: [UInt64] = [2, 5, 15]
        while true {
            do { return try await step() } catch where Self.transient(error) && !wait.isEmpty
                && UIApplication.shared.applicationState == .active {
                try await Task.sleep(nanoseconds: wait.removeFirst() * 1_000_000_000)
            }
        }
    }

    private static func transient(_ error: Error) -> Bool {
        if case AIClient.Failure.http(let code, _) = error { return code == 429 || code >= 500 }
        return error is URLError
    }

    /// iOS suspended the app (it left the screen) or the run was cancelled: resume, do not report.
    private static func interrupted(_ error: Error) -> Bool {
        error is CancellationError || (error is URLError && UIApplication.shared.applicationState != .active)
            || (error as? URLError)?.code == .cancelled || (error as? URLError)?.code == .networkConnectionLost
    }

    /// The error in words the user can act on.
    static func explain(_ error: Error) -> String {
        switch error {
        case AIClient.Failure.notConfigured:
            return "No AI is set up. Add one in Settings › AI settings."
        case AIClient.Failure.http(let code, let body):
            let detail = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(body.prefix(140))
            let what = switch code {
            case 401, 403: "\(AIConfig.provider.rawValue) refused the API key"
            case 404: "\(AIConfig.provider.rawValue) does not know the model \(AIConfig.model)"
            case 429: "\(AIConfig.provider.rawValue) says you have hit its rate limit or quota"
            case 500...: "\(AIConfig.provider.rawValue) had a server problem"
            default: "\(AIConfig.provider.rawValue) rejected the request"
            }
            return "\(what) (HTTP \(code)): \(detail)"
        case let error as URLError where error.code == .notConnectedToInternet:
            return "No internet connection."
        case let error as URLError where error.code == .timedOut:
            return "\(AIConfig.provider.rawValue) took too long to answer, even after retrying."
        default:
            return error.localizedDescription
        }
    }

    func resumePending() async {
        guard let day = Self.pendingDay, !busy, AIConfig.configured else { return }
        try? await generate(day)
    }

    private func json(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast().description
    }
}

/// The languages Auday offers for generated text and, through TranscriptionLanguage, transcription.
enum OutputLanguage: String, CaseIterable {
    case english, mandarin, cantonese, japanese, korean

    var label: String {
        switch self {
        case .english: "English"
        case .mandarin: "普通话"
        case .cantonese: "粤语"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }

    var englishName: String {
        switch self {
        case .english: "English"
        case .mandarin: "Simplified Chinese (Mandarin)"
        case .cantonese: "Traditional Chinese (Cantonese)"
        case .japanese: "Japanese"
        case .korean: "Korean"
        }
    }

    var transcription: TranscriptionLanguage { TranscriptionLanguage(rawValue: rawValue)! }

    /// Auday's Settings › Language list (the app and AI language).
    static let appLanguages: [OutputLanguage] = [.mandarin, .english, .japanese, .korean]
    var appLabel: String {
        switch self {
        case .mandarin: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .cantonese: "粵語"
        }
    }

    static var primary: OutputLanguage {
        get { UserDefaults.standard.string(forKey: "language").flatMap(OutputLanguage.init)
                ?? OutputLanguage(rawValue: TranscriptionLanguage.preferred.rawValue) ?? .english }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "language") }
    }

    static var secondary: OutputLanguage? {
        get { UserDefaults.standard.string(forKey: "secondLanguage").flatMap(OutputLanguage.init) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "secondLanguage") }
    }
}
