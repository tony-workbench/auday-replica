import AudayKit
import SwiftUI
import WatchConnectivity

/// The app as Auday lays it out (docs/AUDAY_UI.md): a floating pill tab bar with Days, Chat and
/// Search; the watch button and "…" (Settings) in the top bar. Everything runs on this iPhone and
/// the watch; a Mac (Settings › Connect to your workflow) is only an optional place to sync a copy.
struct HomeView: View {
    enum Tab: String, CaseIterable { case days = "Days", chat = "Chat", search = "Search" }

    let uploader: Uploader
    let health: HealthSync
    let log: DayLog
    let transcriber: LocalTranscriber
    let store: LocalStore
    @State private var tab = Tab.days
    @State private var paths: [Tab: [Page]] = [:]
    @State private var showWatch = false
    @State private var showSettings = false
    @AppStorage("appearance") private var appearance = Appearance.light

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(Tab.allCases, id: \.self) { item in
                stack(item).opacity(tab == item ? 1 : 0).allowsHitTesting(tab == item)
            }
            if (paths[tab] ?? []).isEmpty {
                PillBar(tab: $tab).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: (paths[tab] ?? []).isEmpty)
        .background(Theme.bg.ignoresSafeArea())
        .tint(Theme.text)
        .preferredColorScheme(appearance.scheme)
        .sheet(isPresented: $showWatch) {
            WatchSheet(uploader: uploader).presentationBackground(Theme.bg).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(uploader: uploader, health: health, transcriber: transcriber, store: store, log: log)
                .presentationBackground(Theme.bg)
        }
        .sensoryFeedback(.selection, trigger: tab)
    }

    private func stack(_ item: Tab) -> some View {
        NavigationStack(path: Binding(get: { paths[item] ?? [] }, set: { paths[item] = $0 })) {
            Group {
                switch item {
                case .days:
                    DaysView(log: log, store: store, transcriber: transcriber,
                             openWatch: { showWatch = true }, openSettings: { showSettings = true })
                case .chat: ChatView(log: log, store: store)
                case .search: SearchView(log: log, store: store, askChat: { tab = .chat })
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Page.self) { PageDestination(page: $0, log: log, store: store, transcriber: transcriber) }
        }
        .environment(\.navigate) { page in paths[item, default: []].append(page) }
    }
}

/// Days / Chat / Search in a floating glass capsule, icon above label; the current tab sits on a
/// light pill.
struct PillBar: View {
    @Binding var tab: HomeView.Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(HomeView.Tab.allCases, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 2) {
                        Image(systemName: icon(item)).font(.system(size: 24))
                        Text(item.rawValue).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Theme.text)
                    .frame(width: 104, height: 58)  // Auday's tab bar spans most of the width
                    .background(tab == item ? Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: 0x3A3936) : UIColor(hex: 0xE2E1DE) }) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.line.opacity(0.8)))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
        .padding(.bottom, 4)
    }

    private func icon(_ tab: HomeView.Tab) -> String {
        switch tab {
        case .days: "calendar"
        case .chat: "bubble.left.and.bubble.right"
        case .search: "magnifyingglass"
        }
    }
}

/// The top bar on Days: the Auday mark and name, the watch capsule (red dot while the watch is
/// not connected), and "…" for Settings.
struct TopBar: View {
    var dot: Bool
    let openWatch: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            AudayLogo(size: 20).foregroundStyle(Theme.text)
            Text("Auday").font(Theme.serif(22, .regular))
            Spacer()
            Button(action: openWatch) {
                HStack(spacing: 4) {
                    Image(systemName: "applewatch").font(.system(size: 15))
                    if dot { Circle().fill(Theme.red).frame(width: 5, height: 5) }
                }
                .frame(width: 58, height: 40)
                .background(Theme.raised, in: Capsule())
                .overlay(Capsule().stroke(Theme.line))
            }
            .accessibilityLabel("Your Watch")
            Button(action: openSettings) { RoundIcon(systemName: "ellipsis") }
                .accessibilityLabel("Settings")
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Days

struct DaysView: View {
    let log: DayLog
    let store: LocalStore
    let transcriber: LocalTranscriber
    let openWatch: () -> Void
    let openSettings: () -> Void
    @Environment(\.navigate) private var navigate
    @State private var date = Format.ymd.string(from: Date())
    @State private var pickingDay = false
    @State private var watchConnected = WatchState.current == .connected

