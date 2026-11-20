import Foundation
import Testing

@testable import LocalAPI

/// What Prism reads ahead of the service: each position's background in
/// the open plan, and that background's picture.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LightingBackgroundsTests {
    private func router() -> (APIRouter, FakeBridge) {
        let bridge = FakeBridge()
        return (APIRouter(routes: APIRouteTable.build(bridge: bridge)), bridge)
    }

    private func call(_ router: APIRouter, _ path: String) async throws -> APIHandlerResponse {
        let match = try #require(router.match(method: "GET", path: path))
        let context = APIRequestContext(pathParameters: match.parameters, body: Data(), scope: .view)
        return try await match.route.handler(context)
    }

    private func object(_ body: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func noPlanOpenIsNullsAndNoPositions() async throws {
        let (router, bridge) = router()
        let response = try await call(router, "/v1/lighting/backgrounds")
        #expect(response.isJSON)
        let json = try object(response.body)
        // Prism checks for null, so the keys are there with null in them.
        #expect(json["serviceId"] is NSNull)
        #expect(json["serviceName"] is NSNull)
        #expect((json["positions"] as? [Any])?.isEmpty == true)
        #expect(bridge.calls == ["lightingBackgrounds"])
    }

    @Test func positionsComeBackInOrderWithNullForNoBackground() async throws {
        let (router, bridge) = router()
        bridge.lighting = APILightingBackgrounds(serviceId: "plan-1", serviceName: "Sunday", positions: [
            .init(position: "countdown", itemId: "i1", itemName: "Countdown", mediaId: "cd-video"),
            .init(position: "song1", itemId: "i2", itemName: "Way Maker", mediaId: "bg-1"),
            .init(position: "message", itemId: "i3", itemName: "Message", mediaId: nil),
        ])
        let response = try await call(router, "/v1/lighting/backgrounds")
        let json = try object(response.body)
        #expect(json["serviceId"] as? String == "plan-1")
        #expect(json["serviceName"] as? String == "Sunday")
        let positions = try #require(json["positions"] as? [[String: Any]])
        #expect(positions.map { $0["position"] as? String } == ["countdown", "song1", "message"])
        #expect(positions[1]["itemId"] as? String == "i2")
        #expect(positions[1]["itemName"] as? String == "Way Maker")
        #expect(positions[1]["mediaId"] as? String == "bg-1")
        #expect(positions[2]["mediaId"] is NSNull)
        #expect(try JSONDecoder().decode(APILightingBackgrounds.self, from: response.body) == bridge.lighting)
    }

    @Test func posterIsAJPEGAndUnknownMediaIs404() async throws {
        let (router, bridge) = router()
        let response = try await call(router, "/v1/media/bg-1/poster")
        #expect(response.contentType == "image/jpeg")
        #expect(!response.isJSON)
        #expect(response.body == FakeBridge.frameBytes)
        do {
            _ = try await call(router, "/v1/media/nope/poster")
            Issue.record("unknown media should be refused")
        } catch let error as APIError {
            #expect(error.status == 404)
        }
        #expect(bridge.calls == ["poster:bg-1", "poster:nope"])
    }

    @Test func watchKeysCanReadBoth() {
        let (router, _) = router()
        #expect(router.match(method: "GET", path: "/v1/lighting/backgrounds")?.route.scope == .view)
        #expect(router.match(method: "GET", path: "/v1/media/bg-1/poster")?.route.scope == .view)
        // Firing media still needs an Operate key.
        #expect(router.match(method: "POST", path: "/v1/media/bg-1/fire")?.route.scope == .control)
    }

    @Test func contractDescribesBoth() throws {
        let (router, _) = router()
        let document = OpenAPIDocument.compose(routes: router.routes, schemaVersion: 1)
        guard case .object(let root) = document,
              case .object(let paths)? = root["paths"],
              case .object(let lighting)? = paths["/v1/lighting/backgrounds"],
              case .object(let lightingGet)? = lighting["get"],
              case .object(let poster)? = paths["/v1/media/{id}/poster"],
              case .object(let posterGet)? = poster["get"],
              case .object(let responses)? = posterGet["responses"],
              case .object(let ok)? = responses["200"],
              case .object(let content)? = ok["content"],
              case .object(let components)? = root["components"],
              case .object(let schemas)? = components["schemas"]
        else {
            Issue.record("lighting routes missing from the contract")
            return
        }
        #expect(lightingGet["tags"] == .array([.string("Lighting")]))
        #expect(content["image/jpeg"] != nil)
        #expect(schemas["LightingBackgrounds"] != nil)
    }
}
