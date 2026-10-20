import Foundation
import PresenterCore

/// Feeds the scheduler each plan's service times (from Shepherd), so a rule
/// can say "5 minutes before each service" instead of a fixed clock time.
@MainActor
final class PlanTimeBridge {
    static let shared = PlanTimeBridge()

    struct PlanTimes: Sendable {
        var planID: String
        var starts: [Date]
    }

    nonisolated private static let cache = Box()

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var plans: [PlanTimes] = []
        func set(_ value: [PlanTimes]) { lock.lock(); plans = value; lock.unlock() }
        func get() -> [PlanTimes] { lock.lock(); defer { lock.unlock() }; return plans }
    }

    private weak var model: AppModel?
    private var timer: Timer?

    func start(_ model: AppModel) {
        self.model = model
        ScheduleMath.planTimeStart = { condition, after in
            let offset = condition.offsetSeconds ?? 0
            return PlanTimeBridge.cache.get()
                .filter { plan in condition.serviceId.map { $0.isEmpty || $0 == plan.planID } ?? true }
                .flatMap { plan -> [Date] in
                    guard let index = condition.serviceTimeIndex else { return plan.starts }
                    return plan.starts.indices.contains(index) ? [plan.starts[index]] : []
                }
                .map { $0.addingTimeInterval(offset) }
                .filter { $0 > after }
                .min()
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in PlanTimeBridge.shared.refresh() }
        }
    }

    func refresh() {
        guard let model else { return }
        let parser = ISO8601DateFormatter()
        Self.cache.set(model.resident.services.values.map { plan in
            PlanTimes(
                planID: plan.id,
                starts: (plan.mxuPlanTimes ?? [])
                    .filter { $0.isRehearsal != true }
                    .compactMap { $0.startsAt.flatMap(parser.date(from:)) }
                    .sorted())
        })
    }
}
