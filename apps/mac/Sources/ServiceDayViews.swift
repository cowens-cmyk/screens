import PresenterCore
import SwiftUI

/// Service Day setup (More › Service Day…): the days and times of the
/// services, and the presentations every plan shares: the pre-service
/// slideshow, the Transition and the Walkout. The service times are what the
/// stage's Before Service countdown and the sermon timer reset fall back on
/// when a plan has no Shepherd times. The pre-service slides no longer
/// restart at set times; the Schedule tab's Countdowns play at set times.
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
    @State private var transitionID = ""
    @State private var walkoutID = ""
    @State private var walkoutMinutes = StandingItems.defaultWalkoutReturnMinutes
    @State private var loaded = false

    private var existing: ServiceDaySettings? { model.slideBuilding.serviceDay }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Service Day").font(.headline)
            Text("The service times, and the presentations every plan shares.")
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

            standingPickers

            HStack {
                if existing != nil {
                    Button("Remove", role: .destructive, action: remove)
                        .help("Forget these times and presentations")
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

    // MARK: Transition and Walkout

    private var standingPickers: some View {
        VStack(alignment: .leading, spacing: 6) {
            StandingPresentationPicker(
                label: "Transition", id: $transitionID, presentations: presentations,
                suggest: StandingItems.looksLikeTransition)
                .help("Added to every plan right before the message")
            StandingPresentationPicker(
                label: "Walkout", id: $walkoutID, presentations: presentations,
                suggest: StandingItems.looksLikeWalkout)
                .help("Added last in every plan")
            if !walkoutID.isEmpty {
                HStack {
                    Spacer().frame(width: 90)
                    Stepper(value: $walkoutMinutes, in: 1 ... 30, step: 1) {
                        Text("Pre-service after \(Int(walkoutMinutes)) min")
                    }
                    .help("After this long on the walkout, the pre-service slides start. A countdown due sooner takes over first.")
                }
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
        let serviceTime = Binding<Date>(
            get: { ScheduleConditionFormat.timeOfDayDate(value.serviceTime) },
            set: { service.wrappedValue.serviceTime = ScheduleConditionFormat.timeOfDay(from: $0) })
        return HStack {
            DatePicker("Service at", selection: serviceTime, displayedComponents: .hourAndMinute)
                .fixedSize()
            if services.count > 1 {
                Button(role: .destructive) { services.removeAll { $0.id == value.id } } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this service time")
            }
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
        transitionID = settings.transitionPresentationId ?? ""
        walkoutID = settings.walkoutPresentationId ?? ""
        walkoutMinutes = StandingItems.walkoutReturnMinutes(settings)
    }

    private func save() {
        let settings = ServiceDaySettings(
            services: ServiceDay.sorted(services), days: days,
            preServicePresentationId: slideshowID.isEmpty ? nil : slideshowID, clearFirst: clearFirst,
            transitionPresentationId: transitionID.isEmpty ? nil : transitionID,
            walkoutPresentationId: walkoutID.isEmpty ? nil : walkoutID,
            walkoutReturnMinutes: walkoutMinutes)
        let standingChanged = settings.transitionPresentationId != existing?.transitionPresentationId
            || settings.walkoutPresentationId != existing?.walkoutPresentationId
        // A different slideshow chosen here becomes the one every plan shows.
        let previous = model.preServiceSlideshowID()
        model.updateSlideBuilding { $0.serviceDay = settings }
        if !slideshowID.isEmpty, slideshowID != previous {
            model.relinkPreServiceItems(to: slideshowID)
        }
        if standingChanged { model.relinkStandingItems() }
        if makeLoop, let fix = loopFix {
            model.updatePresentation(slideshowID) { $0.autoAdvance = fix }
        }
        dismiss()
    }

    private func remove() {
        model.updateSlideBuilding { $0.serviceDay = nil }
        dismiss()
    }
}

/// One of the Service Day's standing presentations: the ones named for it
/// first, then any presentation by name.
struct StandingPresentationPicker: View {
    let label: String
    @Binding var id: String
    let presentations: [LibraryIndex.Entry]
    let suggest: (String) -> Bool

    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).frame(width: 90, alignment: .leading)
                Menu {
                    Button("None") { id = "" }
                    let named = presentations.filter { suggest($0.name) }
                    if !named.isEmpty { Divider() }
                    ForEach(named, id: \.id) { entry in
                        Button(entry.name) { id = entry.id }
                    }
                } label: {
                    Text(id.isEmpty ? "None" : (presentations.first { $0.id == id }?.name ?? "Missing presentation"))
                }
                .fixedSize()
                TextField("Find", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }
            let query = search.trimmingCharacters(in: .whitespaces)
            if !query.isEmpty {
                let hits = presentations.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(5)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(hits), id: \.id) { entry in
                        Button(entry.name) {
                            id = entry.id
                            search = ""
                        }
                        .buttonStyle(.link)
                    }
                    if hits.isEmpty { Text("No match").foregroundStyle(.secondary) }
                }
                .padding(.leading, 98)
            }
        }
    }
}
