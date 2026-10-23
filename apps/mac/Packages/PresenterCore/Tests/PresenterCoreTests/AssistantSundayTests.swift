import Foundation
@testable import PresenterCore
import Testing

/// Build Sunday and Check song lyrics: the lyrics comparison, the choices
/// behind Build Sunday, the job wording and the new tools' inputs. No
/// network; Shepherd's search is a closure here. The hymn is Amazing Grace,
/// which is in the public domain.
struct LyricsCheckTests {
    static let lyrics = """
    Verse 1
    Amazing grace, how sweet the sound
    That saved a wretch like me!
    I once was lost, but now am found;
    Was blind, but now I see.

    Verse 2
    'Twas grace that taught my heart to fear,
    And grace my fears relieved;
    How precious did that grace appear
    The hour I first believed.

    Verse 3
    Through many dangers, toils and snares,
    I have already come;
    'Tis grace hath brought me safe thus far,
    And grace will lead me home.
    """

    static var reference: [LyricsCheck.Section] { LyricsCheck.referenceSections(lyrics: lyrics, chordChart: nil) }

    /// The slides an import would make, two lines each.
    static func slides(_ edit: (inout [LyricsCheck.SlideText]) -> Void = { _ in }) -> [LyricsCheck.SlideText] {
        var slides: [LyricsCheck.SlideText] = []
        for section in reference {
            for (index, start) in stride(from: 0, to: section.lines.count, by: 2).enumerated() {
                slides.append(LyricsCheck.SlideText(
                    id: "\(section.label ?? "x")-\(index)", section: section.label,
                    lines: Array(section.lines[start..<min(start + 2, section.lines.count)])))
            }
        }
        edit(&slides)
        return slides
    }

