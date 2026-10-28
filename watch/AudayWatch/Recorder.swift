import AudayKit
import AVFoundation
import Observation
import UserNotifications
import WatchKit

/// Records continuously in fragments like Auday's watch: AAC, mono, ~32 kbps (~15 MB per hour),
/// each at most 15 minutes and cut at every clock hour. Auday writes CAF; this writes ADTS so a
/// cut-off file still plays. A call or other interruption ends the session; capture resumes
/// afterwards under a new session ID.
///
/// One AVAudioEngine runs for the whole session and the fragments are cut on the audio thread by
/// switching files, so the microphone never stops between fragments. Stopping one recorder and
/// starting the next would leave a gap, and watchOS can suspend a background app in that gap.
@MainActor @Observable
final class Recorder: NSObject {
    enum State { case idle, capturing, interrupted }

    private(set) var state = State.idle
    private(set) var problem: String?
    /// When the user started capturing; interruptions inside it do not reset it.
    private(set) var since: Date?
    /// Marks made since the user started capturing.
    private(set) var marks = 0
    /// When the fragment being recorded started; it counts as awaiting sync on the status page.
    private(set) var fragmentStart: Date? {
        didSet { link.recordingSince = fragmentStart }
    }
    /// Paused, but trying to pick up again by itself; the screen says "Resuming…", not "Tap to resume".
    private(set) var resuming = false

    private let link: WatchLink
    let places = PlaceSampler()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var writer: FragmentWriter?
    /// What the user asked for; an interruption pauses capture without clearing it.
    private var wanted = false
    /// A mark stopped the microphone for its haptic; capture goes on after it.
    private var markGap = false
    /// How long the microphone stays off so a haptic is felt (watchOS mutes them while recording).
    static let hapticGap: TimeInterval = 0.5

