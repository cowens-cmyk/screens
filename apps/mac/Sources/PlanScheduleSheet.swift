import PresenterCore
import SwiftUI

/// Makes or edits a schedule: what plays (a presentation, or an item from a
/// plan or from each week's plan), when (once, every day, or some days every
/// week or every few weeks), from when, and until when. The full trigger
/// editor stays for everything else (timers, calendar events, several
/// conditions or actions).
struct PlanScheduleSheet: View {
    let model: AppModel
    let scheduler: SchedulerController?
    /// Nil for a new schedule.
    let triggerID: String?
    var onSaved: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var nameEdited = false
    /// "library", "type:<service type>", "template:<id>" or "plan:<id>".
    @State private var from = "library"
    @State private var presentationID = ""
    @State private var itemID = ""
    @State private var clearFirst = false
    @State private var repeats: PlanSchedule.Repeat = .weekly
    @State private var days: [Int] = [1]
    @State private var everyWeeks = 1
    @State private var time = ScheduleConditionFormat.timeOfDayDate("09:00")
    @State private var startDay = Date()
    @State private var endsNever = true
    @State private var endDay = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
    @State private var runsHere = ServiceStation.sheetDefault
    /// The plan-item action being edited, kept when its item isn't in the
    /// plan shown now (the saved item is matched again each week).
    @State private var original: SlideAction?
    @State private var loaded = false

    private static let labelWidth: CGFloat = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(triggerID == nil ? "New Schedule" : "Edit Schedule").font(.headline)

