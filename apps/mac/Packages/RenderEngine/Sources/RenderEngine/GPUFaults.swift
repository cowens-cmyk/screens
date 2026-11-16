import Foundation
import Metal

/// Every command buffer the app sends the GPU goes through here: it gets a
/// name, so a Metal System Trace or a frame capture says which work it was,
/// and a check when it finishes, so a fault on the GPU reaches Diagnostics
/// instead of showing only as a black or stale frame. With Metal's
/// validation on (`MTL_DEBUG_LAYER=1`, see scripts/perf/metal-validate.sh)
/// a fault also names the encoder it happened in.
public enum GPUFaults {
    /// Where a fault is written; the app points it at Diagnostics.
    public static let note = Locked<(@Sendable (String) -> Void)?>(nil)

    static let detailed = ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"] == "1"

    private static let reported = Locked(0)

    public static func makeCommandBuffer(on queue: MTLCommandQueue, label: String) -> MTLCommandBuffer? {
        let descriptor = MTLCommandBufferDescriptor()
        if detailed { descriptor.errorOptions = .encoderExecutionStatus }
        guard let buffer = queue.makeCommandBuffer(descriptor: descriptor) else { return nil }
        buffer.label = label
        buffer.addCompletedHandler { report($0) }
        return buffer
    }

    /// The first few faults, then one in a hundred: a fault that repeats
    /// every frame would otherwise fill the breadcrumbs.
    static func report(_ buffer: MTLCommandBuffer) {
        guard buffer.status == .error else { return }
        let count = reported.withLock { count -> Int in
            count += 1
            return count
        }
        guard count <= 5 || count % 100 == 0 else { return }
        note.value?(describe(buffer, count: count))
    }

    static func describe(_ buffer: MTLCommandBuffer, count: Int) -> String {
        let error = buffer.error as NSError?
        var detail = "\(buffer.label ?? "unnamed"): "
            + (error.map { "\($0.localizedDescription) (code \($0.code))" } ?? "failed")
        if let encoders = error?.userInfo[MTLCommandBufferEncoderInfoErrorKey] as? [MTLCommandBufferEncoderInfo] {
            let faulted = encoders.filter { $0.errorState == .faulted }.map(\.label)
            if !faulted.isEmpty { detail += " in " + faulted.joined(separator: ", ") }
        }
        return detail + " (fault \(count))"
    }
}
