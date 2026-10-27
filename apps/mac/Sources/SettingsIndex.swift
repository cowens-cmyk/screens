import Foundation

/// One setting as search knows it: where it lives, what it is called, and
/// the words someone might type for it.
struct SettingsEntry: Identifiable, Hashable {
    let id: String
    let category: SettingsCategory
    var tab: IntegrationTab? = nil
    let title: String
    var caption: String? = nil
    var keywords: String = ""

    /// "Integrations › Anthem": where a search result lands.
    var breadcrumb: String {
        [category.title, tab?.title].compactMap { $0 }.joined(separator: " \u{203A} ")
    }

    var searchText: String {
        "\(title) \(caption ?? "") \(keywords) \(category.title) \(tab?.title ?? "")".lowercased()
    }
}

/// Every setting, in the order the panes show them. The panes read their
/// titles and captions from here (SettingsRow, SettingsToggle,
/// SettingsHeader), so search and the page never disagree, and each row
/// carries its id so a result can scroll to it.
enum SettingsIndex {

    static func entry(_ id: String) -> SettingsEntry? {
        byID[id]
    }

    /// Every word typed must appear somewhere in the entry.
    static func matching(_ query: String) -> [SettingsEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return all.filter { entry in
            let text = entry.searchText
            return words.allSatisfy(text.contains)
        }
    }

