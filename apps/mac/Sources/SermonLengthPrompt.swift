import PresenterCore
import SwiftUI

/// Minutes for the sermon timer: typed, or nudged five at a time.
struct SermonMinutesField: View {
    @Binding var minutes: Int

    var body: some View {
        HStack(spacing: 6) {
            TextField("Minutes", value: $minutes, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
            Text("min")
            Stepper("Minutes", value: $minutes, in: 1...300, step: 5)
                .labelsHidden()
        }
    }
}

/// Asked when a plan is saved as a template: how long the message runs.
/// The answer becomes the template message's sermon timer, so every plan
/// made from the template starts the timer at that length.
struct SermonLengthPrompt: View {
    var initialMinutes = Int(SermonTimer.defaultSeconds / 60)
    /// Called with the minutes chosen.
    let onSave: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var minutes = Int(SermonTimer.defaultSeconds / 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How long is the message?").font(.headline)
            SermonMinutesField(minutes: $minutes)
            Text("Plans made from this template start the sermon timer at this length. You can change it for any week in Message & Series.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Template") {
                    onSave(min(max(minutes, 1), 300))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(minutes < 1)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { minutes = initialMinutes }
    }
}

/// Where a template keeps its sermon length: on its message presentation.
/// Plans made from a template each get a new, empty message, which takes
/// the length from here.
@MainActor
enum TemplateSermonLength {

    /// The plan's message item: the one it names, else the first item filed
    /// as a message.
    static func messageItem(in plan: Service, model: AppModel) -> ServiceItem? {
        plan.items.first { $0.refId == plan.messagePresentationId && plan.messagePresentationId != nil }
            ?? plan.items.first { item in
                item.itemKind == .presentation
                    && model.presentation(item.refId)
                        .map { PresentationTypes.category(of: $0) == PresentationTypes.sermon } == true
            }
    }

    static func hasMessage(_ plan: Service, model: AppModel) -> Bool {
        messageItem(in: plan, model: model) != nil
    }

    /// The minutes to suggest: the plan's own message length, else 40.
    static func suggestedMinutes(for plan: Service, model: AppModel) -> Int {
        SermonTimer.minutes(for: messageItem(in: plan, model: model).flatMap { model.presentation($0.refId) })
    }

    /// Gives the template a placeholder message of its own carrying the
    /// length, so setting it never changes the plan the template came from
    /// (whose message the template would otherwise share).
    static func apply(_ seconds: Double, to template: inout Service, model: AppModel) {
        guard let item = messageItem(in: template, model: model),
              let index = template.items.firstIndex(where: { $0.id == item.id })
        else { return }
        let source = model.presentation(item.refId)
        var message = Presentation(
            id: UUID().uuidString, name: "Message", presentationKind: .deck,
            themeId: template.sermonThemeId ?? source?.themeId ?? model.slideBuilding.sermonThemeId
                ?? BasicTemplates.pointsThemeID,
            slides: [])
        message.category = PresentationTypes.sermon
        message.sermonTimerSeconds = seconds
        model.createInDrive(message)
        template.items[index].refId = message.id
        template.messagePresentationId = message.id
    }

    /// The length a plan made from this template starts its timer at, nil
    /// when the template doesn't set one.
    static func seconds(in template: Service, model: AppModel) -> Double? {
        messageItem(in: template, model: model)
            .flatMap { model.presentation($0.refId)?.sermonTimerSeconds }
    }
}
