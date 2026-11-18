import AppKit
import PresenterCore
import SwiftUI

/// The church's own Media Library categories (see MediaCategories): what the
/// media bin asks of the library to list, make, edit and remove them. The
/// list lives in the church-wide settings, so it syncs; the media in a
/// category is filed in its folder and syncs like any other move.
extension AppModel {
    var mediaCategories: [MediaCategoryDefinition] {
        MediaCategories.effective(slideBuilding.mediaCategories)
    }

    func addMediaCategory(name: String, icon: String) {
        let current = mediaCategories
        updateSlideBuilding { $0.mediaCategories = MediaCategories.adding(name: name, icon: icon, to: current) }
    }

    /// Renames a category and refiles everything in it, keeping folders made
    /// inside it.
    func editMediaCategory(_ old: MediaCategoryDefinition, name: String, icon: String) {
        let current = mediaCategories
        guard MediaCategories.problem(with: name, in: current, renaming: old.name) == nil else { return }
        let clean = MediaCategories.cleanName(name)
        updateSlideBuilding { $0.mediaCategories = MediaCategories.editing(old.name, name: clean, icon: icon, in: current) }
        guard clean != old.name else { return }
        file(entries(in: .media).filter {
            MediaCategories.containing(folder: $0.subkind, in: [old]) != nil
        }.compactMap {
            refile($0, folder: MediaCategories.renamedFolder($0.subkind, to: clean), area: area($0.kind, $0.id))
        })
    }

    /// Takes the category off the list. Its media stays filed in the folder
    /// and is still in All Media; making the category again brings it back.
    func removeMediaCategory(_ category: MediaCategoryDefinition) {
        let current = mediaCategories
        updateSlideBuilding { $0.mediaCategories = MediaCategories.removing(category.name, from: current) }
    }
}

/// A category's icon: a logo drawn in the text color, or a symbol.
struct MediaCategoryIconView: View {
    let icon: String
    var size: CGFloat = 16

    var body: some View {
        if let asset = MediaCategoryIcon.logoAsset(icon) {
            Image(asset)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil ? "folder" : icon)
        }
    }
}

/// New Category… and Edit Category…: a name and an icon.
struct MediaCategoryEditor: View {
    let model: AppModel
    /// The category being edited; nil makes a new one.
    let editing: MediaCategoryDefinition?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var icon = MediaCategoryIcon.defaultChoice

    private var choices: [String] {
        MediaCategoryIcon.choices.filter {
            MediaCategoryIcon.logoAsset($0) != nil || NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
        }
    }

    private var problem: MediaCategories.NameProblem? {
        MediaCategories.problem(with: name, in: model.mediaCategories, renaming: editing?.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "New Category" : "Edit Category")
                .font(.title3.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            if let problem, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(problem.message).font(.callout).foregroundStyle(.red)
            }
            Text("Icon").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 8), spacing: 6) {
                ForEach(choices, id: \.self) { choice in
                    Button {
                        icon = choice
                    } label: {
                        MediaCategoryIconView(icon: choice, size: 20)
                            .font(.system(size: 17))
                            .frame(width: 34, height: 34)
                            .background(
                                icon == choice ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06),
                                in: RoundedRectangle.standard(CornerStandard.element))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Self.label(for: choice))
                }
            }
            if let editing, MediaCategories.cleanName(name) != editing.name, problem == nil {
                Text("Everything in \u{201C}\(editing.name)\u{201D} moves with it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Create" : "Save") {
                    if let editing {
                        model.editMediaCategory(editing, name: name, icon: icon)
                    } else {
                        model.addMediaCategory(name: name, icon: icon)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            name = editing?.name ?? ""
            icon = editing?.icon ?? MediaCategoryIcon.defaultChoice
        }
    }

    private static func label(for icon: String) -> String {
        switch icon {
        case MediaCategoryIcon.studentsLogo: "Hope Students logo"
        case MediaCategoryIcon.hopeLogo: "Hope logo"
        default: icon
        }
    }
}
