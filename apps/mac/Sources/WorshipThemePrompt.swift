import PresenterCore
import SwiftUI

/// Right-click a song's slide › Make This the Worship Theme…: the slide's
/// look becomes the theme every new song is built in, Sunday or Wednesday
/// (the lyrics theme), and optionally every song in the library now. See
/// WorshipThemeFromSlide.
extension AppModel {
    /// The theme the slide follows, while it's in the library.
    func followedWorshipTheme(of slide: Slide, in presentation: Presentation) -> String? {
        WorshipThemeFromSlide.followedTheme(of: slide, in: presentation).flatMap { libraryEntry($0) != nil ? $0 : nil }
    }

    /// Makes the slide's look the lyrics theme: the theme it follows, else a
    /// new theme drawn from it. With `everySong`, every song's slides that
    /// follow a theme switch to it too (slides with a look of their own keep
    /// it). Returns the theme's name.
    @discardableResult
    func makeWorshipTheme(from slide: Slide, in presentation: Presentation, everySong: Bool) async -> String? {
        var themeID = followedWorshipTheme(of: slide, in: presentation)
        if themeID == nil {
            let taken = Set(entries(of: .theme).map { $0.name.lowercased() })
            var name = WorshipThemeFromSlide.defaultName
            var number = 2
            while taken.contains(name.lowercased()) {
                name = "\(WorshipThemeFromSlide.defaultName) \(number)"
                number += 1
            }
            let theme = WorshipThemeFromSlide.theme(from: slide, in: presentation, id: UUID().uuidString, name: name)
            guard (try? await createInDrive(theme).value) != nil else { return nil }
            themeID = theme.id
        }
        guard let themeID else { return nil }
        updateSlideBuilding { $0.lyricsImportThemeId = themeID }
        if everySong {
            let songs = await presentationsFilled(entries(of: .presentation).map(\.id))
            for song in songs.values where song.presentationKind == .song && song.themeId != themeID {
                applyTheme(to: song.id, themeID: themeID)
            }
        }
        DiagnosticsStore.shared.note("worshipTheme.chosen", detail: "\(themeID) every song: \(everySong)")
        return libraryEntry(themeID)?.name
    }
}

/// The question Make This the Worship Theme… asks, and what it says after.
struct WorshipThemePrompt: ViewModifier {
    let model: AppModel
    let presentation: Presentation
    @Binding var slide: Slide?
    @State private var done: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Make this the worship theme?",
                isPresented: Binding(get: { slide != nil }, set: { if !$0 { slide = nil } }),
                titleVisibility: .visible
            ) {
                Button("Use for New Songs") { choose(everySong: false) }
                Button("Use for Every Song") { choose(everySong: true) }
                Button("Cancel", role: .cancel) { slide = nil }
            } message: {
                Text(message)
            }
            .alert(
                "Worship theme set",
                isPresented: Binding(get: { done != nil }, set: { if !$0 { done = nil } })
            ) {
                Button("OK") { done = nil }
            } message: {
                Text("Songs are built in \u{201C}\(done ?? "")\u{201D} on Sundays and Wednesdays. Change it in Theme Editor \u{203A} \(done ?? "").")
            }
    }

    private var message: String {
        if let slide, let theme = model.followedWorshipTheme(of: slide, in: presentation),
           let name = model.libraryEntry(theme)?.name {
            return "This slide uses the \u{201C}\(name)\u{201D} theme. Every new song, Sunday or Wednesday, will be built in it. Every Song also switches the songs already in the library; slides with a look of their own keep it."
        }
        return "Screens makes a theme from how this slide's lyrics are shown (box, font, size, color; not the background), named \(WorshipThemeFromSlide.defaultName), and every new song, Sunday or Wednesday, is built in it. Every Song also switches the songs already in the library; slides with a look of their own keep it."
    }

    private func choose(everySong: Bool) {
        guard let picked = slide else { return }
        slide = nil
        Task { @MainActor in
            done = await model.makeWorshipTheme(from: picked, in: presentation, everySong: everySong)
        }
    }
}
