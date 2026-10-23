import Foundation
@testable import PresenterCore
import Testing

/// The Assistant's pure parts: request building, the streamed reply, the
/// conversation history, tool inputs, and reading the church's events. No
/// network here; every page and reply is written out below.
struct AssistantRequestTests {
    private func body(_ model: AssistantModel = .opus, guide: String = "GUIDE") -> AssistantJSON {
        AssistantRequest.body(
            model: model, instructions: "INSTRUCTIONS", guide: guide,
            tools: AssistantToolCatalog.all, messages: [["role": "user", "content": "hi"]])
    }

    @Test func opusIsTheDefaultWithAdaptiveThinking() {
        #expect(AssistantModel.stored(nil) == .opus)
        #expect(AssistantModel.stored("nonsense") == .opus)
        #expect(AssistantModel.stored("claude-sonnet-5-5") == .sonnet)
        let request = body()
        #expect(request["model"] == "claude-opus-5-5")
        #expect(request["thinking"]?["type"] == "adaptive")
        #expect(request["thinking"]?["budget_tokens"] == nil, "budget_tokens is rejected on these models")
        #expect(request["output_config"]?["effort"] == "high")
        #expect(request["stream"] == true)
        #expect(request["fallbacks"] == "default")
        #expect(request["temperature"] == nil)
        #expect(request["tool_choice"] == nil, "forced tool use is rejected on Opus 5.5")
        #expect(body(.sonnet)["model"] == "claude-sonnet-5-5")
    }

    @Test func theGuideCarriesTheCacheBreakpoint() {
        let system = body()["system"]?.array ?? []
        #expect(system.count == 2)
        #expect(system[0]["text"] == "INSTRUCTIONS")
        #expect(system[0]["cache_control"] == nil)
        #expect(system[1]["text"] == "GUIDE")
        #expect(system[1]["cache_control"]?["type"] == "ephemeral")
        #expect(body()["cache_control"]?["type"] == "ephemeral", "the conversation tail is cached too")
        // Without a guide the instructions take the breakpoint.
        #expect(body(guide: "")["system"]?.array?.first?["cache_control"] != nil)
    }

    @Test func theRequestIsByteStable() {
        // Prompt caching needs the same bytes for the same prefix every time.
        #expect(body().encoded() == body().encoded())
        let text = body().jsonString
        #expect(text.contains("\"max_tokens\":64000"), "whole numbers go out without a fraction")
        #expect(text.range(of: "\"cache_control\"")!.lowerBound < text.range(of: "\"messages\"")!.lowerBound,
                "keys are sorted")
    }

    @Test func headersNeverCarryTheKey() {
        let headers = AssistantRequest.headers
        #expect(headers["anthropic-version"] == "2026-10-21")
        #expect(headers["anthropic-beta"]?.contains("server-side-fallback-2026-07-01") == true)
        #expect(headers["x-api-key"] == nil)
    }

    @Test func everyToolStreamsItsInputAndIsWellFormed() {
        let names = AssistantToolCatalog.all.map(\.name)
        #expect(Set(names).count == names.count, "tool names are unique")
        for spec in AssistantToolCatalog.all {
            #expect(spec.definition["eager_input_streaming"] == true)
            #expect(!spec.description.isEmpty)
            #expect(spec.schema["type"] == "object", "\(spec.name)")
            #expect(spec.schema["additionalProperties"] == false, "\(spec.name)")
            let properties = spec.schema["properties"]?.object ?? [:]
            for required in spec.schema["required"]?.array?.compactMap(\.string) ?? [] {
                #expect(properties[required] != nil, "\(spec.name).\(required) is required but not described")
            }
        }
        let confirmed = Set(AssistantToolCatalog.all.filter(\.needsConfirmation).map(\.name))
        #expect(confirmed == ["delete_slides", "remove_plan_item", "schedule_service", "apply_sunday_setup", "apply_lyric_fixes"])
        for wanted in ["list_plans", "get_plan", "list_presentations", "get_presentation", "create_presentation",
                       "add_slides", "reorder_slides", "set_slide_text", "set_slide_livestream", "set_auto_advance",
                       "add_item_to_plan", "fetch_church_events", "import_announcement_cards", "list_media", "list_themes"] {
            #expect(AssistantToolCatalog.spec(wanted) != nil, "\(wanted)")
        }
    }

    @Test func livestreamChoicesMatchTheSlideMenu() {
        for choice in AssistantLivestream.allCases {
            #expect(AssistantLivestream(design: choice.design) == choice)
        }
        #expect(AssistantLivestream.themeDefault.design == nil)
        #expect(AssistantLivestream.fullScreen.design?.mode == .audience)
        #expect(AssistantLivestream.nothing.design?.mode == .clear)
        #expect(AssistantLivestream.lowerThird.design == StreamDesign(category: "", mode: .design))
    }
}