    @Test func theLyricsAreReadIntoCleanSections() {
        let sections = Self.reference
        #expect(sections.map(\.label) == ["Verse 1", "Verse 2", "Verse 3"])
        #expect(sections[0].lines == [
            "Amazing grace how sweet the sound", "That saved a wretch like me",
            "I once was lost but now am found", "Was blind but now I see",
        ])
        #expect(sections[1].lines[0] == "'Twas grace that taught my heart to fear", "apostrophes stay")
    }

    @Test func aChordChartIsReadWhenThereAreNoLyrics() {
        let chart = "{title: Amazing Grace}\n{comment: Verse 1}\n[G]Amazing [C]grace how [G]sweet the sound\n[G]That saved a [D]wretch like me"
        let sections = LyricsCheck.referenceSections(lyrics: "  ", chordChart: chart)
        #expect(sections == [LyricsCheck.Section(
            label: "Verse 1", lines: ["Amazing grace how sweet the sound", "That saved a wretch like me"])])
        #expect(LyricsCheck.referenceSections(lyrics: nil, chordChart: nil).isEmpty)
    }

    @Test func unlabelledParagraphsAreSectionsOfTheirOwn() {
        let sections = LyricsCheck.referenceSections(lyrics: "One line here\nTwo line here\n\nThree line here", chordChart: nil)
        #expect(sections.count == 2)
        #expect(sections.allSatisfy { $0.label == nil })
    }

    @Test func matchingSlidesMatch() {
        let report = LyricsCheck.compare(slides: Self.slides(), reference: Self.reference)
        #expect(report.wordsMatch)
        #expect(report.issues.isEmpty && report.fixes.isEmpty)
        #expect(report.referenceLines == 12 && report.slideLines == 12 && report.matchedLines == 12)
    }

    @Test func punctuationOnSlidesIsNotADifference() {
        let slides = Self.slides { $0[0].lines = ["Amazing grace, how sweet the sound", "That saved a wretch like me!"] }
        #expect(LyricsCheck.compare(slides: slides, reference: Self.reference).wordsMatch)
    }

    @Test func aTypoIsSpellingAndTheFixKeepsThePunctuation() {
        let slides = Self.slides { $0[0].lines[0] = "Amazing grase, how sweet the sound" }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(!report.wordsMatch)
        #expect(report.issues.count == 1)
        #expect(report.issues[0].kind == .spelling)
        #expect(report.issues[0].changes == [.spelling(had: "grase", expected: "grace")])
        #expect(report.issues[0].section == "Verse 1")
        #expect(report.fixes == [LyricsCheck.Fix(
            slideID: "Verse 1-0",
            original: "Amazing grase, how sweet the sound\nThat saved a wretch like me",
            words: "Amazing grace, how sweet the sound\nThat saved a wretch like me",
            withCapitalization: "Amazing grace, how sweet the sound\nThat saved a wretch like me")])
    }

    @Test func aMissingApostropheIsSpelling() {
        let slides = Self.slides { $0[2].lines[0] = "Twas grace that taught my heart to fear" }
        // "'Twas" against "Twas": the leading apostrophe isn't inside the word, so it matches.
        #expect(LyricsCheck.compare(slides: slides, reference: Self.reference).wordsMatch)
        let reference = [LyricsCheck.Section(label: "Verse 1", lines: ["It's the time"])]
        let typo = [LyricsCheck.SlideText(id: "s", section: "Verse 1", lines: ["Its the time"])]
        #expect(LyricsCheck.compare(slides: typo, reference: reference).issues.first?.changes == [.spelling(had: "Its", expected: "It's")])
    }

    @Test func aDifferentWordIsWording() {
        let slides = Self.slides { $0[4].lines[0] = "Through many dangers toils and traps" }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.issues.map(\.kind) == [.wording])
        #expect(report.issues[0].changes == [.wording(had: "traps", expected: "snares")])
        #expect(report.fixes.first?.words.hasPrefix("Through many dangers toils and snares\n") == true)
    }

    @Test func missingAndExtraWordsAreNamed() {
        let slides = Self.slides { $0[0].lines[1] = "That saved a poor wretch me" }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.issues.count == 1)
        #expect(report.issues[0].changes.contains(.extra("poor")))
        #expect(report.issues[0].changes.contains(.missing("like")))
        #expect(report.fixes.first?.words == "Amazing grace how sweet the sound\nThat saved a wretch like me")
    }

    @Test func aMissingLineGoesBackBesideItsNeighbour() {
        let slides = Self.slides { $0[1].lines = ["I once was lost but now am found"] }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.missingLines == [LyricsCheck.MissingLine(
            section: "Verse 1", expected: "Was blind but now I see", slideID: "Verse 1-1", insertAt: 1)])
        #expect(report.fixes.first { $0.slideID == "Verse 1-1" }?.words
            == "I once was lost but now am found\nWas blind but now I see")
    }

    @Test func anExtraLineIsReportedButNotRemoved() {
        let slides = Self.slides { $0[5].lines.append("Hallelujah hallelujah") }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.extraLines.map(\.had) == ["Hallelujah hallelujah"])
        #expect(report.extraLines.first?.slideID == "Verse 3-1")
        #expect(report.fixes.isEmpty, "extra lines may be on purpose; they're reported, not cut")
    }

    @Test func missingAndExtraSections() {
        let slides = Self.slides { slides in
            slides.removeAll { $0.section == "Verse 3" }
            slides.append(LyricsCheck.SlideText(id: "tag", section: "Tag", lines: ["My chains are gone", "I've been set free"]))
        }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.missingSections == [LyricsCheck.SectionNote(
            label: "Verse 3", lines: 4, opening: "Through many dangers toils…", slideIDs: [])])
        #expect(report.extraSections.map(\.label) == ["Tag"])
        #expect(report.extraSections.first?.slideIDs == ["tag"])
        #expect(report.missingLines.isEmpty, "a whole missing section isn't also listed line by line")
    }

    @Test func aRepeatedSlideIsComparedOnce() {
        let slides = Self.slides { $0.append(LyricsCheck.SlideText(id: "again", section: nil, lines: $0[0].lines)) }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.repeatedSlides == 1)
        #expect(report.wordsMatch)
    }

    @Test func aRepeatedSlideGetsTheSameFix() {
        let slides = Self.slides { slides in
            slides[0].lines[0] = "Amazing grase, how sweet the sound"
            // The copy has its own capitals and punctuation; they stay.
            slides.append(LyricsCheck.SlideText(id: "again", section: "Verse 1",
                                                lines: ["amazing grase how sweet the sound", "That saved a wretch like me"]))
        }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.repeatedSlides == 1)
        let copy = report.fixes.first { $0.slideID == "again" }
        #expect(copy?.copyOf == "Verse 1-0")
        #expect(copy?.words == "amazing grace how sweet the sound\nThat saved a wretch like me")
        #expect(report.fixes(with: "again").map(\.slideID) == ["Verse 1-0", "again"], "either id fixes both")
        #expect(report.fixes(with: "Verse 1-0").map(\.slideID) == ["Verse 1-0", "again"])
        let numbers = Dictionary(slides.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        #expect(report.json(slideNumbers: numbers).jsonString.contains("\"same_words_as_slide\":1"))
    }

    @Test func aMissingLineIsMarkedAsAdded() {
        let slides = Self.slides { $0[1].lines = ["I once was lost but now am found"] }
        let fix = LyricsCheck.compare(slides: slides, reference: Self.reference).fixes.first { $0.slideID == "Verse 1-1" }
        #expect(fix?.addedLines == [1])
    }

    @Test func returnsInTheTextAreLineBreaks() {
        #expect(LyricsCheck.lines(of: "One\r\nTwo\rThree\nFour") == ["One", "Two", "Three", "Four"])
    }

    // MARK: Chords and styles through a fix

    static func box(_ chordPro: String, runs: [TextStyleRun] = []) -> SlideObject {
        let extracted = ChordMath.extract(chordPro)
        return SlideObject(id: "box", objectKind: .text, name: "Lyrics", text: extracted.text,
                           chords: extracted.chords, styleRuns: runs.isEmpty ? nil : runs)
    }

    static func chordPro(_ object: SlideObject) -> String {
        ChordMath.bracketed(object.text, chords: object.chords ?? [])
    }

    @Test func chordsStayOnTheirWordsThroughAFix() throws {
        let object = Self.box("[G]Amazing [C]gra[G]se how [G]sweet the sound\nThat saved a [D]wretch [G]me")
        let fixed = try #require(LyricsCheck.rewrite(
            object, to: "Amazing grace how sweet the sound\nThat saved a wretch like me\nI once was lost", addedLines: [2]))
        #expect(Self.chordPro(fixed) == "[G]Amazing [C]gra[G]ce how [G]sweet the sound\nThat saved a [D]wretch like [G]me\nI once was lost")
    }

    @Test func aFixFromTheCheckKeepsTheChords() throws {
        let slides = Self.slides { $0[0].lines = ["Amazing grase how sweet the sound", "That saved a wretch me"] }
        let fix = try #require(LyricsCheck.compare(slides: slides, reference: Self.reference).fixes.first)
        let object = Self.box("[G]Amazing [G7]grase how [C]sweet the [G]sound\nThat saved a [Em]wretch [D]me")
        #expect(object.text == fix.original)
        let fixed = try #require(LyricsCheck.rewrite(object, to: fix.words, addedLines: fix.addedLines))
        #expect(Self.chordPro(fixed) == "[G]Amazing [G7]grace how [C]sweet the [G]sound\nThat saved a [Em]wretch like [D]me")
    }

    @Test func aReplacedWordKeepsItsChord() throws {
        let object = Self.box("Through many dangers toils and [D]traps")
        let fixed = try #require(LyricsCheck.rewrite(object, to: "Through many dangers toils and snares", addedLines: []))
        #expect(Self.chordPro(fixed) == "Through many dangers toils and [D]snares")
    }

    @Test func aChordOnAWordTakenOutStopsTheFix() {
        let object = Self.box("That saved a [D]poor wretch like me")
        #expect(LyricsCheck.rewrite(object, to: "That saved a wretch like me", addedLines: []) == nil)
        #expect(LyricsCheck.rewrite(object, to: "That saved a poor wretch like me", addedLines: [0]) == nil,
                "a line count that doesn't add up")
    }

    @Test func styleRunsMoveWithTheirWordsOrGo() throws {
        let object = Self.box("Amazing grase how sweet the sound\nThat saved a wretch me", runs: [
            TextStyleRun(line: 0, column: 8, length: 5, underline: true),       // "grase"
            TextStyleRun(line: 0, column: 2, length: 3, colorHex: "#FF0000"),   // inside "Amazing"
            TextStyleRun(line: 1, column: 0, length: 22, fontSize: 80),         // the whole line
            TextStyleRun(line: 1, column: 13, length: 6, strikethrough: true),  // "wretch"
        ])
        let fixed = try #require(LyricsCheck.rewrite(
            object, to: "Amazing grace how sweet the sound\nThat saved a wretch like me", addedLines: []))
        #expect(fixed.styleRuns == [
            TextStyleRun(line: 0, column: 8, length: 5, underline: true),
            TextStyleRun(line: 1, column: 0, length: 27, fontSize: 80),
            TextStyleRun(line: 1, column: 13, length: 6, strikethrough: true),
        ])
    }

    @Test func linesAfterAnAddedLineMoveDown() throws {
        let object = Self.box("[G]I once was lost\n[D]Was blind", runs: [TextStyleRun(line: 1, column: 0, length: 9, underline: true)])
        let fixed = try #require(LyricsCheck.rewrite(object, to: "[new]\nI once was lost\nWas blind", addedLines: [0]))
        #expect(fixed.chords == [ChordPlacement(line: 1, column: 0, symbol: "G"), ChordPlacement(line: 2, column: 0, symbol: "D")])
        #expect(fixed.styleRuns == [TextStyleRun(line: 2, column: 0, length: 9, underline: true)])
    }

    @Test func swappedSectionNamesAreNoticed() {
        let slides = Self.slides { slides in
            for index in slides.indices {
                if slides[index].section == "Verse 1" { slides[index].section = "Verse 2" }
                else if slides[index].section == "Verse 2" { slides[index].section = "Verse 1" }
            }
        }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.wordsMatch, "the words still pair up")
        #expect(Set(report.relabeled.map(\.slides)) == ["Verse 1", "Verse 2"])
    }

    @Test func lyricsWithoutSectionNamesCompareAsOneSong() {
        let plain = Self.lyrics.components(separatedBy: "\n").filter { !$0.hasPrefix("Verse") }.joined(separator: "\n")
        let reference = LyricsCheck.referenceSections(lyrics: plain, chordChart: nil)
        #expect(reference.allSatisfy { $0.label == nil })
        let report = LyricsCheck.compare(slides: Self.slides(), reference: reference)
        #expect(report.wordsMatch)
        #expect(report.matchedLines == 12)
    }

    @Test func capitalsAgainstTheLyricsAreOptionalInTheFix() {
        let slides = Self.slides { $0[0].lines[0] = "amazing Grace how sweet the sound" }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.wordsMatch, "capitals don't count against a match")
        #expect(report.issues.first?.kind == .capitalization)
        let fix = report.fixes.first
        #expect(fix?.changesWords == false)
        #expect(fix?.withCapitalization == "Amazing grace how sweet the sound\nThat saved a wretch like me")
    }

    @Test func capitalsThatDisagreeAcrossTheSlidesAreListed() {
        let slides = [
            LyricsCheck.SlideText(id: "a", section: nil, lines: ["I will praise You", "Forever you reign"]),
            LyricsCheck.SlideText(id: "b", section: nil, lines: ["you are good", "All my days"]),
        ]
        let found = LyricsCheck.capitalization(of: slides)
        #expect(found.upperStarts == 3 && found.lowerStarts == 1)
        #expect(found.oddStarts.map(\.slideID) == ["b"])
        #expect(found.words.map(\.word) == ["you"])
        #expect(Set(found.words.first?.forms.map(\.text) ?? []) == ["You", "you"])
    }

    @Test func slidesWithSeveralTextBoxesGetNoFix() {
        let slides = Self.slides { slides in
            slides[0].lines[0] = "Amazing grase how sweet the sound"
            slides[0].editable = false
        }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.fixes.isEmpty)
        #expect(report.notEditable == ["Verse 1-0"])
    }

    @Test func theSongOrderIsComparedWithThePlan() {
        let order = LyricsCheck.order(
            planned: ["V1", "C", "V2", "V1"], slideOrder: ["Verse 1", "Verse 2", "Verse 1"],
            sections: ["Verse 1", "Verse 2", "Verse 3"])
        #expect(order?.matches == false)
        #expect(order?.notInSlides == ["C"])
        let same = LyricsCheck.order(planned: ["Verse", "Chorus 1"], slideOrder: ["Verse 1", "Chorus"], sections: ["Verse 1", "Chorus"])
        #expect(same?.matches == true && same?.notInSlides.isEmpty == true)
        #expect(LyricsCheck.order(planned: [], slideOrder: nil, sections: []) == nil)
        let report = LyricsCheck.compare(slides: Self.slides(), reference: Self.reference, planned: ["V1", "V2", "V3"], slideOrder: nil)
        #expect(report.order?.slides == nil && report.order?.matches == false)
    }

    @Test func typosAreCloseWordsOnly() {
        #expect(LyricsCheck.isClose("grace", "grase"))
        #expect(LyricsCheck.isClose("everlasting", "everlastnig"))
        #expect(!LyricsCheck.isClose("the", "thy"), "short words differ by meaning")
        #expect(!LyricsCheck.isClose("snares", "traps"))
        #expect(LyricsCheck.distance("kitten", "sitting") == 3)
    }

    @Test func theModelGetsDifferencesNotTheSong() {
        let slides = Self.slides { $0[0].lines[0] = "Amazing grase how sweet the sound" }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference, planned: ["V1", "V2", "V3"],
                                         slideOrder: ["Verse 1", "Verse 2", "Verse 3"])
        let numbers = Dictionary(slides.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        let json = report.json(slideNumbers: numbers)
        let text = json.jsonString
        #expect(json["words_match"] == false)
        #expect(json["line_differences"]?.array?.first?["slide"] == 1)
        #expect(json["line_differences"]?.array?.first?["changes"] == [["had": "grase", "expected": "grace"]])
        #expect(json["fixes"]?.array?.first?["slide_id"] == "Verse 1-0")
        #expect(json["section_order"]?["matches"] == true)
        for line in Self.reference.flatMap(\.lines) {
            #expect(!text.contains(line), "a matching line never goes to the model: \(line)")
        }
    }

    @Test func aLongListIsCapped() {
        let slides = Self.slides { slides in
            for index in slides.indices { slides[index].lines = slides[index].lines.map { $0 + " oh" } }
        }
        let report = LyricsCheck.compare(slides: slides, reference: Self.reference)
        #expect(report.issues.count == 12)
        let json = report.json(slideNumbers: [:], limit: 5)
        #expect(json["line_differences"]?.array?.count == 5)
        #expect(json["truncated"] == true)
    }
}

