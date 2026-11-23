import Foundation
import Testing
@testable import PresenterCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func file(_ name: String, daysAgo: Double, bytes: Int = 10) -> DiagnosticsBundle.Candidate {
    DiagnosticsBundle.Candidate(
        url: URL(fileURLWithPath: "/tmp/\(name)"), modified: now.addingTimeInterval(-daysAgo * 86_400), byteSize: bytes)
}

@Test func diagnosticsSelectionIsTheLastWeekNewestFirstUnderTheCap() {
    let files = [
        file("old.log", daysAgo: 9), file("b.log", daysAgo: 2, bytes: 40),
        file("huge-hang.txt", daysAgo: 1, bytes: 90), file("a.log", daysAgo: 0.5, bytes: 50),
    ]
    let chosen = DiagnosticsBundle.selection(from: files, now: now, byteCap: 100)
    #expect(chosen.map(\.url.lastPathComponent) == ["a.log", "b.log"], "the file that would pass the cap is skipped, smaller ones still fit")
}

@Test func diagnosticsPruneTakesOnlyWhatIsPastRetention() {
    let files = [file("keep.log", daysAgo: 13), file("drop.log", daysAgo: 15)]
    #expect(DiagnosticsBundle.expired(from: files, now: now).map(\.url.lastPathComponent) == ["drop.log"])
}

@Test func crashReportsAreThisAppsAndNewerThanTheLastLaunch() {
    #expect(DiagnosticsBundle.isCrashReport(fileName: "Screens-2026-10-07-101500.ips"))
    #expect(DiagnosticsBundle.isCrashReport(fileName: "Screens_2026-10-07.hang"))
    #expect(DiagnosticsBundle.isCrashReport(fileName: "Screens-2026-09-17-101500.ips"), "named before the rename")
    #expect(!DiagnosticsBundle.isCrashReport(fileName: "Safari-2026-09-17.ips"))
    #expect(!DiagnosticsBundle.isCrashReport(fileName: "Screens notes.txt"))

    let files = [
        file("Screens-new.ips", daysAgo: 0.1), file("Screens-old.ips", daysAgo: 3),
        file("Safari-new.ips", daysAgo: 0.1),
    ]
    let lastLaunch = now.addingTimeInterval(-86_400)
    #expect(DiagnosticsBundle.crashReports(in: files, since: lastLaunch).map(\.url.lastPathComponent) == ["Screens-new.ips"])
    #expect(DiagnosticsBundle.crashReports(in: files, since: nil).isEmpty, "a first launch has no previous run to blame")
}

@Test func candidatesListsRegularFilesAndToleratesAMissingFolder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(DiagnosticsBundle.candidates(in: folder).isEmpty)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("hello".utf8).write(to: folder.appendingPathComponent("breadcrumbs.log"))
    let found = DiagnosticsBundle.candidates(in: folder)
    #expect(found.map(\.url.lastPathComponent) == ["breadcrumbs.log"] && found.first?.byteSize == 5)
}


@Test func anotherAppsCrashIsNotThisRunsCrash() {
    let lastLaunch = Date(timeIntervalSince1970: 1_000)
    let file = { (name: String) in
        DiagnosticsBundle.Candidate(url: URL(fileURLWithPath: "/tmp/\(name)"), modified: Date(timeIntervalSince1970: 2_000), byteSize: 10)
    }
    let files = [file("Screens-perf.ips"), file("Screens-real.ips"), file("Screens-old-format.crash")]
    let ids = ["Screens-perf.ips": "com.example.mxuslides.perf", "Screens-real.ips": "com.example.mxuslides"]
    let found = DiagnosticsBundle.crashReports(
        in: files, since: lastLaunch, bundleID: "com.example.mxuslides",
        reportBundleID: { ids[$0.lastPathComponent] })
    #expect(found.map(\.url.lastPathComponent) == ["Screens-real.ips", "Screens-old-format.crash"])
}

@Test func aReportsBundleIDComesFromItsHeader() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Screens-\(UUID().uuidString).ips")
    let text = #"{"app_name":"Screens","bundleID":"com.example.mxuslides.perf","name":"Screens"}"# + "\n" + #"{"pid":1}"#
    try Data(text.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(DiagnosticsBundle.reportBundleID(url) == "com.example.mxuslides.perf")
}
