import Foundation

/// What the livestream shows for a slide, in the words the tools use. The
/// same four choices as a slide's right-click › Livestream menu.
public enum AssistantLivestream: String, CaseIterable, Sendable {
    case themeDefault = "theme_default"
    case lowerThird = "lower_third"
    case fullScreen = "full_screen"
    case nothing

    /// The slide's stream design; Theme Default clears the slide's own choice.
    public var design: StreamDesign? {
        switch self {
        case .themeDefault: nil
        case .lowerThird: StreamDesign(category: "", mode: .design)
        case .fullScreen: StreamDesign(category: "", mode: .audience)
        case .nothing: StreamDesign(category: "", mode: .clear)
        }
    }

    public init(design: StreamDesign?) {
        switch design?.mode {
        case nil: self = .themeDefault
        case .design: self = .lowerThird
        case .audience: self = .fullScreen
        case .clear: self = .nothing
        }
    }

    /// The menu wording, for activity lines.
    public var title: String {
        switch self {
        case .themeDefault: "Theme Default"
        case .lowerThird: "Lower Third"
        case .fullScreen: "Full Screen"
        case .nothing: "Nothing"
        }
    }
}

/// Every tool the Assistant can call, in a fixed order (the tool list is the
/// front of the cached prompt, so it must not change between requests).
public enum AssistantToolCatalog {
    public static func spec(_ name: String) -> AssistantToolSpec? {
        all.first { $0.name == name }
    }

    // MARK: Schema helpers

    static func object(_ properties: [String: AssistantJSON], required: [String] = []) -> AssistantJSON {
        ["type": "object", "properties": .object(properties), "required": AssistantJSON(required),
         "additionalProperties": false]
    }

    static func string(_ description: String, nonEmpty: Bool = false) -> AssistantJSON {
        nonEmpty
            ? ["type": "string", "description": .string(description), "minLength": 1]
            : ["type": "string", "description": .string(description)]
    }

    static func integer(_ description: String, min: Int? = nil, max: Int? = nil) -> AssistantJSON {
        var fields: [String: AssistantJSON] = ["type": "integer", "description": .string(description)]
        if let min { fields["minimum"] = .number(Double(min)) }
        if let max { fields["maximum"] = .number(Double(max)) }
        return .object(fields)
    }

    static func number(_ description: String, min: Double? = nil, max: Double? = nil) -> AssistantJSON {
        var fields: [String: AssistantJSON] = ["type": "number", "description": .string(description)]
        if let min { fields["minimum"] = .number(min) }
        if let max { fields["maximum"] = .number(max) }
        return .object(fields)
    }

    static func boolean(_ description: String) -> AssistantJSON {
        ["type": "boolean", "description": .string(description)]
    }

    static func strings(_ description: String, minItems: Int = 1, maxItems: Int? = nil) -> AssistantJSON {
        var fields: [String: AssistantJSON] = [
            "type": "array", "description": .string(description), "items": ["type": "string", "minLength": 1],
            "minItems": .number(Double(minItems)),
        ]
        if let maxItems { fields["maxItems"] = .number(Double(maxItems)) }
        return .object(fields)
    }

    static func choice(_ description: String, _ values: [String]) -> AssistantJSON {
        ["type": "string", "description": .string(description), "enum": AssistantJSON(values)]
    }

    static let livestream = choice(
        "What the livestream shows for the slide. theme_default follows the Show Setup switch and the theme; "
            + "lower_third shows the theme's lower third; full_screen sends the slide edge to edge; nothing shows the camera only.",
        AssistantLivestream.allCases.map(\.rawValue))

    static let newSlide = object([
        "name": string("Slide name shown in the grid. For an event promo, the event title."),
        "text": string("The slide's words. Line breaks are kept. Leave out for an image-only slide."),
        "layout": string("A design name from the presentation's theme (list_themes), e.g. \"Announcements\". Leave out for the theme's first design."),
        "background_media_id": string("A Media library id (list_media) to show as the full-slide background."),
        "livestream": livestream,
        "auto_advance_seconds": number("This slide's own auto-advance time, overriding the presentation's.", min: 0, max: 3600),
    ])

    // MARK: Tools

