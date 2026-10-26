import Foundation
import PresenterCore

/// The tools behind Build Sunday and Check song lyrics. Reads and additions
/// (syncing, importing songs, building the message) go ahead; anything that
/// replaces or removes waits for one Approve. Each is safe to call twice:
/// a second call finds the work done and says so.
extension AssistantToolbox {

    // MARK: Shepherd

    func syncShepherd() async throws -> (AssistantJSON, String?) {
        let sync = ShepherdSync.shared
        guard sync.isConfigured else {
            return (["configured": false,
                     "note": "Shepherd isn't set up on this Mac (Settings › Integrations › Shepherd). Plans made in Screens still work."],
                    "Shepherd isn't set up")
        }
        // A sync already running (the ten-minute check) is waited for, not doubled.
        for _ in 0..<120 where sync.isSyncing {
            try await Task.sleep(for: .milliseconds(500))
        }
        await sync.sync()
        var fields: [String: AssistantJSON] = ["configured": true]
        if let summary = sync.lastSummary { fields["summary"] = .string(summary) }
        if let error = sync.lastError { fields["error"] = .string(error) }
        if let when = sync.lastSync { fields["last_sync"] = .string(Self.clock(when)) }
        return (.object(fields), sync.lastError == nil
            ? "Loaded plans from Shepherd (\(sync.lastSummary ?? "done"))" : "Shepherd sync failed")
    }

    // MARK: Readiness

    /// The plan named, or the next one Build Sunday would prepare.
    func readinessPlan(_ id: String?) async throws -> Service {
        if let id, !id.isEmpty { return try await service(id) }
        await model.resident.ready([.service])
        let plans = model.entries(of: .service).compactMap { try? model.service($0.id) }
        guard let next = SundayPrep.nextPlan(plans, today: Self.today) else {
            throw Failure("There's no upcoming plan. Make one with + above the plan list, or load plans from Shepherd.")
        }
        return next
    }

