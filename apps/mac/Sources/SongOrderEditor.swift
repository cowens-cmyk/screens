import PresenterCore
import SlideScene
import SwiftUI

/// A song's order, made by dragging: every section of the song across the
/// top, the order it's sung in below. Drag a section down into place (or
/// click it to add it at the end), drag a block along the order to move
/// it, hover one and click × to take it out. Every change can be undone
/// with ⌘Z.
///
/// It edits the arrangement the plan item plays (else the song's default
/// one); a song with none gets one, starting from the order its slides
/// are in, and the plan item is set to it.
struct SongOrderEditor: View {
    let model: AppModel
    let presentationID: String
    /// The plan item whose order this is, when opened from a plan.
    var planItem: (serviceID: String, itemID: String)?
    var arrangementID: String?

    @State private var dropBefore: Int?
    @State private var hovered: Int?
    @State private var createdID: String?

    private var presentation: Presentation? { model.presentation(presentationID) }
    private var sections: [PresentationSection] { presentation?.sections ?? [] }

    /// The arrangement being edited, if the song has one yet.
    private var arrangement: Arrangement? {
        guard let presentation else { return nil }
        let arrangements = presentation.arrangements ?? []
        for id in [createdID, arrangementID, presentation.defaultArrangementId].compactMap({ $0 }) {
            if let found = arrangements.first(where: { $0.id == id }) { return found }
        }
        return arrangements.first
    }

    private var order: [String] {
        if let arrangement { return arrangement.sectionIds }
        return presentation.map(SongOrderEdit.baseOrder) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sections").font(.headline)
                Text("Drag a section into the order below, or click it to add it at the end.")
                    .font(.caption).foregroundStyle(.secondary)
                WrapLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(sections) { section in
                        chip(section.name, section: section)
                            .onTapGesture { change { SongOrderEdit.inserting(section.id, before: nil, in: $0) } }
                            .draggable(SongOrderEdit.sectionPayload(section.id))
                            .help("\(slideCount(section.id)) slide\(slideCount(section.id) == 1 ? "" : "s")")
                    }
                    if sections.isEmpty {
                        Text("This song has no sections yet.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Order").font(.headline)
                    if let name = arrangement?.name {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Drag to move. Hover a section and click × to take it out; ⌘Z undoes.")
                    .font(.caption).foregroundStyle(.secondary)
                WrapLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(order.enumerated()), id: \.offset) { index, sectionID in
                        orderChip(index: index, sectionID: sectionID)
                    }
                    if order.isEmpty {
                        Text("Drag sections here")
                            .font(.caption).foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                .padding(8)
                .background(Color.primary.opacity(dropBefore == order.count ? 0.08 : 0.04),
                            in: RoundedRectangle(cornerRadius: 8))
                // Dropped on the empty part of the order: at the end.
                .dropDestination(for: String.self) { payloads, _ in
                    defer { dropBefore = nil }
                    return payloads.first.map { drop($0, before: nil) } ?? false
                } isTargeted: { over in
                    dropBefore = over ? order.count : (dropBefore == order.count ? nil : dropBefore)
                }
            }
        }
    }

    private func orderChip(index: Int, sectionID: String) -> some View {
        let section = sections.first { $0.id == sectionID }
        return chip(section?.name ?? "Deleted Section", section: section)
            .overlay(alignment: .topTrailing) {
                if hovered == index {
                    Button {
                        change { SongOrderEdit.removing(at: index, in: $0) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .help("Take this out of the order")
                }
            }
            .overlay(alignment: .leading) {
                if dropBefore == index {
                    Capsule().fill(Color.accentColor).frame(width: 3, height: 20).offset(x: -5)
                }
            }
            .onHover { inside in
                if inside { hovered = index } else if hovered == index { hovered = nil }
            }
            .draggable(SongOrderEdit.blockPayload(index))
            .dropDestination(for: String.self) { payloads, _ in
                defer { dropBefore = nil }
                return payloads.first.map { drop($0, before: index) } ?? false
            } isTargeted: { over in
                if over { dropBefore = index } else if dropBefore == index { dropBefore = nil }
            }
    }

    private func chip(_ name: String, section: PresentationSection?) -> some View {
        let fill = section?.resolvedColorHex(paletteColors: model.groupColors).flatMap(GroupColor.color)
        return Text(name)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((fill ?? .secondary).opacity(0.25), in: Capsule())
            .overlay(Capsule().strokeBorder((fill ?? .secondary).opacity(0.6), lineWidth: 1))
            .contentShape(Capsule())
    }

    private func slideCount(_ sectionID: String) -> Int {
        presentation?.slides.count { $0.sectionId == sectionID } ?? 0
    }

    private func drop(_ text: String, before index: Int?) -> Bool {
        switch SongOrderEdit.payload(text) {
        case .section(let id):
            guard sections.contains(where: { $0.id == id }) else { return false }
            change { SongOrderEdit.inserting(id, before: index, in: $0) }
            return true
        case .block(let from):
            change { SongOrderEdit.moving(from: from, before: index, in: $0) }
            return true
        case nil:
            return false
        }
    }

    /// Applies an edit to the order and registers its undo (⌘Z).
    private func change(_ edit: ([String]) -> [String]) {
        let before = order
        let after = edit(before)
        guard after != before else { return }
        write(after)
        model.moveUndo.registerMove(
            label: "Song Order",
            undo: { write(before); return true },
            redo: { write(after); return true })
    }

    private func write(_ ids: [String]) {
        if let arrangement {
            model.updateArrangement(presentationID, arrangementID: arrangement.id) { $0.sectionIds = ids }
            return
        }
        // The song's first arrangement: the default, and the plan item's.
        let id = UUID().uuidString
        createdID = id
        let made = Arrangement(id: id, name: "Default", sectionIds: ids)
        model.updatePresentation(presentationID) { song in
            song.arrangements = (song.arrangements ?? []) + [made]
            if song.defaultArrangementId == nil { song.defaultArrangementId = id }
        }
        if let planItem {
            model.setServiceItemArrangement(planItem.serviceID, itemID: planItem.itemID, arrangementID: id)
        }
    }
}

/// The editor in a sheet, for the plan's Edit Song Order….
struct SongOrderSheet: View {
    let model: AppModel
    let presentationID: String
    var planItem: (serviceID: String, itemID: String)?
    var arrangementID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Song Order — \(model.presentation(presentationID)?.name ?? "")").font(.title3.weight(.semibold))
            SongOrderEditor(model: model, presentationID: presentationID, planItem: planItem, arrangementID: arrangementID)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