    private static let byID: [String: SettingsEntry] = Dictionary(
        all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    static let all: [SettingsEntry] = general + screens + livestream + stage + slides + bible
        + liveListening + media + integrations + keyboard + assistant + advanced

    // MARK: General

    private static let general: [SettingsEntry] = [
        SettingsEntry(
            id: "present.continuous", category: .general,
            title: "Show whole plan",
            caption: "Every item's slides on one page, in plan order; arrows advance across items. Also in the View menu.",
            keywords: "scroll run order single item continuous playlist present"),
        SettingsEntry(
            id: "present.layouts", category: .general,
            title: "Present layouts",
            caption: "Save and switch whole workspace arrangements: panels, sizes and windows.",
            keywords: "layout workspace arrangement save panels windows dock"),
        SettingsEntry(
            id: "present.runOnly", category: .general,
            title: "Simple Mode",
            caption: "The volunteer view: the plan, big slides, Back, Next and Clear All, with nothing that edits. Leaving asks for the passcode.",
            keywords: "simple mode run only volunteer lock passcode pin kiosk"),
        SettingsEntry(
            id: "general.runsService", category: .general,
            title: "Run on this Mac",
            caption: "Plays the scheduled countdowns and restarts the pre-service slides from this Mac. Other Macs skip them. Kept per Mac.",
            keywords: "service day countdown schedule pre-service preservice slideshow restart station walk-in"),
    ]

    // MARK: Screens

    private static let screens: [SettingsEntry] = [
        SettingsEntry(
            id: "screens.arrangement", category: .screens,
            title: "Displays",
            caption: "Drag Audience, Livestream or Stage onto a display, or click a display to choose.",
            keywords: "display arrangement monitor projector tv connected resolution refresh hz identify drag outputs screen configuration setup"),
        SettingsEntry(
            id: "screens.audience", category: .screens,
            title: "Audience",
            caption: ShowScreen.audience.summary,
            keywords: "audience room projector output display decklink ndi resolution 1080p 4k screen configuration"),
        SettingsEntry(
            id: "screens.livestream", category: .screens,
            title: "Livestream",
            caption: ShowScreen.livestream.summary,
            keywords: "livestream stream output camera decklink ndi resolution 1080p 4k screen configuration"),
        SettingsEntry(
            id: "screens.alphaKey", category: .screens,
            title: "Alpha key (transparent)",
            caption: "Fill and key for the switcher's keyer, from a DeckLink port.",
            keywords: "alpha key transparent fill external internal switcher keyer decklink sdi ndi luma black see-through"),
        SettingsEntry(
            id: "screens.stage", category: .screens,
            title: "Stage",
            caption: ShowScreen.stage.summary,
            keywords: "stage confidence monitor platform output display decklink ndi"),
        SettingsEntry(
            id: "screens.ndi", category: .screens,
            title: "Send over NDI",
            caption: "A screen sent over NDI shows up as a source on the network. NDI carries transparency on its own.",
            keywords: "ndi network output send source vmix obs tricaster"),
        SettingsEntry(
            id: "network.ndi", category: .screens,
            title: "NDI network",
            caption: "Pin NDI to the wired production network when this Mac also joins Wi-Fi. Applies at once; live feeds re-tune.",
            keywords: "ndi network interface adapter nic vlan ethernet wifi wired discovery pin bind"),
        SettingsEntry(
            id: "show.decklink", category: .screens,
            title: "Blackmagic DeckLink",
            caption: "Cards and UltraStudio devices are found on their own.",
            keywords: "decklink blackmagic sdi ultrastudio desktop video output card 8k duo quad driver"),
    ]

    // MARK: Livestream

    private static let livestream: [SettingsEntry] = [
        SettingsEntry(
            id: "show.streamMode", category: .livestream,
            title: "Livestream shows",
            caption: "Transparent: nothing over the camera. Lower Third: each slide in the lower third chosen for its type, or its presentation's or theme's own. Full Screen: the room's slide, edge to edge.",
            keywords: "livestream stream switch mode transparent lower third full screen camera overlay"),
        SettingsEntry(
            id: "show.typeScreens", category: .livestream,
            title: "Lower Thirds",
            caption: "The lower third shown on the livestream for each part of the service. Church-wide.",
            keywords: "lower third lower thirds theme worship message sermon scripture bible announcements livestream stream type default series song"),
    ]

    // MARK: Stage

    private static let stage: [SettingsEntry] = [
        SettingsEntry(
            id: "stage.mode", category: .stage,
            title: "Stage shows",
            caption: "Worship and Message are stage layouts. Audience Screen shows what the room sees.",
            keywords: "stage display confidence layout worship message audience mirror"),
        SettingsEntry(
            id: "stage.follows", category: .stage,
            title: "Follow what's live",
            caption: "Worship for songs, Message for the message. Off, the stage changes only when someone changes it.",
            keywords: "stage follow automatic switch layout song message"),
        SettingsEntry(
            id: "stage.videos", category: .stage,
            title: "Show videos on the stage",
            caption: "While a video plays, the stage shows it with the time left (the Video stage layout), then goes back. Off, the stage keeps its layout.",
            keywords: "stage video countdown time left remaining automatic switch layout"),
        SettingsEntry(
            id: "show.stageMessages", category: .stage,
            title: "Stage messages show for",
            caption: "Then the stage goes back to what it showed. Clear takes a message down sooner; sending another starts the time again.",
            keywords: "stage message seconds clear timeout duration booth"),
        SettingsEntry(
            id: "stage.sermonTimerReset", category: .stage,
            title: "Reset the sermon timer at each service's start",
            caption: "Back to the message's length when the countdown starts, or at the service time. Kept per Mac; only the Mac with Run on this Mac on does it.",
            keywords: "sermon timer reset service start countdown message length clock automatic"),
        SettingsEntry(
            id: "present.nextSkipsBlanks", category: .stage,
            title: "Confidence NEXT skips blank slides",
            caption: "NEXT shows the first upcoming slide that has text.",
            keywords: "confidence monitor next blank empty slide stage skip"),
        SettingsEntry(
            id: "present.types", category: .stage,
            title: "Presentation types",
            caption: "Default actions for each type, run when one goes live: stage layout and timers.",
            keywords: "presentation type category sermon worship bible announcement default action stage layout timer sermon timer"),
    ]

    // MARK: Slides & Themes

    private static let slides: [SettingsEntry] = [
        SettingsEntry(
            id: "present.slideTransition", category: .slides,
            title: "Slide transition",
            caption: "How the slide layer changes between slides. Cut is the lyrics-safe default.",
            keywords: "transition dissolve fade slide default cut lyrics"),
        SettingsEntry(
            id: "present.mediaTransition", category: .slides,
            title: "Media transition",
            caption: "How backgrounds and foreground media come in, and leave on Clear, unless the item sets its own.",
            keywords: "transition dissolve fade blur media default cut clear background foreground"),
        SettingsEntry(
            id: "present.defaultAnimations", category: .slides,
            title: "Default animations",
            caption: "What Apply Default In and Apply Default Out put on the timeline.",
            keywords: "animation default in out fade timeline animate steps"),
        SettingsEntry(
            id: "present.slidesAcross", category: .slides,
            title: "Slides across",
            caption: "Thumbnails per row in Present. Auto fits them to the window.",
            keywords: "slide grid columns across per row thumbnails size zoom auto automatic fit"),
        SettingsEntry(
            id: "present.roundedCorners", category: .slides,
            title: "Rounded thumbnail corners",
            keywords: "slide grid thumbnails corners"),
        SettingsEntry(
            id: "present.legibleText", category: .slides,
            title: "Readable thumbnail text",
            caption: "Boosts lyric legibility in thumbnails, never on the screens.",
            keywords: "slide grid lyrics legible text thumbnails"),
        SettingsEntry(
            id: "present.transparencyGrid", category: .slides,
            title: "Transparency grid in thumbnails",
            caption: "A checkerboard wherever lower layers would show through.",
            keywords: "transparency grid checkerboard alpha thumbnails photoshop"),
        SettingsEntry(
            id: "present.scopedBackgrounds", category: .slides,
            title: "Backgrounds only on declaring slide",
            caption: "Thumbnails after the declaring slide drop the shared background.",
            keywords: "slide grid backgrounds cue thumbnails"),
    ]

    // MARK: Bible

    private static let bible: [SettingsEntry] = [
        SettingsEntry(
            id: "bible.sources", category: .bible,
            title: "Bible translations",
            caption: "Where scripture text comes from. Scripture Slides (File menu) builds slides with your Bible template.",
            keywords: "bible scripture translation esv niv kjv nlt api verse passage key api.bible"),
        SettingsEntry(
            id: "bible.translation", category: .bible,
            title: "Default translation",
            keywords: "bible translation default esv niv kjv nlt refresh"),
        SettingsEntry(
            id: "bible.text", category: .bible,
            title: "Passage text",
            keywords: "bible line breaks verse numbers format passage"),
        SettingsEntry(
            id: "bible.themes", category: .bible,
            title: "Scripture and points themes",
            caption: "Used by the Scripture and Points buttons in the top bar.",
            keywords: "scripture bible points sermon theme default template"),
    ]

    // MARK: Live Listening

    private static let liveListening: [SettingsEntry] = [
        SettingsEntry(
            id: "show.liveAssist", category: .liveListening,
            title: "Live Assist",
            caption: "Start and stop listening, and see detected passages, in Window › Live Assist (⌥⌘L).",
            keywords: "live assist listen microphone input channel level speech"),
        SettingsEntry(
            id: "liveAssist.lyrics", category: .liveListening,
            title: "Advance lyrics as they're sung",
            caption: "Turn on Follow in a song's header. Off, Follow only outlines the next slide.",
            keywords: "live assist lyric following auto advance confidence follow"),
        SettingsEntry(
            id: "liveAssist.scripture", category: .liveListening,
            title: "Watch for spoken Bible references",
            keywords: "live assist scripture detection bible reference sermon"),
    ]

    // MARK: Media & Video

    private static let media: [SettingsEntry] = [
        SettingsEntry(
            id: "avInputs.cameras", category: .media,
            title: "Video inputs",
            caption: "Added inputs run warm from launch and appear in Live Input pickers.",
            keywords: "camera capture device uvc continuity blackmagic live input video ndi web page decklink"),
        SettingsEntry(
            id: "avInputs.audio", category: .media,
            title: "Audio inputs",
            caption: "Interfaces and board feeds, each with its device and channels.",
            keywords: "audio input microphone interface usb board feed sound source channels live assist delay"),
    ]

    // MARK: Integrations

    private static let integrations: [SettingsEntry] = [
        SettingsEntry(
            id: "anthem.link", category: .integrations, tab: .anthem,
            title: "Anthem",
            caption: "Anthem leads: the tracks change the slides, and each song's order follows Anthem's setlist.",
            keywords: "anthem tracks multitrack cue slides network propresenter band setlist arrangement order section match"),
        SettingsEntry(
            id: "anthem.midi", category: .integrations, tab: .anthem,
            title: "Anthem's MIDI",
            keywords: "anthem midi notes fallback next previous trigger"),
        SettingsEntry(
            id: "midi.lightkey", category: .integrations, tab: .lightkey,
            title: "Lightkey",
            keywords: "lightkey lighting dmx midi network rtp channel test note section verse chorus"),
        SettingsEntry(
            id: "midi.lightingCues", category: .integrations, tab: .lightkey,
            title: "Lighting cues",
            caption: "When a plan item goes live, Lightkey gets its position's note.",
            keywords: "lightkey lighting cue scene position walk-in countdown song message closing walkout baptism communion"),
        SettingsEntry(
            id: "midi.devices", category: .integrations, tab: .lightkey,
            title: "MIDI devices",
            caption: "Each can send, listen, or both. With none added, MIDI Out reaches every destination on this Mac.",
            keywords: "midi device destination source input output port note control change iac lighting console enable disable direction"),
        SettingsEntry(
            id: "midi.map", category: .integrations, tab: .lightkey,
            title: "MIDI input map",
            caption: "What incoming notes trigger. ProPresenter's numbers out of the box; every assignment is editable.",
            keywords: "midi input map note trigger command clear slide advance timer combo channel propresenter playlist media alert message select index"),
        SettingsEntry(
            id: "shepherd.sync", category: .integrations, tab: .shepherd,
            title: "Shepherd",
            caption: "Upcoming Sunday plans from Shepherd become services. Songs link to presentations already in the library.",
            keywords: "shepherd hope plan sunday service sync song flag api key"),
        SettingsEntry(
            id: "shepherd.songs", category: .integrations, tab: .shepherd,
            title: "Import lyrics and chords from Shepherd",
            caption: "Planned songs with no slides get them from Shepherd's chord chart; imported songs follow chart changes unless edited in Screens.",
            keywords: "shepherd song lyrics chords chord chart import automatic update newer arrangement key"),
        SettingsEntry(
            id: "lyrics.punctuation", category: .integrations, tab: .shepherd,
            title: "Remove punctuation from imported lyrics",
            caption: "Commas, periods, quotes and dashes come out of every lyrics import. Songs already in the library don't change.",
            keywords: "punctuation comma period lyrics import songselect paste chord chart clean"),
        SettingsEntry(
            id: "website.events", category: .integrations, tab: .website,
            title: "Add events from hopejc.org to the pre-service announcements",
            caption: "Each church event's picture goes in the pre-service slideshow, full screen, and comes out when the event starts. Every Mac keeps them up to date.",
            keywords: "website hopejc events calendar announcements pre-service preservice slideshow loop promo automatic cms"),
        SettingsEntry(
            id: "website.window", category: .integrations, tab: .website,
            title: "Show events starting within",
            keywords: "website events days month window ahead before"),
        SettingsEntry(
            id: "website.removeAt", category: .integrations, tab: .website,
            title: "Take down",
            caption: "When it ends keeps an event that runs several days up until its last day is over.",
            keywords: "website events remove take down start end multi-day"),
        SettingsEntry(
            id: "website.sync", category: .integrations, tab: .website,
            title: "Sync",
            caption: "hopejc.org is read every 30 minutes and slides come and go on time.",
            keywords: "website events sync now refresh update"),
        SettingsEntry(
            id: "website.list", category: .integrations, tab: .website,
            title: "Events",
            caption: "The events in the slideshow now. Don't show leaves an event out, and every later one with the same name.",
            keywords: "website events list hide don't show included"),
        SettingsEntry(
            id: "api.enabled", category: .integrations, tab: .remote,
            title: "Local API",
            caption: "Serves the REST and WebSocket API on this Mac and announces it on the local network.",
            keywords: "api rest websocket http server remote companion stream deck automation bonjour"),
        SettingsEntry(
            id: "api.port", category: .integrations, tab: .remote,
            title: "Port",
            caption: "Changing the port restarts the server.",
            keywords: "api port number network"),
        SettingsEntry(
            id: "api.address", category: .integrations, tab: .remote,
            title: "Connect at",
            caption: "Open http://this address/ in Safari or Chrome on the same Wi-Fi. Companion and Stream Deck use it too.",
            keywords: "api address ip port connect companion stream deck remote host default key"),
        SettingsEntry(
            id: "api.remote", category: .integrations, tab: .remote,
            title: "Phone remote",
            caption: "Scan with a phone or iPad on the same Wi-Fi to open the remote.",
            keywords: "remote phone iphone ipad qr code scan pastor worship leader booth message home screen"),
        SettingsEntry(
            id: "api.tokens", category: .integrations, tab: .remote,
            title: "Access keys",
            caption: "Required: nothing connects without one. Each key grants Watch, Operate or Manage.",
            keywords: "api tokens keys auth bearer secret scope watch operate manage revoke password required"),
        SettingsEntry(
            id: "api.docs", category: .integrations, tab: .remote,
            title: "API reference",
            caption: "Every endpoint with examples, served by this Mac.",
            keywords: "api reference docs documentation openapi explorer examples endpoints developer"),
    ]

    // MARK: Keyboard

    private static let keyboard: [SettingsEntry] = [
        SettingsEntry(
            id: "keyboard.shortcuts", category: .keyboard,
            title: "Keyboard shortcuts",
            caption: "Every command's keys, combos, timers, group hot keys and Settings pages.",
            keywords: "keyboard shortcut key binding hot key chord function f-key combo group conflicts"),
    ]

    // MARK: Assistant

    private static let assistant: [SettingsEntry] = [
        SettingsEntry(
            id: "api.assistant", category: .assistant,
            title: "Anthropic API key",
            caption: "From console.anthropic.com › API Keys. The Assistant, sermon import and series design use it.",
            keywords: "assistant claude anthropic api key ai chat"),
        SettingsEntry(
            id: "assistant.model", category: .assistant,
            title: "Model",
            keywords: "assistant claude model opus sonnet faster"),
        SettingsEntry(
            id: "bible.sermon", category: .assistant,
            title: "Sermon import",
            caption: "Claude reads the week's notes (PDF or Pages) and builds the message slides with the series theme.",
            keywords: "sermon notes import claude series theme message slides pdf pages new sermon series"),
    ]

    // MARK: Advanced

    private static let advanced: [SettingsEntry] = [
        SettingsEntry(
            id: "advanced.updates", category: .advanced,
            title: "Check for updates automatically",
            caption: "At launch and every six hours.",
            keywords: "update updates version release download install automatic"),
        SettingsEntry(
            id: "advanced.diagnostics", category: .advanced,
            title: "Diagnostics",
            caption: "The app's log of what it did, for tracking down a problem.",
            keywords: "diagnostics log logs debug support problem folder finder"),
        SettingsEntry(
            id: "advanced.panelMotion", category: .advanced,
            title: "Measure panel motion",
            caption: "Each time the plan or the screens open or fold, the log notes how many frames came late.",
            keywords: "diagnostics animation smooth laggy stutter frames hitch panel bubble strip performance"),
    ]
}
