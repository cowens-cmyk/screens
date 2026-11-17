import AppKit
import Foundation

/// The one folder Screens keeps its files in, Documents › Screens unless
/// another was chosen in Settings › General:
///
/// - **Plans**: a folder per upcoming plan, named like the plan, holding the
///   whole plan (.screensplan) and each presentation in it (.screenspres),
///   kept current by PlanFileSaver.
/// - **Exports**: where File › Export saves unless told otherwise.
/// - **Backups**: where library backups save unless told otherwise.
///
/// The library itself isn't here: it is the live, synced database, and
/// lives where the library setup put it.
enum ScreensFolder {
    static let rootKey = "screens.folder"

    static var root: URL {
        if let path = UserDefaults.standard.string(forKey: rootKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Screens", isDirectory: true)
    }

    static var plans: URL { made(root.appendingPathComponent("Plans", isDirectory: true)) }
    static var exports: URL { made(root.appendingPathComponent("Exports", isDirectory: true)) }
    static var backups: URL { made(root.appendingPathComponent("Backups", isDirectory: true)) }

    /// The folder, made if it isn't there yet.
    @discardableResult
    static func made(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([made(root)])
    }

    /// A name a file or folder can have: no slashes or colons.
    static func fileName(_ name: String) -> String {
        let cleaned = String(name.map { "/:\\".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
