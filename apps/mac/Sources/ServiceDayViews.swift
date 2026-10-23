import PresenterCore
import SwiftUI

/// The top of the Schedule tab: the service times, when the pre-service
/// slides start again before each, and the rest of the day at a glance
/// (with the countdowns Schedule Service set).
struct ServiceDayCard: View {
    let model: AppModel
    let scheduler: SchedulerController?

    @State private var editing = false

    private var settings: ServiceDaySettings? { model.slideBuilding.serviceDay }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "sunrise")
                    .font(.system(size: 11))
                    .foregroundStyle(HopeStyle.amber)
                Text(settings.map { Self.title(days: ServiceDay.days($0)) } ?? "Service Day")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(settings == nil ? "Set Up" : "Edit") { editing = true }
                    .controlSize(.small)
                    .help("Service times and the pre-service slides")
            }
            if let settings {
                details(settings)
            } else {
                Text("Start the pre-service slides again before each service, so whatever was left up is replaced.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(HopeStyle.amber.opacity(0.07), in: RoundedRectangle.standard(CornerStandard.element))
        .overlay(
            RoundedRectangle.standard(CornerStandard.element)
                .strokeBorder(HopeStyle.amber.opacity(0.25), lineWidth: 1))
        .sheet(isPresented: $editing) {
            ServiceDaySheet(model: model, scheduler: scheduler)
        }
    }

    @ViewBuilder
    private func details(_ settings: ServiceDaySettings) -> some View {
        let slideshowID = settings.preServicePresentationId ?? ""
        if slideshowID.isEmpty {
            Text("Choose the pre-service slides to restart them before each service.")
                .font(.system(size: 9))
                .foregroundStyle(Color.orange)
        } else {
            let folderOn = model.schedulerBoard.folder(id: ServiceDay.folderID)?.enabled ?? true
            HStack(spacing: 4) {
                Text(model.entry(slideshowID)?.name ?? "Missing slideshow")
                    .foregroundStyle(model.entry(slideshowID) == nil ? Color.orange : Color.secondary)
                    .lineLimit(1)
                if !folderOn || scheduler?.enabled != true {
                    Text(scheduler?.enabled != true ? "· Scheduler off" : "· Restarts off")
                        .foregroundStyle(Color.orange)
                }
            }
            .font(.system(size: 9))
        }
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let day = ServiceDay.upcomingDay(
                settings, countdownStarts: countdownStarts, after: context.date, calendar: .current) {
                Text(Self.dayLine(day, now: context.date))
                    .font(.system(size: 10).monospacedDigit())
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No service times.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        Text("A restart is skipped if a slide changed in the last 3 minutes, or a video, the countdown or the message is live.")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The countdowns Schedule Service set, still to run.
    private var countdownStarts: [Date] {
        model.residentScheduleTriggers
            .filter { $0.archived != true && $0.notes?.hasPrefix(ServiceCountdown.triggerNotePrefix) == true }
            .compactMap { ServiceCountdown.startDate(of: $0) }
    }

    static func title(days: [Int]) -> String {
        let names = days.map { Calendar.current.weekdaySymbols[$0 - 1] }
        let list = names.count <= 2
            ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return list + " Services"
    }

    /// "Today · Pre-service 7:30 · Countdown 7:54:50 · Service 8:00 · …",
    /// the day in bold.
    static func dayLine(_ day: (day: Date, events: [ServiceDay.Event]), now: Date) -> AttributedString {
        var line = AttributedString(dayLabel(day.day, now: now))
        line.font = .system(size: 10, weight: .semibold)
        line += AttributedString(" · " + day.events.map(label).joined(separator: " · "))
        return line
    }

    static func dayLabel(_ day: Date, now: Date) -> String {
        Calendar.current.isDate(day, inSameDayAs: now) ? "Today" : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func label(_ event: ServiceDay.Event) -> String {
        let name = switch event.kind {
        case .preService: "Pre-service"
        case .countdown: "Countdown"
        case .service: "Service"
        }
        return name + " " + clock(event.date)
    }

    /// "7:30", or "7:54:50" when the seconds matter.
    static func clock(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        let hour = (parts.hour ?? 0) % 12 == 0 ? 12 : (parts.hour ?? 0) % 12
        let base = String(format: "%d:%02d", hour, parts.minute ?? 0)
        return (parts.second ?? 0) == 0 ? base : base + String(format: ":%02d", parts.second ?? 0)
    }
}

/// Service Day setup: the days and times of the services, the pre-service
/// slideshow, and when it starts again before each. Saving rewrites the
/// restart triggers in the scheduler.
struct ServiceDaySheet: View {
    let model: AppModel
    let scheduler: SchedulerController?

    @Environment(\.dismiss) private var dismiss
    @State private var services: [ServiceDayTime] = []
    @State private var days: [Int] = ServiceDay.defaultDays
    @State private var slideshowID = ""
    @State private var clearFirst = true
    @State private var makeLoop = true
    @State private var search = ""
    @State private var loaded = false

    private var existing: ServiceDaySettings? { model.slideBuilding.serviceDay }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Service Day").font(.headline)
            Text("Before each service the pre-service slides start again from the first slide, replacing whatever was left up.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            dayPicker
            slideshowPicker
            if !slideshowID.isEmpty, let fix = loopFix {
                Toggle(isOn: $makeLoop) {
                    Text("Advance every \(Int(fix.delaySeconds)) seconds and loop")
                }
                .help("Sets this on the slideshow itself")
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach($services) { $service in
                    serviceRow($service)
                }
                Button("Add Service Time", systemImage: "plus") {
                    services.append(ServiceDay.nextService(after: services))
                }
                .buttonStyle(.borderless)
            }

            Toggle("Clear the screens first", isOn: $clearFirst)
                .help("Clears everything on the screens, and audio, before the slides start")

            HStack {
                if existing != nil {
                    Button("Remove", role: .destructive, action: remove)
                        .help("Stop restarting the pre-service slides and forget these times")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(slideshowID.isEmpty || services.isEmpty || days.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear(perform: load)
    }

    // MARK: Days

    private var dayPicker: some View {
        HStack(spacing: 4) {
            Text("Days").frame(width: 90, alignment: .leading)
            ForEach(1 ... 7, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.removeAll { $0 == day } } else { days = (days + [day]).sorted() }
                } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .frame(width: 24, height: 22)
                        .background(on ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.05), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(Calendar.current.weekdaySymbols[day - 1])
            }
        }
    }

    // MARK: The slideshow

    private var presentations: [LibraryIndex.Entry] {
        model.entries(of: .presentation).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var suggestions: [LibraryIndex.Entry] {
        presentations.filter { ServiceDay.looksLikePreService($0.name) }
    }

    private var slideshowPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Pre-service").frame(width: 90, alignment: .leading)
                Menu {
                    ForEach(suggestions, id: \.id) { entry in
                        Button(entry.name) { slideshowID = entry.id }
                    }
                    if suggestions.isEmpty {
                        Text("No presentation named Pre-Service")
                    }
                } label: {
                    Text(slideshowID.isEmpty ? "Choose Slides" : (model.entry(slideshowID)?.name ?? "Missing slideshow"))
                }
                .fixedSize()
            }
            HStack {
                Spacer().frame(width: 90)
                TextField("Find another presentation", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            let query = search.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                let hits = presentations.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(6)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(hits), id: \.id) { entry in
                        Button(entry.name) {
                            slideshowID = entry.id
                            search = ""
                        }
                        .buttonStyle(.link)
                    }
                    if hits.isEmpty {
                        Text("No match").foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 98)
            }
        }
    }

    /// The timing the slideshow needs to advance and loop by itself; nil
    /// when it already does (or isn't loaded yet).
    private var loopFix: AutoAdvance? {
        guard let presentation = model.presentation(slideshowID) else { return nil }
        return ServiceDay.loopingAdvance(presentation.autoAdvance)
    }

    // MARK: Service rows

    private func serviceRow(_ service: Binding<ServiceDayTime>) -> some View {
        let value = service.wrappedValue
        let serviceSeconds = ServiceDay.secondsOfDay(value.serviceTime) ?? 0
        let restartSeconds = ServiceDay.secondsOfDay(value.restartTime) ?? 0
        // Moving the service moves its restart with it, keeping the lead.
        let serviceTime = Binding<Date>(
            get: { ScheduleConditionFormat.timeOfDayDate(value.serviceTime) },
            set: { date in
                let lead = serviceSeconds - restartSeconds
                let time = ScheduleConditionFormat.timeOfDay(from: date)
                service.wrappedValue.serviceTime = time
                service.wrappedValue.restartTime = ServiceDay.timeString(
                    secondsOfDay: (ServiceDay.secondsOfDay(time) ?? 0) - lead)
            })
        let restartTime = Binding<Date>(
            get: { ScheduleConditionFormat.timeOfDayDate(value.restartTime) },
            set: { service.wrappedValue.restartTime = ScheduleConditionFormat.timeOfDay(from: $0) })
        let lead = serviceSeconds - restartSeconds
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    DatePicker("Service at", selection: serviceTime, displayedComponents: .hourAndMinute)
                    Spacer()
                    if services.count > 1 {
                        Button(role: .destructive) { services.removeAll { $0.id == value.id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this service time")
                    }
                }
                DatePicker("Restart pre-service at", selection: restartTime, displayedComponents: .hourAndMinute)
                Text(lead > 0 ? "\(lead / 60) min before the service." : "This is after the service starts.")
                    .font(.caption)
                    .foregroundStyle(lead > 0 ? Color.secondary : Color.orange)
            }
            .padding(4)
        }
    }

    // MARK: Load and save

    private func load() {
        guard !loaded else { return }
        loaded = true
        let candidates = suggestions.map { entry in
            ServiceDay.Candidate(id: entry.id, name: entry.name, autoAdvances: model.presentation(entry.id)?.autoAdvance != nil)
        }
        let settings = existing ?? ServiceDay.defaultSettings(
            preServicePresentationId: ServiceDay.suggestedPresentation(candidates))
        services = ServiceDay.sorted(settings.services)
        days = ServiceDay.days(settings)
        slideshowID = settings.preServicePresentationId ?? ""
        clearFirst = ServiceDay.clearsFirst(settings)
    }

    private func save() {
        let settings = ServiceDaySettings(
            services: ServiceDay.sorted(services), days: days,
            preServicePresentationId: slideshowID.isEmpty ? nil : slideshowID, clearFirst: clearFirst)
        model.updateSlideBuilding { $0.serviceDay = settings }
        apply(ServiceDay.changes(from: model.residentScheduleTriggers, to: settings))
        if makeLoop, let fix = loopFix {
            model.updatePresentation(slideshowID) { $0.autoAdvance = fix }
        }
        dismiss()
    }

    private func remove() {
        model.updateSlideBuilding { $0.serviceDay = nil }
        for trigger in model.residentScheduleTriggers where ServiceDay.isRestartTrigger(trigger) {
            model.deleteScheduleTrigger(trigger.id)
        }
        scheduler?.sweep()
        dismiss()
    }

    private func apply(_ changes: ServiceDay.Changes) {
        for id in changes.deletes {
            model.deleteScheduleTrigger(id)
        }
        for fresh in changes.updates {
            model.updateScheduleTrigger(fresh.id) { ServiceDay.applyManagedFields(of: fresh, to: &$0) }
        }
        for trigger in changes.creates {
            model.createScheduleTrigger(trigger)
        }
        // The table may already hold the new ones; count each once.
        let created = Set(changes.creates.map(\.id))
        let ids = ServiceDay.restartTriggerIDs(
            model.residentScheduleTriggers.filter { !changes.deletes.contains($0.id) && !created.contains($0.id) }
                + changes.creates)
        model.updateSchedulerBoard { board in
            if let placed = board.placingServiceDay(triggerIDs: ids) { board = placed }
        }
        scheduler?.sweep()
    }
}
