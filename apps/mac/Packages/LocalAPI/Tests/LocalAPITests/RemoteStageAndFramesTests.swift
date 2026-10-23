import FlyingFox
import Foundation
import ImageIO
import Testing

@testable import LocalAPI

/// The phone remote's slide pictures, its notes to the booth, and what lets
/// a phone keep it on the home screen.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RemoteStageAndFramesTests {
    private func router() -> (APIRouter, FakeBridge) {
        let bridge = FakeBridge()
        return (APIRouter(routes: APIRouteTable.build(bridge: bridge)), bridge)
    }

    private func call(
        _ router: APIRouter, _ method: String, _ path: String, body: String? = nil, scope: APIScope = .control
    ) async throws -> APIHandlerResponse {
        let match = try #require(router.match(method: method, path: path))
        let context = APIRequestContext(
            pathParameters: match.parameters, body: Data((body ?? "").utf8), scope: scope)
        return try await match.route.handler(context)
    }

    @Test func boothNoteIsTrimmedForwardedAndListed() async throws {
        let (router, bridge) = router()
        let response = try await call(router, "POST", "/v1/booth/messages",
                                      body: #"{"text":"  Mic issue \n","from":"  Stage "}"#)
        #expect(response.status == 201)
        #expect(response.isJSON)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sent = try decoder.decode(APIBoothMessage.self, from: response.body)
        #expect(sent.text == "Mic issue")
        #expect(sent.from == "Stage")
        #expect(bridge.calls == ["booth:Mic issue"])

        let listed = try await call(router, "GET", "/v1/booth/messages", scope: .view)
        #expect(try decoder.decode([APIBoothMessage].self, from: listed.body) == [sent])
    }

    @Test(arguments: [#"{"text":"   "}"#, #"{}"#, "{\"text\":\"\(String(repeating: "a", count: 201))\"}"])
    func boothNoteMustSaySomethingShort(body: String) async throws {
        let (router, bridge) = router()
        await #expect(throws: APIError.self) {
            _ = try await call(router, "POST", "/v1/booth/messages", body: body)
        }
        #expect(bridge.calls.isEmpty)
    }

    @Test func boothNoteSenderIsCappedAndBlankDropped() throws {
        let long = try APIBoothMessageCommand(text: "Ready", from: String(repeating: "x", count: 90)).validated()
        #expect(long.from?.count == APIBoothMessageCommand.maxFromLength)
        #expect(try APIBoothMessageCommand(text: "Ready", from: "  ").validated().from == nil)
    }

    @Test func framesComeBackAsJPEGs() async throws {
        let (router, bridge) = router()
        for which in APIShowFrame.allCases {
            let response = try await call(router, "GET", "/v1/show/frames/\(which.rawValue)", scope: .view)
            #expect(response.contentType == "image/jpeg")
            #expect(!response.isJSON)
            #expect(response.body == FakeBridge.frameBytes)
        }
        #expect(bridge.calls == ["frame:live", "frame:next"])

        bridge.hasNextSlide = false
        await #expect(throws: APIError.self) {
            _ = try await call(router, "GET", "/v1/show/frames/next", scope: .view)
        }
        do {
            _ = try await call(router, "GET", "/v1/show/frames/later", scope: .view)
            Issue.record("an unknown frame should be refused")
        } catch let error as APIError {
            #expect(error.status == 400)
        }
    }

    @Test func scopesKeepWatchKeysReadOnly() {
        let (router, _) = router()
        #expect(router.match(method: "GET", path: "/v1/show/frames/live")?.route.scope == .view)
        #expect(router.match(method: "GET", path: "/v1/booth/messages")?.route.scope == .view)
        #expect(router.match(method: "POST", path: "/v1/booth/messages")?.route.scope == .control)
    }

    @Test func contractDescribesThePictureAsAJPEG() throws {
        let (router, _) = router()
        let document = OpenAPIDocument.compose(routes: router.routes, schemaVersion: 1)
        guard case .object(let root) = document,
              case .object(let paths)? = root["paths"],
              case .object(let item)? = paths["/v1/show/frames/{which}"],
              case .object(let get)? = item["get"],
              case .object(let responses)? = get["responses"],
              case .object(let ok)? = responses["200"],
              case .object(let content)? = ok["content"]
        else {
            Issue.record("frames route missing from the contract")
            return
        }
        #expect(content["image/jpeg"] != nil)
        #expect(content["application/json"] == nil)
    }

    @Test func socketCommandsNeverCarryPictures() async throws {
        let tokens = APITokenStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-frames-\(UUID().uuidString).json"))
        let token = tokens.create(name: "Remote", scope: .control).token
        let (router, _) = router()
        let handler = APIWebSocketHandler(router: router, events: APIEventBus(), token: token, tokens: tokens)
        let (input, continuation) = AsyncStream<WSMessage>.makeStream()
        defer { continuation.finish() }
        var output = try await handler.makeMessages(for: input).makeAsyncIterator()
        #expect(await output.next() != nil)
        continuation.yield(.text(#"{"type":"command","id":"1","method":"GET","path":"/v1/show/frames/live"}"#))
        guard case .text(let frame) = await output.next() else {
            Issue.record("expected a result frame")
            return
        }
        let result = try #require(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        #expect(result["status"] as? Int == 400)
        #expect((result["data"] as? [String: Any])?["code"] as? String == "http_only")
    }

    @Test func pageOffersBothViewsAndHomeScreenInstall() {
        let page = RemotePage.html(serviceName: "Sunday")
        for needle in [
            "/v1/show/frames/", "/v1/booth/messages", "screens.timer.sermon",
            "rel=\"manifest\" href=\"\(RemotePage.manifestPath)\"", "rel=\"apple-touch-icon\" href=\"/apple-touch-icon.png\"",
            "apple-mobile-web-app-capable", "data-role=\"booth\"", "data-role=\"stage\"",
            "data-say=\"Need help\"", "data-say=\"Mic issue\"", "data-say=\"Ready\"",
            "#t=", "Authorization",
        ] {
            #expect(page.contains(needle), "missing \(needle)")
        }
        // Pictures go over fetch with the header, never with the code in an <img> address.
        #expect(!page.contains("frames/live?token"))
    }

    @Test func manifestIsJSONForAStandaloneApp() throws {
        let text = RemotePage.manifest(serviceName: "Hope \"Main\"")
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(manifest["display"] as? String == "standalone")
        #expect(manifest["name"] as? String == "Hope \"Main\" Remote")
        #expect(manifest["start_url"] == nil, "the remote opens where it was added, code and all")
        let icons = try #require(manifest["icons"] as? [[String: Any]])
        let sources = Set(icons.compactMap { $0["src"] as? String })
        #expect(sources.isSubset(of: Set(RemoteIcon.paths.map(\.path))))
    }

    @Test func iconsAreSquarePNGsOfTheirSize() throws {
        for (_, size) in RemoteIcon.paths {
            let png = try #require(RemoteIcon.png(size: size))
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == size && image.height == size)
        }
    }

    @Test func serverHandsOutInstallFilesFreelyAndPicturesOnlyWithACode() async throws {
        let tokens = APITokenStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-frames-\(UUID().uuidString).json"))
        let secret = tokens.create(name: "Phone", scope: .control).secret
        let port = UInt16.random(in: 20000...40000)
        let server = LocalAPIServer(
            configuration: .init(port: port, serviceName: "Test", advertise: false,
                                 info: APIServerInfo(name: "Test", product: "Test", apiVersion: "1", schemaVersion: 1)),
            routes: APIRouteTable.build(bridge: FakeBridge()), tokens: tokens)
        let task = Task { try await server.run() }
        defer { task.cancel() }
        try await server.waitUntilListening()
        let base = "http://127.0.0.1:\(port)"

        for (path, type) in [(RemotePage.manifestPath, "application/manifest+json"), ("/apple-touch-icon.png", "image/png")] {
            let (_, response) = try await URLSession.shared.data(from: URL(string: base + path)!)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200, "\(path)")
            #expect(http.value(forHTTPHeaderField: "Content-Type") == type)
        }

        let (_, refused) = try await URLSession.shared.data(from: URL(string: base + "/v1/show/frames/live")!)
        #expect((refused as? HTTPURLResponse)?.statusCode == 401)

        var request = URLRequest(url: URL(string: base + "/v1/show/frames/live")!)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(http.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(data == FakeBridge.frameBytes)
        await server.stop()
    }
}
