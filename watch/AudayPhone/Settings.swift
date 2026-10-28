import HealthKit
import AVFoundation
import AudayKit
import SwiftUI

/// Settings, opened from "…" as a sheet, laid out like Auday's: a header card, Make it yours,
/// Intelligence, Your archive, About.
struct SettingsView: View {
    @Bindable var uploader: Uploader
    let health: HealthSync
    let transcriber: LocalTranscriber
    let store: LocalStore
    let log: DayLog
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = Appearance.light
    @State private var language = OutputLanguage.primary
    @State private var second = OutputLanguage.secondary

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        AudayLogo(size: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auday").font(Theme.serif(26, .regular))
                            Text("Local Privacy Edition").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "crown.fill").font(.system(size: 14)).foregroundStyle(Color(red: 0.55, green: 0.45, blue: 0.3))
                            Text("LIFETIME\nMEMBER").font(.system(size: 8, weight: .medium)).tracking(1.1).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                    }
                    .padding(.vertical, 10)
                }
                Section {
                    StackedPicker("Appearance", selection: $appearance, options: Appearance.allCases) { $0.rawValue.capitalized }
                    // Auday's four app languages; the AI writes in the one chosen here.
                    StackedPicker("Language", selection: $language, options: OutputLanguage.appLanguages) { $0.appLabel }
                        .onChange(of: language) { _, value in OutputLanguage.primary = value }
                    // Replica improvement: a second language you also speak.
                    StackedPicker("Second language", selection: $second,
                                  options: [nil] + OutputLanguage.allCases.filter { $0 != language }.map(Optional.some)) { $0?.label ?? "None" }
                        .onChange(of: second) { _, value in OutputLanguage.secondary = value }
                } header: { header("Make it yours") } footer: {
                    Text("Transcription also listens for your second language. Highlights, summaries and reflections are always written in the Language above.")
                }
                Section {
                    row("Transcription", "waveform") { TranscriptionView(transcriber: transcriber) }
                    row("My voice recognition", "person.wave.2") { VoiceView(voice: AppDelegate.voice) }
                    row("AI settings", "sparkle") { AISettingsView() }
                    row("Body & location data", "list.bullet.rectangle") { BodyLocationView(health: health) }
                    row("Connect to your workflow", "laptopcomputer.and.iphone") { ConnectMacView(link: AppDelegate.mac, uploader: uploader) }
                    row("Your memory", "square.3.layers.3d") { MemoryView(store: store) }
                } header: { header("Intelligence") }
                Section {
                    stacked("Days", "\(log.days().count)")
                    stacked("Audio stored", ByteCountFormatter.string(fromByteCount: DayLog.audioBytes, countStyle: .file))
                    NavigationLink { KeepAudioView(log: log) } label: { stacked("Keep original audio", KeepAudioView.label(DayLog.keepAudioDays)) }
                    NavigationLink { BatchExportView(log: log, store: store) } label: { Text("Batch export") }
                    if uploader.server != nil {
                        let fragments = uploader.waiting.compactMap { if case .fragment(let f) = $0 { f } else { nil } }
                        stacked("Waiting to sync to your Mac", "\(Format.plural(fragments.count, "recording")) · \(Format.duration(fragments.reduce(0) { $0 + $1.duration }))")
                    }
                } header: { header("Your archive") }
                Section {
                    stacked("Version", "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    NavigationLink { InfoPage(title: "Privacy Policy", text: Self.privacy) } label: { Text("Privacy Policy") }
                    NavigationLink { InfoPage(title: "Terms of Service", text: Self.terms) } label: { Text("Terms of Service") }
                    Link(destination: URL(string: "https://github.com/tony-workbench/auday-replica/issues")!) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Contact us")
                            Text("GitHub issues").foregroundStyle(Theme.muted)
                        }
                    }
                    .foregroundStyle(Theme.text)
                    NavigationLink { InfoPage(title: "Frequently Asked Questions", text: Self.faq) } label: { Text("Frequently\nAsked Questions") }
                    #if DEBUG
                    Button("Load sample day (DEBUG)") { store.loadSample(on: Format.ymd.string(from: Date())) }
                    #endif
                } header: { header("About") }
            }
            .settingsStyle()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
                }
            }
        }
        .tint(Theme.text)
    }

    static let privacy = "Your recordings, transcripts and memories are stored on this iPhone. Transcription runs on the device. The AI features send text and context, never audio, straight to the provider you set in AI settings. If you connect your Mac, a copy goes to your Mac over your own Wi-Fi. There are no Auday Replica servers."
    static let terms = "Auday Replica is an open-source personal project, provided as is, without warranty. You are responsible for recording only where you are allowed to and for your AI provider's terms."
    static let faq = "Why is an hour empty? The watch hands recordings to this iPhone every 15 minutes; transcription follows.\n\nWhy no Highlights or reflection? They need your AI: add it in Settings › AI settings.\n\nDo I need a Mac? No. Connecting a Mac only keeps a copy there."

    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text).textCase(nil)
    }

    private func row<Destination: View>(_ title: String, _ icon: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            Label { Text(title) } icon: { Image(systemName: icon).foregroundStyle(Theme.text) }
        }
    }

    private func stacked(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(value)
        }
        .padding(.vertical, 2)
    }
}

