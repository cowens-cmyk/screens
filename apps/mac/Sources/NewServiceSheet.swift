import PresenterCore
import SwiftUI

/// Builds a service by hand: a name and date, optionally starting from an
/// earlier service's order (so a regular Sunday is a couple of clicks).
struct NewServiceSheet: View {
    let model: AppModel
    let onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = "Sunday Service"
    @State private var date = NewServiceSheet.nextSunday()
    @State private var copyFrom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Plan").font(.headline)
            Form {
                TextField("Name", text: $name)
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Start from", selection: $copyFrom) {
                    Text("Empty").tag("")
                    Divider()
                    ForEach(model.entries(of: .service), id: \.id) { entry in
                        Text("Copy of \(entry.name)").tag(entry.id)
                    }
                }
            }
            .formStyle(.grouped)
            Text("Add songs, presentations, videos and headers with Add, or drag them in from the library.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    static func nextSunday(from now: Date = .now) -> Date {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now)
        let days = weekday == 1 ? 0 : 8 - weekday
        return calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
    }

    private func create() {
        var items: [ServiceItem] = []
        if !copyFrom.isEmpty, let source = try? model.service(copyFrom) {
            // Same order and links; a copy is local, not tied to Shepherd.
            items = source.items.map { item in
                var copy = ServiceItem(id: UUID().uuidString, itemKind: item.itemKind, name: item.name, refId: item.refId)
                copy.arrangementId = item.arrangementId
                copy.colorHex = item.colorHex
                return copy
            }
        }
        let service = Service(
            id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespaces),
            serviceDate: AppModel.isoDate(date), items: items)
        model.createInDrive(service)
        dismiss()
        onCreated(service.id)
    }
}

/// "Also add to <service>" for the song, scripture and points builders.
struct AddToCurrentServiceToggle: View {
    let model: AppModel
    @Binding var isOn: Bool

    var body: some View {
        if let id = model.currentServiceID {
            Toggle("Also add to “\(model.indexEntry(id)?.name ?? "Service")”", isOn: $isOn)
                .font(.callout)
        }
    }

    @MainActor
    static func add(_ presentationID: String, model: AppModel, if isOn: Bool) {
        guard isOn, let serviceID = model.currentServiceID else { return }
        model.addServiceItem(serviceID, refID: presentationID)
    }
}
