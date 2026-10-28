#if DEBUG
import Foundation
import notify

/// Drives the watch app in the simulator without tapping (DEBUG builds only), like the phone's
/// DebugInbox. Each Darwin notification does what the matching control does:
///   xcrun simctl spawn <watch> notifyutil -p auday-replica.watch.toggle   Tap to start, or hold to stop
///   xcrun simctl spawn <watch> notifyutil -p auday-replica.watch.mark     Tap to mark
///   xcrun simctl spawn <watch> notifyutil -p auday-replica.watch.sync     Sync now
enum DebugControl {
    @MainActor
    static func listen(recorder: Recorder, link: WatchLink) {
        let actions: [(String, @MainActor () -> Void)] = [
            ("auday-replica.watch.toggle", { recorder.toggle() }),
            ("auday-replica.watch.mark", { recorder.mark() }),
            ("auday-replica.watch.sync", { recorder.syncNow() }),
        ]
        for (name, action) in actions {
            var token: Int32 = 0
            notify_register_dispatch(name, &token, .main) { _ in
                MainActor.assumeIsolated { action() }
            }
        }
    }
}
#endif