    func checkReadiness(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let plan = try await readinessPlan(input["plan_id"]?.string)
        await model.resident.ready([.service, .media, .theme])
        let decks = await model.presentationsFilled(
            plan.items.filter { $0.itemKind == .presentation && !$0.refId.isEmpty }.map(\.refId))

        var fields: [String: AssistantJSON] = [
            "plan": ["id": .string(plan.id), "name": .string(plan.name), "date": .string(plan.serviceDate),
                     "from_shepherd": .bool(plan.origin == ShepherdPlanSync.origin)],
        ]
        let sync = ShepherdSync.shared
        fields["shepherd"] = sync.isConfigured
            ? ["configured": true, "last_sync": AssistantJSON(sync.lastSync.map(Self.clock))]
            : ["configured": false]

        // Songs.
        fields["songs"] = .array(plan.items.compactMap { item -> AssistantJSON? in
            let deck = decks[item.refId]
            guard item.mxuSongTitle != nil || deck.map(Self.isSong) == true else { return nil }
            var row: [String: AssistantJSON] = [
                "item_id": .string(item.id), "title": .string(item.mxuSongTitle ?? item.name),
                "has_slides": .bool(item.itemKind == .presentation && !item.refId.isEmpty),
            ]
            if let ccli = item.mxuCcliNumber ?? deck?.ccli?.songNumber { row["ccli"] = .number(Double(ccli)) }
            if let deck { row["presentation_id"] = .string(deck.id) }
            return .object(row)
        })

        // Countdown.
        var countdown: [String: AssistantJSON] = [:]
        if let item = ServiceCountdown.item(in: plan) {
            countdown["item_id"] = .string(item.id)
            if let media = item.refId.isEmpty ? nil : model.media(item.refId) {
                countdown["video"] = Self.video(id: media.id, name: media.name, seconds: media.durationSeconds)
            } else {
                countdown["video"] = .null
            }
        } else {
            countdown["item_id"] = .null
            countdown["note"] = plan.countdownRemoved == true
                ? "The countdown was taken out of this plan; it stays out."
                : "No countdown item yet; apply_sunday_setup adds one with the video."
        }
        let allPlans = model.entries(of: .service).compactMap { try? model.mainService($0.id) }
        let used = SundayPrep.countdownsUsedLastWeek(before: plan, among: allPlans)
        if !used.isEmpty {
            countdown["used_last_week"] = AssistantJSON(used.compactMap { model.media($0)?.name }.sorted())
        }
        if let suggestion = SundayPrep.suggestedCountdown(countdownVideos(), for: plan, among: allPlans) {
            countdown["suggested"] = Self.video(id: suggestion.id, name: suggestion.name, seconds: suggestion.seconds)
        } else {
            countdown["suggested"] = .null
            countdown["suggestion_note"] = "No video in Media › Countdowns that wasn't used last week."
        }
        fields["countdown"] = .object(countdown)

        // Message and series.
        var message: [String: AssistantJSON] = [:]
        if let current = await SermonMessage.current(in: plan.id, model: model) {
            message["presentation_id"] = .string(current.id)
            if let deck = current.presentation {
                message["name"] = .string(deck.name)
                message["slides_with_content"] = .number(Double(Self.contentSlides(deck)))
            }
        } else {
            message["presentation_id"] = .null
        }
        let seriesIDs = [plan.sermonThemeId, model.slideBuilding.sermonThemeId].compactMap { $0 }.filter { !$0.isEmpty }
        await model.themesFilled(seriesIDs)
        message["series"] = seriesJSON(plan.sermonThemeId)
        if plan.sermonThemeId?.isEmpty ?? true, let last = model.slideBuilding.sermonThemeId, !last.isEmpty {
            message["last_series_used"] = seriesJSON(last)
        }
        fields["message"] = .object(message)

        // Pre-service slideshow.
        // One slideshow shared by every plan: its slides are edited once,
        // never copied into a plan.
        if let id = preServicePresentationID(), let entry = model.libraryEntry(id) {
            var preService: [String: AssistantJSON] = [
                "presentation_id": .string(id), "name": .string(entry.name), "shared_by_every_plan": true,
            ]
            if let item = PreServiceSlides.item(in: plan) {
                preService["item_id"] = .string(item.id)
            } else if plan.preServiceRemoved == true {
                preService["note"] = "The pre-service slideshow was taken out of this plan; it stays out."
            } else {
                preService["note"] = "Not in this plan yet; Screens puts it first by itself. Don't add it."
            }
            fields["pre_service"] = .object(preService)
        } else {
            fields["pre_service"] = .null
        }

        // Scheduling.
        let videoSeconds = ServiceCountdown.item(in: plan).flatMap { model.media($0.refId)?.durationSeconds }
        let length = (videoSeconds ?? 0) > 0 ? videoSeconds!.rounded(.up) : 300
        let scheduled = model.residentScheduleTriggers
            .filter { ServiceCountdown.isCountdownTrigger($0, planID: plan.id) }
            .compactMap { ServiceCountdown.startDate(of: $0) }
            .sorted()
        let proposed = SundayPrep.proposedServiceTimes(
            planDate: plan.serviceDate, serviceDay: model.slideBuilding.serviceDay,
            shepherdTimes: plan.mxuPlanTimes ?? [], now: .now)
        var schedule: [String: AssistantJSON] = [
            "scheduled_services": AssistantJSON(scheduled.map { Self.clock($0.addingTimeInterval(length)) }),
            "proposed_service_times": AssistantJSON(proposed.times),
            "this_mac_runs_service": .bool(ServiceStation.runsService),
        ]
        if let source = proposed.source { schedule["proposed_from"] = .string(source.rawValue) }
        fields["schedule"] = .object(schedule)

        return (.object(fields), "Checked \(plan.name)")
    }

    // MARK: Songs

