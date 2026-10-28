import SwiftUI

// MARK: - Chat

/// Auday AI: asks your own provider (AI settings) about your days, with what this iPhone has
/// transcribed and summarized as context.
struct ChatView: View {
    let log: DayLog
    let store: LocalStore
    @Environment(\.navigate) private var navigate
    @State private var conversation: Conversation?
    @State private var draft = ""
    @State private var task: Task<Void, Never>?
    @State private var showConversations = false
    @State private var shownSource: ChatSource?
    @State private var player = HourPlayer()
    @FocusState private var typing: Bool

    static let suggestions = ["Help me find that idea I mentioned recently.", "What could I have done better lately?",
                              "What needs my attention next week?"]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let conversation, !conversation.messages.isEmpty {
                            ForEach(conversation.messages) { message(message: $0) }
                            if task != nil {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Reading your days…").font(.system(size: 19)).foregroundStyle(Theme.muted)
                                }
                                .id("reading")
                            }
                        } else {
                            empty
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: conversation?.messages.count) { _, _ in withAnimation { proxy.scrollTo("reading", anchor: .bottom) } }
            }
            composer
        }
        .padding(.bottom, 70)
        .background(Theme.bg)
        .sheet(item: $shownSource) { source in sourceSheet(source) }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showConversations) {
            ConversationsSheet(store: store) { conversation = $0; showConversations = false }
                .presentationDetents([.medium, .large]).presentationBackground(Theme.bg)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            AudayLogo(size: 20)
            Text("Auday AI").font(Theme.serif(22, .regular))
            Spacer()
            Group {
                Button { navigate(.memory) } label: { Image(systemName: "square.3.layers.3d") }.accessibilityLabel("Your memory")
                Button { showConversations = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("Conversations")
                Button { task?.cancel(); task = nil; conversation = nil; draft = "" } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel("New conversation")
            }
            .font(.system(size: 17)).frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20).padding(.top, 8)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("YOUR LIFE IS THE CONTEXT").font(.system(size: 13, weight: .medium)).tracking(1.8).foregroundStyle(Theme.muted)
                .padding(.top, 34)
            Text("Less explaining.\nMore\nunderstanding.").font(Theme.serif(40, .regular)).lineSpacing(-2)
            Text("Your conversations, memories, and daily rhythms give Auday AI a fuller picture.")
                .font(.system(size: 19)).foregroundStyle(Theme.muted).lineSpacing(3)
            VStack(spacing: 0) {
                ForEach(Self.suggestions, id: \.self) { q in
                    Button { send(q) } label: {
                        HStack(alignment: .top) {
                            Text(q).font(.system(size: 19)).multilineTextAlignment(.leading)
                            Spacer(minLength: 20)
                            Image(systemName: "arrow.up.left").font(.system(size: 15))
                        }
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(.top, 14)
            Text("Answers link back to the transcript and original audio.").font(.system(size: 17)).foregroundStyle(Theme.muted)
        }
    }

    private func message(message m: ChatMessage) -> some View {
        Group {
            if m.role == .user {
                HStack {
                    Spacer(minLength: 50)
                    Text(m.text).font(.system(size: 21)).padding(.horizontal, 16).padding(.vertical, 12).card(Theme.panel, radius: 18)
                }
            } else if m.failed {
                VStack(alignment: .leading, spacing: 14) {
                    Text("No answer was saved. You can ask this question again.").font(.system(size: 17)).foregroundStyle(Theme.muted)
                    if !m.text.isEmpty { Text(m.text).font(.system(size: 14)).foregroundStyle(Theme.faint) }
                    Button("Ask again") { askAgain() }.font(.system(size: 18, weight: .medium)).buttonStyle(.plain)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        AudayLogo(size: 13)
                        Text("AUDAY").font(.system(size: 15, weight: .medium)).tracking(1.5)
                    }
                    .foregroundStyle(Theme.muted)
                    Text(answer(m)).font(.system(size: 19)).lineSpacing(4).textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "auday-source", let n = Int(url.host() ?? ""),
                                  let sources = m.sources, sources.indices.contains(n - 1) else { return .systemAction }
                            play(sources[n - 1])
                            return .handled
                        })
                    // Auday lists the cited recordings under the answer; tapping one plays it.
                    if let sources = m.sources {
                        VStack(spacing: 8) {
                            ForEach(Array(sources.enumerated()), id: \.offset) { n, source in sourceCard(n + 1, source) }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    /// The answer with Markdown emphasis applied and each cited source as a small numbered tag
    /// (Auday's ¹ ² chips) that opens the line and its audio.
    private func answer(_ m: ChatMessage) -> AttributedString {
        var out = AttributedString()
        let pieces = m.text.components(separatedBy: "\u{1F}")       // text \u1F n \u1F text …
        for (i, piece) in pieces.enumerated() {
            if i % 2 == 1, let n = Int(piece) {
                var tag = AttributedString(" \(n) ")
                tag.font = .system(size: 14, weight: .medium)
                tag.foregroundColor = Theme.muted
                tag.backgroundColor = Theme.panel2
                tag.link = URL(string: "auday-source://\(n)")
                out += AttributedString(" ") + tag
            } else {
                out += (try? AttributedString(markdown: piece, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(piece)
            }
        }
        return out
    }

    @State private var playingSource: ChatSource?

    /// Plays a cited line from its moment in the recording; tapping the playing one stops it.
    private func play(_ source: ChatSource) {
        if playingSource == source, player.playing { player.stop(); playingSource = nil; return }
        guard let entry = log.entries.first(where: { $0.id == source.entry }),
              FileManager.default.fileExists(atPath: DayLog.audioURL(for: entry).path) else { shownSource = source; return }
        player.play(entries: [entry], from: source.at)
        playingSource = source
    }

    private func sourceCard(_ n: Int, _ source: ChatSource) -> some View {
        let active = playingSource == source && player.playing
        return Button { play(source) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: active ? "stop.fill" : "play.fill").font(.system(size: 11))
                    .frame(width: 30, height: 30).overlay(Circle().stroke(Theme.muted, lineWidth: 1.2))
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(n)  ·  " + Format.english("MMM d · HH:mm:ss", source.at))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted)
                    Text(source.text).font(Theme.serif(17, .regular)).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu { Button("Show the line") { shownSource = source } }
    }

    private func sourceSheet(_ source: ChatSource) -> some View {
        let entry = log.entries.first { $0.id == source.entry }
        return VStack(alignment: .leading, spacing: 16) {
            Text(Format.english("MMM d · HH:mm:ss", source.at)).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.muted)
            Text(source.text).font(Theme.serif(22, .regular)).lineSpacing(3)
            if let entry, FileManager.default.fileExists(atPath: DayLog.audioURL(for: entry).path) {
                Button {
                    if player.playing { player.stop() } else { player.play(entries: [entry], from: source.at) }
                } label: {
                    Label(player.playing ? "Stop" : "Play original audio", systemImage: player.playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.onInk)
                        .padding(.horizontal, 18).frame(height: 46).background(Theme.ink, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text("The original audio is no longer kept.").font(.system(size: 16)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium]).presentationBackground(Theme.bg)
        .onDisappear { player.stop() }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                TextField("Ask about your days...", text: $draft, axis: .vertical)
                    .font(.system(size: 20)).lineLimit(1...4).focused($typing)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.line))
                    .onSubmit { send(draft) }
                Button {
                    if task != nil { task?.cancel(); task = nil } else { send(draft) }
                } label: {
                    Image(systemName: task != nil ? "stop.fill" : "arrow.up").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.onInk).frame(width: 38, height: 38)
                        .background(task != nil || !draft.isEmpty ? Theme.ink : Theme.faint.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task != nil ? "Stop" : "Send")
                .sensoryFeedback(.impact(weight: .light), trigger: task != nil)
            }
            Text(AIConfig.model.isEmpty ? "No AI set up" : AIConfig.model).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16).padding(.top, 6)
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, task == nil else { return }
        draft = ""
        var convo = conversation ?? Conversation(started: Date(), messages: [])
        convo.messages.append(ChatMessage(role: .user, text: question))
        conversation = convo
        task = Task {
            var reply: ChatMessage
            do {
                let (messages, lines) = prompt(for: convo)
                let answer = try await AIClient.complete(messages)
                reply = Self.cite(answer, lines: lines)
            } catch is CancellationError {
                reply = ChatMessage(role: .assistant, text: "Stopped.", failed: true)
            } catch {
                reply = ChatMessage(role: .assistant, text: error.localizedDescription, failed: true)
            }
            guard var current = conversation else { task = nil; return }
            current.messages.append(reply)
            conversation = current
            let saved = current
            store.change { c in
                c.conversations.removeAll { $0.id == saved.id }
                c.conversations.insert(saved, at: 0)
            }
            task = nil
        }
    }

    private func askAgain() {
        guard var convo = conversation, let last = convo.messages.last(where: { $0.role == .user }) else { return }
        convo.messages.removeLast(2)
        conversation = convo
        send(last.text)
    }

    /// What Auday AI may read: recent transcript lines (each with an ID it cites), summaries and
    /// saved memories. Returns the messages and the lines by ID.
    private func prompt(for convo: Conversation) -> ([AIClient.Message], [String: ChatSource]) {
        let recent = log.entries.filter { $0.status == .done && $0.start > Date().addingTimeInterval(-14 * 86400) }
        var lines: [(String, ChatSource)] = []
        for entry in recent {
            for seg in entry.segments ?? [] {
                lines.append(("S\(lines.count + 1)", ChatSource(entry: entry.id, at: entry.start.addingTimeInterval(seg.start), text: seg.text)))
            }
        }
        var context = ""
        for (id, line) in lines.reversed() {           // newest first until the budget is used
            let row = "\(id) [\(Format.english("yyyy-MM-dd HH:mm:ss", line.at))] \(line.text)\n"
            if context.count + row.count > 24000 { break }
            context = row + context
        }
        let memories = store.memories(.saved).map { "- \($0.content)" }.joined(separator: "\n")
        let summaries = store.contents.summaries.suffix(60).map { "[\($0.date) \(Format.hour($0.hour))] \($0.title)" }.joined(separator: "\n")
        let system = """
        You are Auday AI. Answer questions about the user's own days from their recordings. Be concise and specific, \
        and say when something is not in the records. \(Pipeline.languageRule())
        Cite the transcript lines a statement rests on by their IDs in square brackets right after it, e.g. [S12] or \
        [S12][S15]. Cite instead of writing times or quoting: the app shows each cited line and plays its audio. \
        Use only IDs listed below. Plain text: no Markdown headings, bold or tables.
        Saved memories:
        \(memories)
        Hour summaries:
        \(summaries)
        Transcript lines:
        \(context)
        """
        let messages: [AIClient.Message] = [.init(role: "system", content: system)] + convo.messages.filter { !$0.failed }.suffix(12).map {
            .init(role: $0.role.rawValue, content: $0.text.replacingOccurrences(of: "\u{1F}", with: ""))
        }
        return (messages, Dictionary(lines, uniquingKeysWith: { a, _ in a }))
    }

    /// Turns [S12] citations into numbered tags (1, 2 … by first appearance); unknown IDs are dropped.
    static func cite(_ answer: String, lines: [String: ChatSource]) -> ChatMessage {
        var sources: [ChatSource] = []
        var numbers: [String: Int] = [:]
        let regex = try! NSRegularExpression(pattern: #"\s*\[(S\d+)\]"#)
        var text = ""
        var last = answer.startIndex
        for match in regex.matches(in: answer, range: NSRange(answer.startIndex..., in: answer)) {
            guard let whole = Range(match.range, in: answer), let idRange = Range(match.range(at: 1), in: answer) else { continue }
            text += answer[last..<whole.lowerBound]
            last = whole.upperBound
            let id = String(answer[idRange])
            guard let line = lines[id] else { continue }
            let n = numbers[id] ?? { sources.append(line); numbers[id] = sources.count; return sources.count }()
            text += "\u{1F}\(n)\u{1F}"
        }
        text += answer[last...]
        return ChatMessage(role: .assistant, text: text, sources: sources.isEmpty ? nil : sources)
    }
}

struct ConversationsSheet: View {
    let store: LocalStore
    let open: (Conversation) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if store.contents.conversations.isEmpty {
                        Text("No conversations yet.").foregroundStyle(Theme.muted).padding(.top, 30)
                    }
                    ForEach(store.contents.conversations) { c in
                        Button { open(c) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(c.question).font(.system(size: 19)).multilineTextAlignment(.leading)
                                Text(Format.english("MMM d, yyyy · HH:mm", c.started)).font(.system(size: 17)).foregroundStyle(Theme.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(18).card()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.fontWeight(.semibold) } }
        }
    }
}

// MARK: - Search

struct SearchScope: Equatable {
    enum Kind: Equatable { case all, day(String), range(String, String), days(Set<String>) }
    var kind: Kind = .all

    func contains(_ date: String) -> Bool {
        switch kind {
        case .all: true
        case .day(let d): date == d
        case .range(let a, let b): date >= a && date <= b
        case .days(let set): set.contains(date)
        }
    }

    var label: String {
        let today = Format.ymd.string(from: Date())
        switch kind {
        case .all: return "All days"
        case .day(let d): return d == today ? "Today" : short(d)
        case .range(let a, let b):
            if b == today && a == Format.ymd.string(from: Date().addingTimeInterval(-6 * 86400)) { return "Last 7 days" }
            if b == today && a == Format.ymd.string(from: Date().addingTimeInterval(-29 * 86400)) { return "Last 30 days" }
            return "\(short(a)) – \(short(b))"
        case .days(let set): return Format.plural(set.count, "day")
        }
    }

    private func short(_ d: String) -> String { Format.english("MMM d", Format.ymd.date(from: d) ?? Date()) }
}

struct SearchResult: Identifiable {
    var id: String
    var kind: String
    var date: Date
    var title: String?
    var snippet: String
    var page: Page
}

struct SearchView: View {
    let log: DayLog
    let store: LocalStore
    let askChat: () -> Void
    @Environment(\.navigate) private var navigate
    @State private var query = ""
    @State private var results: [SearchResult]?
    @State private var scope = SearchScope()
    @State private var choosingScope = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Find it in\nyour day").font(Theme.serif(40, .regular)).lineSpacing(-2)
                        Text("Keyword and\nsemantic search").font(.system(size: 19)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button { choosingScope = true } label: {
                        VStack(spacing: 3) {
                            HStack(spacing: 2) { Image(systemName: "calendar"); Image(systemName: "chevron.down").font(.system(size: 7)) }
                                .font(.system(size: 13))
                            Text(scope.label).font(.system(size: 9, weight: .medium))
                        }
                        .frame(width: 58, height: 52).card(Theme.panel, radius: 12)
                    }
                    .buttonStyle(.plain).padding(.top, 30)
                }
                .padding(.top, 20)
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 20)).foregroundStyle(Theme.muted)
                    TextField("", text: $query).font(.system(size: 19)).focused($focused).submitLabel(.search)
                        .onSubmit(run)
                        .onChange(of: query) { _, q in if q.isEmpty { results = nil } }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
                .padding(.top, 24)
                if let results { resultList(results) } else { idle }
            }
            .padding(.horizontal, 20).padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .sheet(isPresented: $choosingScope) {
            ScopeSheet(scope: scope, marked: Set(log.days().map(Format.ymd.string))) { scope = $0; if results != nil { run() } }
                .presentationDetents([.large]).presentationDragIndicator(.visible).presentationBackground(Theme.bg)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent searches").font(Theme.serif(28, .regular)).padding(.top, 36)
            if store.contents.recentSearches.isEmpty {
                Text("No recent searches").font(.system(size: 19)).foregroundStyle(Theme.muted).padding(.top, 14)
            } else {
                ForEach(store.contents.recentSearches, id: \.self) { q in
                    Button { query = q; run() } label: {
                        Label(q, systemImage: "clock").font(.system(size: 19)).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Want to explore further?").font(Theme.serif(28, .regular)).padding(.top, 40)
            Text("Chat can help you follow\nthe clues.").font(.system(size: 19)).foregroundStyle(Theme.muted).padding(.top, 8)
            Button(action: askChat) {
                HStack(spacing: 4) { Text("Ask Chat").underline(); Image(systemName: "arrow.up.right").font(.system(size: 10)) }
                    .font(.system(size: 20, weight: .medium))
            }
            .buttonStyle(.plain).padding(.top, 14)
        }
    }

    private func resultList(_ list: [SearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(list.isEmpty ? "Nothing found" : Format.plural(list.count, "result")).font(Theme.serif(28, .regular))
                Spacer()
                Text(scope.label).foregroundStyle(Theme.muted)
            }
            .padding(.top, 30)
            ForEach(list) { r in
                Button { navigate(r.page) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(r.kind.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
                            Spacer()
                            Text(Format.when(r.date)).font(.system(size: 13)).foregroundStyle(Theme.faint)
                        }
                        if let title = r.title { Text(title).font(Theme.serif(21, .regular)).multilineTextAlignment(.leading) }
                        Text(r.snippet).font(.system(size: 16)).foregroundStyle(Theme.muted).lineLimit(3).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16).card()
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Keyword search over everything kept on this iPhone.
    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        store.rememberSearch(q)
        func hit(_ text: String) -> Bool { text.localizedCaseInsensitiveContains(q) }
        func snippet(_ text: String) -> String {
            guard let range = text.range(of: q, options: .caseInsensitive) else { return String(text.prefix(140)) }
            let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
            return (start > text.startIndex ? "…" : "") + String(text[start...].prefix(160))
        }
        var found: [SearchResult] = []
        for e in log.entries where !e.mark && e.status == .done && hit(e.text) {
            let date = Format.ymd.string(from: e.start)
            guard scope.contains(date) else { continue }
            found.append(SearchResult(id: e.id, kind: "Transcript", date: e.start, title: nil, snippet: snippet(e.text),
                                      page: .hour(date, Calendar.current.component(.hour, from: e.start))))
        }
        for h in store.contents.highlights where hit(h.title + " " + h.reading) {
            let date = Format.ymd.string(from: h.start)
            guard scope.contains(date) else { continue }
            found.append(SearchResult(id: h.id, kind: "Highlight", date: h.start, title: h.title, snippet: snippet(h.reading),
                                      page: .hour(date, Calendar.current.component(.hour, from: h.start))))
        }
        for s in store.contents.summaries where scope.contains(s.date) && hit(s.title + " " + s.text) {
            let when = Format.ymd.date(from: s.date).flatMap { Calendar.current.date(bySettingHour: s.hour, minute: 0, second: 0, of: $0) } ?? Date()
            found.append(SearchResult(id: "\(s.date)-\(s.hour)", kind: "Hour summary", date: when, title: s.title,
                                      snippet: snippet(s.text), page: .hour(s.date, s.hour)))
        }
        for m in store.contents.memories where hit(m.content) {
            found.append(SearchResult(id: m.id, kind: "Memory", date: m.addedAt, title: nil, snippet: m.content, page: .memory))
        }
        results = found.sorted { $0.date > $1.date }
    }
}

/// "Search scope": Cancel / Apply, quick ranges, One day · Date range · Several days, a calendar.
struct ScopeSheet: View {
    @State var scope: SearchScope
    let marked: Set<String>
    let apply: (SearchScope) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!

    private var today: String { Format.ymd.string(from: Date()) }
    private func ago(_ n: Int) -> String { Format.ymd.string(from: Date().addingTimeInterval(Double(-n) * 86400)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button("Cancel") { dismiss() }.pillButton()
                    Spacer()
                    Text("Search scope").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    Button("Apply") { apply(scope); dismiss() }.pillButton().fontWeight(.semibold)
                }
                .padding(.top, 14)
                Text("Choose the days\nto search.").font(Theme.serif(32, .regular))
                Text("Use a quick range, or choose dates below.").font(.system(size: 17)).foregroundStyle(Theme.muted)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    quick("Today", .day(today))
                    quick("Last 7 days", .range(ago(6), today))
                    quick("Last 30 days", .range(ago(29), today))
                    quick("All days", .all)
                }
                SegmentedPill(selection: $mode, items: [(0, "One day"), (1, "Date range"), (2, "Several days")])
                calendar
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .sensoryFeedback(.selection, trigger: scope)
    }

    private func quick(_ title: String, _ kind: SearchScope.Kind) -> some View {
        let on = scope.kind == kind
        return Button { scope.kind = kind } label: {
            HStack {
                Text(title).font(.system(size: 20)).multilineTextAlignment(.leading)
                Spacer()
                if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
            }
            .foregroundStyle(on ? Theme.onInk : Theme.text)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(on ? Theme.ink : Theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var calendar: some View {
        let cal = Calendar(identifier: .gregorian)
        let days = cal.range(of: .day, in: .month, for: month)!.count
        let lead = cal.component(.weekday, from: month) - 1
        return VStack(spacing: 12) {
            HStack {
                Text(Format.english("MMMM yyyy", month)).font(.system(size: 15, weight: .semibold))
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                Spacer()
                Button { month = cal.date(byAdding: .month, value: -1, to: month)! } label: { Image(systemName: "chevron.left") }
                Button { month = cal.date(byAdding: .month, value: 1, to: month)! } label: { Image(systemName: "chevron.right") }
                    .padding(.leading, 18).disabled(Format.ymd.string(from: cal.date(byAdding: .month, value: 1, to: month)!) > today)
            }
            .buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 14) {
                ForEach(["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"], id: \.self) {
                    Text($0).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
                }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 30) }
                ForEach(1...days, id: \.self) { n in
                    let d = Format.ymd.string(from: cal.date(byAdding: .day, value: n - 1, to: month)!)
                    let on = selected(d)
                    Button { pick(d) } label: {
                        VStack(spacing: 1) {
                            Text("\(n)").font(.system(size: 18))
                            Capsule().frame(width: 10, height: 1.5).opacity(marked.contains(d) ? 1 : 0)
                        }
                        .foregroundStyle(on ? Theme.onInk : d > today ? Theme.faint.opacity(0.6) : Theme.text)
                        .frame(width: 38, height: 38)
                        .background(on ? Theme.ink : .clear, in: Circle())
                    }
                    .buttonStyle(.plain).disabled(d > today)
                }
            }
        }
        .padding(.top, 6)
    }

    private func selected(_ d: String) -> Bool {
        switch scope.kind {
        case .all: false
        case .day(let x): x == d
        case .range(let a, let b): d >= a && d <= b
        case .days(let set): set.contains(d)
        }
    }

    private func pick(_ d: String) {
        switch mode {
        case 0: scope.kind = .day(d)
        case 1:
            if case .range(let a, let b) = scope.kind, a == b, d > a { scope.kind = .range(a, d) } else { scope.kind = .range(d, d) }
        default:
            var set: Set<String> = []
            if case .days(let s) = scope.kind { set = s }
            if set.contains(d) { set.remove(d) } else { set.insert(d) }
            scope.kind = set.isEmpty ? .all : .days(set)
        }
    }
}

extension View {
    /// Auday's sheet-bar buttons: text on a white capsule.
    func pillButton() -> some View {
        font(.system(size: 17)).foregroundStyle(Theme.text).buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.raised, in: Capsule())
            .overlay(Capsule().stroke(Theme.line))
    }
}
