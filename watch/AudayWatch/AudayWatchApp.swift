import AudayKit
import CoreLocation
import SwiftUI
import WatchKit

@main
struct AudayWatchApp: App {
    @State private var link: WatchLink
    @State private var recorder: Recorder
    @State private var page = 0
    @Environment(\.scenePhase) private var phase

    init() {
        let link = WatchLink()
        _link = State(initialValue: link)
        let recorder = Recorder(link: link)
        _recorder = State(initialValue: recorder)
        link.syncRequested = { recorder.syncNow() }
        #if DEBUG
        DebugControl.listen(recorder: recorder, link: link)
        // `devicectl device process launch … -AudayPage 1` opens on the sync page.
        _page = State(initialValue: UserDefaults.standard.integer(forKey: "AudayPage"))
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $page) {
                CaptureView(recorder: recorder).tag(0)
                StatusView(link: link, recorder: recorder).tag(1)
            }
            .tabViewStyle(.verticalPage)
            .onChange(of: phase) { _, now in
                DiagLog.note("scene \(now)")
                recorder.onScreen = now == .active
            }
        }
    }
}

/// As on Auday's watch, the whole screen is the control: tap to start; while capturing, a tap
/// marks the moment and holding for 1 second stops.
struct CaptureView: View {
    let recorder: Recorder

    @State private var hold = 0.0          // the stop ring, 0...1 while the finger is down
    @State private var flash = false
    @State private var marked: Int?        // shows "Marked" for a moment after each mark
    @State private var holding = false     // switches the hint without animating the text
    @State private var stopping: Task<Void, Never>?
    @State private var stopped = false     // the hold stopped capture; ignore the release
    @State private var pressedAt = Date.distantPast
    @State private var released = Date.distantPast
    @State private var heldFor: TimeInterval = 0

    private var capturing: Bool { recorder.state != .idle }

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .trim(from: 0, to: hold)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(hold > 0 ? 1 : 0)
                AudayLogo(recorder: recorder, live: recorder.state == .capturing && recorder.onScreen)
                    .frame(width: 66, height: 77)
            }
            .frame(width: 100, height: 100)

            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: marked == nil ? 16 : 22, weight: .bold))
                    .foregroundStyle(capturing ? Color.lavender : Color.white)
                    .contentTransition(.opacity)
                if capturing {
                    Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
                        .transaction { $0.animation = nil }
                }
                if let problem = recorder.problem {
                    Text(problem).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.lavender.opacity(flash ? 0.6 : 0).ignoresSafeArea())
        .background(Color.black)
        .contentShape(Rectangle())
        // A button, not tap and long-press gestures: a button gives way to the swipe down to the
        // sync page, while the gestures would hold on to it.
        .pressable(pressed: pressChanged, tapped: tapped)
        .onChange(of: recorder.marks) { old, new in
            guard new > old else { return }
            flash = true
            withAnimation(.easeOut(duration: 0.8)) { flash = false }
            withAnimation { marked = new }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if marked == new { withAnimation { marked = nil } }
            }
        }
        .onChange(of: recorder.state) {
            hold = 0
            holding = false
        }
        .onChange(of: capturing) { _, now in
            if now { stopped = false }
        }
    }

    private func pressChanged(_ pressing: Bool) {
        if pressing {
            pressedAt = Date()
        } else {
            released = Date()
            heldFor = released.timeIntervalSince(pressedAt)
        }
        guard capturing || !pressing else { return }
        holding = pressing
        stopping?.cancel()
        if pressing {
            withAnimation(.linear(duration: 1)) { hold = 1 }
            stopping = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                stopped = true
                recorder.stop()
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { hold = 0 }
        }
    }

    private func tapped() {
        if stopped {
            stopped = false
            return
        }
        // A hold let go before 1 second cancels the stop; it is not a mark. Quick taps inside the
        // paged view often report no press at all, so only a press that just ended counts here.
        if capturing && Date().timeIntervalSince(released) < 0.3 && heldFor > 0.6 { return }
        switch recorder.state {
        case .idle: recorder.start()
        case .capturing: recorder.mark()
        case .interrupted: recorder.resume()
        }
    }

    private var title: String {
        if let marked { return marked == 1 ? "Marked" : "Marked · \(marked)" }
        switch recorder.state {
        case .idle: return "Tap to start"
        case .capturing: return "Capturing..."
        case .interrupted: return recorder.resuming ? "Resuming…" : "Paused"
        }
    }

    private var hint: String {
        if holding { return "Keep holding to stop" }
        guard recorder.state == .interrupted else { return "Tap to mark · Hold to stop" }
        return recorder.resuming ? "Hold to stop" : "Tap to resume · Hold to stop"
    }
}

extension Color {
    static let lavender = Color(red: 0.74, green: 0.76, blue: 1.0)
}

/// The Auday logo, the same four bars as the iPhone and web app (`ICON.logo` in app.js, a
/// 24×28 box). While capturing, the bars follow the microphone level and take a lavender tint.
struct AudayLogo: View {
    let recorder: Recorder
    let live: Bool