struct AssistantHistoryTests {
    @Test func aStoppedTurnJoinsTheNextMessage() {
        var history = AssistantHistory()
        history.appendUserText("first")
        history.appendUserText("second")
        #expect(history.messages.count == 1)
        #expect(history.messages[0]["content"]?.array?.count == 2)
        history.appendAssistant([["type": "text", "text": "ok"]])
        history.appendUserText("third")
        #expect(history.messages.map { $0["role"]?.string } == ["user", "assistant", "user"])
    }

    @Test func openToolCallsAreAnsweredWhenStopped() {
        var history = AssistantHistory()
        history.appendUserText("go")
        history.appendAssistant([
            ["type": "text", "text": "Looking."],
            ["type": "tool_use", "id": "t1", "name": "list_plans", "input": [:]],
            ["type": "tool_use", "id": "t2", "name": "get_plan", "input": ["plan_id": "p"]],
        ])
        #expect(history.unansweredToolUses.map(\.id) == ["t1", "t2"])
        history.closeOpenToolUses("Stopped by the user.")
        let results = history.messages.last?["content"]?.array ?? []
        #expect(results.map { $0["tool_use_id"]?.string } == ["t1", "t2"])
        #expect(results.allSatisfy { $0["is_error"] == true })
        #expect(history.unansweredToolUses.isEmpty)
        history.closeOpenToolUses("again")
        #expect(history.messages.count == 3, "nothing to close twice")
    }

    @Test func aFallbackDropsTheDeclinedModelsCallsButKeepsItsText() {
        let content: [AssistantJSON] = [
            ["type": "thinking", "thinking": "", "signature": "s1"],
            ["type": "text", "text": "Partial"],
            ["type": "tool_use", "id": "dead", "name": "x", "input": [:]],
            ["type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-5"]],
            ["type": "thinking", "thinking": "", "signature": "s2"],
            ["type": "tool_use", "id": "live", "name": "list_plans", "input": [:]],
        ]
        let echoed = AssistantHistory.echo(content)
        #expect(echoed.map { $0["type"]?.string } == ["text", "fallback", "thinking", "tool_use"])
        #expect(echoed.last?["id"] == "live")
        let plain: [AssistantJSON] = [["type": "thinking", "thinking": "", "signature": "s"], ["type": "text", "text": "x"]]
        #expect(AssistantHistory.echo(plain) == plain, "without a fallback the reply goes back unchanged")
    }

    @Test func toolResultsMarkErrors() {
        #expect(AssistantToolResult(id: "a", content: "ok").block["is_error"] == nil)
        #expect(AssistantToolResult.error(id: "a", "bad").block["is_error"] == true)
    }
}

struct AssistantStreamTests {
    private func feed(_ lines: [String]) throws -> (AssistantStream, [AssistantStream.Event]) {
        var stream = AssistantStream()
        var events: [AssistantStream.Event] = []
        for line in lines { events += try stream.feed(line: line) }
        return (stream, events)
    }

    private let reply = [
        #"event: message_start"#,
        #"data: {"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","usage":{"input_tokens":12,"cache_read_input_tokens":9000}}}"#,
        #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Checking the plan."}}"#,
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
        #"data: {"type":"content_block_stop","index":0}"#,
        #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Here "}}"#,
        #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"goes."}}"#,
        #"data: {"type":"content_block_stop","index":1}"#,
        #"data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_plan","input":{}}}"#,
        #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"plan_"}}"#,
        #"data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"id\": \"p1\"}"}}"#,
        #"data: {"type":"content_block_stop","index":2}"#,
        "",
        #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":40}}"#,
        #"data: {"type":"message_stop"}"#,
    ]

