import Foundation

/// Whether to show the first-run welcome: only for a library with no
/// presentations or services that hasn't been marked done.
extension Library {

    nonisolated public static func needsOnboarding(rootURL: URL, snapshot: IndexSnapshot) -> Bool {
        let marked = FileManager.default.fileExists(atPath: onboardedMarker(rootURL: rootURL).path)
        let untouched = snapshot.entries(of: .presentation).isEmpty && snapshot.entries(of: .service).isEmpty
        if !marked, !untouched {
            markOnboarded(rootURL: rootURL)
        }
        return !marked && untouched
    }

    nonisolated public static func markOnboarded(rootURL: URL) {
        FileManager.default.createFile(atPath: onboardedMarker(rootURL: rootURL).path, contents: nil)
    }

    nonisolated private static func onboardedMarker(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(".onboarded-v1")
    }
}