struct SundayPrepTests {
    static func plan(_ id: String, _ date: String, origin: String? = nil, items: [ServiceItem] = [], template: Bool = false) -> Service {
        Service(id: id, name: id, serviceDate: date, items: items, origin: origin, isTemplate: template ? true : nil)
    }

    static func countdown(_ video: String) -> ServiceItem {
        var item = ServiceItem(id: "cd-\(video)", itemKind: .media, name: "Countdown", refId: video)
        item.isCountdown = true
        return item
    }

    @Test func theNextPlanIsShepherdsWhenThereIsOne() {
        let plans = [
            Self.plan("past", "2026-10-18", origin: "shepherd"),
            Self.plan("wednesday", "2026-10-21"),
            Self.plan("sunday", "2026-10-25", origin: "shepherd"),
            Self.plan("later", "2026-11-01", origin: "shepherd"),
            Self.plan("template", "2026-10-20", template: true),
        ]
        #expect(SundayPrep.nextPlan(plans, today: "2026-10-20")?.id == "sunday")
        #expect(SundayPrep.nextPlan(plans.filter { $0.origin == nil }, today: "2026-10-20")?.id == "wednesday")
        #expect(SundayPrep.nextPlan(plans, today: "2026-10-25")?.id == "sunday", "today's plan counts all day")
        #expect(SundayPrep.nextPlan(plans, today: "2026-12-01") == nil)
    }

