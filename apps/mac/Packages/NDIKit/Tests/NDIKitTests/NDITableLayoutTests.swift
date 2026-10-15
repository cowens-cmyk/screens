import CNDI
import XCTest
@testable import NDIKit

final class NDITableLayoutTests: XCTestCase {
    private func loadedLibrary() throws -> NDILibrary {
        do {
            return try NDILibrary.load()
        } catch {
            throw XCTSkip("NDI runtime not installed: \(error)")
        }
    }

    func testEveryCalledSlotIsCheckedAgainstItsNamedExport() {
        // Synthetic addresses are never called. Unlike load(), this fixture does
        // not pre-validate the table with the function under test.
        var table = NDIlib_v5()
        var exports: [String: UnsafeRawPointer] = [:]
        let address0 = UnsafeRawPointer(bitPattern: 4096)!
        table.initialize = unsafeBitCast(address0, to: type(of: table.initialize))
        exports["NDIlib_initialize"] = address0
        let address1 = UnsafeRawPointer(bitPattern: 4352)!
        table.destroy = unsafeBitCast(address1, to: type(of: table.destroy))
        exports["NDIlib_destroy"] = address1
        let address2 = UnsafeRawPointer(bitPattern: 4608)!
        table.find_create_v2 = unsafeBitCast(address2, to: type(of: table.find_create_v2))
        exports["NDIlib_find_create_v2"] = address2
        let address3 = UnsafeRawPointer(bitPattern: 4864)!
        table.find_destroy = unsafeBitCast(address3, to: type(of: table.find_destroy))
        exports["NDIlib_find_destroy"] = address3
        let address4 = UnsafeRawPointer(bitPattern: 5120)!
        table.find_wait_for_sources = unsafeBitCast(address4, to: type(of: table.find_wait_for_sources))
        exports["NDIlib_find_wait_for_sources"] = address4
        let address5 = UnsafeRawPointer(bitPattern: 5376)!
        table.find_get_current_sources = unsafeBitCast(address5, to: type(of: table.find_get_current_sources))
        exports["NDIlib_find_get_current_sources"] = address5
        let address6 = UnsafeRawPointer(bitPattern: 5632)!
        table.recv_create_v3 = unsafeBitCast(address6, to: type(of: table.recv_create_v3))
        exports["NDIlib_recv_create_v3"] = address6
        let address7 = UnsafeRawPointer(bitPattern: 5888)!
        table.recv_destroy = unsafeBitCast(address7, to: type(of: table.recv_destroy))
        exports["NDIlib_recv_destroy"] = address7
        let address8 = UnsafeRawPointer(bitPattern: 6144)!
        table.recv_capture_v3 = unsafeBitCast(address8, to: type(of: table.recv_capture_v3))
        exports["NDIlib_recv_capture_v3"] = address8
        let address9 = UnsafeRawPointer(bitPattern: 6400)!
        table.recv_free_video_v2 = unsafeBitCast(address9, to: type(of: table.recv_free_video_v2))
        exports["NDIlib_recv_free_video_v2"] = address9
        let address10 = UnsafeRawPointer(bitPattern: 6656)!
        table.send_create = unsafeBitCast(address10, to: type(of: table.send_create))
        exports["NDIlib_send_create"] = address10
        let address11 = UnsafeRawPointer(bitPattern: 6912)!
        table.send_destroy = unsafeBitCast(address11, to: type(of: table.send_destroy))
        exports["NDIlib_send_destroy"] = address11
        let address12 = UnsafeRawPointer(bitPattern: 7168)!
        table.send_send_video_v2 = unsafeBitCast(address12, to: type(of: table.send_send_video_v2))
        exports["NDIlib_send_send_video_v2"] = address12
        XCTAssertEqual(NDILibrary.tableMismatches(table) { exports[$0] }, [])
        for name in exports.keys.sorted() {
            let mismatches = NDILibrary.tableMismatches(table) {
                $0 == name ? UnsafeRawPointer(bitPattern: 0xF000) : exports[$0]
            }
            XCTAssertEqual(mismatches, [name], "each slot must be checked independently")
        }
    }

    func testTheSlottingThatCrashedLaunchIsRefusedBeforeAnyCall() throws {
        let library = try loadedLibrary()

        var table = library.table
        table.find_create_v2 = unsafeBitCast(
            library.table.version, to: type(of: table.find_create_v2))
        table.find_wait_for_sources = unsafeBitCast(
            library.table.find_create_v2, to: type(of: table.find_wait_for_sources))

        let expected = ["NDIlib_find_create_v2", "NDIlib_find_wait_for_sources"]
        XCTAssertEqual(NDILibrary.tableMismatches(table, resolve: library.export), expected)
        guard case .failure(let error) = NDILibrary.activate(table: table, handle: library.handle)
        else { return XCTFail("a mis-slotted table must never activate") }
        XCTAssertEqual(error, .tableMismatch(expected))
    }

    func testAnEmptyTableNeverPassesForTheRuntime() {
        let elsewhere = UnsafeRawPointer(bitPattern: 0x1000)
        let mismatches = NDILibrary.tableMismatches(NDIlib_v5()) { _ in elsewhere }
        XCTAssertEqual(mismatches.count, 13)
        XCTAssertEqual(mismatches.first, "NDIlib_initialize")
        XCTAssertTrue(mismatches.contains("NDIlib_find_create_v2"))
    }
}
