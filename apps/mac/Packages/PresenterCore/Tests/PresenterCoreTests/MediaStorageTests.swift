import Foundation
@testable import PresenterCore
import Testing

struct MediaStorageTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaStorageTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, in folder: URL, ext: String = "mov") throws -> URL {
        let scratch = folder.appendingPathComponent(UUID().uuidString + "." + ext)
        try Data(text.utf8).write(to: scratch)
        let hash = try BlobStore.sha256(of: scratch)
        let named = folder.appendingPathComponent(hash + "." + ext)
        try FileManager.default.moveItem(at: scratch, to: named)
        return named
    }

    @Test func thisMacKeepsTheFilesInTheLibrary() throws {
        let library = try temporaryFolder()
        let store = try BlobStore(libraryRoot: library, location: .thisMac)
        #expect(store.directory == library.appendingPathComponent("blobs", isDirectory: true))
        #expect(!store.isExternal && store.isAvailable)
    }

    @Test func aDriveFolderHoldsTheFiles() throws {
        let library = try temporaryFolder()
        let drive = try temporaryFolder()
        let store = try BlobStore(libraryRoot: library, location: .external(drive))
        #expect(store.directory == drive.appendingPathComponent("blobs", isDirectory: true))
        #expect(store.isExternal && store.isAvailable)
        let source = try temporaryFolder().appendingPathComponent("loop.mov")
        try Data("waves".utf8).write(to: source)
        let hash = try store.store(fileURL: source)
        #expect(store.url(forHash: hash)?.deletingLastPathComponent().standardizedFileURL
            == store.directory.standardizedFileURL)
    }

    @Test func anUnpluggedDriveIsNeverWrittenInItsPlace() throws {
        let library = try temporaryFolder()
        // A drive that isn't mounted: its folder doesn't exist.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Unplugged-" + UUID().uuidString, isDirectory: true)
        let store = try BlobStore(libraryRoot: library, location: .external(missing))
        #expect(!store.isAvailable)
        #expect(!FileManager.default.fileExists(atPath: missing.path), "no folder made in the drive's place")
        #expect(store.url(forHash: String(repeating: "a", count: 64)) == nil, "files show as missing")
        let source = try temporaryFolder().appendingPathComponent("loop.mov")
        try Data("waves".utf8).write(to: source)
        #expect(throws: MediaStorage.DriveNotConnected.self) { try store.store(fileURL: source) }
        #expect(throws: MediaStorage.DriveNotConnected.self) { try store.adopt(fileURL: source) }
        #expect(FileManager.default.fileExists(atPath: source.path), "a download isn't lost")
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func aMoveCopiesEveryFileAndChecksIt() throws {
        let source = try temporaryFolder()
        let destination = try temporaryFolder()
        let a = try write("first background", in: source)
        _ = try write("second background", in: source, ext: "jpg")
        let plan = MediaStorage.plan(from: source, to: destination)
        #expect(plan.files.count == 2 && plan.bytes == Int64("first background".utf8.count + "second background".utf8.count))
        for file in plan.files { try MediaStorage.copyVerified(file, into: destination) }
        #expect(MediaStorage.isCompleteCopy(from: source, to: destination))
        #expect(MediaStorage.plan(from: source, to: destination).files.isEmpty, "a second run copies nothing")
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(a.lastPathComponent).path))
        #expect(MediaStorage.totalBytes(in: destination) == plan.bytes)
    }

    @Test func aCopyThatDoesntMatchItsNameStopsTheMove() throws {
        let source = try temporaryFolder()
        let destination = try temporaryFolder()
        // Named as a hash it doesn't have: a damaged file.
        let damaged = source.appendingPathComponent(String(repeating: "b", count: 64) + ".mov")
        try Data("not what the name says".utf8).write(to: damaged)
        #expect(throws: MediaStorage.CopyMismatch.self) { try MediaStorage.copyVerified(damaged, into: destination) }
        #expect(MediaStorage.totalBytes(in: destination) == 0, "nothing half-copied is left")
        #expect(!MediaStorage.isCompleteCopy(from: source, to: destination))
    }

    @Test func theChoiceIsRemembered() throws {
        let defaults = try #require(UserDefaults(suiteName: "MediaStorageTests-" + UUID().uuidString))
        #expect(MediaStorage.location(defaults: defaults) == .thisMac)
        let drive = try temporaryFolder()
        MediaStorage.choose(drive, defaults: defaults)
        guard case .external(let folder) = MediaStorage.location(defaults: defaults) else {
            Issue.record("expected the drive")
            return
        }
        #expect(folder.standardizedFileURL.resolvingSymlinksInPath() == drive.standardizedFileURL.resolvingSymlinksInPath())
        MediaStorage.choose(nil, defaults: defaults)
        #expect(MediaStorage.location(defaults: defaults) == .thisMac)
    }
}
