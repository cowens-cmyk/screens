import Foundation
import Testing

@testable import LocalAPI

@Suite(.timeLimit(.minutes(1)))
struct APIRouterPathExistsTests {
    private func router() -> APIRouter {
        func route(_ method: String, _ path: String) -> APIRoute {
            APIRoute(
                method, path, scope: .edit, operationId: "op\(method)\(path)",
                summary: "", tag: "test", responseSchema: .object([:]),
                handler: { _ in .ok })
        }
        return APIRouter(routes: [
            route("GET", "/v1/documents/{kind}/{id}"),
            route("POST", "/v1/show/advance"),
        ])
    }

    @Test func exactAndParameterizedPathsExist() {
        let router = router()
        #expect(router.pathExists("/v1/show/advance"))
        #expect(router.pathExists("/v1/documents/presentations/abc"))
    }

    @Test func pathWithFewerSegmentsThanTemplateDoesNotExist() {
        let router = router()
        #expect(!router.pathExists("/v1/documents/presentations"))
        #expect(!router.pathExists("/v1/documents"))
        #expect(!router.pathExists("/v1/show"))
        #expect(!router.pathExists("/"))
    }

    @Test func pathWithMoreSegmentsThanTemplateDoesNotExist() {
        let router = router()
        #expect(!router.pathExists("/v1/show/advance/extra"))
        #expect(!router.pathExists("/v1/documents/presentations/abc/def"))
    }
}