    @Test func aReplyIsAssembledInOrder() throws {
        var (stream, events) = try feed(reply)
        #expect(stream.finished)
        #expect(stream.model == "claude-opus-5-5")
        #expect(stream.stopReason == "tool_use")
        #expect(stream.usage["cache_read_input_tokens"] == 9000)
        #expect(stream.usage["output_tokens"] == 40)
        #expect(events.contains(.progress(index: 0, delta: "Checking the plan.")))
        #expect(events.contains(.text(index: 1, delta: "goes.")))
        #expect(events.contains(.toolStarted(index: 2, name: "get_plan")))

        let content = stream.content()
        #expect(content.count == 3)
        #expect(content[0] == ["type": "thinking", "thinking": "Checking the plan.", "signature": "abc"],
                "thinking goes back with its signature")
        #expect(content[1]["text"] == "Here goes.")
        #expect(content[2]["input"] == ["plan_id": "p1"])
        #expect(stream.replyText() == "Here goes.")
        let calls = stream.toolUses()
        #expect(calls.count == 1)
        #expect(calls[0].id == "toolu_1")
        #expect(stream.invalidInputs.isEmpty)
    }

    @Test func brokenToolInputIsFlaggedNotRun() throws {
        var (stream, _) = try feed([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"set_slide_text","input":{}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"text\": \"unterminated"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
        ])
        #expect(stream.invalidInputs["t"] == #"{"text": "unterminated"#)
        #expect(stream.content()[0]["input"] == [:], "echoed with an empty input")
    }

    @Test func aStreamErrorThrows() {
        var stream = AssistantStream()
        #expect(throws: AssistantStream.StreamError.self) {
            _ = try stream.feed(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        }
    }

    @Test func aCancelledStreamStillYieldsItsText() throws {
        var (stream, _) = try feed([
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half"}}"#,
        ])
        #expect(stream.replyText() == "Half")
        #expect(!stream.finished)
    }

    @Test func aReplyCutOffMidToolCallIsAnError() throws {
        let (cut, _) = try feed(Array(reply.prefix(while: { !$0.contains("content_block_stop\",\"index\":2") })))
        #expect(!cut.finished)
        #expect(throws: AssistantStream.StreamError(type: "incomplete", message: "The connection closed early.")) {
            try cut.requireFinished()
        }
        let (whole, _) = try feed(reply)
        #expect(throws: Never.self) { try whole.requireFinished() }
    }
}

struct AssistantToolInputTests {
    private func check(_ tool: String, _ input: AssistantJSON) -> String? {
        AssistantToolInput.validate(input, against: AssistantToolCatalog.spec(tool)!.schema)
    }

    @Test func goodInputPasses() {
        #expect(check("delete_slides", ["presentation_id": "p", "slide_ids": ["a", "b"]]) == nil)
        #expect(check("set_slide_livestream", ["presentation_id": "p", "slide_ids": ["a"], "mode": "full_screen"]) == nil)
        #expect(check("set_auto_advance", ["presentation_id": "p", "seconds": 10]) == nil)
        #expect(check("list_plans", [:]) == nil)
        #expect(check("list_plans", ["limit": nil]) == nil, "an optional field sent as null counts as left out")
        #expect(check("create_presentation", [
            "name": "Pre-Service", "auto_advance_seconds": 10, "loop": true,
            "slides": [["name": "Welcome", "text": "Welcome to Hope"], ["background_media_id": "m1", "livestream": "nothing"]],
        ]) == nil)
    }

    @Test func badInputIsExplained() {
        #expect(check("delete_slides", ["presentation_id": "p"]) == "input.slide_ids is required")
        #expect(check("delete_slides", ["presentation_id": "p", "slide_ids": []]) == "input.slide_ids needs at least 1 item")
        #expect(check("delete_slides", ["presentation_id": 4, "slide_ids": ["a"]]) == "input.presentation_id must be a string")
        #expect(check("delete_slides", ["presentation_id": "", "slide_ids": ["a"]]) == "input.presentation_id must not be empty")
        #expect(check("set_slide_livestream", ["presentation_id": "p", "slide_ids": ["a"], "mode": "big"])?
            .hasPrefix("input.mode must be one of: theme_default") == true)
        #expect(check("list_plans", ["limit": 2.5]) == "input.limit must be a whole number")
        #expect(check("list_plans", ["limit": 500]) == "input.limit must be at most 60")
        #expect(check("list_plans", ["colour": "red"]) == "input.colour is not a known field")
        #expect(check("set_auto_advance", ["presentation_id": "p", "seconds": -1]) == "input.seconds must be at least 0")
        #expect(check("create_presentation", ["name": "X", "slides": [["livestream": "loud"]]])?
            .hasPrefix("input.slides[0].livestream") == true)
        #expect(check("import_announcement_cards", ["cards": [["attachment_id": "att_1"]]])
            == "input.cards[0].title is required")
    }
}

struct ChurchEventsTests {
    private let base = URL(string: "https://church.example/")!

