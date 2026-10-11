import FlyingFox
import Foundation
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
