import AudayKit
import Network
import Observation
import SwiftUI
import UIKit

/// The iPhone side of pairing, like Auday's "Connect to your workflow": with access enabled the
/// iPhone advertises `_audayreplica._tcp` and accepts one TLS-PSK connection keyed by the
/// communication password. The Mac (`python -m app.pair_iphone`) sends its address, port and
/// token; the iPhone checks it can reach the server with them, saves them and answers.
@MainActor @Observable
final class MacLink {
    private(set) var password: String
    private(set) var enabled = false
    private(set) var status: String?
    private(set) var macName = UserDefaults.standard.string(forKey: "macName")

    /// What the Mac gets: transcripts only, or transcripts and the original audio (read-only either way).
    enum Scope: String, CaseIterable { case text, textAndAudio }
    static var scope: Scope {
        get { UserDefaults.standard.string(forKey: "syncScope").flatMap(Scope.init) ?? .textAndAudio }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "syncScope") }
    }
    private var listener: NWListener?
    private let uploader: Uploader

    init(uploader: Uploader) {
        self.uploader = uploader
        if let saved = Keychain.pairPassword, Pairing.normalize(saved) != nil {
            password = saved
        } else {
            password = Pairing.newPassword()
            Keychain.pairPassword = password
        }
    }

    func newPassword() {
        password = Pairing.newPassword()
        Keychain.pairPassword = password
        if enabled { stop(); enable() }
    }

    func enable() {
        guard let parameters = Pairing.parameters(password: password),
              let listener = try? NWListener(using: parameters) else {
            status = "Could not start listening for your Mac"
            return
        }
        listener.service = NWListener.Service(name: UIDevice.current.name, type: Pairing.serviceType)
        listener.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready: self.status = nil
                case .failed(let error): self.status = "Stopped: \(error.localizedDescription)"; self.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in self.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        enabled = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        enabled = false
    }

    func forget() {
        stop()
        uploader.serverText = ""
        uploader.token = ""
        uploader.saveSettings()
        macName = nil
        UserDefaults.standard.removeObject(forKey: "macName")
        status = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        Pairing.receive(on: connection) { request in
            Task { @MainActor in
                let reply = await self.pair(request)
                connection.send(content: Pairing.frame(reply), completion: .contentProcessed { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { connection.cancel() }
                })
            }
        }
        // A connection that never sends a request (wrong password, stalled peer) is dropped.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { connection.cancel() }
    }

    private func pair(_ request: [String: Any]?) async -> [String: Any] {
        guard let request, request["op"] as? String == "pair", let host = request["host"] as? String,
              let port = request["port"] as? Int, let token = request["token"] as? String,
              let server = ReplicaAPI.serverURL(from: "\(host):\(port)") else {
            return ["ok": false, "error": "invalid_request"]
        }
        status = "Checking the connection to your Mac…"
        let code: Int?
        do {
            let (_, response) = try await URLSession.shared.data(for: ReplicaAPI.status(server: server, token: token))
            code = (response as? HTTPURLResponse)?.statusCode
        } catch {
            status = "Your Mac sent its address, but this iPhone cannot reach it"
            return ["ok": false, "error": "mac_unreachable"]
        }
        guard code == 200 else {
            status = "Your Mac's server rejected the pairing token"
            return ["ok": false, "error": code == 401 ? "token_refused" : "server_\(code ?? 0)"]
        }
        let name = request["name"] as? String ?? host
        uploader.serverText = "\(host):\(port)"
        uploader.token = token
        uploader.saveSettings()
        await uploader.checkConnection()
        macName = name
        UserDefaults.standard.set(name, forKey: "macName")
        status = "Connected to \(name)"
        return ["ok": true, "device": UIDevice.current.name, "scope": Self.scope.rawValue]
    }
}