    func importSongs(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let plan = try await service(input["plan_id"]?.string)
        var targets = SundayPrep.songsWithoutSlides(in: plan)
        var rows: [AssistantJSON] = []
        if let wanted = input["item_ids"]?.array?.compactMap(\.string) {
            for id in wanted {
                let item = try planItem(id, in: plan)
                if !targets.contains(where: { $0.id == id }) {
                    rows.append(["item_id": .string(id), "title": .string(item.mxuSongTitle ?? item.name),
                                 "status": item.refId.isEmpty ? "not_a_song" : "already_has_slides"])
                }
            }
            targets = targets.filter { wanted.contains($0.id) }
        }
        guard !targets.isEmpty else {
            return (["songs": .array(rows), "note": "No planned song is missing slides."], nil)
        }
        let sync = ShepherdSync.shared
        let candidates = await ShepherdSync.linkCandidates(model)
        var linked = 0
        for item in targets {
            let title = item.mxuSongTitle ?? item.name
            var row: [String: AssistantJSON] = ["item_id": .string(item.id), "title": .string(title)]
            // A copy already in the library is linked rather than imported again.
            // Earlier songs' imports wait on Shepherd, so someone may have
            // given this one slides meanwhile; link only leaves those alone.
            if let ref = ShepherdSync.librarySong(title: title, ccli: item.mxuCcliNumber, candidates: candidates) {
                if LyricsFetcher.shared.link(item.id, planID: plan.id, to: ref, model: model) {
                    row["status"] = "linked_library_copy"
                    row["presentation_id"] = .string(ref)
                    linked += 1
                } else {
                    row["status"] = "already_has_slides"
                    linked += 1
                }
            } else if !sync.isConfigured {
                row["status"] = "shepherd_not_set_up"
            } else {
                switch await LyricsFetcher.importFromShepherd(item: item, title: title, planID: plan.id, model: model) {
                case .imported(let id):
                    row["status"] = "imported_from_shepherd"
                    row["presentation_id"] = .string(id)
                    linked += 1
                case .alreadyLinked:
                    row["status"] = "already_has_slides"
                    linked += 1
                case .notConfigured: row["status"] = "shepherd_not_set_up"
                case .notFound: row["status"] = "not_in_shepherd"
                case .noWords: row["status"] = "no_lyrics_in_shepherd"
                case .failed(let message):
                    row["status"] = "failed"
                    row["error"] = .string(message)
                }
            }
            rows.append(.object(row))
        }
        let left = targets.count - linked
        var activity = "Linked \(count(linked, "song")) in \(plan.name)"
        if left > 0 { activity += "; \(left) still need lyrics" }
        return (["songs": .array(rows),
                 "still_without_slides": .number(Double(left))], activity)
    }

    // MARK: Message

    /// What build_message_from_notes works from, checked before anything
    /// is asked or read.
    struct MessageBuild {
        var pdf: URL
        var fileName: String
        var plan: Service
        var series: Theme
        /// The message this one replaces, when it has slides.
        var replacing: (name: String, slides: Int)?
        /// A message these notes already built for this plan, still in place.
        var built: (id: String, deck: Presentation)?
        var key: String
    }

    func messageBuild(_ input: AssistantJSON) async throws -> MessageBuild {
        let attachmentID = input["attachment"]?.string ?? ""
        guard let attachment = attachments[attachmentID] else {
            throw Failure("No attachment \(attachmentID). Attached so far: \(attachments.keys.sorted().joined(separator: ", ")). Ask the user to attach the notes PDF with the paperclip.")
        }
        guard let pdf = attachment.sourcePDF else {
            throw Failure("\(attachment.label) isn't a PDF. The notes need to be a PDF here; a Pages file can go through File › Import Sermon….")
        }
        let plan = try await service(input["plan_id"]?.string)
        let fileName = String(pdf.lastPathComponent.dropFirst("source-".count))

        let key = pdf.path + "|" + plan.id
        var built: (id: String, deck: Presentation)?
        if let id = builtMessages[key], plan.messagePresentationId == id,
           let deck = await model.presentationsFilled([id])[id] {
            built = (id, deck)
        }

        // The series first: no point reading the notes without one.
        let requested = input["series_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        guard let seriesID = requested ?? plan.sermonThemeId.flatMap({ $0.isEmpty ? nil : $0 }) else {
            await model.themesFilled([model.slideBuilding.sermonThemeId].compactMap { $0 })
            let hint = model.slideBuilding.sermonThemeId.flatMap { model.theme($0) }
                .map { " The last series used was \($0.name) (id \($0.id))." } ?? ""
            throw Failure("\(plan.name) has no sermon series yet. Ask the user which series this message is in; list_themes marks the sermon series.\(hint)")
        }
        await model.themesFilled([seriesID])
        guard let series = model.theme(seriesID), SermonSeriesTheme.isSeries(series) else {
            throw Failure("\(seriesID) isn't a sermon series theme. list_themes marks them with sermon_series.")
        }

        var replacing: (name: String, slides: Int)?
        if built == nil, let current = await SermonMessage.current(in: plan.id, model: model), let deck = current.presentation,
           Self.contentSlides(deck) > 0 {
            guard input["replace_existing"]?.bool == true else {
                throw Failure("\(plan.name) already has a message, \"\(deck.name)\" (\(count(Self.contentSlides(deck), "slide"))). Ask the user before replacing it, then call again with replace_existing true; the app asks them to approve.")
            }
            replacing = (deck.name, Self.contentSlides(deck))
        }
        return MessageBuild(pdf: pdf, fileName: fileName, plan: plan, series: series,
                            replacing: replacing, built: built, key: key)
    }

