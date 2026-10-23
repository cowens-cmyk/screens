import Foundation
import Testing

/// The in-app Assistant knows Screens from ScreensGuide.md, bundled with the
/// app and loaded into its system prompt. A missing or emptied guide would
/// leave it guessing, so the build's inputs are checked here.
@Suite struct AssistantGuideSweepTests {
    private var guideURL: URL {
        SourceSweep.macRoot().appendingPathComponent("Sources/Assistant/ScreensGuide.md")
    }

    @Test func theGuideExistsAndSaysSomething() throws {
        let text = try String(contentsOf: guideURL, encoding: .utf8)
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        #expect(words >= 1500, "ScreensGuide.md is too thin to guide the Assistant (\(words) words)")
        #expect(text.contains("When a feature changes, update this guide"), "keep the maintenance note at the top")
    }

    @Test func theAppBundlesAndLoadsTheGuide() throws {
        let project = try String(contentsOf: SourceSweep.macRoot().appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(project.contains("Sources/Assistant/ScreensGuide.md"), "project.yml must bundle the guide as a resource")
        #expect(project.contains("buildPhase: resources"))
        let sweep = try SourceSweep.app()
        let loader = try #require(sweep.file("AssistantPrompt.swift"))
        #expect(loader.text.contains("forResource: \"ScreensGuide\", withExtension: \"md\""))
    }
}