/// Settings › Connect to your workflow, laid out like Auday's: what to check first, what the Mac
/// may read, the communication password made on this iPhone, and status. The Mac finds this
/// iPhone by itself; nothing is typed here.
struct ConnectMacView: View {
    let link: MacLink
    let uploader: Uploader
    @State private var showPassword = false
    @State private var scope = MacLink.scope
    @State private var help = false
    @State private var guide = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: -6) {
                    Image(systemName: "iphone").font(.system(size: 50))
                    Image(systemName: "laptopcomputer").font(.system(size: 92))
                }
                .frame(maxWidth: .infinity).padding(.top, 8)
                Text("Bring what Auday knows\nConnect to your workflow").font(Theme.serif(32, .regular))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                Text("Let memories inform your thinking and recordings offer more")
                    .font(.system(size: 18)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: .infinity)

                step("01", "Install Auday Replica", icon: "square.and.arrow.down") {
                    Link(destination: URL(string: "https://github.com/tony-workbench/auday-replica")!) {
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                            Text("github.com/tony-workbench/auday…").font(.system(size: 15, design: .monospaced)).lineLimit(1)
                            Image(systemName: "arrow.up.right").font(.system(size: 12))
                        }
                    }
                    Text("Let the AI agent on your computer install it for you.").font(.system(size: 15)).foregroundStyle(Theme.muted)
                    Divider()
                    Button { guide = true } label: {
                        HStack { Text("View installation guide").font(.system(size: 18, weight: .medium)); Spacer(); Image(systemName: "chevron.right").font(.system(size: 14)) }
                    }
                    .buttonStyle(.plain)
                }
                step("02", "Connect to the same Wi-Fi", icon: "wifi") {
                    Text("Connect your iPhone and computer to the same Wi-Fi").foregroundStyle(Theme.muted)
                    Text("Allow Local Network access when first connecting").foregroundStyle(Theme.muted)
                }
                step("03", "Communication password", icon: "key") {
                    Text("Type it on your computer when it asks. Local connection, no relay server.")
                        .font(.system(size: 15)).foregroundStyle(Theme.muted)
                    HStack {
                        Text(showPassword ? Pairing.formatted(link.password) : "•••• •••• •••• ••••")
                            .font(.system(size: 19, design: .monospaced))
                        Spacer()
                        Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                            .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    .padding(14).card(Theme.panel, radius: 12)
                    Button { UIPasteboard.general.string = Pairing.formatted(link.password) } label: {
                        Label("Copy password", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    Divider()
                    Button(action: link.newPassword) {
                        Label("New password", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                    }
                }
                step("04", "Access scope", trailing: AnyView(Label("Read only", systemImage: "lock").font(.system(size: 16)).foregroundStyle(Theme.muted))) {
                    choice(.text, "All text", "Transcripts, Highlights, summaries and memories", icon: "text.alignleft")
                    Divider()
                    choice(.textAndAudio, "Text and audio", "Explore recordings with your computer's computing power", icon: "waveform")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusLine).font(.system(size: 18, weight: .medium))
                    if let read = uploader.lastUploaded, uploader.server != nil {
                        Text("Last read \(Format.when(read))").font(.system(size: 16)).foregroundStyle(Theme.muted)
                    }
                    if let status = link.status { Text(status).font(.system(size: 15)).foregroundStyle(Theme.muted) }
                }
                Button { withAnimation { help.toggle() } } label: {
                    HStack(spacing: 4) { Text("Can't connect?").underline(); Image(systemName: "chevron.down").rotationEffect(.degrees(help ? 180 : 0)) }
                        .font(.system(size: 17))
                }
                .buttonStyle(.plain)
                if help {
                    VStack(alignment: .leading, spacing: 8) {
                        bullet("Check both devices are on the same Wi-Fi. Guest Wi-Fi often keeps devices from seeing each other.")
                        bullet("On this iPhone: Settings › Privacy & Security › Local Network › turn on Auday Replica.")
                        bullet("Keep this page open, with access enabled, until your Mac says Connected.")
                    }
                    .font(.system(size: 16)).foregroundStyle(Theme.muted)
                }
                if uploader.server != nil {
                    Button("Disconnect this Mac", role: .destructive) { link.forget() }.padding(.top, 8)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 130)
        }
        .background(Theme.bg)
        .tint(Theme.text)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button { link.enabled ? link.stop() : link.enable() } label: {
                    Text(link.enabled ? "Stop access" : "Enable access")
                        .font(.system(size: 20, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .foregroundStyle(Theme.onInk).background(Theme.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .medium), trigger: link.enabled)
                Text("Keep this page open after enabling access").font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 20).padding(.top, 8).background(Theme.bg.opacity(0.96))
        }
        .sheet(isPresented: $guide) { InstallGuideView(command: command) }
        .navigationTitle("Connect to your workflow")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { link.stop() }
    }

    private var statusLine: String {
        if let name = link.macName, uploader.server != nil { return "Connected to \(name)" }
        return link.enabled ? "Waiting for your Mac" : "Not connected"
    }

    private func step<Content: View>(_ number: String, _ title: String, icon: String? = nil, trailing: AnyView? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                // Auday stacks the two digits: 0 over 4.
                VStack(spacing: 0) { ForEach(Array(number), id: \.self) { Text(String($0)) } }
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.muted).padding(.top, 6)
                Text(title).font(Theme.serif(28, .regular))
                Spacer()
                if let icon { Image(systemName: icon).font(.system(size: 15)).frame(width: 34, height: 34).card(Theme.panel, radius: 8) }
                if let trailing { trailing.padding(.top, 6) }
            }
            content()
        }
        .font(.system(size: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .card()
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) { Text("·"); Text(text) }
            .font(.system(size: 17)).foregroundStyle(Theme.muted)
    }

    private func choice(_ value: MacLink.Scope, _ title: String, _ detail: String, icon: String) -> some View {
        Button {
            scope = value
            MacLink.scope = value
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Theme.muted).frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 19, weight: .semibold))
                    Text(detail).font(.system(size: 15)).foregroundStyle(Theme.muted).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: scope == value ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: scope)
    }

    private func command(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
            Spacer()
            Button { UIPasteboard.general.string = text } label: { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("Copy command")
        }
        .padding(10).card(Theme.panel, radius: 8)
    }
}

