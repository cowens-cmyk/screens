import Foundation
import LocalAPI
import PresenterCore

/// The Local API's MCP server (POST /mcp): Claude, in Claude Code or Claude
/// Desktop, builds presentations with the same tools as the in-app Assistant,
/// plus the ones that make a Sunday's slides from what Claude has read —
/// a song from its chart, the order it's sung in, the message from an
/// outline, and what the stage display shows.
///
/// The Assistant's tools that ask the user before they replace or remove
/// something ask through Claude here: the first call answers with what
/// would change, and Claude calls again with confirm true once the user has
/// said yes.
@MainActor
final class ScreensMCP {
    private let model: AppModel
    private let toolbox: AssistantToolbox
    /// Lets a change to a live slide (its lower third, its stage layout)
    /// show at once, as it does from the in-app Assistant.
    private weak var router: ActionRouter?
    /// Files Claude handed over with attach_file, by path, as the
    /// Assistant's attachment ids.
    private var attachedPaths: [String: [String]] = [:]

    init(model: AppModel, router: ActionRouter?) {
        self.model = model
        self.router = router
        self.toolbox = AssistantToolbox(model: model, router: router)
    }

    nonisolated static let instructions = """
    Screens is Hope Church's presentation app. Its library (plans, songs, decks, themes, media) is shared by every \
    Mac linked to the church library and the browser editor, so changes made here reach them all.

    A Sunday: list_plans or check_service_readiness finds the plan. Songs: import_songs_from_shepherd links or \
    imports every planned song from Shepherd (its chord chart is the master: words, chords and sequence). For a song \
    Shepherd doesn't have, or to rebuild one from a chart you were given, use build_song; set_song_sequence sets the \
    order it is sung in. The message: read the pastor's notes yourself and give the outline to \
    build_message_from_outline (title, point, scripture and point_scripture slides, laid out by the sermon series \
    theme, with verses looked up). Lower thirds: set_slide_livestream (lower_third uses the theme's lower third; \
    lower_third_image_id a picture from import_media). Stage display: set_stage_display; a song's chords and lyrics \
    show on the Lyrics and chords stage display by themselves. get_stage_and_stream shows what each plan item does \
    to the stage display and the livestream.

    Tools that replace or remove something answer first with what would change; ask the user, then call again \
    with confirm true. Never set confirm true without the user's yes.
    """

    /// The tools that read a file on this Mac, which Claude through the CMS
    /// can't hand over: pictures for lower thirds go in through the browser
    /// editor there instead.
    private static let localFiles: Set<String> = [
        "attach_file", "import_media", "build_message_from_notes", "import_announcement_cards",
    ]

    /// `remote`: for Claude through the CMS (ClaudeRelay) rather than on this
    /// Mac's Local API.
    func server(version: String, remote: Bool = false) -> MCPServer {
        var tools = AssistantToolCatalog.all.map(assistantTool)
        tools += [attachFile, importMedia, buildSong, setSongSequence, buildMessageFromOutline,
                  setStageDisplay, listStageLayouts, setSlideNotes, stageAndStream]
        var instructions = Self.instructions
        if remote {
            tools.removeAll { Self.localFiles.contains($0.name) }
            instructions += "\n\nThis connection comes through the church's CMS, so files on the Mac can't be attached. "
                + "Pictures and lower-third PNGs are added in the CMS (Sunday › Screens, a presentation's Add pictures or videos); "
                + "list_media then finds them."
        }
        return MCPServer(name: "screens", version: version, instructions: instructions, tools: tools)
    }

    // MARK: The Assistant's tools

    private static let readOnly: Set<String> = [
        "list_plans", "get_plan", "list_presentations", "get_presentation", "search_slides", "list_media",
        "list_themes", "fetch_church_events", "match_slides_to_events", "check_service_readiness", "check_song_lyrics",
    ]

    private func assistantTool(_ spec: AssistantToolSpec) -> MCPTool {
        let asks = spec.needsConfirmation || spec.confirmsWhenReplacing
        var schema = Self.json(spec.schema)
        var description = spec.description
            .replacingOccurrences(of: "The user must approve first.", with: "The user must say yes first (confirm).")
            .replacingOccurrences(of: "the app asks them to approve", with: "then pass confirm true")
        if asks {
            schema = Self.adding(confirm: schema)
            description += " Without confirm true, nothing changes and the answer says what would; ask the user, then call again with confirm true."
        }
        if spec.name == "build_message_from_notes" || spec.name == "import_announcement_cards" {
            description += " Over MCP, attach the file with attach_file first; it answers with the attachment ids."
        }
        let name = spec.name
        let scope: APIScope = Self.readOnly.contains(name) ? .view : .edit
        return MCPTool(
            name: name, title: Self.title(name), description: description, inputSchema: schema,
            scope: scope, readOnly: scope == .view
        ) { [weak self] arguments in
            guard let self else { throw MCPToolError("Screens is closing.") }
            return try await self.runAssistant(spec, arguments: arguments)
        }
    }

