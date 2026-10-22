import Foundation
import PresenterCore

/// A library song from a Shepherd song: its chord chart (ChordPro, with
/// chords and sections) or lyrics, ordered by the arrangement's sequence.
enum SongImport {
    static func presentation(
        song: ShepherdClient.SongDetail, arrangement: ShepherdClient.SongArrangement?,
        playingKey: String?, themeId: String
    ) -> Presentation? {
        let chart = [arrangement?.chordChart, song.chordChart]
            .compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard var presentation = SongAssembly.presentation(
            lyrics: song.lyrics, chordChart: chart, title: song.title, themeId: themeId)
        else { return nil }
        presentation.presentationKind = .song
        presentation.category = PresentationTypes.worship
        if presentation.musicKey == nil { presentation.musicKey = song.defaultKey }
        if let playingKey, let musicKey = presentation.musicKey,
           let display = ChordMath.displayKey(playing: playingKey, musicKey: musicKey),
           display.caseInsensitiveCompare(musicKey) != .orderedSame {
            presentation.displayKey = display
        }
        var ccli = presentation.ccli ?? CCLIInfo()
        ccli.songNumber = ccli.songNumber ?? song.ccliNumber.flatMap(Int.init)
        ccli.songTitle = ccli.songTitle ?? song.title
        ccli.author = ccli.author ?? song.author
        ccli.copyright = ccli.copyright ?? song.copyright
        presentation.ccli = ccli
        let sequence = arrangement?.sequence.isEmpty == false ? arrangement!.sequence : song.sequence
        if let sections = presentation.sections,
           let order = PlanItemSync.arrangement(
               named: arrangement?.name ?? "Default", sequence: sequence, sections: sections) {
            presentation.arrangements = (presentation.arrangements ?? []) + [order]
            presentation.defaultArrangementId = order.id
        }
        return presentation
    }

    static func hasText(song: ShepherdClient.SongDetail?, arrangement: ShepherdClient.SongArrangement?) -> Bool {
        [arrangement?.chordChart, song?.chordChart, song?.lyrics].contains {
            !($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