    @Test func songsWithoutSlidesAreTheFlaggedOnes() {
        var flagged = ServiceItem(id: "a", itemKind: .info, name: "Amazing Grace", refId: "")
        flagged.mxuSongTitle = "Amazing Grace"
        var linked = ServiceItem(id: "b", itemKind: .presentation, name: "Holy", refId: "p1")
        linked.mxuSongTitle = "Holy"
        let note = ServiceItem(id: "c", itemKind: .info, name: "Welcome", refId: "")
        let plan = Self.plan("p", "2026-10-25", items: [flagged, linked, note])
        #expect(SundayPrep.songsWithoutSlides(in: plan).map(\.id) == ["a"])
        #expect(SundayPrep.songsWithSlides(in: plan).map(\.id) == ["b"])
    }

    @Test func theCountdownSuggestionIsTheNewestNotUsedLastWeek() {
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let videos = [
            SundayPrep.Video(id: "old", name: "Old", folder: "Countdowns", added: day),
            SundayPrep.Video(id: "new", name: "New", folder: "Countdowns", added: day.addingTimeInterval(86_400)),
            SundayPrep.Video(id: "newest", name: "Newest", folder: "Countdowns/Fall", added: day.addingTimeInterval(2 * 86_400)),
            SundayPrep.Video(id: "loose", name: "Not a countdown", folder: "Backgrounds", added: day.addingTimeInterval(3 * 86_400)),
        ]
        let sunday = Self.plan("sunday", "2026-10-25")
        let plans = [sunday, Self.plan("last", "2026-10-18", items: [Self.countdown("newest")]),
                     Self.plan("month", "2026-10-04", items: [Self.countdown("new")])]
        #expect(SundayPrep.countdownsUsedLastWeek(before: sunday, among: plans) == ["newest"])
        #expect(SundayPrep.suggestedCountdown(videos, for: sunday, among: plans)?.id == "new")
        #expect(SundayPrep.suggestedCountdown(videos, for: sunday, among: [sunday])?.id == "newest")
        #expect(SundayPrep.suggestedCountdown(Array(videos.suffix(2)), for: sunday, among: plans) == nil)
    }

