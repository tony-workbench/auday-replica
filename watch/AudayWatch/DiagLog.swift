import Foundation

/// A small event log in the app's Caches folder, so a run on a real watch can be read back with
/// `xcrun devicectl device copy from … --source Library/Caches/diag.log`. Times and event names
/// only; no audio or places.
enum DiagLog {
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("diag.log")
    private static let queue = DispatchQueue(label: "diag-log")

    static func note(_ event: String) {
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(event)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// This process's memory footprint and CPU time so far.
enum Usage {
    static func now() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vm = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb = vm == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return String(format: "usage mem=%.1fMB cpu=%.1fs", mb, cpu)
    }
}
