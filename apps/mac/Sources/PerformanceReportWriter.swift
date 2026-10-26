import AppKit
import Darwin
import Foundation
import PresenterCore
import RenderEngine

/// Help › Save Performance Report…: samples the app for two seconds and
/// writes what it is doing to a text file on the Desktop, for whoever is
/// looking into a slow show Mac. Nothing in it names people, presentations
/// or files: threads, screens, devices and counts only.
@MainActor
enum PerformanceReportWriter {
    nonisolated static let sampleSeconds = 2.0

    private static var saving = false

    static func save() {
        guard !saving else { return }
        saving = true
        var mainID: UInt64 = 0
        pthread_threadid_np(nil, &mainID)
        let displays = NSScreen.screens.map { screen in
            PerformanceReport.Display(
                name: screen.localizedName,
                pixelWidth: Int(screen.frame.width * screen.backingScaleFactor),
                pixelHeight: Int(screen.frame.height * screen.backingScaleFactor),
                refreshHz: screen.maximumFramesPerSecond)
        }
        let launched = NSRunningApplication.current.launchDate ?? Date()
        Task.detached(priority: .utility) {
            let first = ThreadTimes.sample(mainThreadID: mainID)
            try? await Task.sleep(for: .seconds(sampleSeconds))
            let second = ThreadTimes.sample(mainThreadID: mainID)
            let threads = ThreadTimes.usage(from: first, to: second, over: sampleSeconds)
            let memory = MemoryFootprint.current()
            let now = Date()
            let report = PerformanceReport(
                generatedAt: now,
                appVersion: versionLine(),
                system: "\(ProcessInfo.processInfo.operatingSystemVersionString), \(hardwareModel())",
                uptimeSeconds: now.timeIntervalSince(launched),
                sampleSeconds: sampleSeconds,
                processCPUPercent: threads.reduce(0) { $0 + $1.cpuPercent },
                threads: threads,
                frames: FrameActivity.shared.snapshot().map {
                    .init(kind: $0.kind, label: $0.label, rendered: $0.rendered, skipped: $0.skipped)
                },
                hangs: DiagnosticsStore.shared.hangs.withLock { $0 },
                memoryFootprintBytes: memory.footprint,
                memoryPeakBytes: memory.peak,
                displays: displays)
            let url = write(report.text(), at: now)
            await MainActor.run {
                saving = false
                if let url {
                    DiagnosticsStore.shared.note("perf.report", detail: url.lastPathComponent)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSSound.beep()
                }
            }
        }
    }

    nonisolated private static func write(_ text: String, at date: Date) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "Screens Performance Report \(formatter.string(from: date)).txt"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        // The Desktop is where someone will look; the diagnostics folder is
        // the fallback when the Desktop can't be written.
        for folder in [desktop, DiagnosticsStore.folder].compactMap({ $0 }) {
            let url = folder.appendingPathComponent(name)
            if (try? Data(text.utf8).write(to: url, options: .atomic)) != nil { return url }
        }
        return nil
    }

    nonisolated private static func versionLine() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    nonisolated private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// CPU time per thread, read with `task_threads` and `thread_info`.
enum ThreadTimes {
    struct Sample {
        var name: String
        var seconds: Double
    }

    static func sample(mainThreadID: UInt64) -> [UInt64: Sample] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [:] }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var samples: [UInt64: Sample] = [:]
        for index in 0..<Int(count) {
            let thread = list[index]
            var identifier = thread_identifier_info_data_t()
            var identifierCount = mach_msg_type_number_t(
                MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size)
            let identified = withUnsafeMutablePointer(to: &identifier) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identifierCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierCount)
                }
            }
            var extended = thread_extended_info_data_t()
            var extendedCount = mach_msg_type_number_t(
                MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            let described = withUnsafeMutablePointer(to: &extended) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
                }
            }
            guard identified == KERN_SUCCESS, described == KERN_SUCCESS else { continue }
            let id = identifier.thread_id
            var name = withUnsafeBytes(of: extended.pth_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if id == mainThreadID {
                name = "main"
            } else if name.isEmpty {
                // Dispatch worker threads carry no name; they are the feeds'
                // conversion queues, Metal's completion queues and the like.
                name = "unnamed worker \(id)"
            }
            let seconds = Double(extended.pth_user_time + extended.pth_system_time) / 1_000_000_000
            samples[id] = Sample(name: name, seconds: seconds)
        }
        return samples
    }

    static func usage(
        from first: [UInt64: Sample], to second: [UInt64: Sample], over seconds: Double
    ) -> [PerformanceReport.ThreadLine] {
        second.map { id, sample in
            let before = first[id]?.seconds ?? sample.seconds
            return PerformanceReport.ThreadLine(
                name: sample.name, cpuPercent: max(0, sample.seconds - before) / seconds * 100)
        }
    }
}

enum MemoryFootprint {
    static func current() -> (footprint: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }
}