    @Test func serviceTimesComeFromTheServiceDaySetup() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let settings = ServiceDaySettings(services: [
            ServiceDayTime(id: "b", serviceTime: "11:15", restartTime: "10:50"),
            ServiceDayTime(id: "a", serviceTime: "09:30", restartTime: "09:00"),
        ])
        let friday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
        let proposed = SundayPrep.proposedServiceTimes(planDate: "2026-10-25", serviceDay: settings, now: friday, calendar: calendar)
        #expect(proposed.times == ["2026-10-25T09:30", "2026-10-25T11:15"])
        #expect(proposed.source == .serviceDay)

        let sundayMidMorning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 10))!
        #expect(SundayPrep.proposedServiceTimes(
            planDate: "2026-10-25", serviceDay: settings, now: sundayMidMorning, calendar: calendar).times == ["2026-10-25T11:15"],
            "a time already past is left out")

        let shepherd = [
            MxUPlanTime(hexId: "r", name: "Rehearsal", startsAt: "2026-10-25T12:00:00Z", isRehearsal: true),
            MxUPlanTime(hexId: "s", name: "Service", startsAt: "2026-10-25T14:00:00Z"),
        ]
        let fallback = SundayPrep.proposedServiceTimes(
            planDate: "2026-10-25", serviceDay: nil, shepherdTimes: shepherd, now: friday, calendar: calendar)
        #expect(fallback.times == ["2026-10-25T10:00"])
        #expect(fallback.source == .shepherd)
        #expect(SundayPrep.proposedServiceTimes(planDate: "2026-10-25", serviceDay: nil, now: friday, calendar: calendar).times.isEmpty)
    }
}

