import PresenterCore
import SwiftUI

/// The top of the Schedule tab: when the countdown plays each week, and
/// what the next service day will play.
struct CountdownsCard: View {
    let model: AppModel
    let scheduler: SchedulerController?

    @State private var editing = false
    @AppStorage(ServiceStation.runsServiceKey) private var runsHere = false

    private var today: String { ScheduleMath.localDayString(Date(), calendar: .current) }
    private var setup: WeeklyCountdown.Setup? {
        WeeklyCountdown.setup(from: model.residentScheduleTriggers, today: today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.system(size: 11))
                    .foregroundStyle(HopeStyle.amber)
                Text("Countdowns")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button(setup == nil ? "Set Up" : "Edit") { editing = true }
                    .controlSize(.small)
                    .help("Which days, and when each countdown starts")
            }
            if let setup {
                Text("\(WeeklyCountdown.daysLabel(setup)) at \(setup.startTimes.map(ServiceDay.displayTime).joined(separator: ", "))")
                    .font(.system(size: 10))
                Text("From each \(CountdownRuns.seriesName(setup.series, model: model)) plan")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    CountdownRunList(model: model, triggers: CountdownRuns.triggers(model), after: context.date, sameDayOnly: true)
                }
                if scheduler?.enabled != true {
                    Text("The Scheduler is off on this Mac.")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                Toggle("Play on this Mac", isOn: $runsHere)
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .font(.system(size: 9))
                    .help("Only the Mac that runs the service plays the countdowns. Other Macs skip them.")
                if !runsHere {
                    Text("This Mac skips the countdowns.")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Play the countdown from each week's plan at set times.")
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
            CountdownScheduleSheet(model: model, scheduler: scheduler)
        }
    }
}

/// Helpers the card and the sheet share.
@MainActor
enum CountdownRuns {
    static func triggers(_ model: AppModel) -> [ScheduleTrigger] {
        model.residentScheduleTriggers.filter { WeeklyCountdown.isWeeklyCountdown($0) && $0.archived != true && $0.enabled != false }
    }

    static func seriesName(_ series: PlanSchedule.Source, model: AppModel) -> String {
        switch series {
        case .serviceType(let type): return type
        case .template(let id, let type):
            return type ?? model.resident.services.value(id).map { PlanSchedule.baseName(ofTemplate: $0.name) } ?? "matching"
        case .plan(let id): return model.resident.services.value(id)?.name ?? "chosen"
        }
    }

    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The next runs of the countdown triggers: when, which video, when it
/// ends, and the plan; or why it won't play.
struct CountdownRunList: View {
    struct Run: Identifiable {
        let date: Date
        let action: SlideAction
        var id: String { "\(date.timeIntervalSince1970)-\(action.id)" }
    }

    let model: AppModel
    let triggers: [ScheduleTrigger]
    let after: Date
    /// Just the next day's runs (the card), or the next several (the sheet).
    var sameDayOnly = false
    var count = 6

    var body: some View {
        let runs = upcoming
        VStack(alignment: .leading, spacing: 2) {
            if runs.isEmpty {
                Text("No countdowns coming up.")
                    .foregroundStyle(.tertiary)
            }
            ForEach(runs) { run in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(run.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute().second())
                        .monospacedDigit()
                        .frame(width: 140, alignment: .leading)
                    detail(run)
                }
            }
        }
        .font(.system(size: 9))
    }

    private var upcoming: [Run] {
        let all = triggers.flatMap { trigger in
            PlanSchedule.upcoming(trigger, after: after, count: count).compactMap { date in
                trigger.actions.first { $0.kind == .fireServiceItem }.map { Run(date: date, action: $0) }
            }
        }.sorted { $0.date < $1.date }
        guard sameDayOnly, let first = all.first else { return Array(all.prefix(count)) }
        return all.filter { Calendar.current.isDate($0.date, inSameDayAs: first.date) }
    }

    @ViewBuilder
    private func detail(_ run: Run) -> some View {
        switch model.resolvePlanItem(run.action, on: run.date) {
        case .plays(let plan, let item):
            let day = ScheduleMath.localDayString(run.date, calendar: .current)
            if WeeklyCountdown.planHasItsOwn(plan.id, on: day, triggers: model.residentScheduleTriggers) {
                Text("\(plan.name) has its own countdown set with Start Time…")
                    .foregroundStyle(.secondary).lineLimit(2)
            } else {
                let name = model.entry(item.refId)?.name ?? "Countdown"
                let seconds = model.media(item.refId).flatMap(ServiceCountdown.videoSeconds(of:))
                let ends = seconds.map { " · ends \(run.date.addingTimeInterval($0.rounded(.up)).formatted(.dateTime.hour().minute().second()))" } ?? ""
                Text("\(name)\(seconds.map { " (\(CountdownRuns.length($0)))" } ?? "")\(ends)")
                    .lineLimit(1)
                    .help(plan.name)
            }
        case .skipped(let reason):
            Text(reason).foregroundStyle(.orange).lineLimit(2)
        }
    }
}