            row("Name") {
                TextField("Name", text: Binding(
                    get: { name },
                    set: { name = $0; nameEdited = true }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Divider()
            whatSection
            Divider()
            whenSection
            Divider()
            preview

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(triggerID == nil ? "Add Schedule" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear(perform: load)
        .onChange(of: from) { _, _ in pickDefaultItem(); autoName() }
        .onChange(of: itemID) { _, _ in autoName() }
        .onChange(of: presentationID) { _, _ in autoName() }
    }

    private func row(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).frame(width: Self.labelWidth, alignment: .leading)
            content()
        }
    }

    // MARK: What

    private var templates: [Service] {
        model.resident.services.values.filter { $0.isTemplate == true }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private var today: String { ScheduleMath.localDayString(Date(), calendar: .current) }

    private var upcomingPlans: [Service] {
        model.resident.services.values
            .filter { $0.isTemplate != true && String($0.serviceDate.prefix(10)) >= today }
            .sorted { ($0.serviceDate, $0.name) < ($1.serviceDate, $1.name) }
    }

    /// Service types with upcoming plans that no template stands for.
    private var serviceTypes: [String] {
        let covered = Set(templates.compactMap(\.mxuServiceTypeName))
        var types = Set(upcomingPlans.compactMap(\.mxuServiceTypeName)).subtracting(covered)
        if from.hasPrefix("type:") { types.insert(String(from.dropFirst(5))) }
        return types.filter { !$0.isEmpty }.sorted()
    }

    private var source: PlanSchedule.Source? {
        if from.hasPrefix("type:") { return .serviceType(String(from.dropFirst(5))) }
        if from.hasPrefix("template:") {
            let id = String(from.dropFirst(9))
            return .template(id: id, serviceType: model.resident.services.value(id)?.mxuServiceTypeName)
        }
        if from.hasPrefix("plan:") { return .plan(id: String(from.dropFirst(5))) }
        return nil
    }

    /// The plan whose items are listed: the template, the series' next
    /// plan, or the one plan.
    private var examplePlan: Service? {
        switch source {
        case .template(let id, _), .plan(let id): return model.resident.services.value(id)
        case .serviceType(let type):
            return upcomingPlans.first { $0.mxuServiceTypeName == type }
                ?? model.resident.services.values
                    .filter { $0.isTemplate != true && $0.mxuServiceTypeName == type }
                    .max { $0.serviceDate < $1.serviceDate }
        case nil: return nil
        }
    }

    /// Items that can play: presentations and videos.
    private var playableItems: [ServiceItem] {
        (examplePlan?.items ?? []).filter { $0.itemKind == .presentation || $0.itemKind == .media }
    }

    private var seriesLabel: String {
        switch source {
        case .serviceType(let type): return type
        case .template(let id, let type):
            return type ?? model.resident.services.value(id).map { PlanSchedule.baseName(ofTemplate: $0.name) } ?? "Plan"
        case .plan(let id): return model.resident.services.value(id)?.name ?? "Plan"
        case nil: return ""
        }
    }

    @ViewBuilder
    private var whatSection: some View {
        row("Plays from") {
            Picker("Plays from", selection: $from) {
                Text("A presentation").tag("library")
                if !templates.isEmpty || !serviceTypes.isEmpty {
                    Section("Each week's plan") {
                        ForEach(templates, id: \.id) { template in
                            Text("Each \(PlanSchedule.baseName(ofTemplate: template.name)) plan (template)")
                                .tag("template:" + template.id)
                        }
                        ForEach(serviceTypes, id: \.self) { type in
                            Text("Each \(type) plan").tag("type:" + type)
                        }
                    }
                }
                if !upcomingPlans.isEmpty {
                    Section("One plan") {
                        ForEach(upcomingPlans, id: \.id) { plan in
                            Text(plan.name).tag("plan:" + plan.id)
                        }
                    }
                }
                if from.hasPrefix("plan:"), !upcomingPlans.contains(where: { "plan:" + $0.id == from }) {
                    Text(model.resident.services.value(String(from.dropFirst(5)))?.name ?? "A plan that's gone").tag(from)
                }
            }
            .labelsHidden()
        }

        if from == "library" {
            row("Presentation") {
                Picker("Presentation", selection: $presentationID) {
                    Text("Choose\u{2026}").tag("")
                    ForEach(model.entries(of: .presentation).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.id) {
                        Text($0.name).tag($0.id)
                    }
                }
                .labelsHidden()
            }
        } else {
            row("Item") {
                Picker("Item", selection: $itemID) {
                    Text("Choose\u{2026}").tag("")
                    ForEach(playableItems, id: \.id) { item in
                        Text(itemLabel(item)).tag(item.id)
                    }
                    if let original, original.serviceItemId == itemID,
                       !playableItems.contains(where: { $0.id == itemID }) {
                        Text(original.serviceItemName ?? "Saved item").tag(itemID)
                    }
                }
                .labelsHidden()
            }
            if source?.repeatsAcrossPlans == true {
                Text(examplePlan.map { "Items from \($0.name). Each week it plays the same item from that day's \(seriesLabel) plan." }
                     ?? "No \(seriesLabel) plan yet to list items from.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.labelWidth + 8)
            }
        }

        Toggle("Clear the screens first", isOn: $clearFirst)
            .padding(.leading, Self.labelWidth + 8)
        if from != "library" {
            Toggle("Play on this Mac", isOn: $runsHere)
                .help("Plan items play only on the Mac that runs the service. Other Macs skip them.")
                .padding(.leading, Self.labelWidth + 8)
        }
    }

    private func itemLabel(_ item: ServiceItem) -> String {
        let position = (examplePlan?.items.firstIndex { $0.id == item.id }).map { "\($0 + 1). " } ?? ""
        guard source?.repeatsAcrossPlans == true, let role = PlanSchedule.role(of: item) else { return position + item.name }
        let what = switch role {
        case .countdown: "each plan's countdown"
        case .preService: "each plan's pre-service"
        case .transition: "each plan's transition"
        case .walkout: "each plan's walkout"
        }
        return position + item.name + " (\(what))"
    }

    // MARK: When

    @ViewBuilder
    private var whenSection: some View {
        row("Repeats") {
            Picker("Repeats", selection: $repeats) {
                Text("Never").tag(PlanSchedule.Repeat.never)
                Text("Every day").tag(PlanSchedule.Repeat.daily)
                Text("Weekly").tag(PlanSchedule.Repeat.weekly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        if repeats == .weekly {
            row("On") { dayChips }
            row("Every") {
                Stepper(value: $everyWeeks, in: 1 ... 12) {
                    Text(everyWeeks == 1 ? "week" : "\(everyWeeks) weeks").monospacedDigit()
                }
                .fixedSize()
            }
        }
        row("At") {
            SecondsTimePicker(date: $time).fixedSize()
        }
        row(repeats == .never ? "On" : "Starts") {
            DatePicker("Starts", selection: $startDay, displayedComponents: .date)
                .labelsHidden()
                .fixedSize()
        }
        if repeats != .never {
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

    private var when: PlanSchedule.When {
        PlanSchedule.When(
            repeats: repeats, days: days, everyWeeks: everyWeeks,
            time: ScheduleConditionFormat.timeOfDay(from: time),
            startDay: ScheduleMath.localDayString(startDay, calendar: .current),
            endDay: endsNever ? nil : ScheduleMath.localDayString(endDay, calendar: .current))
    }

    // MARK: Preview

    /// The rule in words, and the next few runs with the plan each plays from.
    @ViewBuilder
    private var preview: some View {
        let draft = draftTrigger
        VStack(alignment: .leading, spacing: 4) {
            Text(PlanSchedule.describe(when, today: today))
                .font(.callout.weight(.medium))
            let dates = PlanSchedule.upcoming(draft, after: Date(), count: 4)
            if dates.isEmpty {
                Text(repeats == .never ? "That time has passed." : "It has no runs left before it ends.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(dates, id: \.self) { date in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                        .monospacedDigit()
                        .frame(width: 150, alignment: .leading)
                    previewDetail(on: date)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func previewDetail(on date: Date) -> some View {
        if let action = targetAction, action.kind == .fireServiceItem {
            switch model.resolvePlanItem(action, on: date) {
            case .plays(let plan, let item):
                Text("\(item.name) from \(plan.name)").foregroundStyle(.secondary).lineLimit(1)
            case .skipped(let reason):
                Text(reason).foregroundStyle(.orange).lineLimit(2)
            }
        } else if let id = targetAction?.presentationId {
            Text(model.libraryEntry(id)?.name ?? "").foregroundStyle(.secondary).lineLimit(1)
        }
    }

    // MARK: Saving

    /// The action the schedule runs, nil until something is chosen.
    private var targetAction: SlideAction? {
        if from == "library" {
            guard !presentationID.isEmpty else { return nil }
            var action = SlideAction(id: original?.id ?? UUID().uuidString, kind: .firePresentation)
            action.presentationId = presentationID
            action.slideIndex = 0
            return action
        }
        guard let source, !itemID.isEmpty else { return nil }
        if let item = playableItems.first(where: { $0.id == itemID }) {
            return PlanSchedule.action(playing: item, from: source, id: original?.id ?? UUID().uuidString)
        }
        // The saved item, not in the plan shown now: kept as it was.
        if let original, original.serviceItemId == itemID, PlanSchedule.source(of: original) == source {
            return original
        }
        return nil
    }

    private var draftTrigger: ScheduleTrigger {
        ScheduleTrigger(
            id: triggerID ?? "draft", name: name,
            conditions: [PlanSchedule.condition(for: when, id: existingConditionID ?? UUID().uuidString)],
            actions: (clearFirst ? [SlideAction(id: existingClearID ?? UUID().uuidString, kind: .clearAll)] : [])
                + (targetAction.map { [$0] } ?? []),
            enabledUntil: PlanSchedule.enabledUntil(for: when))
    }

    private var existing: ScheduleTrigger? { triggerID.flatMap { try? model.scheduleTrigger($0) } }
    private var existingConditionID: String? { existing?.conditions.first?.id }
    private var existingClearID: String? { existing?.actions.first { $0.kind == .clearAll }?.id }

    private var canSave: Bool {
        targetAction != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (repeats != .weekly || !days.isEmpty)
    }

    private func save() {
        let draft = draftTrigger
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let id: String
        if let triggerID {
            id = triggerID
            model.updateScheduleTrigger(triggerID) { trigger in
                trigger.name = trimmed
                trigger.conditions = draft.conditions
                trigger.actions = draft.actions
                trigger.enabledUntil = draft.enabledUntil
                trigger.conditionLogic = nil
                trigger.archived = nil
            }
        } else {
            id = UUID().uuidString
            var made = draft
            made.id = id
            made.name = trimmed
            made.enabled = true
            model.createScheduleTrigger(made)
        }
        if from != "library" { ServiceStation.runsService = runsHere }
        scheduler?.sweep()
        onSaved(id)
        dismiss()
    }

    // MARK: Loading and defaults

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let trigger = existing else {
            // A new schedule starts on the next Sunday plan's countdown,
            // the one most often wanted.
            if let template = templates.first {
                from = "template:" + template.id
            } else if let type = serviceTypes.first {
                from = "type:" + type
            }
            pickDefaultItem()
            autoName()
            return
        }
        name = trigger.name
        nameEdited = true
        if let rule = PlanSchedule.when(from: trigger, today: today) {
            repeats = rule.repeats
            days = rule.repeats == .weekly ? rule.days : [1]
            everyWeeks = rule.everyWeeks
            time = ScheduleConditionFormat.timeOfDayDate(rule.time)
            startDay = ScheduleMath.parseLocalDate(rule.startDay + "T12:00", calendar: .current) ?? Date()
            if let end = rule.endDay, let date = ScheduleMath.parseLocalDate(end + "T12:00", calendar: .current) {
                endsNever = false
                endDay = date
            }
        }
        clearFirst = trigger.actions.contains { $0.kind == .clearAll }
        if let action = trigger.actions.first(where: { $0.kind == .fireServiceItem }) {
            original = action
            switch PlanSchedule.source(of: action) {
            case .plan(let id): from = "plan:" + id
            case .template(let id, _): from = "template:" + id
            case .serviceType(let type): from = "type:" + type
            case nil: break
            }
            // The item as it is in the plan shown, else the saved one.
            let shown = examplePlan.flatMap { PlanSchedule.item(for: action, in: $0) }
            itemID = shown?.id ?? action.serviceItemId ?? ""
            if let shown, shown.id != action.serviceItemId { original?.serviceItemId = shown.id }
        } else if let action = trigger.actions.first(where: { $0.kind == .firePresentation }) {
            original = action
            from = "library"
            presentationID = action.presentationId ?? ""
        }
    }

    /// The countdown when the plan has one, else its first item.
    private func pickDefaultItem() {
        guard from != "library", !playableItems.contains(where: { $0.id == itemID }) else { return }
        if let original, original.serviceItemId == itemID, PlanSchedule.source(of: original) == source { return }
        itemID = (playableItems.first { $0.isCountdown == true } ?? playableItems.first)?.id ?? ""
    }

    private func autoName() {
        guard !nameEdited else { return }
        if from == "library" {
            name = model.libraryEntry(presentationID)?.name ?? ""
        } else if let item = playableItems.first(where: { $0.id == itemID }) {
            name = source?.repeatsAcrossPlans == true ? "\(seriesLabel) \(item.name)" : "\(item.name), \(seriesLabel)"
        }
    }

    /// Whether the sheet can show a trigger: one once or weekly rule, and
    /// one presentation or plan item (with a clear before it, or not). The
    /// Service Day restarts and the scheduled countdowns are made by their
    /// own setups, which would write over a change made here.
    static func canEdit(_ trigger: ScheduleTrigger) -> Bool {
        guard !ServiceDay.isRestartTrigger(trigger),
              trigger.notes?.hasPrefix(ServiceCountdown.triggerNotePrefix) != true,
              PlanSchedule.when(from: trigger, today: "2000-01-01") != nil
        else { return false }
        let rest = trigger.actions.filter { $0.kind != .clearAll }
        guard trigger.actions.count - rest.count <= 1, rest.count == 1, let target = rest.first else { return false }
        return target.kind == .firePresentation || target.kind == .fireServiceItem
    }
}