struct ShepherdSongMatchTests {
    actor Searches {
        var queries: [String] = []
        func add(_ query: String) { queries.append(query) }
    }

    static func song(_ id: String, _ title: String, ccli: String? = nil, archived: Bool? = nil) -> ShepherdClient.SongSummary {
        ShepherdClient.SongSummary(id: id, title: title, author: nil, ccliNumber: ccli, defaultKey: nil, archived: archived)
    }

    @Test func theCCLINumberComesFirstThenTheTitle() async throws {
        let library = [
            Self.song("old", "Amazing Grace", ccli: "22025", archived: true),
            Self.song("ccli", "Amazing Grace (My Chains Are Gone)", ccli: "22025"),
            Self.song("title", "Amazing Grace"),
        ]
        let searches = Searches()
        let search: @Sendable (String) async throws -> [ShepherdClient.SongSummary] = { query in
            await searches.add(query)
            return library.filter { $0.ccliNumber == query || $0.title.localizedCaseInsensitiveContains(query) }
        }
        #expect(try await ShepherdSongMatch.find(ccli: "22025", title: "Amazing Grace", search: search)?.id == "ccli")
        #expect(await searches.queries == ["22025"])
        #expect(try await ShepherdSongMatch.find(ccli: "999", title: "amazing grace", search: search)?.id == "title")
        #expect(try await ShepherdSongMatch.find(ccli: nil, title: "Nothing Like It", search: search) == nil)
        #expect(ShepherdSongMatch.sameTitle("It Is Well (With My Soul)", "it is well with my soul"))
    }