/// My voice recognition, as Auday does it: three short readings (about 45 s), then every
/// snippet of your recordings is labelled Me or Me* when it sounds like you.
struct VoiceView: View {
    let voice: VoiceModel
    @State private var recorder = ReadingRecorder()
    @State private var reading = 0
    @State private var error: String?
    @State private var enrolling = false
    @State private var recognition = VoiceModel.enabled

    /// Short, uneven passages full of numbers and names, read slowly word by word. A voiceprint
    /// from this kind of reading matches everyday watch speech far better than one from fluent
    /// paragraphs. Each fits 15 s at a careful pace.
    static let readings: [OutputLanguage: [String]] = [
        .english: [
            "Please read slowly: forty-seven blue envelopes, a crooked brass key, and the number three hundred and nine, written twice on the back of a receipt.",
            "Thursday, the twelfth of February. Sixty grams of rice, two thin slices of lemon, one bitter cup of tea. Then a short walk, past the old bridge.",
            "Seventeen, twenty-eight, ninety-four. Thick fog, quick frost, a sharp whistle. My neighbour's grey parrot repeats each word, very slowly, one at a time.",
        ],
        .mandarin: [
            "请慢慢念：四十七个蓝色信封，一把弯曲的铜钥匙，还有三百零九这个数字，在收据背面写了两遍。",
            "二月十二号，星期四。六十克米饭，两片薄柠檬，一杯很苦的茶。然后慢慢走过那座旧石桥。",
            "十七、二十八、九十四。浓雾，薄霜，一声尖锐的口哨。邻居家的灰鹦鹉，一个字一个字地学着说。",
        ],
    ]