    private var today: String { Format.ymd.string(from: Date()) }

    /// The day from this iPhone's recordings, with the summaries and reflection written for it.
    private var shown: DayData {
        var day = ReplicaClient.local(date, log: log)
        for i in day.hours.indices {
            if let s = store.summary(date, day.hours[i].hour) {
                day.hours[i].title = s.title
                day.hours[i].density = s.density
            }
            day.hours[i].highlights = store.highlights(date, hour: day.hours[i].hour).count
        }
        for s in store.contents.summaries where s.date == date && !day.hours.contains(where: { $0.hour == s.hour }) {
            day.hours.append(DayHour(hour: s.hour, transcripts: 1, highlights: store.highlights(date, hour: s.hour).count,
                                     title: s.title, density: s.density))
        }
        day.hours.sort { $0.hour < $1.hour }
        if let r = store.reflection(date) {
            day.reflection = .init(id: "reflection-\(date)", title: r.title, highlights: store.highlights(date).count)
        }
        return day
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                dateHead.padding(.top, 18)
                WeekStrip(date: $date, today: today, marked: Set(log.days().map(Format.ymd.string) + store.contents.summaries.map(\.date)))
                    .padding(.top, 22)
                HourBars(hours: shown.hours).padding(.top, 34)
                if let r = shown.reflection {
                    Button { navigate(.reflection(date)) } label: {
                        ReflectionCard(reflection: r, recorded: shown.recordedSeconds)
                    }
                    .buttonStyle(.plain).padding(.top, 26)
                } else if store.contents.summaries.contains(where: { $0.date == date }) || (AIConfig.configured && shown.hours.contains { $0.transcripts > 0 }) {
                    Button { navigate(.reflection(date)) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("DAILY REFLECTION").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.nightMuted)
                            Text(date == today ? "Written at your Reflection Time." : "No reflection for this day.")
                                .font(.system(size: 22)).foregroundStyle(Theme.nightText)
                            HStack {
                                Text(AIConfig.configured ? "After \(Format.english("HH:mm", AIConfig.reflectionTime))" : "Set up your AI in Settings")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.system(size: 14)).foregroundStyle(Theme.nightMuted)
                        }
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain).padding(.top, 26)
                }
                hoursList
                Label("Stored on your device. Optional services connect directly to your provider.", systemImage: "checkmark.shield")
                    .font(.system(size: 9)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                    .padding(.top, 28)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            TopBar(dot: !watchConnected, openWatch: openWatch, openSettings: openSettings)
                .padding(.horizontal, 20).padding(.vertical, 6)
                .background(Theme.bg.opacity(0.94))
        }
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .refreshable { await transcriber.run(force: true) }
        .onAppear { watchConnected = WatchState.current == .connected }
        .sheet(isPresented: $pickingDay) {
            DatePicker("Choose a day", selection: Binding(get: { Format.ymd.date(from: date) ?? Date() },
                                                          set: { date = Format.ymd.string(from: $0); pickingDay = false }),
                       in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical).padding().presentationDetents([.medium])
        }
        .sensoryFeedback(.selection, trigger: date)
    }

    private var dateHead: some View {
        let d = Format.ymd.date(from: date) ?? Date()
        return HStack(alignment: .top, spacing: 14) {
            Text(Format.english("d", d)).font(Theme.serif(76, .regular)).monospacedDigit()
                .padding(.top, 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.english("EEEE", d)).font(Theme.serif(34, .regular))
                Text(Format.english("MMMM", d)).font(Theme.serif(22, .regular)).foregroundStyle(Theme.muted)
                Text(Format.english("yyyy", d)).font(Theme.serif(22, .regular)).foregroundStyle(Theme.muted)
                HStack(spacing: 8) {
                    Text(date == today ? "TODAY" : Format.english("EEE", d).uppercased())
                        .font(.system(size: 10, weight: .semibold)).tracking(1.6)
                    Rectangle().fill(Theme.line).frame(width: 22, height: 1)
                    Text(Format.duration(shown.recordedSeconds)).font(.system(size: 11))
                }
                .foregroundStyle(Theme.muted).padding(.top, 8)
            }
            Spacer()
            Button { pickingDay = true } label: {
                Image(systemName: "calendar").font(.system(size: 18)).frame(width: 40, height: 40)
            }
            .buttonStyle(.plain).padding(.top, 40).accessibilityLabel("Choose a day")
        }
    }

    @ViewBuilder private var hoursList: some View {
        let listed = shown.hours.filter { $0.captured || $0.quiet || $0.marks > 0 }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("The day's hours").font(Theme.serif(32, .regular)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
            Text("\(listed.filter(\.captured).count) captured").font(.system(size: 17)).foregroundStyle(Theme.muted)
        }
        .padding(.top, 34).padding(.bottom, 18)
        if listed.isEmpty {
            VStack(spacing: 14) {
                Text("No capture \(date == today ? "yet today" : "on this day").").foregroundStyle(Theme.muted)
                Button("Open Your Watch", action: openWatch)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 15).padding(.vertical, 8)
                    .background(Theme.raised, in: Capsule()).overlay(Capsule().stroke(Theme.line))
                    .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 30)
        } else {
            VStack(spacing: 0) {
                ForEach(listed) { x in
                    Button { navigate(.hour(date, x.hour)) } label: {
                        HourRow(x: x, transcribing: transcriber.busy)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

enum WatchState: Equatable {
    case unsupported, notPaired, notInstalled, connected, waiting

    static var current: WatchState {
        guard WCSession.isSupported() else { return .unsupported }
        let session = WCSession.default
        guard session.activationState == .activated else { return .waiting }
        if !session.isPaired { return .notPaired }
        if !session.isWatchAppInstalled && !session.isReachable && !PhoneLink.heardRecently { return .notInstalled }
        // Paired with the app installed is connected: files and messages still arrive while the
        // watch app is in the background (isReachable is only true while it is on screen).
        return .connected
    }

    var label: String {
        switch self {
        case .unsupported: "Not supported"
        case .notPaired: "Not paired"
        case .notInstalled: "App not installed"
        case .connected: "Connected"
        case .waiting: "Waiting for connection"
        }
    }
}

/// Sunday-first week: numbers only, a short dash under days with recordings, the chosen day on a
/// dark circle, days ahead in light grey.
struct WeekStrip: View {
    @Binding var date: String
    let today: String
    let marked: Set<String>

    var body: some View {
        let cal = Calendar(identifier: .gregorian)
        let d = Format.ymd.date(from: date) ?? Date()
        let sunday = cal.date(byAdding: .day, value: -(cal.component(.weekday, from: d) - 1), to: d)!
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                let day = cal.date(byAdding: .day, value: i, to: sunday)!
                let s = Format.ymd.string(from: day)
                Button { if s <= today { date = s } } label: {
                    VStack(spacing: 2) {
                        Text(Format.english("d", day)).font(.system(size: 17)).monospacedDigit()
                        Capsule().frame(width: 12, height: 2).opacity(marked.contains(s) ? 1 : 0)
                    }
                    .foregroundStyle(s == date ? Theme.onInk : s > today ? Theme.faint.opacity(0.7) : Theme.text)
                    .frame(width: 42, height: 42)
                    .background(s == date ? Theme.ink : .clear, in: Circle())
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 0–24: a short dash for an hour without capture, a dark block for a captured one whose height
/// follows the information density (or the recorded time until the hour is summarized).
struct HourBars: View {
    let hours: [DayHour]

    var body: some View {
        let most = max(1, hours.map(\.recordedSeconds).max() ?? 1)
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<24, id: \.self) { h in
                    let x = hours.first { $0.hour == h && ($0.captured || $0.quiet) }
                    let level: Double = x.map { $0.density.map { Double($0) / 100 } ?? $0.recordedSeconds / most } ?? 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(x == nil ? Theme.line : x!.onPhone && x!.transcripts == 0 ? Theme.faint : Theme.ink)
                        .frame(height: x == nil ? 3 : max(10, 44 * level))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 44, alignment: .bottom)
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { t in
                    Text(t).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.faint)
                    if t != "24" { Spacer() }
                }
            }
        }
    }
}

struct ReflectionCard: View {
    let reflection: DayData.Reflection
    let recorded: Double
    var full = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DitherArt(seed: DitherArt.seed(reflection.id), color: Color(hex: 0xC9CED6), wave: true)
                .frame(height: full ? 200 : 150).clipped()
            VStack(alignment: .leading, spacing: 10) {
                Text("DAILY REFLECTION").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.nightMuted)
                Text(reflection.title).font(.system(size: 29)).foregroundStyle(Theme.nightText).lineLimit(full ? nil : 2)
                HStack {
                    Text("\(recorded > 0 ? Format.duration(recorded) + " recorded · " : "")\(reflection.highlights ?? 0) Highlights")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 14)).foregroundStyle(Theme.nightMuted)
            }
            .padding(20)
        }
        .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// An hour on the timeline: the time in monospace beside a thin rail, CAPTURED and the recorded
/// time, the hour's note in serif, then density, marks and Highlights.
struct HourRow: View {
    let x: DayHour
    var transcribing = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 6) {
                Text(Format.hour(x.hour)).font(.system(size: 11, weight: .medium, design: .monospaced))
                Circle().stroke(Theme.faint, lineWidth: 1).frame(width: 6, height: 6)
                Rectangle().fill(Theme.line).frame(width: 1).frame(maxHeight: .infinity)
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(status).font(.system(size: 9, weight: .medium)).tracking(1.6).foregroundStyle(Theme.muted)
                    Spacer()
                    if x.recordedSeconds > 0 {
                        Text(Format.duration(x.recordedSeconds)).font(.system(size: 9)).foregroundStyle(Theme.muted)
                    }
                }
                if let note {
                    Text(note).font(Theme.serif(20, .regular)).lineSpacing(2)
                        .foregroundStyle(x.title == nil && x.firstText == nil ? Theme.muted : Theme.text)
                }
                if !info.isEmpty {
                    HStack(alignment: .top) {
                        Text(info).font(.system(size: 15)).foregroundStyle(Theme.muted).lineSpacing(2)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                Divider().overlay(Theme.line).padding(.top, 8)
            }
        }
        .padding(.bottom, 14)
    }

    private var status: String {
        x.captured ? "CAPTURED" : x.quiet ? "QUIET" : "NO CAPTURE"
    }

    private var note: String? {
        if x.transcripts == 0 && x.quiet { return "A quiet hour." }
        if let title = x.title { return title }
        if let text = x.firstText { return text }
        if x.onPhone { return x.failed && !transcribing ? "Could not transcribe." : transcribing ? "Transcribing…" : "Waiting for transcription." }
        if x.pendingAudio > 0 { return "Waiting for transcription." }
        return nil
    }

    private var info: String {
        if x.quiet && !x.captured { return x.densityLabel ?? "Low information" }
        guard x.captured else { return "" }
        var bits: [String] = []
        if let d = x.densityLabel { bits.append(d) }
        if x.marks > 0 { bits.append("👉 " + Format.plural(x.marks, "mark")) }
        if x.highlights > 0 { bits.append("✦ " + Format.plural(x.highlights, "highlight")) }
        return bits.joined(separator: " · ")
    }
}

