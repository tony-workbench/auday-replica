import AudayKit
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static let uploader = Uploader()
    @MainActor static let health = HealthSync(outbox: uploader.outbox) { uploader.pump() }
    @MainActor static var link: PhoneLink?
    @MainActor static let dayLog = DayLog()
    @MainActor static let transcriber = LocalTranscriber(log: dayLog)
    @MainActor static let store = LocalStore()
    @MainActor static let pipeline = Pipeline(log: dayLog, store: store)
    @MainActor static let mac = MacLink(uploader: uploader)
    @MainActor static let voice = VoiceModel(log: dayLog)
    @MainActor static let whisper = WhisperLocal()
    @MainActor static let places = PlaceLog()
    @MainActor static let senseVoice = SenseVoiceLocal()
    @MainActor static let transcriptions = TranscriptionLog()

    @MainActor
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let uploader = Self.uploader, health = Self.health
        // Recordings still waiting in the outbox show on Days too.
        for item in uploader.outbox.items() {
            switch item {
            case .fragment(let fragment):
                DayLog.keepAudio(of: fragment, from: uploader.outbox.audioURL(for: fragment))
                Self.dayLog.add(fragment)
            case .mark(let mark): Self.dayLog.add(mark)
            default: break
            }
        }
        Self.link = PhoneLink(outbox: uploader.outbox) {
            Task { @MainActor in
                uploader.pump()
                await health.run()        // the body data for the hour just recorded
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-sampleDay") { Self.store.loadSample(on: Format.ymd.string(from: Date())) }
        DebugInbox.listen(Self.link!)
        #endif
        Task { await health.run() }
        Self.dayLog.markMissingAudio()
        Task {
            await Self.voice.upgradeIfNeeded()      // a cold launch never sees the scene turn active
            await Self.transcriber.run()
            await Self.voice.relabel()
            await Self.pipeline.run()
        }
        return true
    }

    @MainActor
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Self.uploader.backgroundEventsDone = completionHandler
    }
}

@main
struct AudayPhoneApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    /// Bumped when the time zone changes (travel), so every screen redraws in the new local time.
    @State private var timeZone = TimeZone.current.identifier

    var body: some Scene {
        WindowGroup {
            HomeView(uploader: AppDelegate.uploader, health: AppDelegate.health, log: AppDelegate.dayLog,
                     transcriber: AppDelegate.transcriber, store: AppDelegate.store)
                .id(timeZone)
                .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                    NSTimeZone.resetSystemTimeZone()
                    timeZone = TimeZone.current.identifier
                }
        }
        .onChange(of: phase) { _, now in
            guard now == .active else { return }
            #if DEBUG
            AppDelegate.link.map(DebugInbox.drain)
            #endif
            AppDelegate.uploader.retryNow()
            AppDelegate.dayLog.pruneAudio()       // applies the "Keep original audio" setting
            Task { await AppDelegate.voice.upgradeIfNeeded() }
            Task { await AppDelegate.health.run() }
            Task {
                await AppDelegate.transcriber.run()
            await AppDelegate.voice.relabel()
                await AppDelegate.pipeline.run()
                await AppDelegate.pipeline.resumePending()     // a reflection cut off when the app left
            }
        }
    }
}
