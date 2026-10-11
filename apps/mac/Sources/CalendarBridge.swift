import EventKit
import Foundation
import Observation
import PresenterCore

/// Feeds Calendar events to the scheduler: a trigger with a Calendar
/// condition fires when a matching event starts (plus an optional offset),
/// e.g. every "Sunday Service" event fires the countdown 10 minutes early.
@MainActor
@Observable
final class CalendarBridge {
    static let shared = CalendarBridge()

    struct CalendarChoice: Identifiable, Hashable {
        let id: String
        let title: String
    }

    private(set) var calendars: [CalendarChoice] = []
    private(set) var authorized = false
    private(set) var statusText: String?

    var onChange: (() -> Void)?

    private let store = EKEventStore()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    private struct Upcoming: Sendable {
        let calendarID: String
        let title: String
        let start: Date
    }

    nonisolated private static let cache = CacheBox()

    private final class CacheBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [Upcoming] = []
        func set(_ value: [Upcoming]) { lock.lock(); events = value; lock.unlock() }
        func get() -> [Upcoming] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private init() {}

    func start() {
        ScheduleMath.calendarEventStart = { condition, after in
            let offset = condition.offsetSeconds ?? 0
            let needle = condition.eventTitleContains?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return CalendarBridge.cache.get()
                .filter { event in
                    (condition.calendarId.map { $0.isEmpty || $0 == event.calendarID } ?? true)
                        && (needle.isEmpty || event.title.lowercased().contains(needle))
                }
                .map { $0.start.addingTimeInterval(offset) }
                .filter { $0 > after }
                .min()
        }
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if authorized { begin() }
    }

    func requestAccess() async {
        do {
            authorized = try await store.requestFullAccessToEvents()
            statusText = authorized ? nil : "Calendar access was declined — allow it in System Settings › Privacy & Security › Calendars."
            if authorized { begin() }
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func begin() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { _ in Task { @MainActor in CalendarBridge.shared.refresh() } }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            Task { @MainActor in CalendarBridge.shared.refresh() }
        }
    }

    func refresh() {
        guard authorized else { return }
        calendars = store.calendars(for: .event)
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-3600), end: now.addingTimeInterval(21 * 86_400), calendars: nil)
        let events = store.events(matching: predicate).compactMap { event -> Upcoming? in
            guard !event.isAllDay, let start = event.startDate else { return nil }
            return Upcoming(calendarID: event.calendar.calendarIdentifier, title: event.title ?? "", start: start)
        }
        Self.cache.set(events)
        onChange?()
    }
}
