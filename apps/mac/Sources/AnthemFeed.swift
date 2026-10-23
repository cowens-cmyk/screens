import Foundation
import Network
import Observation
import PresenterCore
import SwiftUI

/// Reads Anthem's setlist so the slides follow the band. Anthem leads: its
/// setlist says which songs, and each song's performed sections say the
/// order. Screens compares that with each plan song's arrangement and marks
/// the songs that differ (see AnthemSongMatch); "Match Anthem" makes them
/// agree.
///
/// Anthem is found over Bonjour (`_anthem-show._tcp`) or at the address in
/// Settings › Anthem. The setlist is read every 10 s; Anthem's status every
/// 1.5 s only while a song is live. When Anthem is off the feed says
/// "Anthem not found" and keeps quiet.
@MainActor
@Observable
final class AnthemFeed {
    static let shared = AnthemFeed()

    enum Connection: Equatable {
        case off
        case searching
        case connected(String)
        case notFound
    }

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "anthem.feed.enabled")
            restart()
        }
    }
    /// "host" or "host:port"; empty finds Anthem by itself.
    var manualAddress: String {
        didSet {
            guard manualAddress != oldValue else { return }
            UserDefaults.standard.set(manualAddress, forKey: "anthem.feed.address")
            restart()
        }
    }
    var ignoreInstrumental: Bool {
        didSet { UserDefaults.standard.set(ignoreInstrumental, forKey: "anthem.feed.ignoreInstrumental") }
    }
    var autoMatch: Bool {
        didSet {
            UserDefaults.standard.set(autoMatch, forKey: "anthem.feed.autoMatch")
            if autoMatch { autoMatchUpcoming() }
        }
    }
    /// Listen to Anthem's own MIDI source when it appears.
    var followMIDI: Bool {
        didSet {
            UserDefaults.standard.set(followMIDI, forKey: "anthem.midi.follow")
            MIDIInService.shared.setFollowAnthem(followMIDI)
        }
    }
    /// Read Anthem's notes with Anthem's numbers rather than the MIDI input
    /// map in Settings › MIDI.
    var midiUsesAnthemNotes: Bool {
        didSet { UserDefaults.standard.set(midiUsesAnthemNotes, forKey: "anthem.midi.anthemNotes") }
    }

    private(set) var connection: Connection = .off
    private(set) var setlist: AnthemShow.Setlist?
    // These two move on every read; nothing on screen shows them.
    @ObservationIgnored private var setlistAt: Date?
    @ObservationIgnored private var status: AnthemShow.Status?
    private(set) var midiConnected = false

    private weak var model: AppModel?
    private weak var controls: ServiceControls?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var browsed: [NWBrowser.Result] = []
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastSetlistFetch: Date?
    @ObservationIgnored private var setlistRevision = 0
    @ObservationIgnored private var reportCache: [String: AnthemSongMatch.Report?] = [:]
    @ObservationIgnored private var autoMatched: Set<String> = []

    /// A setlist read this long ago is too old to mark plans with.
    private static let setlistShelfLife: TimeInterval = 12 * 60 * 60

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "anthem.feed.enabled") as? Bool ?? true
        manualAddress = defaults.string(forKey: "anthem.feed.address") ?? ""
        ignoreInstrumental = defaults.object(forKey: "anthem.feed.ignoreInstrumental") as? Bool ?? true
        autoMatch = defaults.object(forKey: "anthem.feed.autoMatch") as? Bool ?? false
        followMIDI = defaults.object(forKey: "anthem.midi.follow") as? Bool ?? true
        midiUsesAnthemNotes = defaults.object(forKey: "anthem.midi.anthemNotes") as? Bool ?? true
    }

    func attach(model: AppModel, controls: ServiceControls) {
        self.model = model
        self.controls = controls
        MIDIInService.shared.onAnthemChange = { connected in
            Task { @MainActor in AnthemFeed.shared.midiConnected = connected }
        }
        MIDIInService.shared.setFollowAnthem(followMIDI)
        restart()
    }

    // MARK: Finding Anthem

    private func restart() {
        poller?.cancel()
        poller = nil
        browser?.cancel()
        browser = nil
        browsed = []
        failures = 0
        lastSetlistFetch = nil
        status = nil
        guard enabled, model != nil else {
            setConnection(.off)
            return
        }
        setConnection(.searching)
        if AnthemShow.endpoint(fromManual: manualAddress) == nil { browse() }
        poller = Task { [weak self] in await self?.poll() }
    }

    private func browse() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: AnthemShow.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            Task { @MainActor in
                let feed = AnthemFeed.shared
                feed.browsed = results.sorted { "\($0.endpoint)" < "\($1.endpoint)" }
                if !results.isEmpty, feed.connection != .connected(feed.anthemName) {
                    feed.lastSetlistFetch = nil
                    feed.kick()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// The Mac Anthem runs on, from its Bonjour name or the typed address.
    var anthemName: String {
        if let manual = AnthemShow.endpoint(fromManual: manualAddress) { return manual.host }
        if case .service(let name, _, _, _) = browsed.first?.endpoint { return name }
        return "Anthem"
    }

    private var target: NWEndpoint? {
        if let manual = AnthemShow.endpoint(fromManual: manualAddress),
           let port = NWEndpoint.Port(rawValue: manual.port) {
            return .hostPort(host: NWEndpoint.Host(manual.host), port: port)
        }
        return browsed.first?.endpoint
    }

    // MARK: Polling

    @ObservationIgnored private var nap: Task<Void, Never>?

    /// Read now rather than at the next tick.
    private func kick() { nap?.cancel() }

    /// Writes observed state only when it changes, so a view showing the
    /// feed redraws on news, not on every read.
    private func poll() async {
        while !Task.isCancelled {
            await tick()
            let live = status?.songIsLive == true && connection != .notFound
            let delay: Duration = live ? .seconds(1.5) : .seconds(10)
            let nap = Task { _ = try? await Task.sleep(for: delay) }
            self.nap = nap
            await withTaskCancellationHandler {
                await nap.value
            } onCancel: {
                nap.cancel()
            }
            self.nap = nil
        }
    }

    private func setConnection(_ next: Connection) {
        if connection != next { connection = next }
    }

    private func tick() async {
        if let at = setlistAt, Date.now.timeIntervalSince(at) > Self.setlistShelfLife {
            setSetlist(nil)
        }
        guard let target else {
            // Bonjour gets a moment before "not found".
            setConnection(failures == 0 ? .searching : .notFound)
            failures += 1
            return
        }
        let host = anthemName
        do {
            let due = lastSetlistFetch.map { Date.now.timeIntervalSince($0) >= 9.5 } ?? true
            if due {
                let (code, body) = try await AnthemHTTP.get(target, path: "/v1/setlist/active", host: host)
                switch try AnthemShow.decodeSetlist(body, status: code) {
                case .setlist(let fresh): setSetlist(fresh)
                case .none: setSetlist(nil)
                }
                lastSetlistFetch = .now
                // Also catches a plan that arrived since the setlist did.
                if autoMatch { autoMatchUpcoming() }
            }
            let (code, body) = try await AnthemHTTP.get(target, path: "/v1/status", host: host)
            status = try? AnthemShow.decodeStatus(body, status: code)
            if connection != .connected(host) {
                DiagnosticsStore.shared.note("anthem.feed", detail: "connected: \(host)")
            }
            setConnection(.connected(host))
            failures = 0
        } catch {
            failures += 1
            status = nil
            // One miss can be a busy network; two in a row, Anthem is gone.
            if failures >= 2, connection != .notFound {
                if case .connected = connection {
                    DiagnosticsStore.shared.note("anthem.feed", detail: "lost: \(error.localizedDescription)")
                }
                setConnection(.notFound)
            }
        }
    }

    private func setSetlist(_ fresh: AnthemShow.Setlist?) {
        if fresh != nil { setlistAt = .now }
        guard fresh != setlist else { return }
        setlist = fresh
        setlistRevision += 1
        reportCache.removeAll()
    }

    // MARK: Comparing with plans

    /// How the plan's songs compare with Anthem's setlist; nil when there is
    /// no setlist or the plan isn't the one it's for (a past plan, or one
    /// sharing only a song or two).
    func report(for serviceID: String, model: AppModel) -> AnthemSongMatch.Report? {
        guard let setlist else { return nil }
        // Read so views update when presentations, plans or the rule change.
        let key = "\(serviceID)|\(setlistRevision)|\(model.version(of: .presentation))|\(model.version(of: .service))|\(model.listVersion)|\(ignoreInstrumental)|\(model.currentServiceID ?? "")"
        if let hit = reportCache[key] { return hit }
        guard let service = try? model.service(serviceID) else { return nil }
        let isCurrent = model.currentServiceID == serviceID
        guard isCurrent || String(service.serviceDate.prefix(10)) >= AppModel.isoDate(.now) else { return nil }
        var warming = false
        let songs = service.items.compactMap { item -> AnthemSongMatch.PlanSong? in
            let presentation = item.itemKind == .presentation ? model.presentation(item.refId) : nil
            if item.itemKind == .presentation, presentation == nil { warming = true }
            guard AnthemSongMatch.PlanSong.isSong(item, presentation: presentation) else { return nil }
            return AnthemSongMatch.PlanSong(item: item, presentation: presentation)
        }
        let report = AnthemSongMatch.report(
            setlist: setlist, songs: songs, options: .init(ignoreInstrumental: ignoreInstrumental))
        let result = report.followsSetlist ? report : nil
        // A song still loading would read as no slides; ask again later.
        if !warming {
            if reportCache.count > 32 { reportCache.removeAll() }
            reportCache[key] = result
        }
        return result
    }

    /// With "Match Anthem automatically", every upcoming plan Anthem's
    /// setlist is for gets Anthem's order on its songs that differ. A song
    /// on screen right now is left alone, and a fix the operator undid is
    /// not made again for the same order.
    func autoMatchUpcoming() {
        guard autoMatch, let model, setlist != nil else { return }
        let today = AppModel.isoDate(.now)
        let plans = model.resident.services.values.filter {
            $0.isTemplate != true && String($0.serviceDate.prefix(10)) >= today
        }
        for plan in plans {
            guard let report = report(for: plan.id, model: model) else { continue }
            for result in report.mismatches {
                guard let itemID = result.itemID, let proposed = result.comparison?.proposed, !proposed.isEmpty,
                      controls?.liveContextID != itemID else { continue }
                let key = "\(plan.id)|\(itemID)|\(proposed.joined(separator: ","))"
                guard !autoMatched.contains(key) else { continue }
                autoMatched.insert(key)
                if model.matchAnthem(serviceID: plan.id, itemID: itemID, order: proposed) {
                    DiagnosticsStore.shared.note("anthem.match", detail: "auto: \(result.title)")
                }
            }
        }
    }
}

extension AppModel {
    /// Gives the plan item an arrangement in Anthem's order: the song's
    /// "Anthem" arrangement, rewritten or added, or an existing one already
    /// in that order. Undo puts back the arrangements and the item's pick.
    @discardableResult
    func matchAnthem(serviceID: String, itemID: String, order: [String]) -> Bool {
        guard !order.isEmpty, let service = try? service(serviceID),
              let item = service.items.first(where: { $0.id == itemID }), item.itemKind == .presentation,
              let presentation = presentation(item.refId) else { return false }
        let presentationID = presentation.id
        let before = (arrangements: presentation.arrangements, pick: item.arrangementId)
        let existing = presentation.arrangements ?? []
        let chosen = AnthemSongMatch.anthemArrangement(order: order, in: existing, newID: UUID().uuidString)
        var arrangements = existing
        if let index = arrangements.firstIndex(where: { $0.id == chosen.arrangement.id }) {
            arrangements[index] = chosen.arrangement
        } else {
            arrangements.append(chosen.arrangement)
        }
        let after = (arrangements: Optional(arrangements), pick: Optional(chosen.arrangement.id))
        guard after.arrangements != before.arrangements || after.pick != before.pick else { return false }
        let apply: ((arrangements: [Arrangement]?, pick: String?)) -> Bool = { [weak self] state in
            guard let self, libraryEntry(presentationID) != nil, (try? self.service(serviceID)) != nil else { return false }
            let arrangements = state.arrangements
            updatePresentation(presentationID) { $0.arrangements = arrangements }
            setServiceItemArrangement(serviceID, itemID: itemID, arrangementID: state.pick)
            return true
        }
        _ = apply(after)
        moveUndo.registerEdit(
            key: "matchAnthem:\(serviceID):\(itemID)", label: "Match Anthem",
            undo: { apply(before) }, redo: { apply(after) }
        )
        return true
    }
}

/// One plain GET over the Network framework: Anthem's feed is HTTP on the
/// LAN, found by Bonjour, so this connects to the Bonjour endpoint directly
/// instead of resolving it to a URL first.
enum AnthemHTTP {
    struct Timeout: Error {}
    struct BadResponse: Error {}

    private final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(Int, Data), any Error>?
        private var buffer = Data()

        init(_ continuation: CheckedContinuation<(Int, Data), any Error>) {
            self.continuation = continuation
        }

        func append(_ data: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
            // A feed answer is small; anything this big is not Anthem.
            return buffer.count < 8 * 1024 * 1024
        }

        func finish(_ result: Result<(Int, Data), any Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }

        func finishWithBuffer() {
            lock.lock()
            let data = buffer
            lock.unlock()
            if let parsed = AnthemShow.parseResponse(data) {
                finish(.success((parsed.status, parsed.body)))
            } else {
                finish(.failure(BadResponse()))
            }
        }
    }

    private static let queue = DispatchQueue(label: "org.hopejc.screens.anthem.feed")

    static func get(_ endpoint: NWEndpoint, path: String, host: String, timeout: TimeInterval = 3) async throws -> (Int, Data) {
        let parameters = NWParameters.tcp
        // Bonjour hands back IPv4 and link-local IPv6; IPv4 is the one that
        // works through every church switch.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let exchange = Exchange(continuation)
                @Sendable func receive() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                        if let data, !data.isEmpty, !exchange.append(data) {
                            exchange.finish(.failure(BadResponse()))
                            connection.cancel()
                            return
                        }
                        if complete || error != nil {
                            exchange.finishWithBuffer()
                            connection.cancel()
                        } else {
                            receive()
                        }
                    }
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: AnthemShow.request(path: path, host: host), completion: .contentProcessed { error in
                            if let error {
                                exchange.finish(.failure(error))
                                connection.cancel()
                            } else {
                                receive()
                            }
                        })
                    case .waiting(let error), .failed(let error):
                        // Refused or unreachable: Anthem isn't there.
                        exchange.finish(.failure(error))
                        connection.cancel()
                    case .cancelled:
                        exchange.finish(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    exchange.finish(.failure(Timeout()))
                    connection.cancel()
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

// MARK: Views

/// The orange ⚠ on a plan song whose arrangement differs from Anthem's
/// order. Hover shows the difference; click opens it with "Match Anthem".
struct AnthemMismatchBadge: View {
    let model: AppModel
    let serviceID: String
    let itemID: String
    /// The slide grid's header names it; the plan row stays an icon.
    var labeled = false

    @State private var showing = false

    var body: some View {
        if let result = AnthemFeed.shared.report(for: serviceID, model: model)?.result(forItem: itemID),
           result.status == .mismatch, let comparison = result.comparison {
            Button { showing.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    if labeled { Text("Anthem") }
                }
                .font(labeled ? .caption : .system(size: 11))
                .foregroundStyle(.orange)
                .padding(.horizontal, labeled ? 6 : 0)
                .padding(.vertical, labeled ? 2 : 0)
                .background(labeled ? AnyShapeStyle(Color.orange.opacity(0.12)) : AnyShapeStyle(.clear), in: Capsule())
            }
            .buttonStyle(.borderless)
            .help(comparison.diff)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                AnthemMismatchPopover(model: model, serviceID: serviceID, itemID: itemID, comparison: comparison) {
                    showing = false
                }
            }
        }
    }
}