    /// Building a first message adds; replacing one with slides, or moving
    /// the plan off the series it has, waits for Approve.
    func messageConfirmation(_ input: AssistantJSON) async throws -> (title: String, detail: String)? {
        let build = try await messageBuild(input)
        guard build.built == nil else { return nil }
        var parts: [String] = []
        if let old = build.replacing {
            parts.append("Replaces \"\(old.name)\" (\(count(old.slides, "slide"))) with slides from \(build.fileName).")
        }
        if let current = build.plan.sermonThemeId, !current.isEmpty, current != build.series.id {
            await model.themesFilled([current])
            parts.append("Series: \(model.theme(current)?.name ?? "the plan's series") → \(build.series.name)")
        }
        guard !parts.isEmpty else { return nil }
        let title = build.replacing != nil
            ? "Replace the message in \(build.plan.name)?" : "Change the series of \(build.plan.name)?"
        return (title, parts.joined(separator: "\n"))
    }

    func buildMessage(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let build = try await messageBuild(input)
        if let built = build.built {
            return (["presentation_id": .string(built.id), "name": .string(built.deck.name),
                     "slides": .number(Double(built.deck.slides.count)), "already_built": true], nil)
        }
        let plan = build.plan
        let data = try Data(contentsOf: build.pdf)
        let outline = try await ClaudeClient.outline(fromPDF: data, fileName: build.fileName)
        let theme = await SermonMessage.seriesTheme(build.series.id, model: model)
        let slides = await SermonSlides.build(outline, theme: theme)
        guard !slides.isEmpty else { throw Failure("Claude found no slides in \(build.fileName).") }
        let id = await SermonMessage.place(slides, title: outline.title, seriesID: build.series.id, inPlan: plan.id, model: model)
        builtMessages[build.key] = id
        let rows: [AssistantJSON] = outline.slides.prefix(60).map { item in
            let words = [item.text, item.reference].filter { !$0.isEmpty }.joined(separator: " — ")
            return .string("\(item.kind.label): \(String(words.prefix(120)))")
        }
        return (["presentation_id": .string(id), "title": .string(outline.title), "series": .string(build.series.name),
                 "slides": .number(Double(slides.count)), "outline": .array(rows)],
                "Built the message for \(plan.name) (\(count(slides.count, "slide")))")
    }

    // MARK: Apply (one approval)

    /// What apply_sunday_setup will do, worked out before anyone is asked.
    struct SundayChanges {
        var plan: Service
        var countdown: (media: MediaItem, change: ServiceCountdown.Change?)?
        var times: [Date] = []
        var series: Theme?
        var removal: (deck: Presentation, slides: [Slide], reason: String?)?
        var alreadyGone: [String] = []
    }

    func sundayChanges(_ input: AssistantJSON) async throws -> SundayChanges {
        let plan = try await service(input["plan_id"]?.string)
        var changes = SundayChanges(plan: plan)

        if let id = input["series_id"]?.string, !id.isEmpty, id != plan.sermonThemeId {
            await model.themesFilled([id])
            guard let theme = model.theme(id), SermonSeriesTheme.isSeries(theme) else {
                throw Failure("\(id) isn't a sermon series theme. list_themes marks them with sermon_series.")
            }
            changes.series = theme
        }

        if let id = input["countdown_media_id"]?.string, !id.isEmpty {
            await model.resident.ready([.media])
            guard let media = model.media(id), media.mediaKind == .video else {
                throw Failure("countdown_media_id must be a video in the media library (list_media kind video).")
            }
            if let item = ServiceCountdown.item(in: plan) {
                if item.refId != id { changes.countdown = (media, nil) }
            } else if let change = ServiceCountdown.change(for: plan) {
                changes.countdown = (media, change)
            } else {
                throw Failure("The countdown was taken out of \(plan.name), so it has none to set. The user can add one in the plan.")
            }
        }

        if input["service_times"] != nil {
            changes.times = try serviceTimes(input)
            let hasVideo = changes.countdown != nil || ServiceCountdown.item(in: plan).map { !$0.refId.isEmpty } == true
            guard hasVideo else {
                throw Failure("\(plan.name)'s countdown has no video, and scheduling needs one. Include countdown_media_id.")
            }
        }

        if let removal = input["remove_slides"] {
            let deck = try await presentation(removal["presentation_id"]?.string)
            let ids = removal["slide_ids"]?.array?.compactMap(\.string) ?? []
            let present = deck.slides.filter { ids.contains($0.id) }
            changes.alreadyGone = ids.filter { id in !deck.slides.contains { $0.id == id } }
            guard present.count < deck.slides.count else {
                throw Failure("That would delete every slide in \(deck.name). A presentation keeps at least one.")
            }
            if !present.isEmpty { changes.removal = (deck, present, removal["reason"]?.string) }
        }

        guard changes.series != nil || changes.countdown != nil || !changes.times.isEmpty || changes.removal != nil else {
            throw Failure("Nothing to change: everything given is already that way\(changes.alreadyGone.isEmpty ? "" : ", and those slides are already gone"). Leave out apply_sunday_setup.")
        }
        return changes
    }

    func sundaySetupConfirmation(_ input: AssistantJSON) async throws -> (title: String, detail: String) {
        let changes = try await sundayChanges(input)
        var parts: [String] = []
        if let series = changes.series { parts.append("Series: \(series.name)") }
        if let countdown = changes.countdown {
            let length = countdown.media.durationSeconds.map { " (\(ScheduleServiceSheet.length($0)))" } ?? ""
            parts.append("Countdown video: \(countdown.media.name)\(length)")
        }
        if !changes.times.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM d, h:mm a"
            var block = "Schedule Service:\n" + changes.times.map { "• " + formatter.string(from: $0) }.joined(separator: "\n")
            let existing = model.residentScheduleTriggers.filter { ServiceCountdown.isCountdownTrigger($0, planID: changes.plan.id) }
            if !existing.isEmpty { block += "\nReplaces \(count(existing.count, "countdown")) already scheduled." }
            if !ServiceStation.runsService { block += "\nRun on this Mac is off here, so another Mac plays the countdowns." }
            parts.append(block)
        }
        if let removal = changes.removal {
            var block = "Delete from \(removal.deck.name):\n"
                + removal.slides.map { "• " + label(of: $0, in: removal.deck) }.joined(separator: "\n")
            if let reason = removal.reason, !reason.isEmpty { block += "\n\(reason)" }
            parts.append(block)
        }
        return ("Apply these changes to \(changes.plan.name)?", parts.joined(separator: "\n\n"))
    }

