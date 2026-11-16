import Metal
@testable import RenderEngine
import XCTest

final class GPUFaultsTests: XCTestCase {
    func testCommandBuffersAreNamedAndACleanOneReportsNothing() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let notes = Locked<[String]>([])
        GPUFaults.note.value = { note in notes.withLock { $0.append(note) } }
        defer { GPUFaults.note.value = nil }
        let buffer = try XCTUnwrap(GPUFaults.makeCommandBuffer(on: queue, label: "test.clean"))
        XCTAssertEqual(buffer.label, "test.clean")
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertEqual(buffer.status, .completed)
        XCTAssertEqual(notes.value, [])
    }

    func testAFaultNamesItsCommandBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        buffer.label = "compositor.render.texture"
        XCTAssertEqual(
            GPUFaults.describe(buffer, count: 3), "compositor.render.texture: failed (fault 3)")
    }
}