    @Test func theFeedReadsDatesTimesAndLinks() throws {
        let feed = #"""
        {"events":[
          {"slug":"fall-festival-2026-10-25","title":"Fall Festival","summary":null,"cancelled":false,
           "start_date":"2026-10-25","start_time":"17:00","end_date":"2026-10-25","end_time":"19:00","all_day":false,
           "location_name":"Main Campus","url":"https://church.example/events/fall-festival-2026-10-25"},
          {"slug":"shoeboxes","title":"Shoebox Drive","summary":"Pick up a box.","cancelled":false,
           "start_date":"2026-10-12","start_time":null,"end_date":"2026-11-22","end_time":null,"all_day":true},
          {"title":"No date"}
        ]}
        """#
        let events = try ChurchEvents.parseFeed(Data(feed.utf8))
        #expect(events.count == 2)
        #expect(events[0].title == "Fall Festival")
        #expect(events[0].time == "17:00-19:00")
        #expect(events[0].location == "Main Campus")
        #expect(events[1].time == "All day")
        #expect(events[1].lastDay == "2026-11-22")
        #expect(events[1].hasEnded(today: "2026-10-23") == false, "a running event is current")
        #expect(events[0].hasEnded(today: "2026-10-25") == false, "today's event is current")
        #expect(events[0].hasEnded(today: "2026-10-26"))
        let json = events[0].json(today: "2026-10-26")
        #expect(json["ended"] == true)
        #expect(json["link"] == "https://church.example/events/fall-festival-2026-10-25")
        #expect(throws: (any Error).self) { try ChurchEvents.parseFeed(Data("{}".utf8)) }
    }

    @Test func theHomepageLeadsToTheEventsPage() {
        let home = """
        <nav><a href="/">Home</a><a href="/about">About</a><a href="/events" class="active">Events</a>
        <a href="https://elsewhere.example/events">Partner events</a></nav>
        """
        #expect(ChurchEvents.eventsPageLink(in: home, base: base)?.absoluteString == "https://church.example/events")
        let byText = #"<a href="/whats-on">Events</a>"#
        #expect(ChurchEvents.eventsPageLink(in: byText, base: base)?.path == "/whats-on")
        let page = #"<div><iframe src="https://cal.example/embed?limit=30&amp;x=1" title="Events"></iframe></div>"#
        #expect(ChurchEvents.frames(in: page, base: base).map(\.absoluteString) == ["https://cal.example/embed?limit=30&x=1"])
    }

    @Test func eventCardsAreRead() {
        let html = """
        <h2 class="month">October 2026</h2><div class="grid">
        <a class="card" href="https://church.example/events/shoebox-drive-2026-10-12" target="_top">
          <span class="shot"><img src="/img/a.jpg" alt=""><span class="when range"><b>12-22</b><i>Oct</i></span></span>
          <span class="body"><span class="t">Shoebox Drive</span>
          <span class="meta"><b>All day</b> &middot; Main Campus</span>
          <span class="desc">Boxes are ready &amp; waiting!</span></span></a>
        <a class="card" href="/events/fall-festival-2026-10-25">
          <span class="when"><b>25</b><i>Oct</i></span>
          <span class="t">Fall Festival</span><span class="meta"><b>5 - 7pm</b> &middot; Main Campus</span></a>
        <a class="card" href="/events/new-years-2026-12-30"><span class="when range"><b>30-2</b><i>Dec</i></span>
          <span class="t">New Year Retreat</span></a>
        <a href="/about">About us</a>
        </div>
        """
        let events = ChurchEvents.parseCards(html, base: base)
        #expect(events.map(\.title) == ["Shoebox Drive", "Fall Festival", "New Year Retreat"])
        #expect(events[0].startDate == "2026-10-12")
        #expect(events[0].endDate == "2026-10-22")
        #expect(events[0].time == "All day")
        #expect(events[0].summary == "Boxes are ready & waiting!")
        #expect(events[1].url == "https://church.example/events/fall-festival-2026-10-25")
        #expect(events[1].time == "5 - 7pm")
        #expect(events[2].endDate == "2027-01-02", "a range that wraps the month ends in the next one")
    }

    @Test func pagesBecomeReadableText() {
        let html = """
        <html><head><style>p { color: red }</style><script>var x = "<p>no</p>";</script></head>
        <body><h1>What&#39;s on</h1><p>Join us &amp; bring a friend.</p>
        <a href="/events/x">Read more</a><!-- hidden --></body></html>
        """
        let text = HTMLText.plainText(html, linksFrom: base)
        #expect(text == "What's on\nJoin us & bring a friend.\nRead more (https://church.example/events/x)")
        #expect(HTMLText.decodeEntities("&#x2019;&nbsp;&bogus;") == "’ &bogus;")
    }

    @Test func dayStampsCount() {
        #expect(DayStamp.adding(-90, to: "2026-10-23") == "2026-07-25")
        #expect(DayStamp.adding(10, to: "2026-12-25") == "2027-01-04")
        #expect(DayStamp.days(from: "2026-10-23", to: "2026-10-25") == 2)
        #expect(ChurchEvents.feedURL(from: "2026-07-25").query == "limit=200&past=1&from=2026-07-25")
        #expect(ChurchEvents.feedURL(from: nil).query == "limit=200")
    }
}

struct EventSlideMatcherTests {
    private let today = "2026-10-23"
    private let events = [
        ChurchEvent(title: "Fall Festival", startDate: "2026-10-18"),
        ChurchEvent(title: "Shoebox Drive", startDate: "2026-10-12", endDate: "2026-11-22"),
        ChurchEvent(title: "Discover Hope", startDate: "2026-10-07"),
        ChurchEvent(title: "Discover Hope", startDate: "2026-11-04"),
        ChurchEvent(title: "Kids Christmas Party", startDate: "2026-12-05"),
        ChurchEvent(title: "Baptisms", startDate: "2026-09-20"),
    ]

    private func slide(_ id: String, name: String = "", text: String = "", media: String = "") -> EventSlideMatcher.SlideFacts {
        .init(id: id, name: name, text: text, mediaName: media)
    }

    @Test func promosAreSortedIntoPassedCurrentAndUnmatched() {
        let verdicts = EventSlideMatcher.classify([
            slide("1", name: "Fall Festival"),
            slide("2", media: "shoebox-drive-1920x1080.png"),
            slide("3", name: "Welcome to Hope", text: "We're glad you're here"),
            slide("4", name: "Discover Hope"),
            slide("5", media: "KidsChristmasParty_v2.jpg"),
            slide("6", name: "Baptism Sunday"),
        ], events: events, today: today)
        #expect(verdicts.map(\.status) == [.passed, .current, .unmatched, .current, .current, .passed])
        #expect(verdicts[0].event?.title == "Fall Festival")
        #expect(verdicts[3].event?.startDate == "2026-11-04", "a recurring event matches its next date")
        #expect(verdicts[5].event?.title == "Baptisms", "baptism / baptisms count as the same word")
        #expect(verdicts[2].event == nil)
    }

    @Test func aDateOnTheSlidePicksTheRightOccurrence() {
        let verdict = EventSlideMatcher.classify(
            [slide("1", name: "Discover Hope", text: "Wednesday, Oct 7 at 6:30")], events: events, today: today)[0]
        #expect(verdict.event?.startDate == "2026-10-07")
        #expect(verdict.status == .passed)
    }

    @Test func datesAloneDecideWhenNoEventMatches() {
        let verdicts = EventSlideMatcher.classify([
            slide("1", name: "Men's Breakfast", text: "Saturday, September 12"),
            slide("2", name: "Women's Retreat", text: "Nov 6-8"),
            slide("3", name: "Missions Sunday", text: "Jan 10"),
        ], events: events, today: today)
        #expect(verdicts.map(\.status) == [.passed, .current, .current])
        #expect(verdicts[0].reason.contains("2026-09-12"))
        #expect(verdicts[2].reason.contains("2027-01-10"), "a month far behind today means next year")
    }

    @Test func slideDatesAreRead() {
        #expect(EventSlideMatcher.dates(in: "October 25th, 2026 and 11/4", today: today) == ["2026-10-25", "2026-11-04"])
        #expect(EventSlideMatcher.dates(in: "Sept. 14", today: today) == ["2026-09-14"])
        #expect(EventSlideMatcher.dates(in: "12/05/26", today: today) == ["2026-12-05"])
        #expect(EventSlideMatcher.dates(in: "Room 101 holds 20 people", today: today).isEmpty)
        #expect(EventSlideMatcher.dates(in: "No dates here", today: today).isEmpty)
    }

    @Test func weakOverlapIsNotAMatch() {
        let verdict = EventSlideMatcher.classify(
            [slide("1", name: "Kids Check-in")], events: events, today: today)[0]
        #expect(verdict.status == .unmatched, "one word of three is not enough")
        #expect(EventSlideMatcher.words("Fall-Festival_1920x1080 FINAL.png") == ["fall", "festival"])
    }
}