    private func runAssistant(_ spec: AssistantToolSpec, arguments: JSONValue) async throws -> MCPToolResult {
        let name = spec.name
        var input = try Self.assistant(arguments)
        let confirmed = input["confirm"]?.bool == true
        if case .object(var fields) = input {
            fields["confirm"] = nil
            input = .object(fields)
        }
        // Checked as the in-app Assistant checks it: the tools trust their
        // schema's bounds (a negative limit would stop the app).
        if let problem = AssistantToolInput.validate(input, against: spec.schema) {
            throw MCPToolError("Invalid input: \(problem).")
        }
        // The confirmation runs even with confirm true: some calls are
        // refused there and nowhere else (deleting every slide, removing a
        // plan item Shepherd would put back).
        var ask: (title: String, detail: String)?
        do {
            if spec.needsConfirmation {
                ask = try await toolbox.confirmation(for: name, input: input)
            } else if spec.confirmsWhenReplacing {
                ask = try await toolbox.replacingConfirmation(for: name, input: input)
            }
        } catch let failure as AssistantToolbox.Failure {
            throw MCPToolError(failure.message)
        }
        if let ask, !confirmed {
            return MCPToolResult(
                text: "Nothing changed yet. Ask the user: \(ask.title)\n\(ask.detail)\n\nIf they say yes, call \(name) again with the same input and confirm true.",
                structured: ["needs_confirmation": true, "title": .string(ask.title), "detail": .string(ask.detail)])
        }
        let outcome = await toolbox.run(name, input: input)
        let structured = (try? AssistantJSON.parse(outcome.content)).flatMap { value -> JSONValue? in
            guard case .object = value else { return nil }
            return Self.json(value)
        }
        let text = [outcome.activity, outcome.content].compactMap { $0 }.joined(separator: "\n\n")
        return MCPToolResult(text: text, structured: outcome.isError ? nil : structured, isError: outcome.isError)
    }

    // MARK: Files

    private var attachFile: MCPTool {
        MCPTool(
            name: "attach_file", title: "Attach a file",
            description: "Hands a file on this Mac (PDF, JPEG, PNG or HEIC) to the tools that take attachment ids: "
                + "build_message_from_notes (the notes PDF) and import_announcement_cards (card pictures). Returns one "
                + "attachment id per picture or PDF page. Give an absolute path.",
            inputSchema: Self.object(["path": Self.string("Absolute path to the file.")], required: ["path"]),
            scope: .edit
        ) { [weak self] arguments in
            guard let self else { throw MCPToolError("Screens is closing.") }
            let url = try Self.file(arguments["path"]?.stringValue)
            if let ids = self.attachedPaths[url.path] {
                return .json(["attachment_ids": ids], summary: "Already attached.")
            }
            let first = self.toolbox.attachments.count + 1
            let made = await AssistantAttachments.prepare([url], startingAt: first)
            guard !made.isEmpty else { throw MCPToolError("Couldn't read \(url.lastPathComponent). PDF, JPEG, PNG or HEIC.") }
            for attachment in made { self.toolbox.attachments[attachment.id] = attachment }
            self.attachedPaths[url.path] = made.map(\.id)
            return .json(["attachment_ids": made.map(\.id), "labels": made.map(\.label)],
                         summary: "Attached \(url.lastPathComponent).")
        }
    }

    private var importMedia: MCPTool {
        MCPTool(
            name: "import_media", title: "Import pictures and videos",
            description: "Imports pictures or videos on this Mac into the Media library, as dragging them in does, and "
                + "returns their media ids. Use the ids as slide backgrounds (create_presentation, add_slides, "
                + "set_slide_background) or as a slide's lower-third picture (set_slide_livestream with "
                + "lower_third_image_id; a transparent PNG). A file already in Media is used again.",
            inputSchema: Self.object(["paths": Self.strings("Absolute paths of the files.")], required: ["paths"]),
            scope: .edit
        ) { [weak self] arguments in
            guard let self else { throw MCPToolError("Screens is closing.") }
            let urls = try (arguments["paths"]?.arrayValue ?? []).map { try Self.file($0.stringValue) }
            guard !urls.isEmpty else { throw MCPToolError("Give at least one path.") }
            let ids = await self.model.importFiles(urls)
            await self.model.resident.ready([.media])
            let rows: [[String: String]] = ids.map { id in
                let media = self.model.media(id)
                return ["media_id": id, "name": media?.name ?? "", "kind": media?.mediaKind.rawValue ?? ""]
            }
            guard !rows.isEmpty else { throw MCPToolError("Nothing was imported. Pictures and videos only.") }
            return .json(["media": rows], summary: "Imported \(rows.count) of \(urls.count).")
        }
    }

