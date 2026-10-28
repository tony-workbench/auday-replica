import Foundation
import Observation

/// What Auday writes about your days, kept on this iPhone: hour summaries, Highlights, daily
/// reflections, memories and Chat conversations. The on-device pipeline (AI settings) fills it;
/// the screens read it. Saved as one JSON file in Application Support.
struct HourSummary: Codable, Equatable {
    var date: String            // yyyy-MM-dd
    var hour: Int
    var title: String           // Auday's shortNote, shown on Days
    var text: String
    var density: Int?           // information density 0–100
    var attention: [String]? = nil
    var memoryPoints: [String]? = nil
    var updated: Date? = nil      // "Updated Oct 27 · 02:03" on the Summary tab
}

struct Signal: Codable, Equatable, Hashable {
    enum Kind: String, Codable { case conversation, place, heart, stress, walk, other }
    var kind: Kind
    var label: String
}

struct Highlight: Codable, Equatable, Identifiable {
    var id: String
    var start: Date
    var end: Date
    var title: String
    var reading: String
    var signals: [Signal]
    var marked = false
    var attention: [String]? = nil
}

struct Reflection: Codable, Equatable {
    var date: String
    var title: String
    var summary: String
    var text: String
    var memoryIDs: [String]
    var updatedAt: Date
}

struct Memory: Codable, Equatable, Identifiable {
    enum Status: String, Codable { case review, saved, inactive }
    var id: String
    var content: String
    var status: Status
    var addedAt: Date
    var savedAt: Date?
    var inactiveAt: Date?
    var sourceDate: String?
    var edited = false
}

struct ChatMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID().uuidString
    var role: Role
    var text: String
    var failed = false
    /// The transcript lines an answer cites, numbered 1, 2 … in the order they appear in it.
    var sources: [ChatSource]? = nil
}

/// One cited line: Auday keeps sources as IDs and shows the line and its audio from the phone,
/// so the model never writes the quote or the time itself.
struct ChatSource: Codable, Equatable, Hashable, Identifiable {
    var entry: String           // DayLog entry id
    var at: Date                // when the line was said
    var text: String
    var id: String { "\(entry)@\(at.timeIntervalSince1970)" }
}

struct Conversation: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var started: Date
    var messages: [ChatMessage]
    var question: String { messages.first { $0.role == .user }?.text ?? "" }
}

@MainActor @Observable
final class LocalStore {
    struct Contents: Codable {
        var summaries: [HourSummary] = []
        var highlights: [Highlight] = []
        var reflections: [Reflection] = []
        var memories: [Memory] = []
        var conversations: [Conversation] = []
        var recentSearches: [String] = []
    }

    private(set) var contents = Contents()
    private let file: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        file = support.appendingPathComponent("Library.json")
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: file), let saved = try? decoder.decode(Contents.self, from: data) {
            contents = saved
        }
    }

    func change(_ edit: (inout Contents) -> Void) {
        edit(&contents)
        try? JSONEncoder().encode(contents).write(to: file, options: .atomic)
    }

    func summary(_ date: String, _ hour: Int) -> HourSummary? {
        contents.summaries.first { $0.date == date && $0.hour == hour }
    }

    func highlights(_ date: String, hour: Int? = nil) -> [Highlight] {
        contents.highlights.filter {
            Format.ymd.string(from: $0.start) == date && (hour == nil || Calendar.current.component(.hour, from: $0.start) == hour)
        }.sorted { $0.start < $1.start }
    }

    func reflection(_ date: String) -> Reflection? { contents.reflections.first { $0.date == date } }

    func memories(_ status: Memory.Status) -> [Memory] {
        contents.memories.filter { $0.status == status }.sorted { $0.addedAt > $1.addedAt }
    }

    func setMemory(_ id: String, status: Memory.Status) {
        change { c in
            guard let i = c.memories.firstIndex(where: { $0.id == id }) else { return }
            c.memories[i].status = status
            if status == .saved { c.memories[i].savedAt = Date() }
            if status == .inactive { c.memories[i].inactiveAt = Date() }
        }
    }

    func editMemory(_ id: String, content: String) {
        change { c in
            guard let i = c.memories.firstIndex(where: { $0.id == id }) else { return }
            c.memories[i].content = content
            c.memories[i].edited = true
            c.memories[i].status = .saved            // editing counts as "This is about me"
            c.memories[i].savedAt = c.memories[i].savedAt ?? Date()
        }
    }

    func rememberSearch(_ query: String) {
        change { c in c.recentSearches = Array(([query] + c.recentSearches.filter { $0 != query }).prefix(8)) }
    }
}

#if DEBUG
extension LocalStore {
    /// Made-up sample content for checking the screens in DEBUG builds (Settings › About ›
    /// Load sample day). Nothing personal.
    func loadSample(on date: String) {
        guard let day = Format.ymd.date(from: date) else { return }
        func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
            Calendar.current.date(bySettingHour: h, minute: m, second: s, of: day)!
        }
        let place = Signal(kind: .place, label: "Recorded…")
        change { c in
            c.summaries.removeAll { $0.date == date }
            c.highlights.removeAll { Format.ymd.string(from: $0.start) == date }
            c.reflections.removeAll { $0.date == date }
            c.summaries += [
                HourSummary(date: date, hour: 9, title: "You planned the week's reading list and sorted notes from a museum visit.",
                            text: "A quiet planning hour.", density: 30),
                HourSummary(date: date, hour: 10, title: "A long call about a garden redesign: where the lemon tree goes, and a budget for new benches.",
                            text: "Garden call.", density: 60),
                HourSummary(date: date, hour: 14, title: "You walked to the bakery, talked about sourdough starters and agreed to swap recipes on Friday.",
                            text: "Bakery walk.", density: 55),
            ]
            c.highlights += [
                Highlight(id: "sample-h1", start: at(10, 12, 4), end: at(10, 31, 40), title: "Choosing a Spot for the Lemon Tree",
                          reading: "You weighed morning sun against shelter from wind and settled on the south wall.",
                          signals: [Signal(kind: .conversation, label: "Conversation"), place]),
                Highlight(id: "sample-h2", start: at(14, 5, 10), end: at(14, 6, 2), title: "Agreeing to Swap Sourdough Recipes",
                          reading: "A neighbour offered a rye starter; you agreed to trade recipes on Friday.",
                          signals: [Signal(kind: .walk, label: "Walk"), Signal(kind: .heart, label: "Elevated heart rate"), place], marked: true),
            ]
            let memory = Memory(id: "sample-m1", content: "You are redesigning your garden and want the lemon tree on the south wall.",
                                status: .review, addedAt: at(16, 8), sourceDate: date)
            if !c.memories.contains(where: { $0.id == memory.id }) {
                c.memories += [
                    memory,
                    Memory(id: "sample-m2", content: "You bake sourdough on weekends.", status: .saved, addedAt: at(16, 8),
                           savedAt: at(23, 51), sourceDate: date, edited: true),
                    Memory(id: "sample-m3", content: "You plan to repaint the fence in spring.", status: .inactive, addedAt: at(16, 8),
                           inactiveAt: at(23, 17), sourceDate: date),
                ]
            }
            c.reflections.append(Reflection(date: date, title: "A garden takes shape through small choices",
                                            summary: "You spent the morning planning the garden and the afternoon on a walk to the bakery.",
                                            text: "Small decisions about light and shelter added up to a plan you are happy with.",
                                            memoryIDs: ["sample-m1", "sample-m2"], updatedAt: at(16, 7)))
        }
    }
}
#endif