    /// The primary language's passages, then the second language's when one is set: a voiceprint
    /// from both recognizes you better in either language (docs/AUDAY_OBSERVATIONS.md).
    private var texts: [String] {
        let primary = Self.readings[OutputLanguage.primary] ?? Self.readings[.english]!
        guard let second = OutputLanguage.secondary, second != OutputLanguage.primary, let more = Self.readings[second] else { return primary }
        return primary + more
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if voice.saved == nil || enrolling {
                    Text("Your voice,\nrecognized.").font(Theme.serif(32, .regular)).padding(.top, 8)
                    Text("Read each short passage slowly and clearly, word by word, in your normal voice, in a quiet place. Auday then marks what you say in your recordings as Me. Your voice stays on this iPhone.")
                        .font(.system(size: 17)).foregroundStyle(Theme.muted)
                }
                if voice.saved != nil, !enrolling {
                    // Auday's enrolled state.
                    VStack(spacing: 14) {
                        WaveformArt().frame(height: 80).padding(.top, 20)
                        Text("Your voice\nis ready").font(Theme.serif(40, .regular)).multilineTextAlignment(.center)
                        Text("Highlight your words.").font(.system(size: 19)).foregroundStyle(Theme.muted)
                        if let saved = voice.saved {
                            // Replica improvement: when it was recorded and how it is tuned.
                            Text("Since \(Format.english("MMM d, yyyy", saved.enrolledAt))"
                                 + (saved.thresholds.map { String(format: " · tuned to your recordings (Me at %.2f)", $0.me) } ?? ""))
                                .font(.system(size: 14)).foregroundStyle(Theme.faint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: $recognition) { Text("Voice recognition").font(.system(size: 22, weight: .semibold)) }
                            .toggleStyle(SwitchToggleStyle(tint: Theme.ink))
                            .onChange(of: recognition) { _, on in
                                VoiceModel.enabled = on
                                if on { Task { await voice.relabel(all: true) } }
                            }
                        Text("Uses extra processing and memory when enabled.").font(.system(size: 17)).foregroundStyle(Theme.muted)
                        Divider()
                        Button { start() } label: { Label("Record again", systemImage: "arrow.clockwise").font(.system(size: 20, weight: .medium)) }
                        Button { voice.remove() } label: { Text("Delete voice profile").font(.system(size: 19)) }
                    }
                    .buttonStyle(.plain)
                    .padding(22).frame(maxWidth: .infinity, alignment: .leading).card(radius: 22)
                } else {
                    enrolment
                }
                if let progress = voice.downloading {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Downloading the voice model (26 MB)…").font(.system(size: 15))
                        ProgressView(value: progress)
                    }
                }
                if let status = voice.status { Label(status, systemImage: "waveform").font(.system(size: 15)).foregroundStyle(Theme.muted) }
                if let error { Text(error).font(.system(size: 15)).foregroundStyle(Theme.red) }
            }
            .padding(.horizontal, 20).padding(.bottom, 40)
        }
        .background(Theme.bg)
        .navigationTitle("My voice recognition")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !recorder.recording { recorder.count = texts.count } }
        .onDisappear { recorder.stop() }
        // A finished reading moves straight on to the next; after the last, the voice is learned.
        .onChange(of: recorder.done) { old, new in
            guard new.indices.contains(reading), old.indices.contains(reading), new[reading], !old[reading] else { return }
            if reading < texts.count - 1 {
                reading += 1
                recorder.record(reading)
            } else if !new.contains(false) {
                finish()
            }
        }
    }

    private var enrolment: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ForEach(0..<texts.count, id: \.self) { i in
                    Capsule().fill(recorder.done.indices.contains(i) && recorder.done[i] ? Theme.ink : i == reading ? Theme.muted : Theme.line)
                        .frame(height: 4)
                }
            }
            Text("Reading \(reading + 1) of \(texts.count)").font(.system(size: 13, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
            Text(texts[reading]).font(Theme.serif(23, .regular)).lineSpacing(5)
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<24, id: \.self) { i in
                    Capsule().fill(Double(i) / 24 < recorder.level ? Theme.ink : Theme.line).frame(width: 5, height: 8 + CGFloat(i % 5) * 4)
                }
            }
            .frame(height: 28)
            ProgressView(value: recorder.elapsed, total: ReadingRecorder.length).tint(Theme.ink)
            HStack(spacing: 14) {
                // Record starts the first reading only; after that there is just Stop, which ends
                // the current reading and starts the next.
                if recorder.recording {
                    pill("Stop", "stop.fill") { recorder.stop() }
                } else if voice.busy {
                    Text("Learning your voice…").font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.muted)
                } else if error != nil || recorder.problem != nil || recorder.done.contains(true) {
                    // Something went wrong (too little speech, a silent microphone, a reading cut
                    // short): start all readings over and clear the message.
                    pill("Record again", "arrow.clockwise") { recordAgain() }
                } else {
                    pill("Record", "mic.fill") { error = nil; recorder.record(reading) }
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: recorder.recording)
            .buttonStyle(.plain)
            if let mic = recorder.problem { Text(mic).font(.system(size: 15)).foregroundStyle(Theme.red) }
        }
        .padding(18).card()
    }

    private func recordAgain() {
        error = nil
        recorder.count = texts.count
        recorder.reset()
        reading = 0
        recorder.record(0)
    }

    private func pill(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 18, weight: .medium)).foregroundStyle(Theme.onInk)
                .padding(.horizontal, 20).padding(.vertical, 12).background(Theme.ink, in: Capsule())
        }
    }

    private func start() {
        recorder.count = texts.count
        recorder.reset()
        reading = 0
        enrolling = true
        // Fetch the model while the user reads.
        Task { do { try await voice.ensureModel() } catch { self.error = Self.explain(error) } }
    }

    private func finish() {
        Task {
            do {
                try await voice.enroll(readings: recorder.files)
                enrolling = false
                recorder.reset()
                reading = 0
            } catch {
                self.error = Self.explain(error)
            }
        }
    }

    static func explain(_ error: Error) -> String {
        if let e = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost].contains(e.code) {
            return "No network: the voice model (26 MB) is downloaded once. Connect to the internet and try again."
        }
        return error.localizedDescription
    }
}

