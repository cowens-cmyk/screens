import Foundation
import PresenterCore

/// Runs the Assistant's tools against the library, through AppModel's own
/// edit paths so every change lands like an operator's (undo included).
/// Each tool answers with compact JSON; anything the model got wrong comes
/// back as an error it can read and correct.
@MainActor
final class AssistantToolbox {
    struct Outcome {
        var content: String
        var isError = false
        /// One line for the panel ("Removed 2 slides from Pre-Service").
        var activity: String?
    }

    struct Failure: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    let model: AppModel
    weak var router: ActionRouter?
    /// The pictures attached so far in this conversation, by id.
    var attachments: [String: AssistantAttachment] = [:]
    private var eventCache: (day: String, at: Date, result: ChurchEventsFetcher.Result)?
    /// The last lyrics check of each song presentation: the corrected words
    /// wait here for apply_lyric_fixes, so lyrics never have to travel
    /// through the conversation to be applied.
    var lyricChecks: [String: LyricsCheck.Report] = [:]
    /// Messages built from notes, by attachment file and plan, so asking
    /// twice doesn't read the notes (or build the slides) twice.
    var builtMessages: [String: String] = [:]

    init(model: AppModel, router: ActionRouter?) {
        self.model = model
        self.router = router
    }

    static var today: String { DayStamp.of(.now) }

    // MARK: Running

    func run(_ name: String, input: AssistantJSON) async -> Outcome {
        do {
            let (result, activity) = try await perform(name, input)
            return Outcome(content: result.jsonString, activity: activity)
        } catch let failure as Failure {
            return Outcome(content: failure.message, isError: true, activity: nil)
        } catch {
            return Outcome(content: error.localizedDescription, isError: true, activity: nil)
        }
    }

    private func perform(_ name: String, _ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        switch name {
        case "list_plans": try await listPlans(input)
        case "get_plan": try await getPlan(input)
        case "list_presentations": try await listPresentations(input)
        case "get_presentation": try await getPresentation(input)
        case "search_slides": try await searchSlides(input)
        case "list_media": try await listMedia(input)
        case "list_themes": try await listThemes()
        case "create_presentation": try await createPresentation(input)
        case "add_slides": try await addSlides(input)
        case "delete_slides": try await deleteSlides(input)
        case "reorder_slides": try await reorderSlides(input)
        case "set_slide_text": try await setSlideText(input)
        case "set_slide_background": try await setSlideBackground(input)
        case "set_slide_livestream": try await setSlideLivestream(input)
        case "set_auto_advance": try await setAutoAdvance(input)
        case "update_presentation": try await updatePresentation(input)
        case "add_item_to_plan": try await addItemToPlan(input)
        case "remove_plan_item": try await removePlanItem(input)
        case "schedule_service": try await scheduleService(input)
        case "fetch_church_events": try await fetchEvents(input)
        case "match_slides_to_events": try await matchSlides(input)
        case "import_announcement_cards": try await importCards(input)
        case "sync_shepherd": try await syncShepherd()
        case "check_service_readiness": try await checkReadiness(input)
        case "import_songs_from_shepherd": try await importSongs(input)
        case "build_message_from_notes": try await buildMessage(input)
        case "apply_sunday_setup": try await applySundaySetup(input)
        case "check_song_lyrics": try await checkSongLyrics(input)
        case "apply_lyric_fixes": try await applyLyricFixes(input)
        default: throw Failure("There is no tool named \(name).")
        }
    }

    // MARK: Confirmation

