import Foundation
import PresenterCore

/// A library song from a Shepherd song, with this Mac's lyrics settings and
/// lyrics theme (see ShepherdSongImport for how it is built).
enum SongImport {
    @MainActor
    static func presentation(
        song: ShepherdClient.SongDetail, arrangement: ShepherdClient.SongArrangement?,
        playingKey: String?, model: AppModel
    ) -> Presentation? {
        ShepherdSongImport.presentation(
            song: song, arrangement: arrangement,
            options: ShepherdSync.shared.importOptions(playingKey: playingKey, model: model))
    }

    static func hasText(song: ShepherdClient.SongDetail?, arrangement: ShepherdClient.SongArrangement?) -> Bool {
        ShepherdSongImport.hasText(song: song, arrangement: arrangement)
    }
}