/// Records each reading as a 15 s WAV (16-bit, the microphone's own rate; VoiceModel resamples),
/// with a level meter. An AVAudioEngine tap writes every buffer, so a reading's length is the
/// audio actually written. AVAudioRecorder is not used: it could leave files with only a header.
@MainActor @Observable
final class ReadingRecorder {
    static let length = 15.0
    private(set) var recording = false
    private(set) var level = 0.0
    private(set) var elapsed = 0.0
    private(set) var done = [false, false, false]
    /// How many readings this enrolment has (3, or 6 with a second language).
    var count = 3 {
        didSet { done = Array(repeating: false, count: count) }
    }
    private(set) var problem: String?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var writer: ReadingWriter?
    @ObservationIgnored private var timer: Timer?
    private var current = 0

    var files: [URL] { (0..<count).map(Self.url) }
    static func url(_ i: Int) -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("voice-reading-\(i).wav") }

    func record(_ index: Int) {
        // Mark as recording right away so the button shows Stop at once, also between readings.
        recording = true
        loudest = 0
        problem = nil
        elapsed = 0
        current = index
        Task {
            guard await AVAudioApplication.requestRecordPermission() else {
                problem = "Allow the microphone in Settings › Privacy & Security › Microphone."
                recording = false
                return
            }
            guard recording else { return }
            problem = nil
            do {
                let session = AVAudioSession.sharedInstance()
                // Default mode keeps the iPhone's automatic gain. In .measurement mode most of a
                // reading stayed too quiet to count as speech, so the voiceprint had little to use.
                try session.setCategory(.record, mode: .default)
                try session.setActive(true)
                engine.stop()
                engine.reset()
                let input = engine.inputNode
                guard input.inputFormat(forBus: 0).sampleRate > 0 else { throw ReadingWriter.Failure.noMicrophone }
                let writer = ReadingWriter(url: Self.url(index))
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in writer.append(buffer) }
                engine.prepare()
                try engine.start()
                self.writer = writer
            } catch {
                problem = "The microphone could not start: \(error.localizedDescription)"
                recording = false
                return
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                Task { @MainActor in self.tick() }
            }
        }
    }

    private func tick() {
        guard let writer else { return }
        elapsed = min(Self.length, writer.seconds)
        // -50 dBFS (quiet room) to -20 dBFS (speaking up close) fills the meter. Speech sits
        // around -30 dBFS; with 0 dBFS as full it filled a third.
        level = max(0, min(1, (20 * log10(max(Double(writer.level), 1e-7)) + 50) / 30))
        loudest = max(loudest, writer.level)
        // Nothing as loud as speech in the first 4 s: say so now instead of at the end. Pure
        // silence means the microphone gives nothing (another app or screen capture holding it).
        if writer.seconds >= 4 && loudest < Voice.voicedRMS {
            finished()
            problem = loudest < 0.0005
                ? "No sound is reaching the microphone. Close other apps that record or mirror this iPhone, then tap Record again."
                : "Couldn't hear you reading. Read the passage aloud, close to the iPhone, then tap Record again."
            done = Array(repeating: false, count: count)
            return
        }
        if writer.seconds >= Self.length { finished() }
    }

    @ObservationIgnored private var loudest: Float = 0

    func stop() {
        if recording { finished() }
    }

    private func finished() {
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let written = writer?.close() ?? 0
        writer = nil
        recording = false
        level = 0
        elapsed = min(Self.length, written)
        if written >= 4 { done[current] = true }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func reset() {
        stop()
        done = Array(repeating: false, count: count)
        elapsed = 0
    }
}