    init(link: WatchLink) {
        self.link = link
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                               object: nil, queue: .main) { _ in DiagLog.note("media services reset") }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil,
                                               queue: .main) { note in
            DiagLog.note("route change \(note.userInfo?[AVAudioSessionRouteChangeReasonKey] ?? "?")")
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { self.engineChanged() }
        }
        if link.locationData { places.askIfNeeded() }
        recoverUnfiled()
    }

    func toggle() {
        wanted ? stop() : start()
    }

    func start() {
        problem = nil
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                if granted {
                    self.wanted = true
                    // For "Tap to resume" after a call; asked while the user is looking.
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    self.since = Date()
                    self.marks = 0
                    // The watch mutes haptics while the microphone records, so the tap comes first.
                    WKInterfaceDevice.current().play(.start)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.hapticGap) {
                        if self.wanted && self.state == .idle { self.beginSession() }
                    }
                } else {
                    self.problem = "Allow microphone access in Settings › Privacy"
                }
            }
        }
    }

    func stop() {
        DiagLog.note("stop by user")
        guard wanted else { return }
        wanted = false
        since = nil
        resuming = false
        markGap = false
        stopEngine()               // files the last fragment
        link.syncNow()
        places.stop()
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // The haptic only after the microphone and its session are let go; while they run, the
        // watch mutes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            WKInterfaceDevice.current().play(.stop)
        }
    }

    /// Resumes capture on the audio session the app still holds, without activating it again.
    private func restartEngine() -> Bool {
        writerSession = UUID().uuidString
        startEngine()
        DiagLog.note("engine restart \(state == .capturing ? "worked" : "refused")")
        return state == .capturing
    }

    /// Back on screen while paused: keep trying for a minute. Right after Siri or a call the
    /// microphone is unavailable for a few seconds; if every try fails, "Tap to resume" stays.
    private func resumeOnScreen() {
        DiagLog.note("resume on screen")
        tryResume()
        retryResume()
    }

    /// Every half second for the first 15 s (the microphone comes free about 5 s after Siri),
    /// then less often up to a minute.
    private static let resumeDelays: [TimeInterval] = stride(from: 0.5, through: 15, by: 0.5).map { $0 } + [20, 30, 45, 60]
    @ObservationIgnored private var resumeRetries = 0

    /// Retries on a schedule while paused, also in the background, so capture can resume
    /// without the user.
    private func retryResume() {
        resumeRetries += 1
        let round = resumeRetries
        resuming = true
        for delay in Self.resumeDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard round == self.resumeRetries, self.wanted, self.state == .interrupted else { return }
                DiagLog.note("resume retry at \(delay)s, on screen=\(self.onScreen)")
                self.tryResume()
                if delay == Self.resumeDelays.last, self.state == .interrupted {
                    self.resuming = false          // out of tries: now it's "Tap to resume"
                }
            }
        }
    }

    private func tryResume() {
        if restartEngine() { return }
        if onScreen { beginSession() }
    }

    /// After a call: watchOS lets recording start again only from the foreground, by the user.
    func resume() {
        guard wanted, state == .interrupted else { return }
        DiagLog.note("resume")
        if restartEngine() { return }
        beginSession()
    }

    /// "Sync now": while capturing, cut the current fragment so it goes too; the next one starts
    /// at once in the same session.
    func syncNow() {
        if state == .capturing, let writer, !markGap {
            writer.cutSoon()       // the audio thread files it with the next buffer
        } else {
            link.syncNow()
        }
    }

    func mark() {
        guard wanted else { return }
        link.send(Mark(start: Date()))
        marks += 1
        guard state == .capturing, !markGap else {
            if !markGap { WKInterfaceDevice.current().play(.notification) }
            return
        }
        // Even an idle recording session mutes haptics, so the microphone and the session are let
        // go for a moment. The user is looking at the app, so it stays awake meanwhile.
        markGap = true
        stopEngine()
        try? AVAudioSession.sharedInstance().setActive(false)
        WKInterfaceDevice.current().play(.notification)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hapticGap) {
            guard self.markGap else { return }
            self.markGap = false
            guard self.wanted && self.state == .capturing else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            self.startEngine()
        }
    }

    /// The level meter runs only while on screen.
    var onScreen = true {
        didSet {
            writer?.metering = onScreen
            DiagLog.note(onScreen ? "on screen" : "off screen")
            // Back on screen after an interruption whose end never came: start again.
            if onScreen && wanted && state == .interrupted { resumeOnScreen() }
        }
    }

    /// The input level from 0 to 1, for the live meter.
    func level() -> Double {
        guard onScreen, let writer else { return 0 }
        let db = 20 * log10(Double(max(writer.level, 1e-7)))           // RMS → dBFS
        return min(1, max(0, (db + 50) / 50))
    }

    private func beginSession() {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true)
        } catch {
            DiagLog.note("session activate failed \(error)")
            if state == .interrupted {
                problem = "Tap to resume recording"     // still paused; the user can try again
            } else {
                fail("Microphone unavailable: \(error.localizedDescription)")
            }
            return
        }
        problem = nil
        if link.locationData { places.start() }
        writerSession = UUID().uuidString
        startEngine()
    }

    @ObservationIgnored private var writerSession = ""

    private func startEngine() {
        // After an interruption the microphone's format can change under the engine, and a tap
        // installed with a stale format makes AVFAudio abort the app. Reset first, check the
        // hardware is really there, and let the tap take whatever format comes.
        engine.stop()
        engine.reset()
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            DiagLog.note("no microphone input yet")
            refused("Microphone unavailable")
            return
        }
        let writer = FragmentWriter(session: writerSession) { done in
            DispatchQueue.main.async { self.filed(done) }
        } started: { start in
            DispatchQueue.main.async { self.fragmentStart = start }
        }
        writer.metering = onScreen
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            writer.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            DiagLog.note("engine start failed \(error)")
            refused("Could not start recording: \(error.localizedDescription)")
            return
        }
        self.writer = writer
        state = .capturing
        resuming = false
        // Capturing again: the pause message and the "Tap to resume" notification are stale.
        problem = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["resume"])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["resume"])
        DiagLog.note("engine start \(Int(hardware.sampleRate)) Hz \(hardware.channelCount) ch")
        startUsageNotes()
    }

    /// Paused after a call: stay paused with "Tap to resume". Otherwise give up with the message.
    private func refused(_ message: String) {
        if state == .interrupted {
            problem = "Tap to resume recording"
        } else {
            fail(message)
        }
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        writer?.finish()           // files the open fragment on this thread's next turn
        writer = nil
        fragmentStart = nil
    }

    private func engineChanged() {
        DiagLog.note("engine configuration change, running=\(engine.isRunning)")
        guard wanted, state == .capturing, !markGap, !engine.isRunning else { return }
        stopEngine()
        startEngine()
    }

    private func askToResume() {
        DiagLog.note("asking to resume")
        let content = UNMutableNotificationContent()
        content.title = "Recording paused"
        content.body = "Tap to keep capturing after your call."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "resume", content: content, trigger: nil))
    }

    private func fail(_ message: String) {
        wanted = false
        since = nil
        places.stop()
        state = .idle
        problem = message
    }

    /// A fragment the writer closed (time limit, clock hour, Sync now, stop): send it right away;
    /// the 15-minute timer only retries what could not go.
    private func filed(_ done: FragmentWriter.Done) {
        DiagLog.note("fragment filed \(done.id.prefix(8)) \(Int(done.duration))s")
        guard done.duration >= 0.5 else {
            try? FileManager.default.removeItem(at: done.url)
            return
        }
        link.enqueue(Fragment(id: done.id, session: done.session, start: done.start, duration: done.duration,
                              ext: FragmentWriter.ext,
                              places: places.take(before: done.start.addingTimeInterval(done.duration))),
                     audio: done.url)
        link.syncNow()
    }

    private var usageTimer: Timer?

    /// Every 15 s while capturing: memory footprint and CPU time, so the log shows whether the
    /// system ended the app for memory or for CPU.
    private func startUsageNotes() {
        guard usageTimer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                guard self.wanted else {
                    self.usageTimer?.invalidate()
                    self.usageTimer = nil
                    return
                }
                DiagLog.note(Usage.now())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer
    }

    /// Audio left in tmp by a run the system ended mid-fragment (nothing filed it) is filed now
    /// as its own session, so it still reaches the iPhone instead of being lost.
    private func recoverUnfiled() {
        let tmp = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey]))
            ?? []
        for url in files where ["aac", "caf"].contains(url.pathExtension) {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            // An unfinished file may not open; then estimate from its size at the ~32 kbps bit rate.
            var duration: TimeInterval
            if let audio = try? AVAudioFile(forReading: url), audio.fileFormat.sampleRate > 0, audio.length > 0 {
                duration = Double(audio.length) / audio.fileFormat.sampleRate
            } else {
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                duration = Double(bytes) * 8 / 32_000
            }
            DiagLog.note("recovering \(url.lastPathComponent.prefix(8)) \(Int(duration))s")
            guard duration >= 0.5 else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            link.enqueue(Fragment(id: url.deletingPathExtension().lastPathComponent, session: UUID().uuidString,
                                  start: created, duration: duration, ext: url.pathExtension), audio: url)
        }
    }

    @objc nonisolated private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DiagLog.note("interruption \(raw == 1 ? "began" : "ended") reason=\(note.userInfo?[AVAudioSessionInterruptionReasonKey] ?? "-") options=\(note.userInfo?[AVAudioSessionInterruptionOptionKey] ?? "-")")
        Task { @MainActor in
            switch type {
            case .began:
                guard self.wanted, self.state == .capturing, !self.markGap else { return }
                self.state = .interrupted          // the session ends here
                // File what was recorded, but leave the audio session alone: activating it again
                // later is what watchOS refuses, while restarting the engine may be allowed.
                self.stopEngine()
            case .ended:
                guard self.wanted, self.state == .interrupted else { return }
                // After the call: a new session. First just restart the engine on the session we
                // still hold, which works without the user; only if that is refused fall back.
                if self.restartEngine() { return }
                if self.onScreen {
                    self.resumeOnScreen()
                } else {
                    self.retryResume()
                    // Usually capture is back within seconds; only then still paused, ask the user.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                        if self.wanted && self.state == .interrupted { self.askToResume() }
                    }
                }
            @unknown default:
                break
            }
        }
    }
}

