import XCTest
import Darwin
@testable import NDIKit

final class NDIRuntimeConfigTests: XCTestCase {
    func testPinnedConfigListsTheAdapter() {
        let json = String(
            decoding: NDIRuntimeConfig.configJSON(allowedAdapterIPs: ["10.1.20.7"]),
            as: UTF8.self)
        XCTAssertEqual(json, #"{"ndi":{"adapters":{"allowed":["10.1.20.7"]}}}"#)
    }

    func testAutomaticConfigRestrictsNothing() {
        let json = String(
            decoding: NDIRuntimeConfig.configJSON(allowedAdapterIPs: []),
            as: UTF8.self)
        XCTAssertEqual(json, #"{"ndi":{}}"#)
    }

    func testActivateWritesTheFileAndPointsTheProcessAtIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ndi-config-test-\(ProcessInfo.processInfo.processIdentifier)")
        defer {
            try? FileManager.default.removeItem(at: dir)

            unsetenv("NDI_CONFIG_DIR")
        }
        try NDIRuntimeConfig.activate(directory: dir, allowedAdapterIPs: ["192.168.4.9"])
        XCTAssertEqual(String(cString: getenv("NDI_CONFIG_DIR")), dir.path)
        let written = try Data(contentsOf: dir.appendingPathComponent(NDIRuntimeConfig.fileName))
        XCTAssertEqual(written, NDIRuntimeConfig.configJSON(allowedAdapterIPs: ["192.168.4.9"]))
    }

    func testAdoptReplacesAnExistingConfigDirectory() {
        let old = "/tmp/ndi-config-old"
        let new = URL(fileURLWithPath: "/tmp/ndi-config-new", isDirectory: true)
        setenv("NDI_CONFIG_DIR", old, 1)
        defer { unsetenv("NDI_CONFIG_DIR") }

        NDIRuntimeConfig.adopt(directory: new)

        XCTAssertEqual(String(cString: getenv("NDI_CONFIG_DIR")), new.path)
    }

    func testAdapterListIsLoopbackFreeAndAddressed() throws {
        // Establish the machine's available interfaces independently, so an
        // empty production result cannot silently satisfy the assertions.
        var head: UnsafeMutablePointer<ifaddrs>?
        XCTAssertEqual(getifaddrs(&head), 0)
        let first = try XCTUnwrap(head)
        defer { freeifaddrs(head) }
        var expected: Set<String> = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP | IFF_LOOPBACK) == UInt32(IFF_UP)
            else { continue }
            expected.insert(String(cString: interface.ifa_name))
        }
        try XCTSkipIf(expected.isEmpty, "machine has no active non-loopback IPv4 interface")
        let adapters = NDIAdapterList.current()
        XCTAssertEqual(Set(adapters.map(\.bsdName)), expected)
        for adapter in adapters {
            XCTAssertFalse(adapter.bsdName.hasPrefix("lo"))
            var address = in_addr()
            XCTAssertEqual(inet_pton(AF_INET, adapter.ipv4, &address), 1)
            XCTAssertFalse(adapter.displayName.isEmpty)
        }
    }
}