    @Test func theArrangementIsTheOneThePlanUses() {
        func arrangement(_ id: String, _ name: String, _ sequence: [String]) -> ShepherdClient.SongArrangement {
            ShepherdClient.SongArrangement(id: id, name: name, tempo: nil, timeSignature: nil, lengthSeconds: nil,
                                           sequence: sequence, chordChart: nil, mediaLinks: [])
        }
        let song = ShepherdClient.SongDetail(
            id: "s", title: "Song", author: nil, ccliNumber: nil, copyright: nil, themes: [], defaultKey: nil, tempo: nil,
            timeSignature: nil, sequence: ["V1", "C"], archived: false, keys: [],
            arrangements: [arrangement("a1", "Default", []), arrangement("a2", "Christmas", ["V1", "C", "B"])],
            mediaLinks: [], updatedAt: .now, lyrics: nil, chordChart: nil, files: [])
        #expect(ShepherdSongMatch.arrangement(in: song, id: "a2", name: nil)?.name == "Christmas")
        #expect(ShepherdSongMatch.arrangement(in: song, id: "zz", name: "christmas")?.id == "a2")
        #expect(ShepherdSongMatch.arrangement(in: song, id: nil, name: nil)?.id == "a1")
        #expect(ShepherdSongMatch.sequence(of: song, arrangement: song.arrangements[1]) == ["V1", "C", "B"])
        #expect(ShepherdSongMatch.sequence(of: song, arrangement: song.arrangements[0]) == ["V1", "C"], "an empty one falls back to the song's")
    }
}

struct AssistantJobTests {
    private func tools(in text: String) -> Set<String> {
        let names = Set(AssistantToolCatalog.all.map(\.name))
        let words = text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
        return Set(words.filter { names.contains($0) })
    }