    public static let all: [AssistantToolSpec] = [
        AssistantToolSpec(
            name: "list_plans",
            description: "Lists service plans (the left column of the main window), newest service date first. "
                + "Call this to find a plan by date or name before reading or changing it.",
            schema: object([
                "include_past": boolean("Also list plans whose date has passed. Default false."),
                "limit": integer("Most plans to return. Default 12.", min: 1, max: 60),
            ])),
        AssistantToolSpec(
            name: "get_plan",
            description: "Reads one plan's items in run order: id, kind (presentation, media, audio, playlist, header, info), "
                + "name, the library item it points at, and flags (hidden, countdown).",
            schema: object(["plan_id": string("The plan id from list_plans.", nonEmpty: true)], required: ["plan_id"])),
        AssistantToolSpec(
            name: "list_presentations",
            description: "Lists presentations in the library with their folder. query matches name or folder and ignores "
                + "spaces, hyphens and case (\"preservice\" finds \"Pre-Service\"). Give category to filter by presentation "
                + "type (Worship, Sermon, Bible, Announcements, Video or a custom one); that also returns slide counts and auto-advance.",
            schema: object([
                "query": string("Words to match in the name or folder."),
                "category": string("Presentation type to match, e.g. Announcements."),
                "limit": integer("Most results. Default 40.", min: 1, max: 200),
            ])),
        AssistantToolSpec(
            name: "get_presentation",
            description: "Reads a presentation: name, type, theme, auto-advance, and every slide with its id, index, name, text, "
                + "layout, background media name, own auto-advance and livestream choice. Call before editing slides.",
            schema: object(["presentation_id": string("The presentation id.", nonEmpty: true)], required: ["presentation_id"])),
        AssistantToolSpec(
            name: "search_slides",
            description: "Full-text search of slide words across the library (songs, sermons, announcements). Returns matching presentations with a snippet.",
            schema: object(["query": string("Words to find.", nonEmpty: true)], required: ["query"])),
        AssistantToolSpec(
            name: "list_media",
            description: "Lists images and videos in the Media library: id, name, kind, folder, length. Use to find a background or countdown video.",
            schema: object([
                "query": string("Words to match in the name or folder."),
                "kind": choice("Only images or only videos.", ["image", "video"]),
                "limit": integer("Most results. Default 40.", min: 1, max: 200),
            ])),
        AssistantToolSpec(
            name: "list_themes",
            description: "Lists themes with their design names (the layouts a slide can use) and whether each is a sermon series theme.",
            schema: object([:])),
        AssistantToolSpec(
            name: "create_presentation",
            description: "Creates a presentation in the library with the given slides. For a pre-service slideshow set "
                + "auto_advance_seconds (Hope uses 10) and loop true. Returns the new id. Does not add it to a plan; use add_item_to_plan for that.",
            schema: object([
                "name": string("Presentation name.", nonEmpty: true),
                "category": string("Presentation type: Worship, Sermon, Bible, Announcements, Video, or another word."),
                "theme_id": string("Theme id from list_themes. Leave out for no theme."),
                "folder": string("Library folder to file it in."),
                "auto_advance_seconds": number("Seconds per slide for a slideshow; 0 or left out for none.", min: 0, max: 3600),
                "loop": boolean("With auto-advance: go back to the first slide after the last. Default true."),
                "slides": ["type": "array", "items": newSlide, "minItems": 1, "maxItems": 200,
                           "description": "The slides, in order."],
            ], required: ["name", "slides"])),
        AssistantToolSpec(
            name: "add_slides",
            description: "Adds slides to an existing presentation, after a given slide or at the end.",
            schema: object([
                "presentation_id": string("The presentation id.", nonEmpty: true),
                "after_slide_id": string("Insert after this slide; leave out to add at the end."),
                "slides": ["type": "array", "items": newSlide, "minItems": 1, "maxItems": 200,
                           "description": "The slides, in order."],
            ], required: ["presentation_id", "slides"])),
        AssistantToolSpec(
            name: "delete_slides",
            description: "Deletes slides from a presentation. The user sees a summary and must approve before anything is "
                + "deleted; the result says whether they did. Only call after you have read the presentation and are sure which slides go.",
            schema: object([
                "presentation_id": string("The presentation id.", nonEmpty: true),
                "slide_ids": strings("Ids of the slides to delete.", maxItems: 200),
                "reason": string("One short line for the user saying why, e.g. \"Events have passed\"."),
            ], required: ["presentation_id", "slide_ids"]),
            needsConfirmation: true),
        AssistantToolSpec(
            name: "reorder_slides",
            description: "Puts a presentation's slides in a new order. slide_ids must list every slide exactly once.",
            schema: object([
                "presentation_id": string("The presentation id.", nonEmpty: true),
                "slide_ids": strings("Every slide id, in the new order.", maxItems: 2000),
            ], required: ["presentation_id", "slide_ids"])),
        AssistantToolSpec(
            name: "set_slide_text",
            description: "Changes a slide's words and/or its name. The words go in the slide's first text box (one is added if it has none).",
            schema: object([
                "presentation_id": string("The presentation id.", nonEmpty: true),
                "slide_id": string("The slide id.", nonEmpty: true),
                "text": string("New words for the slide."),
                "name": string("New slide name."),
            ], required: ["presentation_id", "slide_id"])),
        AssistantToolSpec(
            name: "set_slide_background",
            description: "Sets or clears a slide's full-slide background image or video.",
            schema: object([
                "presentation_id": string("The presentation id.", nonEmpty: true),
                "slide_id": string("The slide id.", nonEmpty: true),
                "media_id": string("Media library id; leave out to clear the background."),
            ], required: ["presentation_id", "slide_id"])),
        AssistantToolSpec(
            name: "set_slide_livestream",
            description: "Sets what the livestream shows for one or more slides (the slide's right-click › Livestream choice). "
                + "A slide's own choice beats the Show Setup switch.",
            schema: object([
                "presentation_id": string("The presentation id.", nonEmpty: true),
                "slide_ids": strings("The slides to change.", maxItems: 2000),
                "mode": livestream,
            ], required: ["presentation_id", "slide_ids", "mode"])),
        AssistantToolSpec(
            name: "set_auto_advance",
            description: "Sets auto-advance. Without slide_ids it sets the presentation's slideshow timing (every slide); "
                + "with slide_ids it sets those slides' own timing. 0 seconds turns it off.",
            schema: object([
                "presentation_id": string("The presentation id.", nonEmpty: true),
                "seconds": number("Seconds per slide; 0 turns auto-advance off.", min: 0, max: 3600),
                "loop": boolean("Presentation-wide only: loop back to the first slide after the last. Default true."),
                "slide_ids": strings("Only these slides.", maxItems: 2000),
            ], required: ["presentation_id", "seconds"])),
        AssistantToolSpec(
            name: "update_presentation",
            description: "Renames a presentation or changes its type (category).",
            schema: object([
                "presentation_id": string("The presentation id.", nonEmpty: true),
                "name": string("New name."),
                "category": string("New presentation type; an empty string clears it."),
            ], required: ["presentation_id"])),
        AssistantToolSpec(
            name: "add_item_to_plan",
            description: "Adds a library item (presentation, media, audio or playlist, by id) or a header to a plan, after a "
                + "given item or at the end. Give ref_id or header, not both.",
            schema: object([
                "plan_id": string("The plan id.", nonEmpty: true),
                "ref_id": string("Library id of the presentation or media to add."),
                "header": string("Text for a header (section label) instead of a library item."),
                "after_item_id": string("Insert after this plan item; leave out to add at the end."),
            ], required: ["plan_id"])),
        AssistantToolSpec(
            name: "remove_plan_item",
            description: "Removes an item from a plan (the library item itself is kept). The user must approve first.",
            schema: object([
                "plan_id": string("The plan id.", nonEmpty: true),
                "item_id": string("The plan item id from get_plan.", nonEmpty: true),
            ], required: ["plan_id", "item_id"]),
            needsConfirmation: true),
        AssistantToolSpec(
            name: "schedule_service",
            description: "Schedule Service: sets the plan's service start times. The plan's countdown video is started so it "
                + "reaches zero at each time, then the plan moves on by itself. Replaces any countdowns already scheduled "
                + "for this plan, so the user approves first. The plan needs a countdown item with a video.",
            schema: object([
                "plan_id": string("The plan id.", nonEmpty: true),
                "service_times": strings("Local start times as YYYY-MM-DDTHH:MM, e.g. 2026-10-25T09:00.", maxItems: 8),
            ], required: ["plan_id", "service_times"]),
            needsConfirmation: true),
        AssistantToolSpec(
            name: "fetch_church_events",
            description: "Gets Hope Church's events from hopejc.org: title, start and end dates, time, short description, "
                + "link, and whether each has already ended (judged against today's date).",
            schema: object([
                "include_recent_past": boolean("Also return events that ended in the last 90 days. Default true."),
            ])),
        AssistantToolSpec(
            name: "match_slides_to_events",
            description: "For a presentation of event promos (pre-service slideshow, announcements): fetches the church's "
                + "events and matches each slide by its name, words and background file name. Each slide comes back as "
                + "passed, current or unmatched, with the event and the reason. Read it, then decide; ask the user about unclear ones.",
            schema: object(["presentation_id": string("The presentation id.", nonEmpty: true)], required: ["presentation_id"])),
        AssistantToolSpec(
            name: "import_announcement_cards",
            description: "Builds announcement slides from card images the user attached (attachment ids appear in the user's "
                + "message). Each card is imported into the Media library and becomes one slide with the card as its "
                + "full-slide background and the event title as the slide name. Adds to presentation_id, or to a "
                + "presentation named presentation_name (default \"Announcements\"), creating it if needed.",
            schema: object([
                "cards": ["type": "array", "minItems": 1, "maxItems": 60, "description": "One entry per slide, in order.",
                          "items": object([
                              "attachment_id": string("Attachment id, e.g. att_1.", nonEmpty: true),
                              "title": string("The event title, used as the slide name.", nonEmpty: true),
                              "livestream": livestream,
                          ], required: ["attachment_id", "title"])],
                "presentation_id": string("Existing presentation to add the slides to."),
                "presentation_name": string("Name to find or create when no presentation_id is given."),
            ], required: ["cards"])),
    ]
}