    // MARK: Songs

    private var buildSong: MCPTool {
        MCPTool(
            name: "build_song", title: "Build a song",
            description: "Makes a song presentation the way Screens imports one from Shepherd: lyric slides by section, "
                + "chords kept for the Lyrics and chords stage display, the key, and the sequence as the song's order. "
                + "From shepherd_song_id (Shepherd's chart, linked so it follows chart changes), or from chart: ChordPro "
                + "([G]words, {title:}, section labels like Verse 1 / Chorus on their own line), chords over lyrics, or "
                + "plain lyrics with section labels. With presentation_id the song is rebuilt in place: its id, theme, "
                + "backgrounds and other orders stay, so plans keep working. With plan_id and item_id the plan item "
                + "plays it, in this sequence.",
            inputSchema: Self.object([
                "title": Self.string("Song title. Required with chart."),
                "chart": Self.string("The words and chords."),
                "shepherd_song_id": Self.string("Build from this Shepherd song's chart instead (Shepherd's search_songs gives ids)."),
                "shepherd_arrangement_id": Self.string("The Shepherd arrangement whose chart and sequence to use; default the song's default."),
                "sequence": Self.strings("Section names in the order sung, e.g. [\"Verse 1\", \"Chorus\", \"Verse 2\", \"Chorus\", \"Bridge\", \"Chorus x2\"]."),
                "key": Self.string("The key the chart is written in, e.g. G."),
                "playing_key": Self.string("The key the band plays it in, when different; the stage display shows chords in it."),
                "theme_id": Self.string("Theme for the slides (list_themes); default the lyrics theme set in Screens."),
                "lines_per_slide": ["type": "integer", "minimum": 1, "maximum": 8, "description": "Lines per slide. Default 2."],
                "author": Self.string("Writers, for the CCLI line."),
                "ccli_number": Self.string("CCLI song number."),
                "copyright": Self.string("Copyright line."),
                "presentation_id": Self.string("Rebuild this existing song instead of making a new one."),
                "plan_id": Self.string("Plan to use it in."),
                "item_id": Self.string("The plan item (get_plan) that plays it. With plan_id and no item_id it is added at the end."),
            ]),
            scope: .edit
        ) { [weak self] arguments in
            guard let self else { throw MCPToolError("Screens is closing.") }
            return try await self.buildSong(arguments)
        }
    }