    /// What the user is asked to approve before a destructive tool runs.
    /// Throws when the call can't run at all, so nothing is asked.
    func confirmation(for name: String, input: AssistantJSON) async throws -> (title: String, detail: String) {
        switch name {
        case "delete_slides":
            let deck = try await presentation(input["presentation_id"]?.string)
            let ids = input["slide_ids"]?.array?.compactMap(\.string) ?? []
            let doomed = try slides(ids, in: deck)
            guard doomed.count < deck.slides.count else {
                throw Failure("That would delete every slide. A presentation keeps at least one; delete the presentation in the library instead.")
            }
            let names = doomed.map { "• " + label(of: $0, in: deck) }.joined(separator: "\n")
            let why = input["reason"]?.string.map { "\n\n\($0)" } ?? ""
            return ("Delete \(count(doomed.count, "slide")) from \(deck.name)?", names + why)
        case "remove_plan_item":
            let plan = try await service(input["plan_id"]?.string)
            let item = try planItem(input["item_id"]?.string, in: plan)
            if item.mxuItemHexId != nil {
                throw Failure("\"\(item.name)\" comes from Shepherd and would come back on the next sync. Change it in Shepherd, or hide it in Screens (right-click the item).")
            }
            return ("Remove \"\(item.name)\" from \(plan.name)?", "The \(item.itemKind.rawValue) stays in the library.")
        case "schedule_service":
            let plan = try await service(input["plan_id"]?.string)
            let times = try serviceTimes(input)
            _ = try countdownVideo(plan)
            let existing = model.residentScheduleTriggers.filter { ServiceCountdown.isCountdownTrigger($0, planID: plan.id) }
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM d, h:mm a"
            var detail = times.map { "• " + formatter.string(from: $0) }.joined(separator: "\n")
            detail += "\n\nThe countdown video starts so it ends at each time."
            if !existing.isEmpty { detail += " Replaces \(count(existing.count, "countdown")) already scheduled." }
            return ("Schedule \(plan.name)?", detail)
        case "apply_sunday_setup":
            return try await sundaySetupConfirmation(input)
        case "apply_lyric_fixes":
            return try await lyricFixesConfirmation(input)
        default:
            return ("Run \(name)?", "")
        }
    }

    // MARK: Plans

    private func listPlans(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        await model.resident.ready([.service])
        let today = Self.today
        let includePast = input["include_past"]?.bool ?? false
        let limit = input["limit"]?.int ?? 12
        var plans = model.entries(of: .service).compactMap { (try? model.mainService($0.id)) }
            .filter { $0.isTemplate != true }
        if !includePast { plans = plans.filter { String($0.serviceDate.prefix(10)) >= today } }
        plans.sort { includePast ? $0.serviceDate > $1.serviceDate : $0.serviceDate < $1.serviceDate }
        let rows: [AssistantJSON] = plans.prefix(limit).map { plan in
            var fields: [String: AssistantJSON] = [
                "id": .string(plan.id), "name": .string(plan.name), "date": .string(plan.serviceDate),
                "items": .number(Double(plan.items.count)),
            ]
            if let type = plan.mxuServiceTypeName { fields["service_type"] = .string(type) }
            if plan.id == model.currentServiceID { fields["open_in_main_window"] = true }
            return .object(fields)
        }
        return (["today": .string(today), "plans": .array(rows)], "Looked at \(count(rows.count, "plan"))")
    }

    private func getPlan(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let plan = try await service(input["plan_id"]?.string)
        let items: [AssistantJSON] = plan.items.enumerated().map { index, item in
            var fields: [String: AssistantJSON] = [
                "id": .string(item.id), "position": .number(Double(index + 1)),
                "kind": .string(item.itemKind.rawValue), "name": .string(item.name),
            ]
            if !item.refId.isEmpty {
                fields["ref_id"] = .string(item.refId)
                if let entry = model.libraryEntry(item.refId), entry.name != item.name {
                    fields["library_name"] = .string(entry.name)
                }
            }
            if item.hiddenInPresenter == true { fields["hidden"] = true }
            if item.isCountdown == true {
                fields["countdown"] = true
                if item.refId.isEmpty { fields["countdown_video"] = "not chosen" }
            }
            if item.mxuItemHexId != nil { fields["from_shepherd"] = true }
            if item.mxuItemHexId != nil, item.refId.isEmpty, item.itemKind == .presentation { fields["no_slides"] = true }
            if let song = item.mxuSongTitle {
                fields["song"] = .string(song)
                if item.refId.isEmpty { fields["no_slides"] = true }
            }
            return .object(fields)
        }
        var fields: [String: AssistantJSON] = [
            "id": .string(plan.id), "name": .string(plan.name), "date": .string(plan.serviceDate), "items": .array(items),
        ]
        if let message = plan.messagePresentationId { fields["message_presentation_id"] = .string(message) }
        return (.object(fields), "Read plan \(plan.name)")
    }

