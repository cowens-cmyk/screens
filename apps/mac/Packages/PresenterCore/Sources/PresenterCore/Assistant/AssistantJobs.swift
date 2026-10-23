import Foundation

/// The one-click jobs at the top of the Assistant panel. Each is a message
/// sent as if the user typed it: the model still decides the order of the
/// steps and reads before it changes anything; the tools keep it safe.
/// Kept here rather than in the app so the wording can be tested.
public enum AssistantJob: Equatable, Sendable, Identifiable {
    case updatePreService
    case announcementsFromCards
    case buildSunday
    /// One song by name, or every song in the next plan when nil.
    case checkSongLyrics(song: String?)

    public var id: String {
        switch self {
        case .updatePreService: "updatePreService"
        case .announcementsFromCards: "announcementsFromCards"
        case .buildSunday: "buildSunday"
        case .checkSongLyrics(let song): "checkSongLyrics:\(song ?? "")"
        }
    }

    public var title: String {
        switch self {
        case .updatePreService: "Update pre-service slides"
        case .announcementsFromCards: "Build announcements from a card…"
        case .buildSunday: "Build Sunday"
        case .checkSongLyrics: "Check song lyrics"
        }
    }

    public var systemImage: String {
        switch self {
        case .updatePreService: "calendar.badge.clock"
        case .announcementsFromCards: "photo.on.rectangle"
        case .buildSunday: "checklist"
        case .checkSongLyrics: "music.note.list"
        }
    }

    public var instruction: String {
        switch self {
        case .updatePreService:
            """
            Update the pre-service slides. Find the pre-service slideshow: a presentation whose name, folder or \
            type contains "Pre-Service" or "Pre Service" (it auto-advances). If there is more than one, ask me which. \
            Match its slides against the church's events on hopejc.org and remove the promo slides for events \
            that have already ended. Ask me about any slide you are not sure of instead of deleting it. Then tell \
            me what you removed, what is still current, and which upcoming events have no slide yet.
            """
        case .announcementsFromCards:
            """
            Build announcement slides from the attached cards: one slide per card, with the card as the \
            full-slide background and the event title as the slide name, in the Announcements presentation \
            (create it if there isn't one). If I haven't said what the livestream should show for these \
            slides, ask me before adding them: Theme Default, Lower Third, Full Screen or Nothing.
            """
        case .buildSunday:
            Self.buildSundayInstruction
        case .checkSongLyrics(let song):
            Self.checkLyricsInstruction(song: song)
        }
    }

    /// Steps that only read or add go ahead; everything that replaces or
    /// removes is gathered into one apply_sunday_setup call, so the user
    /// approves a single summary. Run twice, it only fills in what's left.
    static let buildSundayInstruction = """
    Build Sunday: get the next upcoming plan ready, then show me one summary to approve.

    1. Call sync_shepherd, then check_service_readiness without a plan_id to find the next upcoming plan. Say which \
    plan you're preparing.
    2. Songs: if any planned song has no slides, call import_songs_from_shepherd for the plan. Name the songs that \
    still have none; they need Get Lyrics (SongSelect) in the plan.
    3. Message: if the plan has no message slides, check its series. If no series is selected, ask me which one \
    (list_themes marks the sermon series). If I attached the message notes PDF, call build_message_from_notes with \
    it; if not, ask me to attach it with the paperclip and wait. If I say the notes aren't ready, carry on and mark \
    the message as still to do.
    4. Pre-service: run match_slides_to_events on the pre-service slideshow that check_service_readiness names, and \
    note the promos for events that have ended. Don't delete them yet.
    5. Countdown: if the countdown has no video, use the suggested one (the newest in Media › Countdowns that \
    wasn't used last week).
    6. Scheduling: if no countdowns are scheduled for the plan, use the proposed service times.
    7. Call apply_sunday_setup once with whatever from steps 3 to 6 still needs changing: the countdown video, the \
    service times, the series and the pre-service slides to remove. It shows me one summary to approve. Leave out \
    anything already done; skip the call if nothing is left.
    8. Finish with a short "Ready for Sunday" checklist: one line each for Songs, Message, Pre-service, Countdown \
    and Schedule, starting with ✓ when it's done or ⚠ with what's left.

    Syncing, importing songs and building a first message add things and don't need my approval; replacing a \
    message or changing the plan's series asks me to approve it. Don't call delete_slides or schedule_service \
    separately during this job.
    """

    static func checkLyricsInstruction(song: String?) -> String {
        let which = song.map { name in
            "Check the lyrics on the slides for the song \"\(name.trimmingCharacters(in: .whitespacesAndNewlines))\". "
                + "Find it in the next upcoming plan, or in the library if it isn't planned, and call check_song_lyrics for it."
        } ?? "Check the lyrics on the slides for every song in the next upcoming plan: call check_song_lyrics with that plan's id."
        return which + " " + """
        The tool compares the slides with the song's lyrics in Shepherd and returns only the differences. For each \
        song, tell me briefly: misspellings, wrong, missing or extra words, missing or extra lines and sections, \
        whether the section order matches the plan's arrangement, and capitalization that isn't consistent. Quote \
        only the words that differ, never whole verses. Say plainly when a song matches. If a song isn't in \
        Shepherd, say so. When there are fixes, offer them; if I say yes, call apply_lyric_fixes, which asks me to \
        approve the exact changes.
        """
    }
}