/// Writes one reading's buffers to its WAV on the audio thread; the file is opened with the
/// format of the first buffer.
final class ReadingWriter: @unchecked Sendable {
    enum Failure: LocalizedError {
        case noMicrophone
        var errorDescription: String? { "no microphone input" }
    }

    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var rate = 0.0
    private var lastLevel: Float = 0

    init(url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)
    }

    var seconds: Double { lock.withLock { rate > 0 ? Double(frames) / rate : 0 } }
    var level: Float { lock.withLock { lastLevel } }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let format = buffer.format
        if file == nil {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                           AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false]
            file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat,
                                    interleaved: format.isInterleaved)
            rate = format.sampleRate
        }
        guard let file, (try? file.write(from: buffer)) != nil else { return }
        frames += AVAudioFramePosition(buffer.frameLength)
        if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            lastLevel = (sum / Float(buffer.frameLength)).squareRoot()
        }
    }

    /// Finishes the WAV and returns the seconds written.
    func close() -> Double {
        lock.withLock {
            file = nil
            return rate > 0 ? Double(frames) / rate : 0
        }
    }
}

/// The grey waveform drawn above "Your voice is ready".
struct WaveformArt: View {
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<44, id: \.self) { i in
                let x = Double(i) / 43
                let h = 0.15 + 0.85 * abs(sin(x * .pi * 3.2)) * (0.55 + 0.45 * sin(x * .pi))
                Capsule().fill(Theme.muted.opacity(0.35 + 0.5 * h)).frame(width: 3, height: max(6, 70 * h))
            }
        }
    }
}

/// Auday's Storage duration page: Forever, 7 days, 30 days or a custom number of days, with the
/// space each would take, and "Delete all existing audio". Only audio goes; text stays.
struct KeepAudioView: View {
    let log: DayLog
    @State private var days = DayLog.keepAudioDays
    @State private var custom = ![0, 7, 30].contains(DayLog.keepAudioDays)
    @State private var confirmDelete = false

    static func label(_ days: Int) -> String {
        days == 0 ? "Forever" : days == 1 ? "1 day" : "\(days) days"
    }

    /// What `days` of audio takes, from the average per recorded day so far.
    private func estimate(_ days: Int) -> String? {
        let recorded = log.days().count
        guard recorded > 0, DayLog.audioBytes > 0 else { return nil }
        return "≈ " + ByteCountFormatter.string(fromByteCount: DayLog.audioBytes / Int64(recorded) * Int64(days), countStyle: .file)
    }

    private func choose(_ value: Int, custom isCustom: Bool = false) {
        days = value
        custom = isCustom
        DayLog.keepAudioDays = value
        log.pruneAudio()
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Original audio storage duration").font(.system(size: 26, weight: .semibold))
                    (Text("Choose how long to keep original audio on this phone. ")
                     + Text("Don’t worry, your transcripts, summaries, and other text are kept permanently.").underline())
                        .foregroundStyle(Theme.muted)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                option("Forever", selected: days == 0 && !custom) { choose(0) }
                option("7 days", note: estimate(7), selected: days == 7 && !custom) { choose(7) }
                option("30 days", note: estimate(30), selected: days == 30 && !custom) { choose(30) }
                option("Custom", selected: custom) { choose(days == 0 ? 14 : days, custom: true) }
                if custom {
                    Stepper(value: Binding(get: { max(days, 1) }, set: { choose($0, custom: true) }), in: 1...365) {
                        HStack {
                            Text(Self.label(max(days, 1)))
                            if let note = estimate(max(days, 1)) { Text(note).foregroundStyle(Theme.muted).font(.footnote) }
                        }
                    }
                }
            }
            Section {
                Button("Delete all existing audio", role: .destructive) { confirmDelete = true }
            }
        }
        .settingsStyle()
        .navigationTitle("Storage duration")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete all existing audio?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete audio", role: .destructive) { log.pruneAudio(all: true) }
        } message: {
            Text("Transcripts, summaries and other text stay. Recordings still waiting to be transcribed keep their audio.")
        }
    }

    private func option(_ title: String, note: String? = nil, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Theme.text)
                if let note { Text(note).foregroundStyle(Theme.muted).font(.footnote) }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Theme.text) }
            }
        }
    }
}

