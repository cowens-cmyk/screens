import Foundation
import Testing

@testable import PresenterCore

struct ImportArchiveValidationTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportArchiveValidationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func acceptsRegularFilesAndNestedDirectories() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("media/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data("b".utf8).write(to: nested.appendingPathComponent("image.png"))
        try ImportArchiveValidation.validateExtractedFiles(in: root)
    }

    @Test func acceptsEmptyFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try ImportArchiveValidation.validateExtractedFiles(in: root)
    }

    @Test func rejectsSymlinkToFileOutsideRoot() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let target = outside.appendingPathComponent("secret.txt")
        try Data("s".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: target)
        #expect {
            try ImportArchiveValidation.validateExtractedFiles(in: root)
        } throws: { error in
            guard case ImportArchiveValidation.ValidationError.unsafeEntry(let name) = error else { return false }
            return name == "link.txt"
        }
    }

    @Test func rejectsSymlinkToDirectoryNestedInSubfolder() throws {
        let root = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: sub.appendingPathComponent("dirlink"), withDestinationURL: outside)
        #expect(throws: ImportArchiveValidation.ValidationError.self) {
            try ImportArchiveValidation.validateExtractedFiles(in: root)
        }
    }

    @Test func rejectsDanglingSymlink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dangling"),
            withDestinationURL: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(throws: ImportArchiveValidation.ValidationError.self) {
            try ImportArchiveValidation.validateExtractedFiles(in: root)
        }
    }

    @Test func errorDescriptionsNameTheEntry() {
        let unsafe = ImportArchiveValidation.ValidationError.unsafeEntry("x.png")
        #expect(unsafe.errorDescription?.contains("x.png") == true)
        #expect(ImportArchiveValidation.ValidationError.unreadableArchive.errorDescription != nil)
    }
}