/// Countdowns setup: the days, every how many weeks, when each countdown
/// starts, which plans, and from when until when.
struct CountdownScheduleSheet: View {
    let model: AppModel
    let scheduler: SchedulerController?

    @Environment(\.dismiss) private var dismiss
    /// "type:<service type>" or "template:<id>".
    @State private var series = ""
    @State private var days: [Int] = [1]
    @State private var everyWeeks = 1
    @State private var times: [TimeRow] = WeeklyCountdown.defaultStartTimes.map(TimeRow.init)

    struct TimeRow: Identifiable {
        let id = UUID()
        var date: Date
        init(_ raw: String) { date = ScheduleConditionFormat.timeOfDayDate(raw) }
        init(date: Date) { self.date = date }
    }
    @State private var startDay = Date()
    @State private var endsNever = true
    @State private var endDay = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var fallbackVideoID = ""
    @State private var runsHere = ServiceStation.sheetDefault
    @State private var loaded = false

    private static let labelWidth: CGFloat = 90
    private var today: String { ScheduleMath.localDayString(Date(), calendar: .current) }
    private var existing: WeeklyCountdown.Setup? {
        WeeklyCountdown.setup(from: model.residentScheduleTriggers, today: today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Countdowns").font(.headline)
            Text("The countdown plays from that day's plan at each time, and the plan moves on when it ends.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            row("Days") { dayChips }
            row("Every") {
                Stepper(value: $everyWeeks, in: 1 ... 12) {
                    Text(everyWeeks == 1 ? "week" : "\(everyWeeks) weeks").monospacedDigit()
                }
                .fixedSize()
            }
            row("Starts at") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach($times) { $row in
                        HStack(spacing: 6) {
                            SecondsTimePicker(date: $row.date).fixedSize()
                            if times.count > 1 {
                                let rowID = row.id
                                Button(role: .destructive) { times.removeAll { $0.id == rowID } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this time")
                            }
                        }
                    }
                    Button("Add Time", systemImage: "plus") {
                        let last = times.map(\.date).max() ?? ScheduleConditionFormat.timeOfDayDate("09:25")
                        times.append(TimeRow(date: last.addingTimeInterval(105 * 60)))
                    }
                    .buttonStyle(.borderless)
                }
            }
            row("Plan") {
                Picker("Plan", selection: $series) {
                    if series.isEmpty { Text("Choose\u{2026}").tag("") }
                    ForEach(templates, id: \.id) { template in
                        Text("Each \(PlanSchedule.baseName(ofTemplate: template.name)) plan (template)")
                            .tag("template:" + template.id)
                    }
                    ForEach(serviceTypes, id: \.self) { type in
                        Text("Each \(type) plan").tag("type:" + type)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("If no video") {
                Picker("If no video", selection: $fallbackVideoID) {
                    Text("Skip that week").tag("")
                    ForEach(countdownVideos, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Played when that week's plan has no countdown video chosen")
            }
            row("Starts") {
                DatePicker("Starts", selection: $startDay, displayedComponents: .date)
                    .labelsHidden()
                    .fixedSize()
            }
            row("Ends") {
                Picker("Ends", selection: $endsNever) {
                    Text("Never").tag(true)
                    Text("On a date").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if !endsNever {
                    DatePicker("Ends", selection: $endDay, in: startDay..., displayedComponents: .date)
                        .labelsHidden()
                        .fixedSize()
                }
            }
            Toggle("Play on this Mac", isOn: $runsHere)
                .padding(.leading, Self.labelWidth + 8)
                .help("Only the Mac that runs the service plays the countdowns. Other Macs skip them.")

            Divider()
            Text("Coming up").font(.callout.weight(.medium))
            if let setup {
                CountdownRunList(model: model, triggers: WeeklyCountdown.triggers(for: setup), after: Date())
            }

            HStack {
                if existing != nil {
                    Button("Remove", role: .destructive, action: remove)
                        .help("Stop playing the countdowns at set times")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup == nil)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear(perform: load)
    }

    private func row(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).frame(width: Self.labelWidth, alignment: .leading)
            content()
        }
    }

    private var dayChips: some View {
        HStack(spacing: 4) {
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

    // MARK: Choices

    private var templates: [Service] {
        model.resident.services.values.filter { $0.isTemplate == true }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Service types with plans, except those a template stands for.
    private var serviceTypes: [String] {
        let covered = Set(templates.compactMap(\.mxuServiceTypeName))
        var types = Set(model.resident.services.values.filter { $0.isTemplate != true }.compactMap(\.mxuServiceTypeName))
            .subtracting(covered)
        if series.hasPrefix("type:") { types.insert(String(series.dropFirst(5))) }
        return types.filter { !$0.isEmpty }.sorted()
    }

    private var source: PlanSchedule.Source? {
        if series.hasPrefix("type:") { return .serviceType(String(series.dropFirst(5))) }
        if series.hasPrefix("template:") {
            let id = String(series.dropFirst(9))
            return .template(id: id, serviceType: model.resident.services.value(id)?.mxuServiceTypeName)
        }
        return nil
    }

    /// Videos in the Countdowns folder, by name.
    private var countdownVideos: [LibraryIndex.Entry] {
        var videos = model.entries(of: .media)
            .filter { ServiceCountdown.isCountdownFolder($0.subkind) && model.media($0.id)?.mediaKind == .video }
        if !fallbackVideoID.isEmpty, !videos.contains(where: { $0.id == fallbackVideoID }),
           let chosen = model.entry(fallbackVideoID) {
            videos.append(chosen)
        }
        return videos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var setup: WeeklyCountdown.Setup? {
        guard let source, !days.isEmpty, !times.isEmpty else { return nil }
        return WeeklyCountdown.Setup(
            series: source, days: days, everyWeeks: everyWeeks,
            startTimes: times.map { ScheduleConditionFormat.timeOfDay(from: $0.date) },
            startDay: ScheduleMath.localDayString(startDay, calendar: .current),
            endDay: endsNever ? nil : ScheduleMath.localDayString(endDay, calendar: .current),
            fallbackVideoID: fallbackVideoID.isEmpty ? nil : fallbackVideoID)
    }

    // MARK: Load and save

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let existing else {
            // The template when there is one, else Sunday's service type.
            if let template = templates.first {
                series = "template:" + template.id
                fallbackVideoID = ServiceCountdown.item(in: template)?.refId ?? ""
            } else {
                let sunday = model.resident.services.values
                    .filter { $0.isTemplate != true && $0.mxuServiceTypeName != nil }
                    .sorted { $0.serviceDate > $1.serviceDate }
                    .first { PlanSchedule.weekday(of: String($0.serviceDate.prefix(10)), calendar: .current) == 1 }
                if let type = sunday?.mxuServiceTypeName ?? serviceTypes.first { series = "type:" + type }
            }
            return
        }
        switch existing.series {
        case .template(let id, _): series = "template:" + id
        case .serviceType(let type): series = "type:" + type
        case .plan: break
        }
        days = existing.days
        everyWeeks = existing.everyWeeks
        times = existing.startTimes.map(TimeRow.init)
        startDay = ScheduleMath.parseLocalDate(existing.startDay + "T12:00", calendar: .current) ?? Date()
        if let end = existing.endDay, let date = ScheduleMath.parseLocalDate(end + "T12:00", calendar: .current) {
            endsNever = false
            endDay = date
        }
        fallbackVideoID = existing.fallbackVideoID ?? ""
    }

    private func save() {
        guard let setup else { return }
        ServiceStation.runsService = runsHere
        apply(WeeklyCountdown.changes(from: model.residentScheduleTriggers, to: setup))
        dismiss()
    }

    private func remove() {
        apply(WeeklyCountdown.changes(from: model.residentScheduleTriggers, to: nil))
        dismiss()
    }

    private func apply(_ changes: ServiceDay.Changes) {
        for id in changes.deletes { model.deleteScheduleTrigger(id) }
        for fresh in changes.updates {
            model.updateScheduleTrigger(fresh.id) { $0 = fresh }
        }
        for trigger in changes.creates { model.createScheduleTrigger(trigger) }
        let created = Set(changes.creates.map(\.id))
        let ids = WeeklyCountdown.triggerIDs(
            model.residentScheduleTriggers.filter { !changes.deletes.contains($0.id) && !created.contains($0.id) }
                + changes.creates)
        model.updateSchedulerBoard { board in
            if let placed = board.placingWeeklyCountdowns(triggerIDs: ids) { board = placed }
        }
        scheduler?.sweep()
    }
}