    private func addItemToPlan(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let plan = try await service(input["plan_id"]?.string)
        let after = input["after_item_id"]?.string
        if let after { _ = try planItem(after, in: plan) }
        let ref = input["ref_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let header = input["header"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let item: ServiceItem
        switch (ref, header) {
        case (let ref?, nil):
            if let entry = model.libraryEntry(ref) {
                let kinds: [DocumentKind: ServiceItemKind] = [.presentation: .presentation, .media: .media, .audio: .audio, .playlist: .playlist]
                guard let kind = kinds[entry.kind] else { throw Failure("\(entry.name) can't go in a plan.") }
                item = ServiceItem(id: UUID().uuidString, itemKind: kind, name: entry.name, refId: ref)
            } else if let deck = await model.presentationsFilled([ref])[ref] {
                item = ServiceItem(id: UUID().uuidString, itemKind: .presentation, name: deck.name, refId: ref)
            } else {
                throw Failure("No presentation or media has the id \(ref).")
            }
        case (nil, let header?):
            item = ServiceItem(id: UUID().uuidString, itemKind: .header, name: header, refId: "")
        default:
            throw Failure("Give either ref_id or header.")
        }
        model.updateService(plan.id) { plan in
            let at = after.flatMap { id in plan.items.firstIndex { $0.id == id } }.map { $0 + 1 } ?? plan.items.count
            plan.items.insert(item, at: at)
        }
        if let ref { model.markUsed(ref) }
        return (["added_item_id": .string(item.id), "plan": .string(plan.name)], "Added \(item.name) to \(plan.name)")
    }

    private func removePlanItem(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let plan = try await service(input["plan_id"]?.string)
        let item = try planItem(input["item_id"]?.string, in: plan)
        model.removeServiceItem(plan.id, itemID: item.id)
        return (["removed": .string(item.name)], "Removed \(item.name) from \(plan.name)")
    }

    private func scheduleService(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let plan = try await service(input["plan_id"]?.string)
        let times = try serviceTimes(input)
        let (item, seconds) = try countdownVideo(plan)
        let rows = scheduleCountdowns(plan, item: item, videoSeconds: seconds, times: times)
        return (["plan": .string(plan.name), "scheduled": .array(rows)], "Scheduled \(plan.name) (\(count(times.count, "service")))")
    }

    // MARK: Presentations

    private func listPresentations(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let query = input["query"]?.string.map(Self.squash) ?? ""
        let category = input["category"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        let limit = input["limit"]?.int ?? 40
        var entries = model.entries(of: .presentation)
        if !query.isEmpty {
            entries = entries.filter { Self.squash($0.name + " " + $0.subkind).contains(query) }
        }
        var rows: [AssistantJSON] = []
        if category.isEmpty {
            rows = entries.prefix(limit).map { entry in
                var fields: [String: AssistantJSON] = ["id": .string(entry.id), "name": .string(entry.name)]
                if !entry.subkind.isEmpty { fields["folder"] = .string(entry.subkind) }
                return .object(fields)
            }
        } else {
            let candidates = Array(entries.prefix(400))
            let decks = await model.presentationsFilled(candidates.map(\.id))
            for entry in candidates {
                guard let deck = decks[entry.id],
                      PresentationTypes.category(of: deck)?.caseInsensitiveCompare(category) == .orderedSame
                else { continue }
                rows.append(summary(of: deck))
                if rows.count >= limit { break }
            }
        }
        return (["count": .number(Double(rows.count)), "presentations": .array(rows)],
                "Looked through presentations (\(rows.count) found)")
    }

    private func summary(of deck: Presentation) -> AssistantJSON {
        var fields: [String: AssistantJSON] = [
            "id": .string(deck.id), "name": .string(deck.name), "slides": .number(Double(deck.slides.count)),
        ]
        if let folder = deck.folder { fields["folder"] = .string(folder) }
        if let category = PresentationTypes.category(of: deck) { fields["category"] = .string(category) }
        if let advance = deck.autoAdvance {
            fields["auto_advance"] = ["seconds": .number(advance.delaySeconds), "loop": .bool(advance.loopToStart ?? false)]
        }
        return .object(fields)
    }

    private func getPresentation(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let deck = try await presentation(input["presentation_id"]?.string)
        await model.themesFilled([deck.themeId] + deck.slides.compactMap(\.themeId))
        var fields = summary(of: deck).object ?? [:]
        if let theme = model.theme(deck.themeId) {
            fields["theme"] = ["id": .string(theme.id), "name": .string(theme.name)]
        }
        fields["slides"] = .array(deck.slides.enumerated().map { index, slide in
            var row: [String: AssistantJSON] = ["id": .string(slide.id), "index": .number(Double(index + 1))]
            if !slide.name.isEmpty { row["name"] = .string(slide.name) }
            let text = Self.text(of: slide)
            if !text.isEmpty { row["text"] = .string(String(text.prefix(500))) }
            if let layout = slide.themeSlideName { row["layout"] = .string(layout) }
            if let media = mediaName(of: slide) { row["background"] = .string(media) }
            if let advance = slide.autoAdvance { row["auto_advance_seconds"] = .number(advance.delaySeconds) }
            let stream = AssistantLivestream(design: slide.streamDesign)
            if stream != .themeDefault { row["livestream"] = .string(stream.rawValue) }
            return .object(row)
        })
        return (.object(fields), "Read \(deck.name)")
    }

    private func searchSlides(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let hits = await model.search(input["query"]?.string ?? "")
        let rows: [AssistantJSON] = hits.prefix(25).map { hit in
            var fields: [String: AssistantJSON] = [
                "id": .string(hit.entry.id), "name": .string(hit.entry.name), "kind": .string(hit.entry.kind.rawValue),
            ]
            if let snippet = hit.snippet { fields["snippet"] = .string(snippet) }
            return .object(fields)
        }
        return (["results": .array(rows)], "Searched the library (\(count(rows.count, "match", "matches")))")
    }

    private func listMedia(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        await model.resident.ready([.media])
        let query = input["query"]?.string.map(Self.squash) ?? ""
        let kind = input["kind"]?.string.flatMap(MediaKind.init(rawValue:))
        let limit = input["limit"]?.int ?? 40
        let items = model.resident.media.values
            .filter { kind == nil || $0.mediaKind == kind }
            .filter { query.isEmpty || Self.squash($0.name + " " + ($0.folder ?? "")).contains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let rows: [AssistantJSON] = items.prefix(limit).map { item in
            var fields: [String: AssistantJSON] = [
                "id": .string(item.id), "name": .string(item.name), "kind": .string(item.mediaKind.rawValue),
            ]
            if let folder = item.folder { fields["folder"] = .string(folder) }
            if let seconds = item.durationSeconds { fields["seconds"] = .number(seconds.rounded()) }
            return .object(fields)
        }
        return (["count": .number(Double(items.count)), "media": .array(rows)], "Looked through media (\(items.count) found)")
    }

    private func listThemes() async throws -> (AssistantJSON, String?) {
        await model.resident.ready([.theme])
        let themes = model.resident.themes.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let rows: [AssistantJSON] = themes.map { theme in
            var fields: [String: AssistantJSON] = [
                "id": .string(theme.id), "name": .string(theme.name),
                "designs": AssistantJSON((theme.slides ?? []).map(\.name)),
            ]
            if theme.isSermonSeries == true { fields["sermon_series"] = true }
            return .object(fields)
        }
        return (["themes": .array(rows)], "Looked at \(count(rows.count, "theme"))")
    }

    private func createPresentation(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let name = (input["name"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let themeID = input["theme_id"]?.string ?? ""
        let theme = try await theme(themeID)
        let slides = try (input["slides"]?.array ?? []).map { try makeSlide($0, themeID: themeID, theme: theme) }
        let folder = input["folder"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        var deck = Presentation(
            id: UUID().uuidString, name: name, presentationKind: .deck, themeId: themeID, folder: folder, slides: slides)
        if let category = input["category"]?.string, !category.isEmpty { deck.category = category }
        if let seconds = input["auto_advance_seconds"]?.number, seconds > 0 {
            deck.autoAdvance = AutoAdvance(delaySeconds: seconds, loopToStart: input["loop"]?.bool ?? true)
        }
        _ = try? await model.createInDrive(deck, folder: folder).value
        return (["id": .string(deck.id), "name": .string(name), "slides": .number(Double(slides.count))],
                "Created \(name) (\(count(slides.count, "slide")))")
    }

    private func addSlides(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let deck = try await presentation(input["presentation_id"]?.string)
        let after = input["after_slide_id"]?.string
        if let after { _ = try slides([after], in: deck) }
        let theme = try await theme(deck.themeId)
        let made = try (input["slides"]?.array ?? []).map { try makeSlide($0, themeID: deck.themeId, theme: theme) }
        model.insertSlides(deck.id, slides: made, afterSlideID: after ?? deck.slides.last?.id)
        return (["added_slide_ids": AssistantJSON(made.map(\.id))], "Added \(count(made.count, "slide")) to \(deck.name)")
    }

    private func deleteSlides(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let deck = try await presentation(input["presentation_id"]?.string)
        let doomed = try slides(input["slide_ids"]?.array?.compactMap(\.string) ?? [], in: deck)
        guard doomed.count < deck.slides.count else { throw Failure("A presentation keeps at least one slide.") }
        let ids = Set(doomed.map(\.id))
        model.updatePresentation(deck.id) { $0.slides.removeAll { ids.contains($0.id) } }
        return (["deleted": AssistantJSON(doomed.map { label(of: $0, in: deck) }),
                 "slides_left": .number(Double(deck.slides.count - doomed.count))],
                "Removed \(count(doomed.count, "slide")) from \(deck.name)")
    }

    private func reorderSlides(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let deck = try await presentation(input["presentation_id"]?.string)
        let order = input["slide_ids"]?.array?.compactMap(\.string) ?? []
        guard order.count == deck.slides.count, Set(order) == Set(deck.slides.map(\.id)) else {
            throw Failure("slide_ids must list each of the \(deck.slides.count) slides exactly once.")
        }
        model.updatePresentation(deck.id) { presentation in
            let byID = Dictionary(presentation.slides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let reordered = order.compactMap { byID[$0] }
            if reordered.count == presentation.slides.count { presentation.slides = reordered }
        }
        return (["ok": true], "Reordered \(deck.name)")
    }

    private func setSlideText(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let deck = try await presentation(input["presentation_id"]?.string)
        let slide = try slides([input["slide_id"]?.string ?? ""], in: deck)[0]
        let text = input["text"]?.string
        let name = input["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != nil || name != nil else { throw Failure("Give text, name, or both.") }
        model.updateSlide(presentationID: deck.id, slideID: slide.id, undoLabel: "Edit Slide") { slide in
            if let text {
                if let index = slide.objects.firstIndex(where: { $0.objectKind == .text }) {
                    slide.objects[index].text = text
                } else {
                    slide.objects.append(SlideObject(id: UUID().uuidString, objectKind: .text, name: "Text", text: text))
                }
            }
            if let name { slide.name = name }
        }
        return (["ok": true], "Edited \(label(of: slide, in: deck)) in \(deck.name)")
    }

    private func setSlideBackground(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let deck = try await presentation(input["presentation_id"]?.string)
        let slide = try slides([input["slide_id"]?.string ?? ""], in: deck)[0]
        let cue = try input["media_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }.map { id in
            try backgroundCue(id, behindText: !Self.text(of: slide).isEmpty)
        }
        model.updateSlide(presentationID: deck.id, slideID: slide.id, undoLabel: "Set Background") { $0.background = cue }
        return (["ok": true], cue == nil ? "Cleared a background in \(deck.name)" : "Set a background in \(deck.name)")
    }

    private func setSlideLivestream(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let deck = try await presentation(input["presentation_id"]?.string)
        let targets = try slides(input["slide_ids"]?.array?.compactMap(\.string) ?? [], in: deck)
        guard let mode = input["mode"]?.string.flatMap(AssistantLivestream.init(rawValue:)) else {
            throw Failure("mode must be theme_default, lower_third, full_screen or nothing.")
        }
        let ids = Set(targets.map(\.id))
        var chosen = mode.design
        if let imageID = input["lower_third_image_id"]?.string, !imageID.isEmpty {
            guard mode == .lowerThird else { throw Failure("lower_third_image_id needs mode lower_third.") }
            guard let media = model.media(imageID), media.mediaKind == .image else {
                throw Failure("lower_third_image_id must be a picture in the media library.")
            }
            chosen = .lowerThirdImage(media.id)
        }
        let design = chosen
        model.updateSlides(presentationID: deck.id, undoLabel: "Livestream") { presentation in
            for index in presentation.slides.indices where ids.contains(presentation.slides[index].id) {
                presentation.slides[index].streamDesign = design
            }
        }
        router?.noteStreamDesign(design, forSlides: ids)
        let what = design?.lowerThirdImageID.flatMap { model.media($0)?.name }.map { "the lower-third picture \($0)" } ?? mode.title
        return (["ok": true], "Set livestream to \(what) on \(count(ids.count, "slide")) in \(deck.name)")
    }

    private func setAutoAdvance(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let deck = try await presentation(input["presentation_id"]?.string)
        let seconds = input["seconds"]?.number ?? 0
        if let ids = input["slide_ids"]?.array?.compactMap(\.string) {
            let targets = Set(try slides(ids, in: deck).map(\.id))
            let advance = seconds > 0 ? AutoAdvance(delaySeconds: seconds) : nil
            model.updateSlides(presentationID: deck.id, undoLabel: "Auto Advance") { presentation in
                for index in presentation.slides.indices where targets.contains(presentation.slides[index].id) {
                    presentation.slides[index].autoAdvance = advance
                }
            }
            return (["ok": true], seconds > 0
                ? "Set \(count(targets.count, "slide")) in \(deck.name) to \(Self.seconds(seconds))"
                : "Turned off auto-advance on \(count(targets.count, "slide")) in \(deck.name)")
        }
        let advance = seconds > 0 ? AutoAdvance(delaySeconds: seconds, loopToStart: input["loop"]?.bool ?? true) : nil
        model.updatePresentation(deck.id) { $0.autoAdvance = advance }
        return (["ok": true], seconds > 0
            ? "\(deck.name) now advances every \(Self.seconds(seconds))"
            : "Turned off auto-advance in \(deck.name)")
    }

    private func updatePresentation(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let deck = try await presentation(input["presentation_id"]?.string)
        let name = input["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = input["category"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != nil || category != nil else { throw Failure("Give a name, a category, or both.") }
        if let name, !name.isEmpty, name != deck.name, let entry = model.libraryEntry(deck.id) {
            model.rename(entry, to: name)
        }
        if let category {
            model.updatePresentation(deck.id) { $0.category = category.isEmpty ? nil : category }
        }
        return (["ok": true], "Updated \(name ?? deck.name)")
    }

    // MARK: Events

    func events(includeRecentPast: Bool = true) async throws -> ChurchEventsFetcher.Result {
        let today = Self.today
        if includeRecentPast, let cache = eventCache, cache.day == today, cache.at.timeIntervalSinceNow > -600 {
            return cache.result
        }
        let result = try await ChurchEventsFetcher.fetch(today: today, includeRecentPast: includeRecentPast)
        if includeRecentPast { eventCache = (today, .now, result) }
        return result
    }

    private func fetchEvents(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let today = Self.today
        let result = try await events(includeRecentPast: input["include_recent_past"]?.bool ?? true)
        var fields: [String: AssistantJSON] = [
            "today": .string(today), "source": .string(result.source),
            "events": .array(result.events.sorted { $0.startDate < $1.startDate }.map { $0.json(today: today) }),
        ]
        if let text = result.pageText { fields["page_text"] = .string(text) }
        let upcoming = result.events.filter { !$0.hasEnded(today: today) }.count
        return (.object(fields), "Checked hopejc.org events (\(upcoming) upcoming)")
    }

    private func matchSlides(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let deck = try await presentation(input["presentation_id"]?.string)
        let today = Self.today
        let result = try await events()
        guard !result.events.isEmpty else {
            throw Failure("Couldn't read any events from hopejc.org. Try fetch_church_events to see the page text.")
        }
        let facts = deck.slides.map { slide in
            EventSlideMatcher.SlideFacts(
                id: slide.id, name: slide.name, text: Self.text(of: slide), mediaName: mediaName(of: slide) ?? "")
        }
        let verdicts = EventSlideMatcher.classify(facts, events: result.events, today: today)
        let covered = Set(verdicts.filter { $0.status == .current }.compactMap { $0.event?.title.lowercased() })
        let soon = DayStamp.adding(60, to: today)
        let missing = result.events
            .filter { !$0.hasEnded(today: today) && $0.startDate <= soon && !$0.cancelled && !covered.contains($0.title.lowercased()) }
            .sorted { $0.startDate < $1.startDate }
        var seen = Set<String>()
        let uniqueMissing = missing.filter { seen.insert($0.title.lowercased()).inserted }.prefix(15)
        let rows = zip(verdicts.indices, zip(verdicts, facts)).map { index, pair in
            pair.0.json(index: index + 1, slide: pair.1, today: today)
        }
        let passed = verdicts.filter { $0.status == .passed }.count
        return ([
            "today": .string(today), "presentation": .string(deck.name),
            "slides": .array(rows),
            "upcoming_events_without_a_slide": .array(uniqueMissing.map { $0.json(today: today) }),
        ], "Matched \(deck.name) against events (\(passed) look passed)")
    }

    // MARK: Announcement cards

    private func importCards(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let cards = input["cards"]?.array ?? []
        let picked: [(attachment: AssistantAttachment, title: String, stream: AssistantLivestream?)] = try cards.map { card in
            let id = card["attachment_id"]?.string ?? ""
            guard let attachment = attachments[id] else {
                throw Failure("No attachment \(id). Attached so far: \(attachments.keys.sorted().joined(separator: ", ")).")
            }
            return (attachment, card["title"]?.string ?? attachment.label,
                    card["livestream"]?.string.flatMap(AssistantLivestream.init(rawValue:)))
        }
        // Find the presentation first, so a wrong id fails before anything is imported.
        var target: Presentation?
        if let id = input["presentation_id"]?.string, !id.isEmpty {
            target = try await presentation(id)
        } else {
            let name = input["presentation_name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? PresentationTypes.announcements
            if let entry = model.entries(of: .presentation).first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                target = try await presentation(entry.id)
            }
        }
        var slides: [Slide] = []
        for card in picked {
            guard let mediaID = await model.importFiles([card.attachment.fileURL]).first,
                  let item = model.media(mediaID)
            else { throw Failure("Couldn't import \(card.attachment.label) into the Media library.") }
            let title = card.title
            model.updateMedia(mediaID) { $0.name = title }
            var slide = Slide(id: UUID().uuidString, name: title, objects: [])
            slide.background = .droppedAsNewSlide(for: item)
            slide.unthemed = true
            slide.streamDesign = card.stream?.design
            slides.append(slide)
        }
        let names = slides.map(\.name)
        if let target {
            model.insertSlides(target.id, slides: slides, afterSlideID: target.slides.last?.id)
            return (["presentation_id": .string(target.id), "added": AssistantJSON(names)],
                    "Added \(count(slides.count, "announcement slide")) to \(target.name)")
        }
        let name = input["presentation_name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? PresentationTypes.announcements
        var deck = Presentation(id: UUID().uuidString, name: name, presentationKind: .deck, themeId: "", slides: slides)
        deck.category = PresentationTypes.announcements
        _ = try? await model.createInDrive(deck).value
        return (["presentation_id": .string(deck.id), "created": .string(name), "added": AssistantJSON(names)],
                "Created \(name) with \(count(slides.count, "slide"))")
    }

    // MARK: Lookups

    func presentation(_ id: String?) async throws -> Presentation {
        guard let id, !id.isEmpty else { throw Failure("presentation_id is required.") }
        guard let deck = await model.presentationsFilled([id])[id] else {
            throw Failure("No presentation has the id \(id). Use list_presentations to find it.")
        }
        return deck
    }

    func service(_ id: String?) async throws -> Service {
        guard let id, !id.isEmpty else { throw Failure("plan_id is required.") }
        await model.resident.ready([.service])
        guard let plan = try? model.service(id) else {
            throw Failure("No plan has the id \(id). Use list_plans to find it.")
        }
        return plan
    }

    private func theme(_ id: String) async throws -> Theme? {
        guard !id.isEmpty else { return nil }
        await model.resident.ready([.theme])
        guard let theme = model.theme(id) else { throw Failure("No theme has the id \(id). Use list_themes.") }
        return theme
    }

    func planItem(_ id: String?, in plan: Service) throws -> ServiceItem {
        guard let item = plan.items.first(where: { $0.id == id }) else {
            throw Failure("\(plan.name) has no item with the id \(id ?? ""). Use get_plan.")
        }
        return item
    }

    func slides(_ ids: [String], in deck: Presentation) throws -> [Slide] {
        let missing = ids.filter { id in !deck.slides.contains { $0.id == id } }
        guard missing.isEmpty else {
            throw Failure("\(deck.name) has no slide with the id \(missing.joined(separator: ", ")). Use get_presentation.")
        }
        let wanted = Set(ids)
        return deck.slides.filter { wanted.contains($0.id) }
    }

    func serviceTimes(_ input: AssistantJSON) throws -> [Date] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let times = try (input["service_times"]?.array?.compactMap(\.string) ?? []).map { text in
            guard let date = formatter.date(from: String(text.prefix(16))) else {
                throw Failure("\(text) isn't a time like 2026-10-25T09:00.")
            }
            guard date > .now else { throw Failure("\(text) has already passed.") }
            return date
        }
        return times.sorted()
    }

    func countdownVideo(_ plan: Service) throws -> (item: ServiceItem, seconds: Double?) {
        guard let item = ServiceCountdown.item(in: plan) else {
            throw Failure("\(plan.name) has no countdown item. Plans get one first in the run order; the user can add the countdown in the plan.")
        }
        guard !item.refId.isEmpty else {
            throw Failure("The countdown in \(plan.name) has no video yet. Ask the user to choose one with the Countdown button on the plan's first item.")
        }
        return (item, model.media(item.refId)?.durationSeconds)
    }

    private func backgroundCue(_ mediaID: String, behindText: Bool) throws -> CueMedia {
        guard let item = model.media(mediaID) else { throw Failure("No media has the id \(mediaID). Use list_media.") }
        // Behind words it's the slide's background (Set Background); on its
        // own it's the slide itself, as when an image is dropped to make one.
        return behindText ? .droppedOnSlide(for: item) : .droppedAsNewSlide(for: item)
    }

    /// A new slide from the tool's slide object.
    private func makeSlide(_ spec: AssistantJSON, themeID: String, theme: Theme?) throws -> Slide {
        let text = spec["text"]?.string ?? ""
        let layout = spec["layout"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        var slide: Slide
        if let theme, !text.isEmpty || layout != nil {
            let designs = theme.slides ?? []
            let design = layout.map { name in designs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
                ?? designs.first
            if let layout, design == nil {
                throw Failure("\(theme.name) has no design named \(layout). Its designs: \(designs.map(\.name).joined(separator: ", ")).")
            }
            if let design {
                slide = NewSlide.fromDesign(design, themeId: themeID, deckThemeId: themeID, sectionId: nil)
                if let index = slide.objects.firstIndex(where: { $0.objectKind == .text }) {
                    slide.objects[index].text = text
                } else if !text.isEmpty {
                    slide.objects.append(SlideObject(id: UUID().uuidString, objectKind: .text, name: "Text", text: text))
                }
            } else {
                slide = Slide(id: UUID().uuidString, name: "", objects: [
                    SlideObject(id: UUID().uuidString, objectKind: .text, name: "Text", text: text),
                ])
            }
        } else {
            slide = Slide(id: UUID().uuidString, name: "", objects: text.isEmpty ? [] : [
                SlideObject(id: UUID().uuidString, objectKind: .text, name: "Text", text: text),
            ])
            if text.isEmpty { slide.unthemed = true }
        }
        slide.name = spec["name"]?.string ?? ""
        if let mediaID = spec["background_media_id"]?.string, !mediaID.isEmpty {
            slide.background = try backgroundCue(mediaID, behindText: !text.isEmpty)
        }
        if let stream = spec["livestream"]?.string.flatMap(AssistantLivestream.init(rawValue:)) {
            slide.streamDesign = stream.design
        }
        if let seconds = spec["auto_advance_seconds"]?.number, seconds > 0 {
            slide.autoAdvance = AutoAdvance(delaySeconds: seconds)
        }
        return slide
    }

    // MARK: Wording

    static func text(of slide: Slide) -> String {
        slide.objects.filter { $0.objectKind == .text }.map(\.text)
            .filter { !$0.isEmpty }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func mediaName(of slide: Slide) -> String? {
        let ids = [slide.background?.mediaId] + slide.objects.map(\.mediaId)
        return ids.compactMap { $0 }.compactMap { model.media($0)?.name }.first
    }

    func label(of slide: Slide, in deck: Presentation) -> String {
        let index = (deck.slides.firstIndex { $0.id == slide.id } ?? 0) + 1
        let words = slide.name.isEmpty ? Self.text(of: slide).split(separator: "\n").first.map(String.init) ?? "" : slide.name
        return words.isEmpty ? "Slide \(index)" : "Slide \(index): \(words)"
    }

    /// Lowercased letters and digits only, so "Pre-Service" and "pre service" match.
    static func squash(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func seconds(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value)) seconds" : "\(value) seconds"
    }

    func count(_ n: Int, _ noun: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? noun : (plural ?? noun + "s"))"
    }
}