    private func buildSong(_ args: JSONValue) async throws -> MCPToolResult {
        let lines = args["lines_per_slide"]?.intValue
        let playing = Self.nonEmpty(args["playing_key"]?.stringValue)
        // Slides are split to fit the theme the song is shown in: the one
        // asked for, else the song's own when it replaces one, else the
        // lyrics import theme.
        await model.resident.ready([.theme])
        var showingTheme: String?
        if let theme = Self.nonEmpty(args["theme_id"]?.stringValue) {
            await model.themesFilled([theme])
            guard model.theme(theme) != nil else { throw MCPToolError("No theme \(theme). list_themes gives the ids.") }
            showingTheme = theme
        } else if let existingID = Self.nonEmpty(args["presentation_id"]?.stringValue) {
            showingTheme = (try? await toolbox.presentation(existingID))?.themeId
        }
        var options = ShepherdSync.shared.importOptions(playingKey: playing, model: model, themeId: showingTheme)
        if let lines { options.linesPerSlide = max(1, min(8, lines)) }

        var built: Presentation
        if let songID = Self.nonEmpty(args["shepherd_song_id"]?.stringValue) {
            guard ShepherdSync.shared.isConfigured else {
                throw MCPToolError("Shepherd isn't set up on this Mac (Settings › Integrations › Shepherd). Give the chart instead.")
            }
            let song = try await ShepherdSync.shared.client.song(id: songID)
            let arrangement = ShepherdSongImport.trackedArrangement(of: song, id: Self.nonEmpty(args["shepherd_arrangement_id"]?.stringValue))
            guard let made = ShepherdSongImport.presentation(song: song, arrangement: arrangement, options: options) else {
                throw MCPToolError("\(song.title) has no chart or lyrics in Shepherd.")
            }
            built = made
        } else {
            guard let title = Self.nonEmpty(args["title"]?.stringValue) else { throw MCPToolError("Give the song a title.") }
            guard let chart = Self.nonEmpty(args["chart"]?.stringValue) else {
                throw MCPToolError("Give the chart (or shepherd_song_id).")
            }
            let source = chart.contains("[") || chart.contains("{") ? chart : ChordChartImport.chordPro(fromChart: chart)
            let song = ShepherdClient.SongDetail(
                id: "", title: title, author: Self.nonEmpty(args["author"]?.stringValue),
                ccliNumber: Self.nonEmpty(args["ccli_number"]?.stringValue),
                copyright: Self.nonEmpty(args["copyright"]?.stringValue),
                defaultKey: Self.nonEmpty(args["key"]?.stringValue), chordChart: source,
                chart: ShepherdClient.ChartInfo(writtenKey: Self.nonEmpty(args["key"]?.stringValue)))
            guard var made = ShepherdSongImport.presentation(song: song, arrangement: nil, options: options) else {
                throw MCPToolError("No words found in the chart.")
            }
            // Not a Shepherd song: plan sync must never refresh it from there.
            made.shepherdSongId = nil
            made.shepherdArrangementId = nil
            made.shepherdChartHash = nil
            made.shepherdImportHash = nil
            if var order = made.arrangements?.first {
                order.id = UUID().uuidString
                order.name = "Chart"
                order.shepherdArrangementId = nil
                made.arrangements = [order]
                made.defaultArrangementId = order.id
            }
            built = made
        }

        var warnings: [String] = []
        if let sequence = args["sequence"]?.arrayValue?.compactMap(\.stringValue), !sequence.isEmpty {
            let mapping = ShepherdArrangementSync.mapping(sequence: sequence, onto: built)
            if mapping.sectionIds.isEmpty {
                throw MCPToolError("None of the sequence matches the song's sections: \(Self.sectionNames(built)).")
            }
            warnings += mapping.missing.map { "No section \"\($0)\" (sections: \(Self.sectionNames(built)))." }
            let order = Arrangement(id: UUID().uuidString, name: "Sequence", sectionIds: mapping.sectionIds)
            built.arrangements = [order] + (built.arrangements ?? [])
            built.defaultArrangementId = order.id
        }

        let id: String
        if let existingID = Self.nonEmpty(args["presentation_id"]?.stringValue) {
            let existing = try await toolbox.presentation(existingID)
            guard existing.presentationKind == .song else { throw MCPToolError("\(existing.name) isn't a song.") }
            var fresh = ShepherdSongImport.replacing(existing, with: built)
            if built.shepherdSongId == nil {
                fresh.shepherdSongId = nil
                fresh.shepherdChartHash = nil
                fresh.shepherdImportHash = nil
            }
            fresh.name = built.name
            fresh.defaultArrangementId = built.defaultArrangementId
            let final = fresh
            _ = try await model.updatePresentation(existingID) { $0 = final }.value
            id = existingID
            built = final
        } else {
            _ = try await model.createInDrive(built).value
            id = built.id
        }

        var planNote: String?
        if let planID = Self.nonEmpty(args["plan_id"]?.stringValue) {
            planNote = try await use(id, in: planID, itemID: Self.nonEmpty(args["item_id"]?.stringValue),
                                     arrangementID: built.defaultArrangementId, name: built.name)
        }
        let order = built.arrangements?.first { $0.id == built.defaultArrangementId }
        let names = Dictionary(uniqueKeysWithValues: (built.sections ?? []).map { ($0.id, $0.name) })
        var result: [String: JSONValue] = [
            "presentation_id": .string(id), "name": .string(built.name), "slides": .integer(built.slides.count),
            "sections": .array((built.sections ?? []).map { .string($0.name) }),
            "sequence": .array((order?.sectionIds ?? []).map { .string(names[$0] ?? "?") }),
            "has_chords": .bool(built.slides.contains { $0.objects.contains { !($0.chords ?? []).isEmpty } }),
        ]
        if let key = built.musicKey { result["key"] = .string(key) }
        if let key = built.displayKey { result["stage_key"] = .string(key) }
        if !warnings.isEmpty { result["warnings"] = .array(warnings.map(JSONValue.string)) }
        if let planNote { result["plan"] = .string(planNote) }
        return MCPToolResult(text: Self.text(.object(result)), structured: .object(result))
    }