/// Writes the microphone's buffers into fragment files on the audio thread: a new file at each
/// fragment end (15 minutes, clock hour) or when asked, so cutting never stops the microphone.
final class FragmentWriter: @unchecked Sendable {
    struct Done {
        var url: URL
        var id: String
        var session: String
        var start: Date
        var duration: TimeInterval
    }

    private let session: String
    /// The tap's format, taken from the first buffer.
    private var format: AVAudioFormat?
    private let filed: (Done) -> Void
    private let started: (Date) -> Void
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var current: (url: URL, id: String, start: Date, end: Date, frames: AVAudioFramePosition)?
    private var cutRequested = false
    /// The latest buffer's RMS, for the level meter; only measured while on screen.
    private(set) var level: Float = 0
    var metering = true

    init(session: String, filed: @escaping (Done) -> Void, started: @escaping (Date) -> Void) {
        self.session = session
        self.filed = filed
        self.started = started
    }

    static func end(of start: Date) -> Date {
        let end = FragmentClock.end(of: start)
        #if DEBUG
        // `devicectl device process launch … -AudayFragmentSeconds 60` tests cutting in minutes.
        let seconds = UserDefaults.standard.double(forKey: "AudayFragmentSeconds")
        if seconds > 0 { return min(end, start.addingTimeInterval(seconds)) }
        #endif
        return end
    }

    static let ext = "aac"

    func cutSoon() {
        lock.withLock { cutRequested = true }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if format == nil { format = buffer.format }
        if let current, cutRequested || now >= current.end { close() }
        cutRequested = false
        if current == nil { open(at: now) }
        guard let file else { return }
        do {
            try file.write(from: buffer)
            current?.frames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            DiagLog.note("write failed \(error)")
        }
        if metering, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            level = (sum / Float(buffer.frameLength)).squareRoot()
        }
    }

    /// Files whatever is open; nothing is written after this.
    func finish() {
        lock.withLock { close() }
    }

    private func open(at now: Date) {
        guard let format else { return }
        let id = UUID().uuidString
        // AAC in ADTS: every frame carries its own header, so a file the system cut off when it
        // ended the app still plays. AAC in CAF needs a packet table written on close and is
        // unreadable without it.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).\(FragmentWriter.ext)")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            do {
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
            } catch {
                // An encoder that refuses 32 kbps at this sample rate gets its own default rate.
                DiagLog.note("open at 32 kbps failed \(error); using the encoder's default")
                var fallback = settings
                fallback[AVEncoderBitRateKey] = nil
                file = try AVAudioFile(forWriting: url, settings: fallback, commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
            }
            current = (url, id, now, Self.end(of: now), 0)
            DiagLog.note("fragment start \(id.prefix(8))")
            started(now)
        } catch {
            DiagLog.note("open failed \(error)")
        }
    }

    private func close() {
        guard let current else { return }
        file = nil                 // closing the AVAudioFile writes out the last frames
        self.current = nil
        filed(Done(url: current.url, id: current.id, session: session, start: current.start,
                   duration: Double(current.frames) / (format?.sampleRate ?? 48_000)))
    }
}
