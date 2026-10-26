import Foundation
import PresenterCore

/// Sets the Sermon timer back as each service starts, so it's ready for the
/// message without anyone touching it. The day's service times come from
/// the plan (Shepherd), else Schedule Service, else the Service Day setup
/// (SermonTimerReset.services); the moment is the service's countdown
/// starting, or the service time when it has none.
///
/// The countdown playing sets it back by itself (ServiceControls), so this
/// watches the clock for the services that have no countdown, and for a
/// scheduled countdown that didn't play. Like the countdowns and pre-service
/// restarts, it acts only on the Mac that runs the service.
@MainActor
final class SermonTimerAutoReset {
    static let shared = SermonTimerAutoReset()
    static let enabledKey = "sermonTimer.resetsAtServiceStart"

    /// How often the clock is checked; a start is acted on within this.
    private static let tickSeconds: TimeInterval = 5
    /// The day's services are worked out again this often, so a plan
    /// synced from Shepherd or a service scheduled since counts.
    private static let refreshSeconds: TimeInterval = 60

    private weak var model: AppModel?
    private weak var controls: ServiceControls?
    private var timer: Timer?
    private var lastCheck = Date()
    private var services: [SermonTimerReset.Service] = []
    private var servicesWorkedOut: Date?

    /// Every plan's times are read when the current plan has none today, so
    /// each stamp is parsed once rather than on every pass over the library.
    private var parsedTimes: [String: Date?] = [:]
    private let parser = ISO8601DateFormatter()

    private func parsedTime(_ stamp: String) -> Date? {
        if let known = parsedTimes[stamp] { return known }
        if parsedTimes.count > 5_000 { parsedTimes.removeAll() }
        let date = parser.date(from: stamp)
        parsedTimes[stamp] = date
        return date
    }

    func start(model: AppModel, controls: ServiceControls) {
        guard timer == nil else { return }
        self.model = model
        self.controls = controls
        lastCheck = Date()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) { _ in
            Task { @MainActor in SermonTimerAutoReset.shared.tick() }
        }
    }

    private func tick() {
        guard let model, let controls else { return }
        let now = Date()
        let calendar = Calendar.current
        if servicesWorkedOut.map({ now.timeIntervalSince($0) >= Self.refreshSeconds || !calendar.isDate($0, inSameDayAs: now) }) ?? true {
            services = todaysServices(model: model, now: now, calendar: calendar)
            servicesWorkedOut = now
        }
        defer { lastCheck = now }

        let on = controls.sermonTimerResetsAtServiceStart && ServiceStation.runsService
        let next = on ? SermonTimerReset.next(services, after: now)?.resetAt : nil
        if controls.nextSermonTimerReset != next { controls.nextSermonTimerReset = next }
        guard on, let due = SermonTimerReset.due(services, after: lastCheck, now: now) else { return }
        let time = due.time.formatted(date: .omitted, time: .shortened)
        controls.sermonTimerAtServiceStart(
            due.countdownStart == nil ? "\(time) service" : "\(time) service countdown")
    }

    /// Today's services: the current plan's Shepherd times first (any
    /// plan's when it has none today), the countdowns Schedule Service set,
    /// and the Service Day setup.
    private func todaysServices(model: AppModel, now: Date, calendar: Calendar) -> [SermonTimerReset.Service] {
        func times(_ plan: Service) -> [Date] {
            guard plan.isTemplate != true else { return [] }
            return (plan.mxuPlanTimes ?? [])
                .filter { $0.isRehearsal != true }
                .compactMap { $0.startsAt.flatMap(parsedTime) }
                .filter { calendar.isDate($0, inSameDayAs: now) }
        }
        let current = model.currentServiceID.flatMap { model.resident.services.value($0) }
        var planTimes = current.map(times) ?? []
        if planTimes.isEmpty { planTimes = model.resident.services.values.flatMap(times) }

        // Spent countdowns are archived once they fire; they still say when
        // today's services are.
        let scheduled = model.residentScheduleTriggers.compactMap { trigger -> SermonTimerReset.ScheduledCountdown? in
            guard let notes = trigger.notes, notes.hasPrefix(ServiceCountdown.triggerNotePrefix),
                  let start = ServiceCountdown.startDate(of: trigger, calendar: calendar),
                  calendar.isDate(start, inSameDayAs: now)
            else { return nil }
            let planID = String(notes.dropFirst(ServiceCountdown.triggerNotePrefix.count))
            let video = model.resident.services.value(planID)
                .flatMap(ServiceCountdown.item(in:))
                .flatMap { $0.refId.isEmpty ? nil : model.media($0.refId)?.durationSeconds }
            return .init(start: start, serviceTime: ServiceCountdown.serviceTime(start: start, videoSeconds: video))
        }
        return SermonTimerReset.services(
            on: now, planTimes: planTimes, scheduled: scheduled,
            serviceDay: model.slideBuilding.serviceDay, calendar: calendar)
    }
}