enum Appearance: String, CaseIterable {
    case system, light, dark
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

struct BodyLocationView: View {
    let health: HealthSync
    @State private var locationData = PhoneLink.locationData
    @State private var bodyData = HealthSync.enabled

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("The context of\nyour day.").font(Theme.serif(30, .regular))
                    Text("Add body states, heart-rate and HRV statistics from Apple Health, and places recorded by your Watch to your words. Enabled context is shared with your selected AI provider for Chat, Highlights, summaries and reflections.")
                        .font(.system(size: 17)).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 8)
            }
            Section {
                Toggle("Body data", isOn: $bodyData)
                    .onChange(of: bodyData) { _, on in
                        HealthSync.enabled = on
                        if on { Task { await health.run() } }
                    }
                Text(HKHealthStore.isHealthDataAvailable() ? "Available" : "Not available on this device").foregroundStyle(Theme.muted)
            } header: { SectionHeader("Apple Health") }
            Section {
                Toggle("Location data", isOn: $locationData)
                    .onChange(of: locationData) { _, on in
                        PhoneLink.locationData = on
                        AppDelegate.link?.sendLocationData()
                    }
            } header: { SectionHeader("Recording places") } footer: {
                Text("While recording, the watch notes roughly where you are every 2 minutes. This iPhone names places with Apple's geocoder; only the place name and time go to your AI, never coordinates.")
            }
        }
        .settingsStyle()
        .toggleStyle(SwitchToggleStyle(tint: Theme.ink))
        .navigationTitle("Body & location data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Settings › Transcription (Auday's "Transcription mode"). Local efficient runs SenseVoice
/// (Apple's on-device speech model until it is downloaded), Local accurate runs Whisper, and
/// Cloud & self-hosted is listed as in Auday but not built yet.
struct TranscriptionView: View {
    let transcriber: LocalTranscriber
    @State private var automatic = LocalTranscriber.automatic
    @State private var chosen = LocalTranscriber.mode
    private let whisper = AppDelegate.whisper
    private let senseVoice = AppDelegate.senseVoice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Transcription mode").font(.system(size: 28, weight: .bold)).padding(.top, 8)
                mode(icon: "bolt.fill", title: "Local efficient", recommended: true, chosen: chosen == .efficient, pick: .efficient,
                     text: "Fast transcription with lower resource use.",
                     languages: TranscriptionLanguage.allCases.map(\.name)) {
                    // SenseVoice Small, as Auday; downloaded once on this iPhone.
                    if let progress = senseVoice.downloading {
                        Text("Downloading SenseVoice (\(SenseVoiceLocal.sizeLabel))…").font(.system(size: 16))
                        ProgressView(value: progress).tint(Theme.ink)
                    } else if !senseVoice.ready {
                        Button("Download SenseVoice (\(SenseVoiceLocal.sizeLabel))") { Task { await senseVoice.download() } }
                            .font(.system(size: 17, weight: .medium))
                        Text("Until it is downloaded, Apple's on-device speech model is used.").font(.system(size: 15)).foregroundStyle(Theme.faint)
                    }
                    if let problem = senseVoice.problem { Text(problem).font(.system(size: 15)).foregroundStyle(Theme.red) }
                    LabeledContent("Languages", value: [OutputLanguage.primary.label, OutputLanguage.secondary?.label]
                        .compactMap { $0 }.joined(separator: " · "))
                    Toggle("Automatic transcription", isOn: $automatic)
                        .toggleStyle(SwitchToggleStyle(tint: Theme.ink))
                        .onChange(of: automatic) { _, on in
                            LocalTranscriber.automatic = on
                            if on { Task { await transcriber.run() } }
                        }
                        .padding(.leading, 26)
                }
                mode(icon: "waveform", title: "Local accurate", chosen: chosen == .accurate, pick: .accurate,
                     text: "Quality first. More time and power. iPhone 15 or later recommended.",
                     languages: TranscriptionLanguage.allCases.map(\.name)) {
                    // Replica detail: Whisper is downloaded on this iPhone when you choose it.
                    if let progress = whisper.downloading {
                        Text("Downloading Whisper (\(WhisperLocal.sizeLabel))…").font(.system(size: 16))
                        ProgressView(value: progress).tint(Theme.ink)
                    } else if let progress = whisper.loading {
                        Text(whisper.preparing ? "Preparing the model on this iPhone (first time only, a few minutes)… \(Int(progress * 100)) %"
                                               : "Loading Whisper… \(Int(progress * 100)) %").font(.system(size: 16))
                        ProgressView(value: progress).tint(Theme.ink)
                    } else if whisper.ready {
                        Text("Whisper small (compressed) is on this iPhone.").font(.system(size: 16)).foregroundStyle(Theme.muted)
                        Button("Delete the model", role: .destructive) { whisper.remove(); choose(.efficient) }.font(.system(size: 16))
                    } else {
                        Button("Download Whisper (\(WhisperLocal.sizeLabel))") { Task { await whisper.download() } }
                            .font(.system(size: 17, weight: .medium))
                    }
                    if !WhisperLocal.recommendedDevice {
                        Text("This iPhone is older than recommended: transcription will be slow and use more battery.")
                            .font(.system(size: 15)).foregroundStyle(Theme.faint)
                    }
                    if let problem = whisper.problem { Text(problem).font(.system(size: 15)).foregroundStyle(Theme.red) }
                    LabeledContent("Languages", value: [OutputLanguage.primary.label, OutputLanguage.secondary?.label]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                mode(icon: "cloud", title: "Cloud & self-hosted", chosen: false,
                     text: "Use your own API key or connect to a speech service on your network.",
                     languages: []) {
                    Divider()
                    Text("For mixed languages, try Deepgram. Nova-3 mixes 10 supported languages, excluding Chinese.\nFor Chinese dialects, try Qwen. Language support varies by model.")
                        .font(.system(size: 18)).foregroundStyle(Theme.muted)
                    Text("Not in the replica yet.").font(.system(size: 15)).foregroundStyle(Theme.faint)
                }
                // Replica improvement: how many recordings wait, and a button to transcribe now.
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Waiting", value: "\(transcriber.pending)")
                    if let status = transcriber.status {
                        HStack(spacing: 6) {
                            Text(status)
                            if let started = transcriber.startedAt { Text(started, style: .timer).monospacedDigit() }
                            if let progress = whisper.transcribing { Text("· \(Int(progress * 100)) %").monospacedDigit() }
                        }
                        .font(.footnote).foregroundStyle(Theme.muted)
                        if let progress = whisper.transcribing { ProgressView(value: progress).tint(Theme.ink) }
                        else if let progress = whisper.loading, transcriber.busy { ProgressView(value: progress).tint(Theme.ink) }
                    }
                    if let last = transcriber.lastResult, transcriber.status == nil {
                        Label(last, systemImage: "checkmark").font(.footnote).foregroundStyle(Theme.muted)
                    }
                    Button(transcriber.busy ? "Transcribing…" : "Transcribe now") {
                        AppDelegate.dayLog.retryFailed()
                        Task { await transcriber.run(force: true) }
                    }
                    .disabled(transcriber.busy)
                }
                .font(.system(size: 18))
                // Replica improvement: what happened to each recording, newest first.
                let runs = AppDelegate.transcriptions.runs.suffix(12).reversed()
                if !runs.isEmpty {
                    Text("Recent transcriptions").font(Theme.serif(26, .regular)).padding(.top, 10)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(runs)) { run in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(Format.english("MMM d HH:mm", run.recordedAt)) · \(Format.duration(run.seconds))")
                                        .font(.system(size: 16, weight: .medium))
                                    Spacer()
                                    Text(run.result == "done" ? Format.plural(run.lines, "line") : run.result == "silent" ? "No speech" : "Failed")
                                        .font(.system(size: 15)).foregroundStyle(run.result == "failed" ? Theme.red : Theme.muted)
                                }
                                Text([run.engine, run.language, run.ended.map { String(format: "%.0f s", $0.timeIntervalSince(run.started)) }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 14)).foregroundStyle(Theme.faint)
                                if let error = run.error { Text(error).font(.system(size: 14)).foregroundStyle(Theme.red) }
                            }
                            .padding(.vertical, 10)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16).card(radius: 18)
                }
                Text("Applies to new transcription tasks. Completed recordings stay unchanged.")
                    .font(.system(size: 19)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 20).padding(.bottom, 30)
        }
        .background(Theme.bg)
        .navigationTitle("Transcription")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ mode: LocalTranscriber.Mode) {
        chosen = mode
        LocalTranscriber.mode = mode
    }

    private func mode<Extra: View>(icon: String, title: String, recommended: Bool = false, chosen: Bool,
                                   pick: LocalTranscriber.Mode? = nil, text: String,
                                   languages: [String], @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 34, height: 34).card(Theme.panel, radius: 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 30, weight: .semibold))
                    if recommended {
                        Text("Recommended").font(.system(size: 17)).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 10).padding(.vertical, 3).background(Theme.panel, in: Capsule())
                    }
                }
                Spacer()
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.system(size: 34, weight: .light))
                    .foregroundStyle(chosen ? Theme.ink : Theme.line)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard let pick else { return }
                choose(pick)
                if pick == .accurate && !whisper.ready { Task { await whisper.download() } }
            }
            .sensoryFeedback(.selection, trigger: chosen)
            Text(text).font(.system(size: 18)).foregroundStyle(Theme.muted)
            if !languages.isEmpty {
                Divider()
                Text("Supported languages").font(.system(size: 19, weight: .medium))
                FlowLayout(spacing: 6) {
                    ForEach(languages, id: \.self) {
                        Text($0).font(.system(size: 17)).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 8).padding(.vertical, 4).card(Theme.panel, radius: 4)
                    }
                }
            }
            extra()
        }
        .font(.system(size: 18))
        .padding(20)
        .card(Theme.raised, radius: 22)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(chosen ? Theme.muted : .clear, lineWidth: 1.5))
        .opacity(chosen ? 1 : 0.85)
    }
}

