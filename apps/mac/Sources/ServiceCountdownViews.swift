import PresenterCore
import SwiftUI

/// The countdown row's video: this week's countdown, picked from the
/// Countdowns folder in Media (newest first), any other video below.
struct CountdownVideoMenu: View {
    let model: AppModel
    let planID: String
    let item: ServiceItem

    private var videos: (countdowns: [LibraryIndex.Entry], others: [LibraryIndex.Entry]) {
        let all = model.entries(of: .media)
            .filter { model.media($0.id)?.mediaKind == .video }
            .sorted { $0.updatedAt > $1.updatedAt }
        let inFolder = all.filter { $0.subkind == ServiceCountdown.folder || $0.subkind.hasPrefix(ServiceCountdown.folder + "/") }
        return (inFolder, all.filter { entry in !inFolder.contains { $0.id == entry.id } })
    }

    var body: some View {
        let lists = videos
        Menu {
            if lists.countdowns.isEmpty {
                Text("Put countdown videos in Media › \(ServiceCountdown.folder)")
            }
            ForEach(lists.countdowns.prefix(20), id: \.id) { entry in
                Button(entry.name) { choose(entry.id) }
            }
            if !lists.others.isEmpty {
                Menu("Other Videos") {
                    ForEach(lists.others.prefix(40), id: \.id) { entry in
                        Button(entry.name) { choose(entry.id) }
                    }
                }
            }
        } label: {
            // Small enough to sit beside the name in the narrow plan column;
            // orange until this week's video is chosen.
            Image(systemName: item.refId.isEmpty ? "film.fill" : "film")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((item.refId.isEmpty ? Color.orange : Color.secondary).opacity(0.18), in: Capsule())
                .foregroundStyle(item.refId.isEmpty ? Color.orange : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(item.refId.isEmpty ? "Choose this service's countdown video" : "Change the countdown video")
    }

    /// The video itself is left as it is: the plan moves on from its
    /// countdown at zero whatever the video is set to do elsewhere.
    private func choose(_ mediaID: String) {
        model.setCountdownVideo(mediaID, itemID: item.id, planID: planID)
    }
}

/// Schedule Service: when each service starts and when its countdown
/// starts. The countdown start follows the service time (its video's length
/// before it) until it's changed by hand. Saving replaces the plan's
/// countdown triggers in the scheduler.
struct ScheduleServiceSheet: View {
    let model: AppModel
    let planID: String

    @Environment(\.dismiss) private var dismiss
    @State private var times: [Row] = []
    @State private var runsHere = ServiceStation.sheetDefault

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var service: Date
        var countdown: Date
        var countdownChanged = false
    }

    private var plan: Service? { model.resident.services.value(planID) }
    private var countdownItem: ServiceItem? { plan.flatMap(ServiceCountdown.item(in:)) }
    /// As it plays: trimmed to its in and out points, at its play rate.
    private var videoSeconds: Double? { model.countdownVideoSeconds(planID: planID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule Service").font(.headline)
            if let plan { Text(plan.name).foregroundStyle(.secondary) }

            countdownVideo

            ForEach($times) { $row in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            DatePicker("Service starts", selection: $row.service)
                            Spacer()
                            if times.count > 1 {
                                Button(role: .destructive) { times.removeAll { $0.id == row.id } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this service time")
                            }
                        }
                        // To the second: a 5:10 countdown starts at :50.
                        let start = Binding(
                            get: { row.countdown },
                            set: { row.countdown = $0; row.countdownChanged = true })
                        HStack {
                            Text("Countdown starts")
                            Spacer()
                            Text(row.countdown.formatted(.dateTime.hour().minute().second()))
                                .monospacedDigit()
                            Stepper("", value: Binding(
                                get: { start.wrappedValue.timeIntervalSinceReferenceDate },
                                set: { start.wrappedValue = Date(timeIntervalSinceReferenceDate: $0) }),
                                    step: 5)
                                .labelsHidden()
                                .help("Five seconds earlier or later")
                        }
                        Text(caption(row))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
                .onChange(of: row.service) { _, service in
                    if !row.countdownChanged {
                        row.countdown = ServiceCountdown.start(serviceTime: service, videoSeconds: videoSeconds)
                    }
                }
            }
            // A video picked from the film menu above, or trimmed meanwhile,
            // has another length: starts not set by hand follow it.
            .onChange(of: videoSeconds) { _, seconds in
                for index in times.indices where !times[index].countdownChanged {
                    times[index].countdown = ServiceCountdown.start(serviceTime: times[index].service, videoSeconds: seconds)
                }
            }

            Button("Add Service Time", systemImage: "plus") {
                let last = times.last?.service ?? defaultTime()
                let next = last.addingTimeInterval(105 * 60)
                times.append(Row(service: next, countdown: ServiceCountdown.start(serviceTime: next, videoSeconds: videoSeconds)))
            }
            .buttonStyle(.borderless)

            Toggle("Run on this Mac", isOn: $runsHere)
                .help("Play the countdowns from this Mac. Other Macs skip them.")

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Schedule", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(times.isEmpty || countdownItem == nil)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var countdownVideo: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer").foregroundStyle(HopeStyle.amber)
            if let item = countdownItem {
                if item.refId.isEmpty {
                    Text("No countdown video yet").foregroundStyle(.orange)
                } else {
                    Text(model.entry(item.refId)?.name ?? "Countdown")
                    if let seconds = videoSeconds {
                        Text(Self.length(seconds)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                CountdownVideoMenu(model: model, planID: planID, item: item)
            } else {
                Text("This plan has no countdown item.").foregroundStyle(.secondary)
            }
        }
    }

    /// Where the video really ends, which a start moved by hand can put
    /// before or after the service time.
    private func caption(_ row: Row) -> String {
        guard row.service > row.countdown else { return "The countdown starts after the service time." }
        guard let seconds = videoSeconds, seconds > 0 else {
            return "The countdown runs \(Self.length(row.service.timeIntervalSince(row.countdown))) and ends at \(row.service.formatted(date: .omitted, time: .shortened))."
        }
        let end = row.countdown.addingTimeInterval(seconds.rounded(.up))
        let off = Int(end.timeIntervalSince(row.service).rounded())
        let endText = end.formatted(.dateTime.hour().minute().second())
        if off == 0 { return "The video runs \(Self.length(seconds)) and ends at \(endText)." }
        let side = off < 0 ? "before" : "after"
        return "The video runs \(Self.length(seconds)) and ends at \(endText), \(Self.length(Double(abs(off)))) \(side) the service time."
    }

    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Load and save

    /// What's scheduled already; else Shepherd's service times; else 10:30
    /// on the plan's date.
    private func load() {
        let seconds = videoSeconds
        let existing = model.residentScheduleTriggers
            .filter { ServiceCountdown.isCountdownTrigger($0, planID: planID) }
            .compactMap { trigger -> (start: Date, service: Date)? in
                guard let start = ServiceCountdown.startDate(of: trigger),
                      let service = ServiceCountdown.serviceTime(of: trigger, videoSeconds: seconds)
                else { return nil }
                return (start, service)
            }
            .sorted { $0.start < $1.start }
        if !existing.isEmpty {
            // A start that is the video's length before its service time
            // still follows the service time; only one moved by hand stays.
            times = existing.map { pair in
                let fitted = ServiceCountdown.start(serviceTime: pair.service, videoSeconds: videoSeconds)
                return Row(service: pair.service, countdown: pair.start,
                           countdownChanged: abs(pair.start.timeIntervalSince(fitted)) >= 0.5)
            }
            return
        }
        let formatter = ISO8601DateFormatter()
        let planned = (plan?.mxuPlanTimes ?? [])
            .filter { $0.isRehearsal != true }
            .compactMap { $0.startsAt.flatMap(formatter.date(from:)) }
            .sorted()
        let services = planned.isEmpty ? [defaultTime()] : planned
        times = services.map { Row(service: $0, countdown: ServiceCountdown.start(serviceTime: $0, videoSeconds: videoSeconds)) }
    }

    private func defaultTime() -> Date {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = plan.flatMap { formatter.date(from: $0.serviceDate) } ?? calendar.startOfDay(for: .now)
        return calendar.date(bySettingHour: 10, minute: 30, second: 0, of: day) ?? day
    }

    private func save() {
        guard let plan, let item = countdownItem else { return }
        ServiceStation.runsService = runsHere
        for old in model.residentScheduleTriggers where ServiceCountdown.isCountdownTrigger(old, planID: planID) {
            model.deleteScheduleTrigger(old.id)
        }
        for row in times.sorted(by: { $0.service < $1.service }) {
            model.createScheduleTrigger(ServiceCountdown.trigger(
                planID: planID, planName: plan.name, countdownItemID: item.id,
                start: row.countdown, serviceTime: row.service))
        }
        dismiss()
    }
}

extension AppModel {
    /// Whether a drag from the media bin (a bare library id) is a video the
    /// countdown item can take.
    func isCountdownVideoDrop(_ payload: String?, on item: ServiceItem) -> Bool {
        guard item.isCountdown == true, let payload else { return false }
        return media(payload)?.mediaKind == .video
    }

    /// A video dropped on the countdown item, in the plan or its card,
    /// becomes its video, the same as choosing it from the film menu.
    func dropCountdownVideo(_ payload: String?, on item: ServiceItem, planID: String) -> Bool {
        guard let payload, isCountdownVideoDrop(payload, on: item) else { return false }
        setCountdownVideo(payload, itemID: item.id, planID: planID)
        return true
    }

    /// How long the plan's countdown video runs on the screens (trimmed, at
    /// its play rate); nil without one.
    func countdownVideoSeconds(planID: String) -> Double? {
        guard let item = resident.services.value(planID).flatMap(ServiceCountdown.item(in:)),
              !item.refId.isEmpty
        else { return nil }
        return media(item.refId).flatMap(ServiceCountdown.videoSeconds(of:))
    }

    /// Gives the plan's countdown a new video. Countdowns already scheduled
    /// move with its length, so they still end at their service times
    /// rather than at the old video's.
    func setCountdownVideo(_ mediaID: String, itemID: String, planID: String) {
        guard let plan = resident.services.value(planID),
              ServiceCountdown.item(in: plan)?.id == itemID
        else {
            updateService(planID) { _ = ServiceCountdown.setVideo(mediaID, onItem: itemID, in: &$0) }
            return
        }
        let before = countdownVideoSeconds(planID: planID)
        updateService(planID) { _ = ServiceCountdown.setVideo(mediaID, onItem: itemID, in: &$0) }
        rescheduleCountdowns(planID: planID, from: before, to: media(mediaID).flatMap(ServiceCountdown.videoSeconds(of:)))
    }

    /// Moves the plan's countdowns still to come for a video that runs
    /// `new` seconds instead of `old`. One already running is left alone.
    func rescheduleCountdowns(planID: String, from old: Double?, to new: Double?) {
        let now = Date()
        for trigger in residentScheduleTriggers
        where trigger.archived != true && ServiceCountdown.isCountdownTrigger(trigger, planID: planID) {
            guard let start = ServiceCountdown.startDate(of: trigger), start > now else { continue }
            updateScheduleTrigger(trigger.id) { _ = ServiceCountdown.reschedule(&$0, fromVideoSeconds: old, toVideoSeconds: new) }
        }
    }

    /// Whether files dragged from the Finder hold a video for the countdown.
    func isCountdownVideoFileDrop(_ urls: [URL], on item: ServiceItem) -> Bool {
        item.isCountdown == true && ServiceCountdown.videoFile(in: urls) != nil
    }

    /// A video dragged from the Finder onto the countdown is imported into
    /// Media › Countdowns, where the film menu looks for them, then becomes
    /// the countdown's video. True once the import has started.
    func dropCountdownVideoFile(_ urls: [URL], on item: ServiceItem, planID: String) -> Bool {
        guard item.isCountdown == true, let file = ServiceCountdown.videoFile(in: urls) else { return false }
        let itemID = item.id
        let placement = LibraryHome.Placement.drive(
            viewing: LibraryHome.Viewed(kind: .media, area: .team, path: ServiceCountdown.folder))
        Task { @MainActor in
            guard let mediaID = await importFiles([file], placement: placement).first else { return }
            setCountdownVideo(mediaID, itemID: itemID, planID: planID)
        }
        return true
    }
}
