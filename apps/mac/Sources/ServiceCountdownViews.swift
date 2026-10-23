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
                Text("Put countdown videos in Media › \\(ServiceCountdown.folder)")
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
            Text(item.refId.isEmpty ? "Choose Video" : "Change")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background((item.refId.isEmpty ? Color.orange : Color.secondary).opacity(0.18), in: Capsule())
                .foregroundStyle(item.refId.isEmpty ? Color.orange : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("This service's countdown video")
    }

    private func choose(_ mediaID: String) {
        let itemID = item.id
        model.updateService(planID) { plan in
            guard let index = plan.items.firstIndex(where: { $0.id == itemID }) else { return }
            plan.items[index].refId = mediaID
        }
        // At zero the plan moves on to its next item by itself.
        if model.media(mediaID)?.endAction != .next {
            model.updateMedia(mediaID) { $0.endAction = .next }
        }
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

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var service: Date
        var countdown: Date
        var countdownChanged = false
    }

    private var plan: Service? { model.resident.services.value(planID) }
    private var countdownItem: ServiceItem? { plan.flatMap(ServiceCountdown.item(in:)) }
    private var videoSeconds: Double? {
        countdownItem.flatMap { $0.refId.isEmpty ? nil : model.media($0.refId)?.durationSeconds }
    }

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

            Button("Add Service Time", systemImage: "plus") {
                let last = times.last?.service ?? defaultTime()
                let next = last.addingTimeInterval(105 * 60)
                times.append(Row(service: next, countdown: ServiceCountdown.start(serviceTime: next, videoSeconds: videoSeconds)))
            }
            .buttonStyle(.borderless)

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

    private func caption(_ row: Row) -> String {
        let seconds = row.service.timeIntervalSince(row.countdown)
        guard seconds > 0 else { return "The countdown starts after the service time." }
        return "The countdown runs \(Self.length(seconds)) and ends at \(row.service.formatted(date: .omitted, time: .shortened))."
    }

    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Load and save

    /// What's scheduled already; else Shepherd's service times; else 10:30
    /// on the plan's date.
    private func load() {
        let existing = model.residentScheduleTriggers
            .filter { ServiceCountdown.isCountdownTrigger($0, planID: planID) }
            .compactMap { ServiceCountdown.startDate(of: $0) }
            .sorted()
        if !existing.isEmpty {
            let length = (videoSeconds ?? 0) > 0 ? videoSeconds!.rounded(.up) : 300
            times = existing.map { Row(service: $0.addingTimeInterval(length), countdown: $0, countdownChanged: true) }
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