/// "View installation guide": like Auday's, the setup is handed to an AI agent on the computer
/// (Codex, Claude, WorkBuddy…) in three cards, with one prompt to copy.
struct InstallGuideView<Command: View>: View {
    let command: (String) -> Command
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    static var prompt: String {
        """
        Set up Auday Replica on this computer so it can read my iPhone's Auday Replica data.
        1. Get https://github.com/tony-workbench/auday-replica (clone it, or pull if it is already here) and install it by following its README. Do every step yourself; only ask me for things you cannot do.
        2. Start its server for my local network: ./scripts/start.sh --host 0.0.0.0 (keep it running).
        3. Pair with my iPhone: .venv/bin/python -m app.pair_iphone. My iPhone has Connect to your workflow open with access enabled. When it asks for the communication password, ask me to type it; never print it or save it anywhere.
        4. Check that my iPhone shows it is connected, then tell me what is ready.
        """
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Auday's three cards: open your desktop AI, send it the prompt, come back and enable access.
                    card("01", "Open your desktop AI") {
                        Text("Codex, Claude, WorkBuddy or another AI agent on your computer.").foregroundStyle(Theme.muted)
                    }
                    card("02", "Send this to your AI") {
                        Text(Self.prompt).font(.system(size: 14, design: .monospaced)).textSelection(.enabled)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).card(Theme.panel, radius: 12)
                        Button {
                            UIPasteboard.general.string = Self.prompt
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy installation prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 17, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 12)
                                .foregroundStyle(Theme.bg).background(Theme.ink, in: Capsule())
                        }
                        .sensoryFeedback(.success, trigger: copied)
                    }
                    card("03", "Return to your phone and enable access") {
                        Text("Keep this iPhone and the computer on the same Wi-Fi, tap Enable access, and enter the communication password on your computer when it asks.")
                            .foregroundStyle(Theme.muted)
                    }
                    // Replica improvement: the two Mac commands, for doing it by hand.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or do it yourself").font(.system(size: 19, weight: .semibold))
                        Text("On your Mac, in the auday-replica folder:").font(.system(size: 15)).foregroundStyle(Theme.muted)
                        command("./scripts/start.sh --host 0.0.0.0")
                        command(".venv/bin/python -m app.pair_iphone")
                    }
                    .padding(.top, 6)
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Installation guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func card<Content: View>(_ number: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(number).font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.muted)
            Text(title).font(Theme.serif(24, .regular))
            content()
        }
        .font(.system(size: 16))
        .padding(18).frame(maxWidth: .infinity, alignment: .leading).card(Theme.raised, radius: 20)
    }
}
