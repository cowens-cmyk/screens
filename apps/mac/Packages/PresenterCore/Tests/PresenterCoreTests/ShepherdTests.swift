import Foundation
import Testing
@testable import PresenterCore

// The plan-detail example abbreviates the shared summary fields with "…".
// This fixture expands those fields from the plans example immediately above it.
private let shepherdPlansJSON = """
{
  "from": "2026-10-18", "to": "2026-10-25",
  "plans": [{
    "id": "3c1d…", "service_type": {"id": "8e20…", "name": "Sunday Worship"},
    "title": "Living Water", "series": "The Gospel of John",
    "series_art_url": "/api/v1/services/series/51aa…/art?v=1791900000",
    "starts_at": "2026-10-18T14:30:00Z", "location": "Sanctuary",
    "times": [
      {"kind": "rehearsal", "label": "Run-through", "starts_at": "2026-10-18T13:00:00Z", "ends_at": "2026-10-18T13:45:00Z"},
      {"kind": "service", "label": "Service", "starts_at": "2026-10-18T14:30:00Z", "ends_at": null}
    ],
    "length_seconds": 4500, "live_item_id": null, "live_at": null,
    "updated_at": "2026-10-14T19:02:11Z"
  }]
}
"""

private let shepherdItemsJSON = """
[
  {"id": "a1…", "position": 0, "kind": "header", "title": "Worship", "description": null, "length_seconds": null,
   "starts_at": "2026-10-18T14:30:00Z", "song": null, "files": []},
  {"id": "a2…", "position": 1, "kind": "song", "title": "Living Hope", "description": null, "length_seconds": 300,
   "starts_at": "2026-10-18T14:30:00Z",
   "song": {
     "id": "5e3b…", "title": "Living Hope", "author": "Phil Wickham, Brian Johnson", "ccli_number": "7106807",
     "copyright": "2017 Phil Wickham Music…", "key": "Bb", "arrangement_id": "77c0…", "arrangement": "Acoustic",
     "tempo": 72, "time_signature": "4/4", "sequence": ["Verse 1", "Chorus", "Verse 2", "Chorus", "Bridge", "Chorus"],
     "media_links": [{"service": "spotify", "url": "https://open.spotify.com/track/…"}]
   }, "files": []},
  {"id": "a3…", "position": 2, "kind": "item", "title": "Welcome", "description": "Greeting and announcements",
   "length_seconds": 120, "starts_at": "2026-10-18T14:35:00Z", "song": null, "files": []}
]
"""

// /songs/{id} has the song-list example's fields, plus these scope-gated fields.
private let shepherdSongJSON = """
{
  "id": "5e3b…", "title": "Living Hope", "author": "Phil Wickham, Brian Johnson", "ccli_number": "7106807",
  "copyright": "2017 Phil Wickham Music…", "themes": ["Hope", "Resurrection"], "default_key": "C",
  "tempo": 72, "time_signature": "4/4", "sequence": ["Verse 1", "Chorus", "Bridge"], "archived": false,
  "keys": [{"key": "C", "description": "Original"}, {"key": "Bb", "description": "Lower"}],
  "arrangements": [{
    "id": "77c0…", "name": "Acoustic", "tempo": 72, "time_signature": "4/4", "length_seconds": 300,
    "sequence": ["Verse 1", "Chorus", "Bridge"], "chord_chart": null,
    "media_links": [{"service": "youtube", "url": "https://www.youtube.com/watch?v=…"}]
  }],
  "media_links": [{"service": "spotify", "url": "https://open.spotify.com/track/…"}],
  "updated_at": "2026-10-14T19:02:11Z", "lyrics": null, "chord_chart": null, "files": []
}
"""

private let shepherdPingJSON = """
{"ok": true, "app": "Hope Church App", "scopes": ["profile:read", "serving:read"], "api_version": 1}
"""

private func shepherdDetailData() throws -> Data {
    let root = try #require(JSONSerialization.jsonObject(with: Data(shepherdPlansJSON.utf8)) as? [String: Any])
    var plan = try #require((root["plans"] as? [[String: Any]])?.first)
    plan["items"] = try JSONSerialization.jsonObject(with: Data(shepherdItemsJSON.utf8))
    plan["files"] = [[
        "id": "0f9e…", "name": "Order of service.pdf", "content_type": "application/pdf",
        "size": 48211, "created_at": "2026-10-12T15:00:00Z",
    ]]
    return try JSONSerialization.data(withJSONObject: plan)
}

private func shepherdDetail() throws -> ShepherdClient.PlanDetail {
    try ShepherdClient.decoder().decode(ShepherdClient.PlanDetail.self, from: shepherdDetailData())
}

