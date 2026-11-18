import FlyingFox
import Foundation
import JavaScriptCore
import Testing

@testable import LocalAPI

@Suite(.timeLimit(.minutes(1)))
struct RemotePageTests {
    @Test func pageCarriesKeyEndpointsAndIsWellFormed() {
        let page = RemotePage.html(serviceName: "Sunday <AM>")
        for needle in [
            "/v1/status", "/v1/show/advance", "/v1/show/slide", "/v1/show/clear",
            "/v1/show/clear-all", "/v1/timers", "/v1/library/action-combos",
            "/v1/action-combos/", "/v1/documents/presentations/", "/v1/ws?token=",
        ] {
            #expect(page.contains(needle), "missing \(needle)")
        }
        #expect(page.contains("name=\"viewport\""))
        #expect(page.contains("replaceState"))
        #expect(page.components(separatedBy: "<script").count == page.components(separatedBy: "</script>").count)
        #expect(page.contains("Sunday &lt;AM&gt;"))
        #expect(!page.contains("__SERVICE_NAME__"))
    }

    /// A phone that can't reach the Mac is pointed at the remote that works
    /// from anywhere; with none given, the page still parses.
    @Test func aLostPhoneIsOfferedTheAnywhereRemote() throws {
        let page = RemotePage.html(serviceName: "Sunday", anywhereURL: "https://dashboard.hopejc.org/screens/remote")
        #expect(page.contains("var ANYWHERE=\"https:\\/\\/dashboard.hopejc.org\\/screens\\/remote\"") || page.contains("var ANYWHERE=\"https://dashboard.hopejc.org/screens/remote\""))
        #expect(page.contains("id=\"lost\""))
        #expect(!page.contains("__ANYWHERE_URL__"))
        let bare = RemotePage.html(serviceName: "Sunday")
        #expect(bare.contains("var ANYWHERE=\"\""))
        for html in [page, bare] {
            let start = try #require(html.range(of: "<script>"))
            let end = try #require(html.range(of: "</script>", range: start.upperBound..<html.endIndex))
            let script = String(html[start.upperBound..<end.lowerBound])
            let context = try #require(JSContext())
            var error: String?
            context.exceptionHandler = { _, value in error = value?.toString() }
            // Parse only: wrapping in a function that's never called.
            context.evaluateScript("(function(){" + script + "})")
            #expect(error == nil, "\(error ?? "")")
        }
    }

    /// A code the Mac turned down leaves the address and storage both, and
    /// is passed over when the address still has it (a home-screen app opens
    /// at the address it was added with). Connect writes the new code to both.
    @Test func aRejectedCodeLeavesTheAddressAndStaysOut() throws {
        let page = RemotePage.html(serviceName: "Sunday")
        for needle in [
            "REJECTED=\"remoteRejected\"", "if(sent===token){refuse(sent);",
            "(t?\"#t=\"+encodeURIComponent(t):\"\")", "no.indexOf(t)<0", "setCode(v)",
        ] {
            #expect(page.contains(needle), "missing \(needle)")
        }
        #expect(!page.contains("store(KEY,t);q.delete"), "the old init kept the fragment's code over a rejection")
        let start = try #require(page.range(of: "<script>\n"))
        let end = try #require(page.range(of: "</script>", range: start.upperBound..<page.endIndex))
        let script = String(page[start.upperBound..<end.lowerBound])
        let context = try #require(JSContext())
        context.setObject(script, forKeyedSubscript: "source" as NSString)
        context.evaluateScript("new Function(source)")
        #expect(context.exception == nil, "the remote's script doesn't parse: \(String(describing: context.exception))")
    }

    /// The Stage tab counts a timed message down on the phone's own clock
    /// from the seconds left the Mac sent, and shows Nothing once it is up.
    @Test func theStageTabCountsDownATimedMessage() {
        let page = RemotePage.html(serviceName: "Sunday")
        for needle in [
            "al.secondsLeft", "Date.now()+al.secondsLeft*1000", "clears in ", "if(stageEnds)stageNow();",
        ] {
            #expect(page.contains(needle), "missing \(needle)")
        }
    }

    @Test func rootAndRemoteRoutesServeThePageWithoutAuth() async throws {
        let tokens = APITokenStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-tokens-\(UUID().uuidString).json"))
        let port = UInt16.random(in: 20000...40000)
        let server = LocalAPIServer(
            configuration: .init(port: port, serviceName: "Test", advertise: false,
                                 info: APIServerInfo(name: "Test", product: "Test", apiVersion: "1", schemaVersion: 1)),
            routes: [], tokens: tokens)
        let task = Task { try await server.run() }
        defer { task.cancel() }
        try await server.waitUntilListening()
        for path in ["/", "/remote"] {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self).contains("/v1/show/advance"))
        }
        await server.stop()
    }
}