struct InfoPage: View {
    let title: String
    let text: String
    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 18)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }
        .background(Theme.bg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Batch export: the chosen days' transcripts as Notes (text) and their audio, shared from the iPhone.
struct BatchExportView: View {
    let log: DayLog
    let store: LocalStore
    @State private var from = Calendar.current.startOfDay(for: Date())
    @State private var to = Date()

    var body: some View {
        List {
            Section {
                DatePicker("From", selection: $from, in: ...Date(), displayedComponents: .date)
                DatePicker("To", selection: $to, in: ...Date(), displayedComponents: .date)
            } footer: {
                Text("Exports the transcripts as one text file and the original audio files of these days.")
            }
            Section {
                ShareLink(items: files()) { Label("Export", systemImage: "square.and.arrow.up") }
            }
        }
        .settingsStyle()
        .navigationTitle("Batch export")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func files() -> [URL] {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to))!
        let entries = log.entries.filter { !$0.mark && $0.start >= Calendar.current.startOfDay(for: from) && $0.start < end }
        let notes = entries.map { "[\(Format.english("yyyy-MM-dd HH:mm:ss", $0.start))] \($0.text)" }.joined(separator: "\n")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Auday_\(Format.ymd.string(from: from))_\(Format.ymd.string(from: to)).txt")
        try? notes.write(to: file, atomically: true, encoding: .utf8)
        return [file] + entries.map(DayLog.audioURL).filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