    private var setSongSequence: MCPTool {
        MCPTool(
            name: "set_song_sequence", title: "Set a song's sequence",
            description: "Sets the order a song is sung in, from section names (\"Chorus x2\" repeats; a blank opener is "
                + "kept first). Makes or updates an order with this name on the song. With plan_id and item_id only that "
                + "plan item plays it (other plan items keep their order; the answer gives the order's name); otherwise it "
                + "becomes the song's default order. Tracks (Anthem) follow the order, "
                + "so match the band's sequence.",
            inputSchema: Self.object([
                "presentation_id": Self.string("The song."),
                "sequence": Self.strings("Section names in the order sung."),
                "name": Self.string("Name for this order. Default \"Sequence\"."),
                "plan_id": Self.string("Plan whose item should play it."),
                "item_id": Self.string("The plan item."),
            ], required: ["presentation_id", "sequence"]),
            scope: .edit
        ) { [weak self] arguments in
            guard let self else { throw MCPToolError("Screens is closing.") }
            let id = arguments["presentation_id"]?.stringValue ?? ""
            let song = try await self.toolbox.presentation(id)
            let sequence = arguments["sequence"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let mapping = ShepherdArrangementSync.mapping(sequence: sequence, onto: song)
            guard !mapping.sectionIds.isEmpty else {
                throw MCPToolError("None of that matches \(song.name)'s sections: \(Self.sectionNames(song)).")
            }
            let planID = Self.nonEmpty(arguments["plan_id"]?.stringValue)
            let itemID = Self.nonEmpty(arguments["item_id"]?.stringValue)
            // The plan item is checked before the song is touched, so a call
            // that fails leaves the song as it was.
            var target: (plan: Service, item: ServiceItem)?
            if let planID, let itemID {
                let plan = try await self.toolbox.service(planID)
                let item = try self.toolbox.planItem(itemID, in: plan)
                guard item.refId == id else { throw MCPToolError("\(item.name) doesn't play \(song.name).") }
                target = (plan, item)
            }
            let choice = SongSequenceOrder.choose(
                name: Self.nonEmpty(arguments["name"]?.stringValue) ?? "Sequence", in: song,
                forItem: target != nil, itemPlays: target?.item.arrangementId)
            let orderID = choice.id
            let name = choice.name
            let forItem = target != nil
            let sectionIDs = mapping.sectionIds
            _ = try await self.model.updatePresentation(id) { deck in
                var orders = deck.arrangements ?? []
                if let index = orders.firstIndex(where: { $0.id == orderID }) {
                    orders[index].sectionIds = sectionIDs
                } else {
                    orders.append(Arrangement(id: orderID, name: name, sectionIds: sectionIDs))
                }
                deck.arrangements = orders
                if !forItem { deck.defaultArrangementId = orderID }
            }.value
            var note = "Default order of \(song.name)."
            if let target {
                self.model.setServiceItemArrangement(target.plan.id, itemID: target.item.id, arrangementID: orderID)
                note = "\(target.item.name) in \(target.plan.name) plays it."
            }
            var result: [String: JSONValue] = ["arrangement_id": .string(orderID), "name": .string(name), "note": .string(note)]
            if !mapping.missing.isEmpty {
                result["missing"] = .array(mapping.missing.map(JSONValue.string))
                result["sections"] = .string(Self.sectionNames(song))
            }
            return MCPToolResult(text: Self.text(.object(result)), structured: .object(result))
        }
    }

    // MARK: Message

    private var buildMessageFromOutline: MCPTool {
        let slide = Self.object([
            "kind": ["type": "string", "enum": ["title", "point", "scripture", "point_scripture"],
                     "description": "title: the message title (reference: the line under it, e.g. series or speaker). point: a point on its own. scripture: a passage read on screen (reference: e.g. Genesis 41:14-16; the verses are looked up and split across slides). point_scripture: a point with the verse that supports it."],
            "text": Self.string("The point's words, the title, or for scripture the reference as written."),
            "reference": Self.string("Bible reference to look up (scripture, point_scripture), or the title's subtitle."),
        ], required: ["kind", "text"])
        return MCPTool(
            name: "build_message_from_outline", title: "Build the message",
            description: "Builds a message presentation from an outline you read from the pastor's notes, as Import Sermon "
                + "does: Title, Point, Scripture and Point + Scripture slides, laid out by the sermon series theme (its "
                + "designs include the livestream lower thirds), filed as Sermon so the stage display shows the sermon "
                + "timer. With plan_id it becomes the plan's message (the series from series_id, else the plan's). A "
                + "plan whose message already has slides needs replace_existing and confirm.",
            inputSchema: Self.object([
                "title": Self.string("The message title."),
                "slides": ["type": "array", "items": slide, "minItems": 1, "maxItems": 120, "description": "The slides, in order."],
                "plan_id": Self.string("The plan whose message this is."),
                "series_id": Self.string("Sermon series theme id (list_themes marks them)."),
                "replace_existing": ["type": "boolean", "description": "Replace a message that already has slides."],
                "confirm": ["type": "boolean", "description": "Set only after the user said yes to replacing or changing the series."],
            ], required: ["title", "slides"]),
            scope: .edit
        ) { [weak self] arguments in
            guard let self else { throw MCPToolError("Screens is closing.") }
            return try await self.buildMessage(arguments)
        }
    }

    private func buildMessage(_ args: JSONValue) async throws -> MCPToolResult {
        let title = Self.nonEmpty(args["title"]?.stringValue) ?? "Message"
        let items: [SermonOutline.Item] = try (args["slides"]?.arrayValue ?? []).map { row in
            let raw = (row["kind"]?.stringValue ?? "").replacingOccurrences(of: "point_scripture", with: "pointScripture")
            guard let kind = SermonOutline.Kind(rawValue: raw) else { throw MCPToolError("Unknown slide kind \(raw).") }
            return SermonOutline.Item(kind: kind, text: row["text"]?.stringValue ?? "", reference: row["reference"]?.stringValue ?? "")
        }
        guard !items.isEmpty else { throw MCPToolError("Give at least one slide.") }
        let outline = SermonOutline(title: title, slides: items)

        var plan: Service?
        if let planID = Self.nonEmpty(args["plan_id"]?.stringValue) { plan = try await toolbox.service(planID) }
        let seriesID = Self.nonEmpty(args["series_id"]?.stringValue) ?? plan?.sermonThemeId.flatMap(Self.nonEmpty)
        if let seriesID {
            await model.themesFilled([seriesID])
            guard let series = model.theme(seriesID), SermonSeriesTheme.isSeries(series) else {
                throw MCPToolError("\(seriesID) isn't a sermon series theme. list_themes marks them with sermon_series.")
            }
        } else if plan != nil {
            throw MCPToolError("The plan has no sermon series. Ask the user which series this message is in (list_themes marks them), and pass series_id.")
        }

        if let plan, args["confirm"]?.boolValue != true {
            var asks: [String] = []
            if let current = await SermonMessage.current(in: plan.id, model: model), let deck = current.presentation,
               AssistantToolbox.contentSlides(deck) > 0 {
                guard args["replace_existing"]?.boolValue == true else {
                    throw MCPToolError("\(plan.name) already has a message, \"\(deck.name)\" (\(deck.slides.count) slides). Ask the user before replacing it, then call again with replace_existing and confirm true.")
                }
                asks.append("Replaces \"\(deck.name)\" (\(deck.slides.count) slides).")
            }
            if let current = plan.sermonThemeId, !current.isEmpty, let seriesID, current != seriesID {
                await model.themesFilled([current])
                asks.append("Series: \(model.theme(current)?.name ?? "the plan's series") → \(model.theme(seriesID)?.name ?? seriesID).")
            }
            if !asks.isEmpty {
                let detail = asks.joined(separator: "\n")
                return MCPToolResult(
                    text: "Nothing changed yet. Ask the user:\n\(detail)\n\nIf they say yes, call build_message_from_outline again with confirm true.",
                    structured: ["needs_confirmation": true, "detail": .string(detail)])
            }
        }

        let theme: Theme? = if let seriesID { await SermonMessage.seriesTheme(seriesID, model: model) } else { nil }
        let slides = await SermonSlides.build(outline, theme: theme)
        let id: String
        if let plan, let seriesID {
            id = await SermonMessage.place(slides, title: title, seriesID: seriesID, inPlan: plan.id, model: model)
        } else {
            let deck = SermonMessage.newMessage(slides: slides, title: title, seriesID: seriesID ?? "")
            _ = try await model.createInDrive(deck).value
            id = deck.id
        }
        let result: JSONValue = [
            "presentation_id": .string(id), "title": .string(title), "slides": .integer(slides.count),
            "series": .string(seriesID.flatMap { model.theme($0)?.name } ?? "none"),
            "plan": .string(plan?.name ?? "not in a plan; add it with add_item_to_plan"),
        ]
        return MCPToolResult(text: Self.text(result), structured: result)
    }

    // MARK: Stage display

    private static let stageModes: [String: String] = [
        "lyrics_and_chords": "worship", "message": "message", "pre_service": "preService", "audience": "mirror",
    ]

    private var setStageDisplay: MCPTool {
        MCPTool(
            name: "set_stage_display", title: "Set the stage display",
            description: "Sets what the stage display shows from a slide on: lyrics_and_chords (the slide's words with the "
                + "song's chords in the key the band plays, and the next slide), message (sermon timer and clock), "
                + "pre_service (time until the service), audience (what the room sees), or default (the presentation's "
                + "type decides: Worship shows lyrics and chords, Sermon the message timer). Without slide_ids it goes "
                + "on the first slide, so it holds for the whole presentation. stage_layout_id (list_stage_layouts) "
                + "picks a particular stage layout for the slides, or the whole presentation without slide_ids.",
            inputSchema: Self.object([
                "presentation_id": Self.string("The presentation."),
                "slide_ids": Self.strings("Only these slides."),
                "mode": ["type": "string", "enum": ["default", "lyrics_and_chords", "message", "pre_service", "audience"],
                         "description": "What the stage display shows."],
                "stage_layout_id": Self.string("A stage layout id; an empty string clears it."),
            ], required: ["presentation_id"]),
            scope: .edit
        ) { [weak self] arguments in
            guard let self else { throw MCPToolError("Screens is closing.") }
            let id = arguments["presentation_id"]?.stringValue ?? ""
            let deck = try await self.toolbox.presentation(id)
            let wanted = arguments["slide_ids"]?.arrayValue?.compactMap(\.stringValue)
            let targets = try wanted.map { try self.toolbox.slides($0, in: deck).map(\.id) } ?? [deck.slides.first?.id].compactMap { $0 }
            let mode = arguments["mode"]?.stringValue
            if let mode, mode != "default", Self.stageModes[mode] == nil { throw MCPToolError("Unknown mode \(mode).") }
            let stage = mode.flatMap { Self.stageModes[$0] }
            let layout = arguments["stage_layout_id"]?.stringValue
            if let layout, !layout.isEmpty, !self.model.entries(of: .confidenceLayout).contains(where: { $0.id == layout }) {
                throw MCPToolError("No stage layout \(layout). list_stage_layouts gives the ids.")
            }
            let deckWide = wanted == nil
            _ = try await self.model.updatePresentation(id) { deck in
                if let layout, deckWide { deck.stageLayoutId = layout.isEmpty ? nil : layout }
                for index in deck.slides.indices where targets.contains(deck.slides[index].id) {
                    if mode != nil {
                        var actions = (deck.slides[index].actions ?? []).filter { $0.kind != .setStageMode }
                        if let stage {
                            var action = SlideAction(id: UUID().uuidString, kind: .setStageMode)
                            action.stageMode = stage
                            actions.append(action)
                        }
                        deck.slides[index].actions = actions.isEmpty ? nil : actions
                    }
                    if let layout, !deckWide { deck.slides[index].stageLayoutId = layout.isEmpty ? nil : layout }
                }
            }.value
            // As the slide's right-click menu does: a live slide's stage
            // follows at once instead of on its next fire.
            if let layout, !deckWide {
                self.router?.noteStageLayout(layout.isEmpty ? nil : layout, forSlides: Set(targets))
            }
            let what = mode.map { "Stage display: \($0.replacingOccurrences(of: "_", with: " "))" } ?? "Stage layout set"
            return MCPToolResult(text: "\(what) on \(targets.count) slide\(targets.count == 1 ? "" : "s") of \(deck.name).")
        }
    }

    private var listStageLayouts: MCPTool {
        MCPTool(
            name: "list_stage_layouts", title: "List stage layouts",
            description: "Lists the stage display layouts (ids and names) for set_stage_display's stage_layout_id.",
            inputSchema: Self.object([:]), scope: .view, readOnly: true
        ) { [weak self] _ in
            guard let self else { throw MCPToolError("Screens is closing.") }
            let rows = self.model.entries(of: .confidenceLayout).map { ["id": $0.id, "name": $0.name] }
            return .json(["stage_layouts": rows])
        }
    }

    private var setSlideNotes: MCPTool {
        MCPTool(
            name: "set_slide_notes", title: "Set slide notes",
            description: "Sets a slide's notes: words only the stage display shows (on layouts with a slide notes box), "
                + "such as the pastor's cue or a reminder for the band. An empty string clears them.",
            inputSchema: Self.object([
                "presentation_id": Self.string("The presentation."),
                "slide_id": Self.string("The slide."),
                "notes": Self.string("The notes."),
            ], required: ["presentation_id", "slide_id", "notes"]),
            scope: .edit
        ) { [weak self] arguments in
            guard let self else { throw MCPToolError("Screens is closing.") }
            let id = arguments["presentation_id"]?.stringValue ?? ""
            let deck = try await self.toolbox.presentation(id)
            let slide = try self.toolbox.slides([arguments["slide_id"]?.stringValue ?? ""], in: deck)[0]
            let notes = arguments["notes"]?.stringValue ?? ""
            let slideID = slide.id
            _ = try await self.model.updatePresentation(id) { deck in
                guard let index = deck.slides.firstIndex(where: { $0.id == slideID }) else { return }
                deck.slides[index].notes = notes.isEmpty ? nil : notes
            }.value
            return MCPToolResult(text: notes.isEmpty ? "Notes cleared." : "Notes set on \(self.toolbox.label(of: slide, in: deck)).")
        }
    }

    private var stageAndStream: MCPTool {
        MCPTool(
            name: "get_stage_and_stream", title: "What each item does",
            description: "For each item in a plan: what the stage display shows and what the livestream shows when it's "
                + "live (the tags Present shows). With presentation_id, slide by slide for that item. Use it to check "
                + "a plan after building it.",
            inputSchema: Self.object([
                "plan_id": Self.string("The plan."),
                "presentation_id": Self.string("One of the plan's presentations, slide by slide."),
            ], required: ["plan_id"]),
            scope: .view, readOnly: true
        ) { [weak self] arguments in
            guard let self else { throw MCPToolError("Screens is closing.") }
            let plan = try await self.toolbox.service(arguments["plan_id"]?.stringValue)
            await self.model.resident.ready([.media, .theme])
            _ = await self.model.presentationsFilled(plan.items.filter { $0.itemKind == .presentation }.map(\.refId))
            await self.model.themesFilled(self.model.entries(of: .theme).map(\.id))
            let library = StageStreamTags.Library(
                presentation: { self.model.presentation($0) }, media: { self.model.media($0) },
                theme: { self.model.theme($0) }, settings: self.model.slideBuilding)
            if let deckID = Self.nonEmpty(arguments["presentation_id"]?.stringValue) {
                guard let item = plan.items.first(where: { $0.refId == deckID }), let deck = self.model.presentation(deckID) else {
                    throw MCPToolError("That presentation isn't in \(plan.name).")
                }
                let rows: [[String: String]] = deck.slides.map { slide in
                    let tags = StageStreamTags.tags(for: slide, of: item, in: plan, library: library)
                    return ["slide_id": slide.id, "slide": self.toolbox.label(of: slide, in: deck),
                            "stage_display": tags?.stage ?? "", "livestream": tags?.stream ?? ""]
                }
                let result: JSONValue = ["presentation": .string(deck.name),
                                          "slides": .array(rows.map { .object($0.mapValues(JSONValue.string)) })]
                return MCPToolResult(text: Self.text(result), structured: result)
            }
            let rows: [[String: String]] = plan.items.compactMap { item in
                guard let tags = StageStreamTags.tags(for: item, in: plan, library: library) else { return nil }
                return ["item_id": item.id, "name": item.name, "stage_display": tags.stage, "livestream": tags.stream]
            }
            let result: JSONValue = ["plan": .string(plan.name), "plan_id": .string(plan.id),
                                      "items": .array(rows.map { .object($0.mapValues(JSONValue.string)) })]
            return MCPToolResult(text: Self.text(result), structured: result)
        }
    }

    // MARK: Plans

    /// Puts the presentation in the plan: on the named item, or as a new
    /// item at the end.
    private func use(_ id: String, in planID: String, itemID: String?, arrangementID: String?, name: String) async throws -> String {
        let plan = try await toolbox.service(planID)
        if let itemID {
            let item = try toolbox.planItem(itemID, in: plan)
            model.updateService(planID) { service in
                guard let index = service.items.firstIndex(where: { $0.id == itemID }) else { return }
                service.items[index].itemKind = .presentation
                service.items[index].refId = id
                service.items[index].arrangementId = arrangementID
            }
            return "\(item.name) in \(plan.name) plays it."
        }
        model.addServiceItem(planID, refID: id)
        return "Added to the end of \(plan.name)."
    }

    // MARK: Helpers

    private static func title(_ name: String) -> String {
        let words = name.split(separator: "_").map(String.init)
        return ([words.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? ""] + words.dropFirst()).joined(separator: " ")
    }

    private static func sectionNames(_ song: Presentation) -> String {
        (song.sections ?? []).map(\.name).joined(separator: ", ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func file(_ path: String?) throws -> URL {
        guard let path = nonEmpty(path), path.hasPrefix("/") else { throw MCPToolError("Give an absolute path on this Mac.") }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw MCPToolError("Screens can't read \(path). The file has to be on the Mac running Screens.")
        }
        return url
    }

    private static func text(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string))]
    }

    private static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    private static func strings(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    private static func adding(confirm schema: JSONValue) -> JSONValue {
        guard case .object(var fields) = schema, case .object(var properties)? = fields["properties"] else { return schema }
        properties["confirm"] = ["type": "boolean", "description": "Set only after the user has said yes to this change."]
        fields["properties"] = .object(properties)
        return .object(fields)
    }

    static func json(_ value: AssistantJSON) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: value.encoded())) ?? .object([:])
    }

    static func assistant(_ value: JSONValue) throws -> AssistantJSON {
        do { return try AssistantJSON.parse(JSONEncoder().encode(value)) } catch {
            throw MCPToolError("Couldn't read the arguments.")
        }
    }
}

/// The toolbox's own mistakes read as plain sentences over MCP too.
extension AssistantToolbox.Failure: LocalizedError {
    var errorDescription: String? { message }
}