    func applySundaySetup(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let changes = try await sundayChanges(input)
        let plan = changes.plan
        var done: [String: AssistantJSON] = [:]
        var summary: [String] = []

        if let series = changes.series {
            let id = series.id
            model.updateService(plan.id) { $0.sermonThemeId = id }
            done["series"] = .string(series.name)
            summary.append("series")
        }
        if let countdown = changes.countdown {
            let mediaID = countdown.media.id
            let change = countdown.change
            model.updateService(plan.id) { plan in
                if let change { ServiceCountdown.apply(change, to: &plan) }
                guard let index = plan.items.firstIndex(where: { $0.isCountdown == true }) else { return }
                // A countdown that came from Shepherd starts as a plain item.
                plan.items[index].itemKind = .media
                plan.items[index].refId = mediaID
            }
            done["countdown_video"] = .string(countdown.media.name)
            summary.append("countdown video")
        }
        if !changes.times.isEmpty {
            let fresh = try await service(plan.id)
            let (item, seconds) = try countdownVideo(fresh)
            done["scheduled"] = .array(scheduleCountdowns(fresh, item: item, videoSeconds: seconds, times: changes.times))
            summary.append(count(changes.times.count, "service"))
        }
        if let removal = changes.removal {
            let ids = Set(removal.slides.map(\.id))
            model.updatePresentation(removal.deck.id) { $0.slides.removeAll { ids.contains($0.id) } }
            done["deleted"] = AssistantJSON(removal.slides.map { label(of: $0, in: removal.deck) })
            summary.append("removed \(count(removal.slides.count, "slide"))")
        }
        if !changes.alreadyGone.isEmpty { done["already_gone"] = AssistantJSON(changes.alreadyGone) }
        return (.object(done), "Updated \(plan.name): \(summary.joined(separator: ", "))")
    }

