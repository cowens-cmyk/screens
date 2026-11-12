import AppKit
import Foundation
import PresenterCore
import SwiftUI

/// This Mac's media location (MediaStorage) as the app sees it: whether the
/// external drive is plugged in, moving the files to a drive and back, and
/// finishing a move after the relaunch.
@MainActor
@Observable
final class MediaDriveMonitor {
    static let shared = MediaDriveMonitor()

    /// The internal files folder a move to a drive left behind; removed at
    /// the next launch once every file is on the drive.
    private static let pendingRemovalKey = "media.storage.pendingRemoval"
    private static let checkSeconds: TimeInterval = 10

    /// Where the files are now (fixed for this launch).
    private(set) var resolved: MediaStorage.Resolved?
    /// The drive is plugged in (always true for this Mac).
    private(set) var isConnected = true
    private(set) var freeBytes: Int64?

    /// A move in progress: files done of total, and bytes.
    struct Move: Equatable {
        var toDrive: Bool
        var done = 0
        var total = 0
        var bytes: Int64 = 0
        var current = ""
    }

    private(set) var move: Move?
    private(set) var problem: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var libraryRoot: URL?

    var isExternal: Bool { resolved?.isExternal == true }

    func start(model: AppModel) {
        self.model = model
        let root = model.client.rootURL
        libraryRoot = root
        resolved = MediaStorage.resolve(libraryRoot: root, location: MediaStorage.location())
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Task { await finishPendingRemoval() }
    }

    /// Checks the drive; a change shows the files again (or as missing).
    func refresh() {
        guard let resolved else { return }
        let connected = !resolved.isExternal || MediaStorage.isReachable(resolved.directory)
        let values = try? (connected ? resolved.directory : resolved.root)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeBytes = values?.volumeAvailableCapacityForImportantUsage
        guard connected != isConnected else { return }
        isConnected = connected
        DiagnosticsStore.shared.note(connected ? "media.drive.connected" : "media.drive.disconnected", detail: resolved.root.path)
        model?.noteBlobsChanged()
    }

    /// The bytes the media files take up where they are now.
    func usedBytes() async -> Int64 {
        guard let directory = resolved?.directory, isConnected else { return 0 }
        return await Task.detached(priority: .utility) {
            MediaStorage.totalBytes(in: directory)
        }.value
    }

    // MARK: Moving

    /// Asks for a folder on a drive, then moves the files there.
    func chooseDriveAndMove() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder for Media"
        panel.message = "Pick or make a folder on the external drive, for example \u{201C}Screens Media\u{201D}. Every picture, video and audio file moves there."
        panel.prompt = "Move Media Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        if let root = libraryRoot, folder.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
            problem = "Choose a folder outside the Screens library."
            return
        }
        Task { await moveFiles(toDrive: folder) }
    }

    /// Moves the files back into the library on this Mac. The copies on the
    /// drive are left there.
    func moveBackToThisMac() {
        Task { await moveFiles(toDrive: nil) }
    }

    private func moveFiles(toDrive folder: URL?) async {
        guard move == nil, let libraryRoot, let current = resolved else { return }
        problem = nil
        guard isConnected else {
            problem = "Plug in the media drive first: its files have to be copied."
            return
        }
        let target = MediaStorage.resolve(
            libraryRoot: libraryRoot, location: folder.map { .external($0) } ?? .thisMac)
        guard target.directory.standardizedFileURL != current.directory.standardizedFileURL else { return }
        move = Move(toDrive: folder != nil)
        defer { move = nil }
        do {
            try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
            let source = current.directory
            let destination = target.directory
            // Files imported while the move runs land in the old folder, so
            // it goes round until nothing is left to copy.
            for _ in 0 ..< 3 {
                let plan = await Task.detached(priority: .userInitiated) {
                    MediaStorage.plan(from: source, to: destination)
                }.value
                if plan.files.isEmpty { break }
                if let free = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage, free < plan.bytes + 1_000_000_000 {
                    throw MoveError.noRoom(needed: plan.bytes)
                }
                move?.total += plan.files.count
                for file in plan.files {
                    move?.current = file.lastPathComponent
                    try await Task.detached(priority: .userInitiated) {
                        try MediaStorage.copyVerified(file, into: destination)
                    }.value
                    move?.done += 1
                    move?.bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }
            MediaStorage.choose(folder)
            if folder != nil, !current.isExternal {
                // The copies on this Mac go once the drive has been used for a launch.
                UserDefaults.standard.set(source.path, forKey: Self.pendingRemovalKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pendingRemovalKey)
            }
            DiagnosticsStore.shared.note("media.storage.moved", detail: destination.path)
            relaunch()
        } catch {
            problem = error.localizedDescription
            DiagnosticsStore.shared.note("media.storage.moveFailed", detail: "\(error)")
        }
    }

    enum MoveError: LocalizedError {
        case noRoom(needed: Int64)

        var errorDescription: String? {
            switch self {
            case .noRoom(let needed):
                "There isn't room on that drive: the media needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) plus 1 GB to spare. Nothing was changed."
            }
        }
    }

    /// After a move to a drive: once this launch finds the drive, anything
    /// still missing there is copied, and then the copies on this Mac go.
    private func finishPendingRemoval() async {
        guard let path = UserDefaults.standard.string(forKey: Self.pendingRemovalKey),
              let resolved, resolved.isExternal, isConnected else { return }
        let old = URL(fileURLWithPath: path, isDirectory: true)
        let destination = resolved.directory
        let finished: Bool = await Task.detached(priority: .utility) {
            for file in MediaStorage.plan(from: old, to: destination).files {
                guard (try? MediaStorage.copyVerified(file, into: destination)) != nil else { return false }
            }
            guard MediaStorage.isCompleteCopy(from: old, to: destination) else { return false }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: old, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for file in files { try? FileManager.default.removeItem(at: file) }
            return true
        }.value
        if finished {
            UserDefaults.standard.removeObject(forKey: Self.pendingRemovalKey)
            DiagnosticsStore.shared.note("media.storage.cleanedUp", detail: old.path)
        }
    }

    /// Opens a new copy of Screens once this one has quit, so every part of
    /// it starts on the new location.
    private func relaunch() {
        let app = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        /usr/bin/open "\(app)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        AppDelegate.quitsWithoutAsking = true
        NSApp.terminate(nil)
    }
}

