import CDeckLink
import CoreVideo
import Foundation

public enum DeckLinkKeying: Int32, Sendable, CaseIterable {
    case off = 0
    case internalKey = 1
    case externalKey = 2
}

public enum DeckLinkError: Error, Equatable {
    case openFailed(String)
}

/// See `dlk_output_copy_counts`.
public struct DeckLinkPaceCounts: Codable, Equatable, Sendable {
    public var fresh: UInt64 = 0
    public var stutters: UInt64 = 0
    public var dropped: UInt64 = 0

    public init() {}

    init(_ counts: DLKPaceCounts) {
        fresh = counts.fresh
        stutters = counts.stutters
        dropped = counts.dropped
    }

    /// The frame pacing the card would give `events` (see `dlk_pacer_run`):
    /// the frame number each card frame showed, and the counts.
    public static func simulate(_ events: String) -> (shown: [Int], counts: DeckLinkPaceCounts) {
        let capacity = events.count
        var shown = [Int32](repeating: 0, count: max(capacity, 1))
        var counts = DLKPaceCounts()
        let taken = events.withCString { dlk_pacer_run($0, &shown, Int32(capacity), &counts) }
        return (shown.prefix(Int(taken)).map(Int.init), DeckLinkPaceCounts(counts))
    }
}

public final class DeckLinkOutput: @unchecked Sendable {
    /// Nil once closed. Frames and the close take the lock, so a close
    /// waits out a frame being copied in and no frame reaches a closed port.
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public init(
        persistentID: Int64, modeID: UInt32, keying: DeckLinkKeying
    ) throws {
        var error = [CChar](repeating: 0, count: 256)
        guard let opened = dlk_output_open(
            persistentID, modeID,
            DLKKeying(rawValue: UInt32(keying.rawValue)),
            &error, error.count)
        else {
            throw DeckLinkError.openFailed(String(cString: error))
        }
        handle = opened
    }

    @discardableResult
    public func display(pixelBuffer: CVPixelBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return false
        }
        return dlk_output_display(
            handle,
            base.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBytesPerRow(pixelBuffer))
    }

    /// How this output's frames have gone out since it opened.
    public func paceCounts() -> DeckLinkPaceCounts {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return DeckLinkPaceCounts() }
        var counts = DLKPaceCounts()
        dlk_output_copy_counts(handle, &counts)
        return DeckLinkPaceCounts(counts)
    }

    /// Stops playback and gives the port back to the driver now, rather
    /// than whenever the last reference goes. Safe to call more than once.
    public func close() {
        lock.lock()
        let closing = handle
        handle = nil
        lock.unlock()
        if let closing { dlk_output_close(closing) }
    }

    deinit {
        close()
    }
}