// MARK: - Your Watch

struct WatchSheet: View {
    let uploader: Uploader
    @Environment(\.dismiss) private var dismiss
    @State private var state = WatchState.current
    @State private var syncing = false
    @State private var synced = false
    @State private var showHelp = false
    @State private var showTips = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Text("Your Watch").font(.system(size: 17, weight: .semibold))
                    HStack {
                        Spacer()
                        Button { dismiss() } label: { RoundIcon(systemName: "xmark") }.buttonStyle(.plain)
                            .accessibilityLabel("Close")
                    }
                }
                .padding(.top, 18)
                HStack(alignment: .top, spacing: 14) {
                    AudayLogo(size: 34).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The best AI hardware.").font(Theme.serif(26, .regular))
                        Text("Maybe you already own it.").font(.system(size: 18)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.top, 22)
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap").font(.system(size: 16))
                    Text("Hold the Watch screen for 1 second to stop recording.").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 18)
                HStack(spacing: 10) {
                    Image(systemName: "applewatch").font(.system(size: 22))
                    Text("Apple Watch").font(.system(size: 22))
                    Spacer()
                    Text(state.label).font(.system(size: 18)).foregroundStyle(Theme.muted).multilineTextAlignment(.trailing)
                }
                .padding(.top, 22)
                HStack {
                    Text("Awaiting sync").font(.system(size: 18))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Format.duration(awaiting)).font(.system(size: 18)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.vertical, 16)
                Button {
                    syncing = true
                    synced = false
                    AppDelegate.link?.requestSync { ok in
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.5))
                            syncing = false
                            synced = ok
                        }
                    }
                    uploader.retryNow()
                } label: {
                    HStack {
                        Text(syncing ? "Syncing…" : synced ? "Synced" : "Manually sync now")
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .font(.system(size: 18))
                    .padding(.horizontal, 16).padding(.vertical, 15)
                    .foregroundStyle(canSync ? Theme.onInk : Theme.faint)
                    .background(canSync ? Theme.ink : Theme.panel2, in: Capsule())
                }
                .buttonStyle(.plain).disabled(!canSync || syncing)
                .sensoryFeedback(.success, trigger: synced)
                Text("Automatically syncs every 15 minutes")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity).padding(.top, 10)
                Text("Open Auday on your Watch to start capturing.")
                    .font(.system(size: 17)).foregroundStyle(Theme.muted).padding(.top, 16)
                Button { showHelp.toggle() } label: {
                    HStack(alignment: .top) {
                        Text("Can't connect your Apple Watch?").underline()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 17))
                }
                .buttonStyle(.plain).padding(.top, 4)
                if showHelp {
                    Text("Open the Watch app on this iPhone and check that Auday Replica is installed on your watch. Keep Bluetooth on; the watch hands recordings to this iPhone every 15 minutes.")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted).padding(.top, 6)
                }
                Button { showTips.toggle() } label: {
                    Text("Read the Watch Recording Tips").underline().font(.system(size: 17))
                }
                .buttonStyle(.plain).padding(.top, 22)
                if showTips {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("· Tap the screen to mark a moment; marked moments are favoured for Highlights.")
                        Text("· Hold the screen for 1 second to stop recording.")
                        Text("· Recordings go from your watch to this iPhone, and on to your Mac if you connect one.")
                    }
                    .font(.system(size: 14)).foregroundStyle(Theme.muted).padding(.top, 6)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .onAppear { state = WatchState.current }
        .onReceive(NotificationCenter.default.publisher(for: PhoneLink.stateChanged)) { _ in state = WatchState.current }
    }

    /// Auday's "Awaiting sync": audio recorded on the watch and not yet on this iPhone.
    private var awaiting: Double { PhoneLink.awaitingOnWatch }

    private var canSync: Bool { state == .connected }      // asks the watch; the Mac copy follows if connected
}