    /// Replaces the plan's countdown triggers with one per service time.
    func scheduleCountdowns(_ plan: Service, item: ServiceItem, videoSeconds: Double?, times: [Date]) -> [AssistantJSON] {
        for old in model.residentScheduleTriggers where ServiceCountdown.isCountdownTrigger(old, planID: plan.id) {
            model.deleteScheduleTrigger(old.id)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d, h:mm:ss a"
        return times.map { time in
            let start = ServiceCountdown.start(serviceTime: time, videoSeconds: videoSeconds)
            model.createScheduleTrigger(ServiceCountdown.trigger(
                planID: plan.id, planName: plan.name, countdownItemID: item.id, start: start, serviceTime: time))
            return ["service": .string(formatter.string(from: time)), "countdown_starts": .string(formatter.string(from: start))]
        }
    }

    // MARK: Lyrics

    func checkSongLyrics(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let planID = input["plan_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let itemID = input["item_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let deckID = input["presentation_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        var targets: [(item: ServiceItem?, deck: Presentation)] = []
        if let deckID {
            let deck = try await presentation(deckID)
            var plan: Service?
            if let planID { plan = try await service(planID) }
            targets = [(plan?.items.first { $0.refId == deck.id }, deck)]
        } else if let planID {
            let plan = try await service(planID)
            if let itemID {
                let item = try planItem(itemID, in: plan)
                guard item.itemKind == .presentation, !item.refId.isEmpty else {
                    throw Failure("\"\(item.name)\" has no slides yet; import_songs_from_shepherd or Get Lyrics first.")
                }
                targets = [(item, try await presentation(item.refId))]
            } else {
                let refs = plan.items.filter { $0.itemKind == .presentation && !$0.refId.isEmpty }
                let decks = await model.presentationsFilled(refs.map(\.refId))
                targets = refs.compactMap { item -> (item: ServiceItem?, deck: Presentation)? in
                    guard let deck = decks[item.refId], item.mxuSongTitle != nil || Self.isSong(deck) else { return nil }
                    return (item: item, deck: deck)
                }
                guard !targets.isEmpty else { throw Failure("\(plan.name) has no songs with slides to check.") }
            }
        } else {
            throw Failure("Give plan_id (with item_id for one song), or presentation_id.")
        }
        let sync = ShepherdSync.shared
        guard sync.isConfigured else {
            throw Failure("Shepherd isn't set up on this Mac, so there are no lyrics to compare with (Settings › Integrations › Shepherd).")
        }
        let client = sync.client

        var rows: [AssistantJSON] = []
        var clean = 0
        for (item, deck) in targets.prefix(12) {
            let title = item?.mxuSongTitle ?? deck.ccli?.songTitle ?? deck.name
            var row: [String: AssistantJSON] = ["song": .string(title), "presentation_id": .string(deck.id)]
            if let item { row["item_id"] = .string(item.id) }
            do {
                var detail: ShepherdClient.SongDetail?
                if let id = item?.mxuSourceSongId, !id.isEmpty { detail = try? await client.song(id: id) }
                if detail == nil {
                    let ccli = (item?.mxuCcliNumber ?? deck.ccli?.songNumber).map(String.init)
                    if let match = try await ShepherdSongMatch.find(
                        ccli: ccli, title: title, search: { try await client.searchSongs($0) }) {
                        detail = try await client.song(id: match.id)
                    }
                }
                guard let detail else {
                    row["found_in_shepherd"] = false
                    rows.append(.object(row))
                    continue
                }
                let arrangement = ShepherdSongMatch.arrangement(
                    in: detail, id: item?.mxuSourceArrangementId, name: item?.mxuArrangementName)
                row["shepherd_song"] = .string(detail.ccliNumber.map { "\(detail.title) (CCLI \($0))" } ?? detail.title)
                // The line and word alignment is quadratic in a song's lines
                // and words; a dozen songs' worth stays off the main thread.
                let lyrics = detail.lyrics
                let chart = arrangement?.chordChart ?? detail.chordChart
                let slides = deck.slides.map(Self.lyricText(of: deck))
                let planned = item.map { _ in ShepherdSongMatch.sequence(of: detail, arrangement: arrangement) }
                let order = Self.arrangementOrder(deck, arrangementID: item?.arrangementId)
                let compared = await Task.detached(priority: .userInitiated) { () -> LyricsCheck.Report? in
                    let reference = LyricsCheck.referenceSections(lyrics: lyrics, chordChart: chart)
                    guard !reference.isEmpty else { return nil }
                    return LyricsCheck.compare(slides: slides, reference: reference, planned: planned, slideOrder: order)
                }.value
                guard let report = compared else {
                    row["no_lyrics_in_shepherd"] = true
                    rows.append(.object(row))
                    continue
                }
                lyricChecks[deck.id] = report
                if report.wordsMatch && report.order?.matches != false { clean += 1 }
                let numbers = Dictionary(deck.slides.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
                for (key, value) in report.json(slideNumbers: numbers).object ?? [:] { row[key] = value }
                if let arrangement { row["arrangement"] = .string(arrangement.name) }
            } catch {
                row["error"] = .string(error.localizedDescription)
            }
            rows.append(.object(row))
        }
        var fields: [String: AssistantJSON] = ["songs": .array(rows)]
        if targets.count > 12 { fields["not_checked"] = .number(Double(targets.count - 12)) }
        return (.object(fields), "Checked the lyrics of \(count(rows.count, "song")) (\(clean) match)")
    }

    /// One slide apply_lyric_fixes will change: its words before and
    /// after, and its text box as it will be, chords and styles moved with
    /// their words.
    struct LyricFix {
        var slide: Slide
        var from: String
        var to: String
        var box: SlideObject
        /// The box's text when this was worked out, so a later edit isn't
        /// written over.
        var boxText: String
        var note: String?
    }

    /// The slide-number fixes apply_lyric_fixes will make, checked against
    /// the slides as they are now. A slide named brings the slides with the
    /// same words along.
    func pendingLyricFixes(_ input: AssistantJSON) async throws -> (deck: Presentation, fixes: [LyricFix], skipped: [String]) {
        let deck = try await presentation(input["presentation_id"]?.string)
        guard let report = lyricChecks[deck.id] else {
            throw Failure("There's no lyrics check for \(deck.name) yet. Call check_song_lyrics first.")
        }
        let caps = input["include_capitalization"]?.bool ?? false
        var wanted: [LyricsCheck.Fix] = []
        for id in input["slide_ids"]?.array?.compactMap(\.string) ?? [] {
            guard let slide = deck.slides.first(where: { $0.id == id }) else {
                throw Failure("\(deck.name) has no slide with the id \(id).")
            }
            let together = report.fixes(with: id)
            guard !together.isEmpty else {
                throw Failure("The last check has no fix for \(label(of: slide, in: deck)).")
            }
            for fix in together where !wanted.contains(where: { $0.slideID == fix.slideID }) { wanted.append(fix) }
        }
        var fixes: [LyricFix] = []
        var skipped: [String] = []
        for fix in wanted {
            // A copy deleted since the check is simply not there to fix.
            guard let slide = deck.slides.first(where: { $0.id == fix.slideID }) else { continue }
            let name = label(of: slide, in: deck)
            let target = caps ? fix.withCapitalization : fix.words
            let now = Self.lyricText(of: deck)(slide).lines.joined(separator: "\n")
            if now == target {
                skipped.append("\(name): already fixed")
            } else if now != fix.original {
                skipped.append("\(name): changed since the check")
            } else if target == fix.original {
                skipped.append("\(name): only capitals differ")
            } else if let index = Self.lyricBox(in: slide),
                      let box = LyricsCheck.rewrite(slide.objects[index], to: target, addedLines: fix.addedLines) {
                let chorded = !(box.chords ?? []).isEmpty
                fixes.append(LyricFix(
                    slide: slide, from: now, to: target, box: box, boxText: slide.objects[index].text,
                    note: chorded && !fix.addedLines.isEmpty ? "the added line has no chords" : nil))
            } else {
                skipped.append("\(name): its chords or text animations wouldn't stay on their words, so change it by hand")
            }
        }
        return (deck, fixes, skipped)
    }

    func lyricFixesConfirmation(_ input: AssistantJSON) async throws -> (title: String, detail: String) {
        let pending = try await pendingLyricFixes(input)
        guard !pending.fixes.isEmpty else {
            throw Failure("Nothing to fix: \(pending.skipped.joined(separator: "; ")).")
        }
        var lines: [String] = []
        for fix in pending.fixes {
            lines.append(label(of: fix.slide, in: pending.deck) + (fix.note.map { " (\($0))" } ?? ""))
            let before = fix.from.components(separatedBy: "\n")
            let after = fix.to.components(separatedBy: "\n")
            for change in after.difference(from: before).sorted(by: { Self.offset($0) < Self.offset($1) }) {
                switch change {
                case .remove(_, let line, _): lines.append("   − \(line)")
                case .insert(_, let line, _): lines.append("   + \(line)")
                }
            }
        }
        if lines.count > 60 { lines = Array(lines.prefix(60)) + ["…"] }
        if !pending.skipped.isEmpty { lines.append("\nSkipped: " + pending.skipped.joined(separator: "; ")) }
        return ("Fix the words on \(count(pending.fixes.count, "slide")) of \(pending.deck.name)?", lines.joined(separator: "\n"))
    }

    func applyLyricFixes(_ input: AssistantJSON) async throws -> (AssistantJSON, String?) {
        let pending = try await pendingLyricFixes(input)
        guard !pending.fixes.isEmpty else { throw Failure("Nothing to fix: \(pending.skipped.joined(separator: "; ")).") }
        for fix in pending.fixes {
            let box = fix.box
            let before = fix.boxText
            model.updateSlide(presentationID: pending.deck.id, slideID: fix.slide.id, undoLabel: "Fix Lyrics") { slide in
                guard let index = slide.objects.firstIndex(where: { $0.id == box.id }),
                      slide.objects[index].text == before else { return }
                slide.objects[index] = box
            }
        }
        var fields: [String: AssistantJSON] = [
            "fixed": AssistantJSON(pending.fixes.map { label(of: $0.slide, in: pending.deck) }),
        ]
        let notes = pending.fixes.compactMap { fix in fix.note.map { "\(label(of: fix.slide, in: pending.deck)): \($0)" } }
        if !notes.isEmpty { fields["notes"] = AssistantJSON(notes) }
        if !pending.skipped.isEmpty { fields["skipped"] = AssistantJSON(pending.skipped) }
        return (.object(fields), "Fixed the words on \(count(pending.fixes.count, "slide")) of \(pending.deck.name)")
    }

    // MARK: Helpers

    /// A slide's words for the lyrics check: its one text box, line by
    /// line. Words split over several boxes are compared but not fixed.
    static func lyricText(of deck: Presentation) -> (Slide) -> LyricsCheck.SlideText {
        let names = Dictionary((deck.sections ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return { slide in
            let boxes = slide.objects.filter { $0.objectKind == .text && !$0.text.isEmpty }
            // "\r\n" is one break, as chords and style runs count lines.
            let lines = LyricsCheck.lines(of: boxes.map(\.text).joined(separator: "\n"))
            return LyricsCheck.SlideText(
                id: slide.id, section: slide.sectionId.flatMap { names[$0] }, lines: boxes.isEmpty ? [] : lines,
                editable: boxes.count <= 1)
        }
    }

    /// The text box a fix writes: the slide's one box with words.
    static func lyricBox(in slide: Slide) -> Int? {
        slide.objects.firstIndex { $0.objectKind == .text && !$0.text.isEmpty }
            ?? slide.objects.firstIndex { $0.objectKind == .text }
    }

    /// The section names in the order the plan plays the song: the plan
    /// item's arrangement, else the song's default; nil when it has none.
    static func arrangementOrder(_ deck: Presentation, arrangementID: String?) -> [String]? {
        let arrangements = deck.arrangements ?? []
        guard let chosen = arrangements.first(where: { $0.id == arrangementID })
            ?? arrangements.first(where: { $0.id == deck.defaultArrangementId }) ?? arrangements.first
        else { return nil }
        let names = Dictionary((deck.sections ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return chosen.sectionIds.compactMap { names[$0] }
    }

    static func isSong(_ deck: Presentation) -> Bool {
        deck.presentationKind == .song || PresentationTypes.category(of: deck) == PresentationTypes.worship
    }

    /// Slides with words or a picture: a template's empty Message has none.
    static func contentSlides(_ deck: Presentation) -> Int {
        deck.slides.filter { !text(of: $0).isEmpty || $0.background != nil }.count
    }

    static func offset(_ change: CollectionDifference<String>.Change) -> Int {
        switch change {
        case .remove(let offset, _, _), .insert(let offset, _, _): offset
        }
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d, h:mm a"
        return formatter.string(from: date)
    }

    static func video(id: String, name: String, seconds: Double?) -> AssistantJSON {
        var fields: [String: AssistantJSON] = ["id": .string(id), "name": .string(name)]
        if let seconds { fields["length"] = .string(ScheduleServiceSheet.length(seconds)) }
        return .object(fields)
    }

    func countdownVideos() -> [SundayPrep.Video] {
        model.entries(of: .media).compactMap { entry in
            guard let media = model.media(entry.id), media.mediaKind == .video else { return nil }
            return SundayPrep.Video(
                id: entry.id, name: entry.name, folder: entry.subkind, added: entry.updatedAt, seconds: media.durationSeconds)
        }
    }

    func seriesJSON(_ id: String?) -> AssistantJSON {
        guard let id, !id.isEmpty, let theme = model.theme(id), SermonSeriesTheme.isSeries(theme) else { return .null }
        return ["id": .string(theme.id), "name": .string(theme.name)]
    }

    /// The Service Day setup's slideshow, else one named Pre-Service.
    func preServicePresentationID() -> String? {
        model.preServiceSlideshowID()
    }
}