// MARK: Views

/// Settings › Media & Video › Media Storage.
struct MediaStorageSection: View {
    @State private var used: Int64?
    @State private var confirmingBack = false
    @Environment(\.runOnly) private var runOnly

    var body: some View {
        let monitor = MediaDriveMonitor.shared
        Section {
            LabeledContent("Media files") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(monitor.isExternal ? (monitor.resolved?.root.path ?? "") : "On this Mac")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if monitor.isExternal, !monitor.isConnected {
                        Label("Drive not connected", systemImage: "externaldrive.badge.xmark")
                            .foregroundStyle(.red)
                    } else {
                        Text(Self.sizes(used: used, free: monitor.freeBytes))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
            }
            if let move = monitor.move {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(move.done), total: Double(max(move.total, 1)))
                    Text("Moving \(move.done) of \(move.total) · \(ByteCountFormatter.string(fromByteCount: move.bytes, countStyle: .file)) · \(move.current)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            } else {
                HStack {
                    Spacer()
                    if monitor.isExternal {
                        Button("Move Back to This Mac…") { confirmingBack = true }
                    }
                    Button(monitor.isExternal ? "Choose Another Drive…" : "Use an External Drive…") {
                        monitor.chooseDriveAndMove()
                    }
                }
                .disabled(runOnly)
            }
            if let problem = monitor.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        } header: {
            Text("Media Storage")
        } footer: {
            Text("Keep this Mac's pictures, videos and audio on an external SSD instead of its own drive. Every file is copied and checked, then Screens relaunches; the copies on this Mac are removed once it has started from the drive. Videos play straight from the drive, so keep it plugged in during services. Kept per Mac.")
        }
        .task { used = await monitor.usedBytes() }
        .confirmationDialog("Move media back to this Mac?", isPresented: $confirmingBack) {
            Button("Move Back") { monitor.moveBackToThisMac() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every file is copied back into the library on this Mac, then Screens relaunches. The files on the drive are left where they are.")
        }
    }

    static func sizes(used: Int64?, free: Int64?) -> String {
        let format = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        return [used.map { "\(format($0)) used" }, free.map { "\(format($0)) free" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Over the slides while the media drive is unplugged: nothing on it can
/// play until it's back.
struct MediaDriveBanner: View {
    var body: some View {
        let monitor = MediaDriveMonitor.shared
        if monitor.isExternal, !monitor.isConnected {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.system(size: 20))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Media drive not connected").font(.headline)
                    Text("Backgrounds and videos can\u{2019}t play until it\u{2019}s plugged back in.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.red, lineWidth: 2))
            .padding(.top, 10)
        }
    }
}