private struct AnthemMismatchPopover: View {
    let model: AppModel
    let serviceID: String
    let itemID: String
    let comparison: AnthemArrangementMatch.Comparison
    let done: () -> Void

    @Environment(\.runOnly) private var runOnly

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Order differs from Anthem")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("Anthem: " + comparison.anthemTokens.joined(separator: " "))
                Text("Screens: " + comparison.screensTokens.joined(separator: " "))
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            if let note = AnthemArrangementMatch.missingNote(comparison.missing) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Match Anthem") {
                    model.matchAnthem(serviceID: serviceID, itemID: itemID, order: comparison.proposed)
                    done()
                }
                .disabled(runOnly || comparison.proposed.isEmpty)
                .help("Sets this song's arrangement to Anthem's order, in an arrangement named Anthem.")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }
}

/// The plan's one-line Anthem summary, beside the item count.
struct AnthemPlanSummary: View {
    let model: AppModel
    let serviceID: String

    var body: some View {
        if let report = AnthemFeed.shared.report(for: serviceID, model: model) {
            let differ = report.mismatches.count
            let missing = report.notInScreens.count
            Group {
                if differ > 0 {
                    Label(differ == 1 ? "1 song differs from Anthem" : "\(differ) songs differ from Anthem",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else if missing > 0 {
                    Text(missing == 1 ? "1 Anthem song not in plan" : "\(missing) Anthem songs not in plan")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Matches Anthem")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .help(summaryHelp(report))
        }
    }

    private func summaryHelp(_ report: AnthemSongMatch.Report) -> String {
        var lines = report.mismatches.compactMap { result in result.comparison.map { "\(result.title): \($0.diff)" } }
        let missing = report.notInScreens.map(\.title)
        if !missing.isEmpty { lines.append("Not in this plan: " + missing.joined(separator: ", ")) }
        return lines.isEmpty ? "Every song is in Anthem's order." : lines.joined(separator: "\n")
    }
}
