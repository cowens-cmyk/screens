import CryptoKit
import Foundation

/// A media file the church library refers to: its SHA-256 and the extension
/// it's stored with (the blob store names files `<hash>.<ext>`).
public struct CloudBlobRef: Hashable, Sendable {
    public var hash: String
    public var ext: String

    public init(hash: String, ext: String) {
        self.hash = hash.lowercased()
        self.ext = ext.lowercased()
    }

    public init?(hash: String, fileName: String) {
        guard Self.isHash(hash) else { return nil }
        self.init(hash: hash, ext: (fileName as NSString).pathExtension)
    }

    static func isHash(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isHexDigit }
    }
}

public enum CloudBlobPlan {
    /// What to fetch and what to send, given the files the library refers
    /// to, which of them are on this Mac, and which the hub is known to have.
    public static func plan(
        refs: Set<CloudBlobRef>, present: Set<String>, uploaded: Set<String>
    ) -> (download: [CloudBlobRef], upload: [CloudBlobRef]) {
        let sorted = refs.sorted { $0.hash < $1.hash }
        return (sorted.filter { !present.contains($0.hash) },
                sorted.filter { present.contains($0.hash) && !uploaded.contains($0.hash) })
    }
}

/// Moves media files between this Mac and the hub's storage
/// (docs/cloud-sync.md › Media files): uploads what the hub lacks, downloads
/// what this Mac lacks, two of each at a time. A file not on the hub yet is
/// tried again when the hub says it has arrived, or every few minutes.
public actor CloudBlobTransfer {
    public struct Progress: Sendable, Equatable {
        public var downloading = 0
        public var uploading = 0
        public var waitingForHub = 0

        public init(downloading: Int = 0, uploading: Int = 0, waitingForHub: Int = 0) {
            self.downloading = downloading
            self.uploading = uploading
            self.waitingForHub = waitingForHub
        }
    }

    /// Workers take request bodies up to about 100 MB; anything bigger goes
    /// up in parts.
    private let singleUploadLimit: Int
    private let partSize: Int

    private let base: URL
    private let token: String
    private let blobs: BlobStore
    private let http: URLSession
    private let uploaded: @Sendable (String) async -> Void
    private let landed: @Sendable (String) async -> Void
    private let progress: @Sendable (Progress) -> Void

    private var downloads: [CloudBlobRef] = []
    private var uploads: [CloudBlobRef] = []
    private var missing: [String: CloudBlobRef] = [:]
    private var active: Set<String> = []
    private var running = (down: 0, up: 0)
    private let lanes = 2

    public init(
        base: URL, token: String, blobs: BlobStore, http: URLSession = .shared,
        uploaded: @escaping @Sendable (String) async -> Void,
        landed: @escaping @Sendable (String) async -> Void,
        progress: @escaping @Sendable (Progress) -> Void = { _ in },
        singleUploadLimit: Int = 90 << 20, partSize: Int = 64 << 20
    ) {
        self.singleUploadLimit = singleUploadLimit
        self.partSize = partSize
        self.base = base
        self.token = token
        self.blobs = blobs
        self.http = http
        self.uploaded = uploaded
        self.landed = landed
        self.progress = progress
    }

    public func want(_ refs: [CloudBlobRef]) {
        for ref in refs where !active.contains(ref.hash) && !downloads.contains(ref) {
            missing[ref.hash] = nil
            downloads.append(ref)
        }
        pump()
    }

    public func offer(_ refs: [CloudBlobRef]) {
        for ref in refs where !active.contains(ref.hash) && !uploads.contains(ref) {
            uploads.append(ref)
        }
        pump()
    }

    /// The hub says a file arrived: fetch it now if this Mac was waiting.
    public func arrived(_ hash: String) {
        if let ref = missing.removeValue(forKey: hash) { want([ref]) }
    }

    /// Everything the hub didn't have last time, asked for again.
    public func retryMissing() {
        let refs = Array(missing.values)
        missing = [:]
        want(refs)
    }

    // MARK: Running

    private func pump() {
        while running.down < lanes, !downloads.isEmpty {
            let ref = downloads.removeFirst()
            guard active.insert(ref.hash).inserted else { continue }
            running.down += 1
            Task { await self.finishDownload(ref, ok: await self.download(ref)) }
        }
        while running.up < lanes, !uploads.isEmpty {
            let ref = uploads.removeFirst()
            guard active.insert(ref.hash).inserted else { continue }
            running.up += 1
            Task { await self.finishUpload(ref, ok: await self.upload(ref)) }
        }
        report()
    }

    private func finishDownload(_ ref: CloudBlobRef, ok: Bool?) async {
        running.down -= 1
        active.remove(ref.hash)
        switch ok {
        case true?: await landed(ref.hash)
        case false?: missing[ref.hash] = ref
        case nil: missing[ref.hash] = ref
        }
        pump()
    }

    private func finishUpload(_ ref: CloudBlobRef, ok: Bool) async {
        running.up -= 1
        active.remove(ref.hash)
        if ok { await uploaded(ref.hash) }
        pump()
    }

    private func report() {
        progress(Progress(downloading: running.down + downloads.count, uploading: running.up + uploads.count,
                          waitingForHub: missing.count))
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        // Built as text: the path may hold an already-encoded upload id that
        // appendingPathComponent would encode a second time.
        let root = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        var request = URLRequest(url: URL(string: root + "/api/screens/blobs/" + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        return request
    }

    // MARK: Down

    /// True when the file is here and its hash checks out; false when the hub
    /// doesn't have it (yet); nil on a failure worth trying again.
    private func download(_ ref: CloudBlobRef) async -> Bool? {
        if blobs.url(forHash: ref.hash) != nil { return true }
        do {
            let (temporary, response) = try await http.download(for: request(ref.hash))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                return status == 404 ? false : nil
            }
            // Named with its extension, so the store files it the same way
            // the Mac that imported it did.
            let named = temporary.deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString + (ref.ext.isEmpty ? "" : "." + ref.ext))
            try FileManager.default.moveItem(at: temporary, to: named)
            let hash = try blobs.adopt(fileURL: named)
            guard hash == ref.hash else {
                // Not what was asked for: never kept under a name it isn't.
                _ = try? blobs.remove(hash: hash)
                return nil
            }
            return true
        } catch {
            return nil
        }
    }

    // MARK: Up

    private func upload(_ ref: CloudBlobRef) async -> Bool {
        guard let file = blobs.url(forHash: ref.hash) else { return false }
        do {
            let (_, head) = try await http.data(for: request(ref.hash, method: "HEAD"))
            if (head as? HTTPURLResponse)?.statusCode == 200 { return true }
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            return size <= singleUploadLimit
                ? try await single(ref, file: file)
                : try await multipart(ref, file: file, size: size)
        } catch {
            return false
        }
    }

    private func single(_ ref: CloudBlobRef, file: URL) async throws -> Bool {
        var put = request(ref.hash, method: "PUT")
        put.setValue(ref.ext, forHTTPHeaderField: "X-Screens-Ext")
        put.timeoutInterval = 1800
        let (_, response) = try await http.upload(for: put, fromFile: file)
        return [200, 201].contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func multipart(_ ref: CloudBlobRef, file: URL, size: Int) async throws -> Bool {
        var start = request("\(ref.hash)/uploads", method: "POST")
        start.setValue(ref.ext, forHTTPHeaderField: "X-Screens-Ext")
        let (body, response) = try await http.data(for: start)
        let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard [200, 201].contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return false }
        // Another Mac sent it meanwhile.
        if answer?["existed"] as? Bool == true { return true }
        guard let raw = answer?["uploadId"] as? String,
              let uploadID = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return false }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var parts: [[String: Any]] = []
        var number = 1
        do {
            while let chunk = try handle.read(upToCount: partSize), !chunk.isEmpty {
                var put = request("\(ref.hash)/uploads/\(uploadID)/\(number)", method: "PUT")
                put.timeoutInterval = 1800
                let (answer, response) = try await http.upload(for: put, from: chunk)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let etag = (try? JSONSerialization.jsonObject(with: answer) as? [String: Any])?["etag"] as? String
                else { throw URLError(.badServerResponse) }
                parts.append(["partNumber": number, "etag": etag])
                number += 1
            }
            var complete = request("\(ref.hash)/uploads/\(uploadID)/complete", method: "POST")
            complete.setValue("application/json", forHTTPHeaderField: "Content-Type")
            complete.httpBody = try JSONSerialization.data(withJSONObject: ["parts": parts])
            let (_, done) = try await http.data(for: complete)
            return [200, 201].contains((done as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            _ = try? await http.data(for: request("\(ref.hash)/uploads/\(uploadID)", method: "DELETE"))
            throw error
        }
    }
}