    private static let bars: [(x: Double, top: Double, bottom: Double)] = [
        (3, 10, 19), (8.5, 4, 26), (14, 7, 20), (19.5, 11, 19),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !live)) { context in
            let level = live ? recorder.level() : 0
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let unit = min(size.width / 24, size.height / 28)
                for (i, bar) in Self.bars.enumerated() {
                    var top = bar.top, bottom = bar.bottom
                    if live {
                        // Each bar breathes on its own phase and grows with the level.
                        let wave = 0.5 + 0.5 * sin(t * 5 + Double(i) * 1.7)
                        let stretch = 0.75 + 0.25 * wave + 0.6 * level
                        let mid = (top + bottom) / 2, half = (bottom - top) / 2 * stretch
                        top = max(1, mid - half)
                        bottom = min(27, mid + half)
                    }
                    let width = 3.6
                    let rect = CGRect(x: (bar.x - width / 2) * unit, y: top * unit,
                                      width: width * unit, height: (bottom - top) * unit)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: width * unit / 2),
                                with: .linearGradient(
                                    Gradient(colors: live ? [.white, .lavender] : [.white, .white]),
                                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                }
            }
        }
    }
}

/// iPhone connection, today's total, what is waiting, "Sync now", like Auday's second page.
struct StatusView: View {
    let link: WatchLink
    let recorder: Recorder

    private enum SyncButton { case ready, syncing, synced }
    @State private var button = SyncButton.ready

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Label(link.phone, systemImage: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                VStack(alignment: .leading, spacing: 0) {
                    Text("TODAY, TOGETHER")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)
                    Text(RecordedToday.format(link.recordedToday))
                        .font(.system(size: 34, weight: .regular, design: .serif))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }

                HStack {
                    Text("Awaiting sync").font(.system(size: 13))
                    Spacer()
                    // Counts up while recording and starts over once the iPhone has the audio.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(awaiting(at: context.date))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let syncLine {
                    Text(syncLine.text)
                        .font(.system(size: 11))
                        .foregroundStyle(syncLine.problem ? Color.orange : Color.secondary)
                }

                Label(locationLine, systemImage: "location.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(recorder.places.allowed == .denied || recorder.places.allowed == .restricted
                                     ? Color.orange : Color.secondary)

                Button(action: sync) {
                    Label(buttonTitle, systemImage: button == .synced ? "checkmark" : "arrow.triangle.2.circlepath")
                        .symbolEffect(.pulse, isActive: button == .syncing)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color(red: 0.42, green: 0.45, blue: 0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .disabled(button == .syncing)

                Text("Your data only stays local")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
    }

    private var syncLine: (text: String, problem: Bool)? {
        if link.sending > 0 { return ("Sending \(link.sending) to iPhone…", false) }
        if let problem = link.syncProblem { return ("Not sent: \(problem)", true) }
        if let last = link.lastDelivered {
            return ("Last synced \(last.formatted(date: .omitted, time: .shortened))", false)
        }
        return link.awaiting.isEmpty ? nil : ("Syncs every 15 minutes", false)
    }

    private var locationLine: String {
        guard link.locationData else { return "Location data off on iPhone" }
        switch recorder.places.allowed {
        case .notDetermined: return "Location: not asked yet"
        case .denied, .restricted: return "Location not allowed · Settings › Privacy"
        default:
            guard let fix = recorder.places.lastFix else { return "Location allowed" }
            return "Location \(fix.formatted(date: .omitted, time: .shortened))"
        }
    }

    private var buttonTitle: String {
        switch button {
        case .ready: return "Sync now"
        case .syncing: return "Syncing…"
        case .synced: return "Synced"
        }
    }

    /// The haptic is muted while recording, so the button itself shows the sync going through.
    private func sync() {
        WKInterfaceDevice.current().play(.click)
        button = .syncing
        recorder.syncNow()
        Task {
            try? await Task.sleep(for: .seconds(1))          // the cut fragment is filed and sent
            for _ in 0..<60 where link.sending > 0 {
                try? await Task.sleep(for: .seconds(0.5))
            }
            withAnimation { button = link.sending == 0 && link.syncProblem == nil ? .synced : .ready }
            try? await Task.sleep(for: .seconds(2))
            withAnimation { button = .ready }
        }
    }

    private func awaiting(at now: Date) -> String {
        var seconds = link.awaiting.reduce(0) { $0 + $1.duration }
        if let start = recorder.fragmentStart { seconds += max(0, now.timeIntervalSince(start)) }
        let whole = Int(seconds)
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        return RecordedToday.format(seconds)
    }
}

/// Reports when the finger goes down and up, and a tap on release, through a plain button.
private struct PressButtonStyle: ButtonStyle {
    let pressed: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, now in pressed(now) }
    }
}

private extension View {
    func pressable(pressed: @escaping (Bool) -> Void, tapped: @escaping () -> Void) -> some View {
        Button(action: tapped) { self }
            .buttonStyle(PressButtonStyle(pressed: pressed))
    }
}