private struct ShepherdReply: Sendable {
    var status: Int = 200
    var body: String = shepherdPingJSON
}

/// URLProtocol calls arrive off the test executor. Every mutable field is
/// protected by the lock; the serialized suite owns one scenario at a time.
private final class ShepherdStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [ShepherdReply] = []
    private var requests: [URLRequest] = []
    private var delays: [Duration] = []

    func reset(_ replies: [ShepherdReply]) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        requests = []
        delays = []
    }

    func reply(to request: URLRequest) -> ShepherdReply {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return replies.isEmpty ? ShepherdReply(status: 418) : replies.removeFirst()
    }

    func record(_ delay: Duration) {
        lock.lock()
        defer { lock.unlock() }
        delays.append(delay)
    }

    func snapshot() -> (requests: [URLRequest], delays: [Duration]) {
        lock.lock()
        defer { lock.unlock() }
        return (requests, delays)
    }
}

private final class ShepherdURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = ShepherdStubState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.reply(to: request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func shepherdClient(_ replies: [ShepherdReply]) -> ShepherdClient {
    ShepherdURLProtocol.state.reset(replies)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ShepherdURLProtocol.self]
    var client = ShepherdClient(
        baseURL: URL(string: "https://shepherd.invalid/api/v1")!,
        apiKey: "  shp_test_only\n", session: URLSession(configuration: configuration))
    client.sleep = { ShepherdURLProtocol.state.record($0) }
    return client
}

