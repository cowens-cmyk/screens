import Foundation
import Testing

/// Guards on the app's MCP server and library start-up that live in the app
/// target, where a unit test can't reach.
@Suite struct MCPSafetySweepTests {
    /// The tools trust their schema's bounds (a negative limit stops the
    /// app), and some refusals live only in the confirmation step, so MCP
    /// calls go through both, as the in-app Assistant's do.
    @Test func mcpCallsAreValidatedAndAlwaysRunTheConfirmation() throws {
        let file = try #require(try SourceSweep.app().file("ScreensMCP.swift"))
        let start = try #require(file.text.range(of: "private func runAssistant("))
        let body = String(file.text[start.upperBound...].prefix(2500))
        #expect(body.contains("AssistantToolInput.validate(input, against: spec.schema)"))
        let confirm = try #require(body.range(of: "toolbox.confirmation(for: name"))
        #expect(!body[..<confirm.lowerBound].contains("if !confirmed {"),
                "the confirmation must run even with confirm true")
    }

    /// Nothing moves the library to the Trash when the app opens.
    @Test func openingTheAppNeverTrashesTheLibrary() throws {
        let file = try #require(try SourceSweep.app().file("AppModel.swift"))
        #expect(!file.codeLines.contains { $0.contains("trashItem(at: root") })
    }

    /// The plan item is added at its place in one write; moving the plan's
    /// last item afterwards moved the closing item when nothing was added.
    @Test func theAPIAddsAPlanItemWhereItGoesInOneWrite() throws {
        let file = try #require(try SourceSweep.app().file("LocalAPIBridgeAdapter.swift"))
        let start = try #require(file.text.range(of: "func addServiceItem(serviceId:"))
        let body = String(file.text[start.upperBound...].prefix(900))
        #expect(!body.contains("removeLast()"))
        #expect(body.contains("APIError.badRequest"))
    }

    /// Unlinked in the CMS: the media transfer holding the dead key goes.
    @Test func unlinkedInTheCMSDropsTheMediaTransfer() throws {
        let file = try #require(try SourceSweep.app().file("CloudSync.swift"))
        let start = try #require(file.text.range(of: "closeCode.rawValue == 4401"))
        let branch = String(file.text[start.upperBound...].prefix(700))
        #expect(branch.contains("transfer = nil"))
    }
}
