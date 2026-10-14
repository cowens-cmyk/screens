import Foundation
import Testing

@Test func quittingClosesTheWelcomeSheetInsteadOfBeingBlockedByIt() throws {
    let view = try String(
        contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/OnboardingView.swift"), encoding: .utf8)
    #expect(view.contains(".interactiveDismissDisabled()\n        .background(QuitDismissesSheet())"))
    #expect(view.contains("window?.preventsApplicationTerminationWhenModal = false"))
}
