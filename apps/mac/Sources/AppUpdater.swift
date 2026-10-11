import AppKit
import Foundation
import Observation
import Security

/// Updates from the GitHub repository's Releases: checks the latest release
/// at launch and every few hours, and when it's newer, downloads its DMG,
/// verifies the app inside is signed by the same Developer ID team as this
/// one, swaps it in and relaunches. No more downloading DMGs by hand.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    static let repository = Bundle.main.object(forInfoDictionaryKey: "ScreensUpdateRepository") as? String
        ?? "cowens-cmyk/screens"
    /// Only apps signed by this team are installed.
    static let teamIdentifier = "TCAQTA64TB"
    private static let autoKey = "updates.automatic"

    struct Release: Equatable {
        var version: String
        var notes: String
        var dmgURL: URL
        var page: URL?
    }

    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Self.autoKey) }
    }
    private(set) var available: Release?
    private(set) var status: String?
    private(set) var isWorking = false
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {
        checksAutomatically = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true
    }

    func start() {
        guard checksAutomatically else { return }
        Task { await check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await AppUpdater.shared.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) async {
        isWorking = true
        defer { isWorking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                status = "No releases published yet."
                return
            }
            struct GitHubRelease: Decodable {
                struct Asset: Decodable { var name: String; var browser_download_url: URL }
                var tag_name: String
                var body: String?
                var html_url: URL?
                var assets: [Asset]
            }
            let latest = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard let dmg = latest.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
                status = "The latest release has no DMG."
                return
            }
            if Self.isNewer(version, than: currentVersion) {
                available = Release(version: version, notes: latest.body ?? "", dmgURL: dmg.browser_download_url, page: latest.html_url)
                status = "Screens \(version) is available."
                if !userInitiated { promptToInstall() }
            } else {
                available = nil
                status = "Screens is up to date (\(currentVersion))."
            }
        } catch {
            status = "Couldn't check for updates: \(error.localizedDescription)"
        }
        if userInitiated, available != nil { promptToInstall() }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    private func promptToInstall() {
        guard let available else { return }
        let alert = NSAlert()
        alert.messageText = "Screens \(available.version) is available"
        alert.informativeText = (available.notes.isEmpty ? "" : String(available.notes.prefix(600)) + "\n\n")
            + "You have \(currentVersion). Screens will quit, update and reopen. Don't update during a service."
        alert.addButton(withTitle: "Update and Relaunch")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await install(available) }
        }
    }

    func install(_ release: Release) async {
        isWorking = true
        defer { isWorking = false }
        status = "Downloading \(release.version)…"
        do {
            let (downloaded, _) = try await URLSession.shared.download(from: release.dmgURL)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("screens-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmg = work.appendingPathComponent("Screens.dmg")
            try FileManager.default.moveItem(at: downloaded, to: dmg)
            let mount = work.appendingPathComponent("mount")
            try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path])
            defer { try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
            guard let app = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            else { throw UpdateError.noApp }
            let staged = work.appendingPathComponent(app.lastPathComponent)
            try Self.run("/usr/bin/ditto", [app.path, staged.path])
            try Self.verifySignature(staged)
            try relaunch(replacingWith: staged)
        } catch {
            status = "Update failed: \(error.localizedDescription)"
            let alert = NSAlert()
            alert.messageText = "Update failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    enum UpdateError: LocalizedError {
        case noApp, badSignature(String), command(String)
        var errorDescription: String? {
            switch self {
            case .noApp: "The downloaded DMG doesn't contain an app."
            case .badSignature(let why): "The download isn't signed by Hope Church's Developer ID, so it wasn't installed. \(why)"
            case .command(let detail): detail
            }
        }
    }

    /// Valid signature from Apple's Developer ID chain with our team ID.
    static func verifySignature(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.badSignature("Unreadable signature.")
        }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            throw UpdateError.badSignature("Bad requirement.")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), requirement)
        guard status == errSecSuccess else { throw UpdateError.badSignature("Code \(status).") }
    }

    /// A tiny helper script waits for this process to quit, swaps the app
    /// bundle in place and opens the new one.
    private func relaunch(replacingWith staged: URL) throws {
        let current = Bundle.main.bundleURL
        let script = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
        rm -rf "\(current.path).old"
        mv "\(current.path)" "\(current.path).old" && /usr/bin/ditto "\(staged.path)" "\(current.path)" && rm -rf "\(current.path).old" || mv "\(current.path).old" "\(current.path)"
        /usr/bin/open "\(current.path)"
        """
        let file = staged.deletingLastPathComponent().appendingPathComponent("swap.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [file.path]
        try process.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw UpdateError.command("\(tool) failed: \(output.prefix(300))") }
        return output
    }
}