    @Test func buildSundayWalksEveryAreaAndAsksOnce() {
        let text = AssistantJob.buildSunday.instruction
        #expect(tools(in: text) == [
            "sync_shepherd", "check_service_readiness", "import_songs_from_shepherd", "list_themes",
            "build_message_from_notes", "match_slides_to_events", "apply_sunday_setup", "delete_slides", "schedule_service",
        ])
        #expect(text.contains("Call apply_sunday_setup once"))
        #expect(text.contains("Don't call delete_slides or schedule_service separately"))
        for area in ["Songs", "Message", "Pre-service", "Countdown", "Schedule"] {
            #expect(text.contains(area), "the checklist covers \(area)")
        }
        #expect(text.contains("✓") && text.contains("⚠"))
        #expect(text.contains("Media › Countdowns"))
        #expect(!text.localizedCaseInsensitiveContains("SongSelect") || text.contains("Get Lyrics (SongSelect)"),
                "the job never goes to SongSelect itself")
    }

    @Test func checkLyricsNamesTheSongOrThePlan() {
        let one = AssistantJob.checkSongLyrics(song: "  Amazing Grace ").instruction
        #expect(one.contains("\"Amazing Grace\""))
        let all = AssistantJob.checkSongLyrics(song: nil).instruction
        #expect(all.contains("every song in the next upcoming plan"))
        for text in [one, all] {
            #expect(tools(in: text) == ["check_song_lyrics", "apply_lyric_fixes"])
            #expect(text.contains("never whole verses"))
        }
    }

    @Test func jobsAreDistinctAndTitled() {
        let jobs: [AssistantJob] = [.updatePreService, .announcementsFromCards, .buildSunday,
                                    .checkSongLyrics(song: nil), .checkSongLyrics(song: "Holy")]
        #expect(Set(jobs.map(\.id)).count == jobs.count)
        #expect(AssistantJob.buildSunday.title == "Build Sunday")
        #expect(AssistantJob.checkSongLyrics(song: "x").title == "Check song lyrics")
        for job in jobs {
            #expect(!job.instruction.isEmpty && !job.systemImage.isEmpty)
            #expect(!job.instruction.contains("  "), "line continuations leave no double spaces: \(job.id)")
            for tool in tools(in: job.instruction) {
                #expect(AssistantToolCatalog.spec(tool) != nil, "\(job.id) names \(tool)")
            }
        }
    }
}

struct AssistantSundayToolInputTests {
    private func check(_ tool: String, _ input: AssistantJSON) -> String? {
        AssistantToolInput.validate(input, against: AssistantToolCatalog.spec(tool)!.schema)
    }

    @Test func goodInputPasses() {
        #expect(check("sync_shepherd", [:]) == nil)
        #expect(check("check_service_readiness", [:]) == nil)
        #expect(check("check_service_readiness", ["plan_id": "p"]) == nil)
        #expect(check("import_songs_from_shepherd", ["plan_id": "p", "item_ids": ["a"]]) == nil)
        #expect(check("build_message_from_notes", ["attachment": "att_1", "plan_id": "p", "series_id": "s"]) == nil)
        #expect(check("apply_sunday_setup", [
            "plan_id": "p", "countdown_media_id": "m", "service_times": ["2026-10-25T09:30"], "series_id": "s",
            "remove_slides": ["presentation_id": "pre", "slide_ids": ["a"], "reason": "Events have passed"],
        ]) == nil)
        #expect(check("check_song_lyrics", [:]) == nil, "which song is checked in the app, with a readable error")
        #expect(check("check_song_lyrics", ["plan_id": "p", "item_id": "i"]) == nil)
        #expect(check("apply_lyric_fixes", ["presentation_id": "p", "slide_ids": ["a"], "include_capitalization": true]) == nil)
    }

    @Test func badInputIsExplained() {
        #expect(check("import_songs_from_shepherd", [:]) == "input.plan_id is required")
        #expect(check("build_message_from_notes", ["attachment": " ", "plan_id": "p"]) == "input.attachment must not be empty")
        #expect(check("build_message_from_notes", ["attachment": "att_1", "plan_id": "p", "replace_existing": "yes"])
            == "input.replace_existing must be true or false")
        #expect(check("apply_sunday_setup", ["countdown_media_id": "m"]) == "input.plan_id is required")
        #expect(check("apply_sunday_setup", ["plan_id": "p", "remove_slides": ["presentation_id": "pre"]])
            == "input.remove_slides.slide_ids is required")
        #expect(check("apply_sunday_setup", ["plan_id": "p", "service_times": AssistantJSON(Array(repeating: "2026-10-25T09:00", count: 9))])
            == "input.service_times takes at most 8 items")
        #expect(check("apply_sunday_setup", ["plan_id": "p", "delete_everything": true]) == "input.delete_everything is not a known field")
        #expect(check("check_song_lyrics", ["song": "Holy"]) == "input.song is not a known field")
        #expect(check("apply_lyric_fixes", ["presentation_id": "p", "slide_ids": []]) == "input.slide_ids needs at least 1 item")
        #expect(check("apply_lyric_fixes", ["presentation_id": "p", "slide_ids": ["a"], "text": "new words"])
            == "input.text is not a known field", "fixes come from the check, never from the model's own words")
    }
}
