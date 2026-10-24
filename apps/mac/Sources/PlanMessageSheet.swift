import PresenterCore
import SwiftUI

/// A plan's message and sermon series, with what every screen will show:
/// the series theme on the audience screens, its lower thirds on the
/// livestream, and the sermon timer and clock on the stage. Each line says
/// whether that screen is covered, so nothing is left to chance on Sunday.
struct PlanMessageSheet: View {
    let model: AppModel
    let planID: String

    @Environment(\.dismiss) private var dismiss
    @State private var creatingSeries = false
    @State private var importingNotes = false
    /// Series art (or a Claude Design download) dropped on the sheet, to
    /// make a new series from.
    @State private var seriesArt: [URL] = []
    @State private var artTargeted = false

    private var plan: Service? { model.resident.services.value(planID) }
    private var seriesID: String { plan?.sermonThemeId ?? model.slideBuilding.sermonThemeId ?? "" }
    private var series: Theme? { seriesID.isEmpty ? nil : model.theme(seriesID) }
    private var messageID: String? { Self.messageID(of: plan, model: model) }
    private var message: Presentation? { messageID.flatMap { model.presentation($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Message & Sermon Series").font(.title3.weight(.semibold))

            Form {
                Section("Sermon series") {
                    HStack {
                        Picker("Series", selection: Binding(get: { seriesID }, set: chooseSeries)) {
                            Text("Choose…").tag("")
                            ForEach(model.entries(of: .theme), id: \.id) { Text($0.name).tag($0.id) }
                        }
                        Button("New Series…") {
                            seriesArt = []
                            creatingSeries = true
                        }
                    }
                    Text("The series sets the look of the message on every screen. Switch series here any week, or drop the series art (or a Claude Design download) anywhere here to make a new one from it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Message") {
                    HStack {
                        Text("Build the message from the pastor's notes in the series' designs.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Import Notes…") { importingNotes = true }
                    }
                    if let message {
                        LabeledContent("Presentation", value: message.name)
                        LabeledContent("Sermon timer") {
                            SermonMinutesField(minutes: Binding(
                                get: { SermonTimer.minutes(for: message) },
                                set: { minutes in
                                    let seconds = SermonTimer.seconds(minutes: minutes)
                                    model.updatePresentation(message.id) { $0.sermonTimerSeconds = seconds }
                                }))
                        }
                    } else {
                        Button("Add a Message to This Plan", action: addMessage)
                    }
                }
                Section("Every screen") {
                    check("Audience", ok: series != nil && message?.themeId == seriesID,
                          detail: series.map { "Message slides use \($0.name)" } ?? "Choose a series")
                    check("Livestream", ok: (series?.streamDesigns?.isEmpty == false) || series?.streamLowerThirdThemeId != nil,
                          detail: (series?.streamDesigns?.isEmpty == false) || series?.streamLowerThirdThemeId != nil
                              ? "Lower thirds from \(series?.name ?? "the series")"
                              : "This series has no lower thirds — set them in the theme editor")
                    check("Stage", ok: message != nil,
                          detail: "Sermon timer (\(SermonTimer.minutes(for: message)) min, red past 0:00) and the clock")
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 3)
            .opacity(artTargeted ? 1 : 0).allowsHitTesting(false))
        .dropDestination(for: URL.self) { urls, _ in
            guard PhotoSeries.accepts(urls) else { return false }
            seriesArt = urls
            creatingSeries = true
            return true
        } isTargeted: { artTargeted = $0 }
        .sheet(isPresented: $creatingSeries) {
            // A new series made here is this plan's series; art dropped
            // here starts building as the sheet opens.
            SermonSeriesSheet(model: model, dropped: seriesArt, onCreated: chooseSeries)
        }
        .sheet(isPresented: $importingNotes) { SermonImportSheet(model: model, planID: planID) }
    }

    private func check(_ screen: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(screen).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseSeries(_ id: String) {
        model.useSeries(id, forPlan: planID)
    }

    fileprivate static func messageID(of plan: Service?, model: AppModel) -> String? {
        plan?.messagePresentationId
            ?? plan?.items.first { item in
                item.itemKind == .presentation
                    && model.presentation(item.refId).map { PresentationTypes.category(of: $0) == PresentationTypes.sermon } == true
            }?.refId
    }

    private func addMessage() {
        var message = Presentation(
            id: UUID().uuidString, name: "Message", presentationKind: .deck,
            themeId: seriesID.isEmpty ? BasicTemplates.pointsThemeID : seriesID, slides: [])
        message.category = PresentationTypes.sermon
        model.createInDrive(message)
        let item = ServiceItem(id: UUID().uuidString, itemKind: .presentation, name: "Message", refId: message.id)
        let id = message.id
        model.updateService(planID) { plan in
            plan.items.append(item)
            plan.messagePresentationId = id
        }
    }
}

extension AppModel {
    /// The plan, its message and future sermon imports all follow the series.
    func useSeries(_ id: String, forPlan planID: String) {
        guard !id.isEmpty else { return }
        let messageID = PlanMessageSheet.messageID(of: resident.services.value(planID), model: self)
        updateService(planID) { $0.sermonThemeId = id }
        updateSlideBuilding { $0.sermonThemeId = id }
        if let messageID {
            updatePresentation(messageID) { message in
                message.themeId = id
                for index in message.slides.indices { message.slides[index].themeId = nil }
            }
        }
    }
}