@Suite(.serialized)
struct ShepherdTests {
    @Test func pingUsesBearerAndDecodesExample() async throws {
        let client = shepherdClient([ShepherdReply()])
        defer { client.session.invalidateAndCancel() }
        let ping = try await client.ping()
        #expect(ping.ok && ping.app == "Hope Church App")
        #expect(ping.scopes == ["profile:read", "serving:read"] && ping.apiVersion == 1)
        let request = try #require(ShepherdURLProtocol.state.snapshot().requests.first)
        #expect(request.url?.absoluteString == "https://shepherd.invalid/api/v1/ping")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer shp_test_only")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func plansDecodeExampleAndSendFilters() async throws {
        let client = shepherdClient([ShepherdReply(body: shepherdPlansJSON)])
        defer { client.session.invalidateAndCancel() }
        let plans = try await client.plans(from: "2026-10-18", to: "2026-10-25", serviceType: "Sunday Worship")
        #expect(plans.count == 1)
        let plan = try #require(plans.first)
        #expect(plan.id == "3c1d…" && plan.title == "Living Water")
        #expect(plan.serviceType.name == "Sunday Worship" && plan.serviceType.id == "8e20…")
        #expect(plan.series == "The Gospel of John" && plan.location == "Sanctuary")
        #expect(plan.seriesArtUrl == "/api/v1/services/series/51aa…/art?v=1791900000")
        #expect(plan.lengthSeconds == 4500 && plan.liveItemId == nil && plan.liveAt == nil)
        #expect(plan.times.count == 2 && plan.times[0].kind == "rehearsal")
        #expect(plan.times[0].endsAt?.timeIntervalSince(plan.times[0].startsAt!) == 2700)
        #expect(plan.times[1].startsAt == plan.startsAt && plan.times[1].endsAt == nil)
        #expect(plan.updatedAt == ISO8601DateFormatter().date(from: "2026-10-14T19:02:11Z"))
        let request = try #require(ShepherdURLProtocol.state.snapshot().requests.first)
        let url = try #require(request.url)
        #expect(url.path == "/api/v1/services/plans")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "from", value: "2026-10-18"),
            URLQueryItem(name: "to", value: "2026-10-25"),
            URLQueryItem(name: "service_type", value: "Sunday Worship"),
        ])
    }

    @Test func songSearchDecodesTheListAndSendsTheQuery() async throws {
        let list = """
        {"songs": [{"id": "5e3b…", "title": "Living Hope", "author": "Phil Wickham, Brian Johnson",
          "ccli_number": "7106807", "copyright": "2017", "themes": ["Hope"], "default_key": "C",
          "tempo": 72, "time_signature": "4/4", "sequence": [], "archived": false, "keys": [],
          "arrangements": [], "media_links": [], "updated_at": "2026-10-14T19:02:11Z"}],
         "next_offset": null}
        """
        let client = shepherdClient([ShepherdReply(body: list)])
        defer { client.session.invalidateAndCancel() }
        let songs = try await client.searchSongs("  hope ")
        #expect(songs.map(\.title) == ["Living Hope"])
        #expect(songs.first?.ccliNumber == "7106807" && songs.first?.defaultKey == "C")
        let url = try #require(ShepherdURLProtocol.state.snapshot().requests.first?.url)
        #expect(url.path == "/api/v1/services/songs")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "q", value: "hope"),
            URLQueryItem(name: "limit", value: "50"),
        ])
    }

    @Test func planDetailDecodesExample() async throws {
        let client = shepherdClient([ShepherdReply(body: String(decoding: try shepherdDetailData(), as: UTF8.self))])
        defer { client.session.invalidateAndCancel() }
        let plan = try await client.plan(id: "plan-id")
        #expect(plan.items.map(\.kind) == ["header", "song", "item"])
        #expect(plan.items.map(\.position) == [0, 1, 2])
        #expect(plan.items[0].song == nil && plan.items[0].lengthSeconds == nil)
        #expect(plan.items[1].lengthSeconds == 300 && plan.items[1].song?.ccliNumber == "7106807")
        #expect(plan.items[1].song?.key == "Bb" && plan.items[1].song?.arrangementId == "77c0…")
        #expect(plan.items[1].song?.tempo == 72 && plan.items[1].song?.timeSignature == "4/4")
        #expect(plan.items[1].song?.sequence.count == 6 && plan.items[1].song?.mediaLinks.first?.service == "spotify")
        #expect(plan.items[2].description == "Greeting and announcements")
        #expect(plan.items[2].startsAt?.timeIntervalSince(plan.startsAt!) == 300)
        #expect(plan.files.first?.contentType == "application/pdf" && plan.files.first?.size == 48211)
        #expect(plan.files.first?.createdAt == ISO8601DateFormatter().date(from: "2026-10-12T15:00:00Z"))
        #expect(ShepherdURLProtocol.state.snapshot().requests.first?.url?.path == "/api/v1/services/plans/plan-id")
    }

    @Test func songDetailDecodesWithAndWithoutLyricsScope() async throws {
        let client = shepherdClient([ShepherdReply(body: shepherdSongJSON)])
        defer { client.session.invalidateAndCancel() }
        let song = try await client.song(id: "song-id")
        #expect(song.id == "5e3b…" && song.title == "Living Hope" && song.ccliNumber == "7106807")
        #expect(song.defaultKey == "C" && song.tempo == 72 && song.timeSignature == "4/4")
        #expect(song.themes == ["Hope", "Resurrection"] && !song.archived)
        #expect(song.keys.map(\.key) == ["C", "Bb"])
        #expect(song.arrangements.first?.lengthSeconds == 300 && song.arrangements.first?.chordChart == nil)
        #expect(song.mediaLinks.first?.service == "spotify")
        #expect(song.lyrics == nil && song.chordChart == nil && song.files.isEmpty)
        #expect(ShepherdURLProtocol.state.snapshot().requests.first?.url?.path == "/api/v1/services/songs/song-id")

        var json = try #require(JSONSerialization.jsonObject(with: Data(shepherdSongJSON.utf8)) as? [String: Any])
        json["lyrics"] = "Amazing grace"
        json["chord_chart"] = "[G]Amazing [C]grace"
        json["updated_at"] = "2026-10-14T19:02:11.125Z"
        json["files"] = [[
            "id": "chart", "name": "Amazing in A.cho", "content_type": "text/plain", "size": 100,
            "created_at": "2026-10-12T15:00:00Z", "arrangement_id": "77c0…", "key": "A", "keys": ["A", "G"],
        ]]
        json["future_field"] = true
        let full = try ShepherdClient.decoder().decode(
            ShepherdClient.SongDetail.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(full.lyrics == "Amazing grace" && full.chordChart == "[G]Amazing [C]grace")
        #expect(full.files.first?.keys == ["A", "G"] && full.files.first?.arrangementId == "77c0…")
        #expect(abs(full.updatedAt.timeIntervalSince(song.updatedAt) - 0.125) < 0.001)
        json.removeValue(forKey: "lyrics")
        json.removeValue(forKey: "chord_chart")
        let omitted = try ShepherdClient.decoder().decode(
            ShepherdClient.SongDetail.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(omitted.lyrics == nil && omitted.chordChart == nil)
    }

    @Test(arguments: [401, 403, 404, 429, 500, 503])
    func httpErrorsAreSafeAndRetriesAreBounded(status: Int) async throws {
        let client = shepherdClient(Array(repeating: ShepherdReply(
            status: status, body: #"{"error":"shp_test_only"}"#), count: 5))
        defer { client.session.invalidateAndCancel() }
        do {
            _ = try await client.ping()
            Issue.record("An HTTP error must throw.")
        } catch let error as ShepherdError {
            #expect(error == .http(status))
            let expected: [Int: String] = [
                401: "Shepherd rejected the key. It may have been rotated or disabled.",
                403: "This key is missing the services:read scope. Ask the church to add it.",
                404: "This Shepherd item could not be found.",
                429: "Shepherd is busy. Wait a moment and try again.",
                500: "Shepherd is having trouble. Try again shortly.",
                503: "Shepherd is having trouble. Try again shortly.",
            ]
            #expect(error.errorDescription == expected[status])
            #expect(!error.localizedDescription.contains("shp_test_only"))
            #expect(!String(reflecting: error).contains("shp_test_only"))
        }
        let retryable = status == 429 || status >= 500
        let snapshot = ShepherdURLProtocol.state.snapshot()
        #expect(snapshot.requests.count == (retryable ? 4 : 1))
        #expect(snapshot.delays == (retryable ? [.seconds(1), .seconds(2), .seconds(4)] : []))
    }

    @Test(arguments: [429, 503])
    func retriesThenSucceeds(status: Int) async throws {
        let client = shepherdClient(
            Array(repeating: ShepherdReply(status: status), count: 3) + [ShepherdReply()])
        defer { client.session.invalidateAndCancel() }
        let ping = try await client.ping()
        #expect(ping.ok)
        let snapshot = ShepherdURLProtocol.state.snapshot()
        #expect(snapshot.requests.count == 4)
        #expect(snapshot.delays == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(snapshot.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer shp_test_only" })
    }

    @Test func malformedResponseDoesNotExposeBody() async throws {
        let client = shepherdClient([ShepherdReply(body: #"{"api_version":"shp_test_only"}"#)])
        defer { client.session.invalidateAndCancel() }
        await #expect(throws: ShepherdError.invalidResponse) { try await client.ping() }
        #expect(ShepherdURLProtocol.state.snapshot().requests.count == 1)
    }

    @Test func cancellationStopsBackoff() async throws {
        var client = shepherdClient([ShepherdReply(status: 429), ShepherdReply()])
        defer { client.session.invalidateAndCancel() }
        client.sleep = { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await client.ping() }
        #expect(ShepherdURLProtocol.state.snapshot().requests.count == 1)
    }

    @Test func planItemsLinkOnlyThroughLibraryLookup() throws {
        var plan = try shepherdDetail()
        var missing = plan.items[1]
        missing.id = "missing"
        missing.position = 3
        missing.title = "Unlisted song"
        missing.song?.id = "missing-song"
        missing.song?.title = "Not in library"
        missing.song?.ccliNumber = "1234567"
        plan.items.append(missing)
        plan.items.reverse() // Position is authoritative.
        let rules = ServiceLinkRules(id: "rules", rules: [
            ServiceLinkRule(id: "welcome", normalizedName: "welcome", serviceTypeName: "Sunday Worship",
                            itemKind: .presentation, refId: "welcome-deck"),
            ServiceLinkRule(id: "wrong-song", normalizedName: "unlisted song",
                            itemKind: .presentation, refId: "must-not-link"),
        ])
        var lookedUp: [PlanFeed.Item] = []
        let items = ShepherdPlanSync.items(for: plan, rules: rules, existing: []) { item in
            lookedUp.append(item)
            return item.song?.ccliNumber == 7106807 ? ("library-song", "library-arrangement") : nil
        }
        #expect(items.map(\.itemKind) == [.header, .presentation, .presentation, .info])
        #expect(items.map(\.mxuSourceItemId) == ["a1…", "a2…", "a3…", "missing"])
        #expect(items[1].refId == "library-song" && items[1].arrangementId == "library-arrangement")
        #expect(items[1].mxuSongKey == "Bb" && items[1].duration == 300)
        #expect(items[1].mxuCcliNumber == 7106807 && items[1].mxuSongTitle == "Living Hope")
        #expect(items[1].mxuArrangementName == "Acoustic" && items[1].mxuBpm == 72 && items[1].mxuTimeSignature == "4/4")
        #expect(items[2].refId == "welcome-deck" && items[2].duration == 120)
        #expect(items[2].mxuDescription == "Greeting and announcements")
        #expect(items[3].refId.isEmpty && items[3].mxuSongTitle == "Not in library" && items[3].mxuCcliNumber == 1234567)
        #expect(lookedUp.map(\.id) == ["a2…", "missing"])
        #expect(lookedUp[0].arrangementSequence == ["Verse 1", "Chorus", "Verse 2", "Chorus", "Bridge", "Chorus"])
        #expect(lookedUp[0].song?.copyright == "2017 Phil Wickham Music…")
    }

    @Test func resyncPreservesIDsAndLocalItemsButRechecksSongLinks() throws {
        let plan = try shepherdDetail()
        let rules = ServiceLinkRules(id: "rules", rules: [])
        var original = ShepherdPlanSync.items(for: plan, rules: rules, existing: []) { _ in ("library", nil) }
        original[1].colorHex = "#ffffff"
        original[1].outputPresetId = "preset"
        original[1].hiddenInPresenter = true
        original.append(ServiceItem(id: "local", itemKind: .info, name: "Local", refId: ""))
        let synced = ShepherdPlanSync.items(for: plan, rules: rules, existing: original) { _ in nil }
        #expect(synced.map(\.id) == original.map(\.id))
        #expect(synced.last?.name == "Local")
        #expect(synced[1].colorHex == "#ffffff" && synced[1].outputPresetId == "preset" && synced[1].hiddenInPresenter == true)
        #expect(synced[1].itemKind == .info && synced[1].refId.isEmpty)
        #expect(synced[1].mxuSongTitle == "Living Hope" && synced[1].mxuCcliNumber == 7106807)
    }

    @Test func resyncKeepsTheItemsArrangementWhileTheSongIsTheSame() throws {
        let plan = try shepherdDetail()
        let rules = ServiceLinkRules(id: "rules", rules: [])
        var original = ShepherdPlanSync.items(for: plan, rules: rules, existing: []) { _ in ("library", nil) }
        original[1].arrangementId = "shepherd-a1"
        original[1].mxuSyncedArrangementId = "shepherd-a1"
        original[1].mxuArrangementWarnings = ["Shepherd's arrangement has Tag; this song has no Tag"]
        // A plan edit in Shepherd re-reads the items: the pick and what
        // sync noticed stay with the same library song.
        let same = ShepherdPlanSync.items(for: plan, rules: rules, existing: original) { _ in ("library", nil) }
        #expect(same[1].arrangementId == "shepherd-a1" && same[1].mxuSyncedArrangementId == "shepherd-a1")
        #expect(same[1].mxuArrangementWarnings?.count == 1)
        // Linked to another song: they go.
        let other = ShepherdPlanSync.items(for: plan, rules: rules, existing: original) { _ in ("other", nil) }
        #expect(other[1].refId == "other" && other[1].arrangementId == nil)
        #expect(other[1].mxuSyncedArrangementId == nil && other[1].mxuArrangementWarnings == nil)
    }

    @Test func invalidCCLIAndMissingSongStillKeepTitle() throws {
        var plan = try shepherdDetail()
        plan.items[1].song?.ccliNumber = "not-a-number"
        let rules = ServiceLinkRules(id: "rules", rules: [])
        let invalid = ShepherdPlanSync.items(for: plan, rules: rules, existing: []) { _ in nil }
        #expect(invalid[1].mxuCcliNumber == nil && invalid[1].mxuSongTitle == "Living Hope")
        plan.items[1].song = nil
        let missing = ShepherdPlanSync.items(for: plan, rules: rules, existing: []) { _ in nil }
        #expect(missing[1].itemKind == .info && missing[1].mxuSongTitle == "Living Hope")
    }

    @Test func namesAndDatesUseChurchCalendar() throws {
        var plan = try shepherdDetail()
        var summary = try #require(ShepherdClient.decoder().decode(
            ShepherdClient.Plans.self, from: Data(shepherdPlansJSON.utf8)).plans.first)
        #expect(ShepherdPlanSync.origin == "shepherd")
        #expect(ShepherdPlanSync.serviceName(for: plan) == "2026-10-18 — Living Water")
        #expect(ShepherdPlanSync.serviceName(for: summary) == "2026-10-18 — Living Water")
        for (timestamp, date) in [
            ("2026-01-19T04:30:00Z", "2026-01-18"),
            ("2026-07-19T04:30:00Z", "2026-07-19"),
            ("2026-07-19T03:30:00Z", "2026-07-18"),
        ] {
            plan.startsAt = ISO8601DateFormatter().date(from: timestamp)
            summary.startsAt = plan.startsAt
            #expect(ShepherdPlanSync.serviceDate(for: plan) == date)
            #expect(ShepherdPlanSync.serviceDate(for: summary) == date)
        }
        plan.title = " \n"
        #expect(ShepherdPlanSync.serviceName(for: plan) == "2026-07-18 — Sunday Worship")
        plan.startsAt = nil
        #expect(ShepherdPlanSync.serviceDate(for: plan).isEmpty)
        #expect(ShepherdPlanSync.serviceName(for: plan) == "Sunday Worship")
    }
}
