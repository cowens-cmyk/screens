import CoreMIDI
import Foundation
import PresenterCore
import SlideScene

final class MIDIInService: @unchecked Sendable {
    static let shared = MIDIInService()

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var ready = false
    private var wanted = Set<Int32>()
    private var connected: [Int32: MIDIEndpointRef] = [:]
    private var handler: (@Sendable (Int32, UInt8, UInt8, UInt8) -> Void)?
    private let lock = NSLock()

    /// Anthem's virtual source is listened to without being added under
    /// MIDI devices, whenever it is there.
    private var followAnthem = false
    private var anthemUIDs = Set<Int32>()
    /// The "Screens In" virtual destination any app on this Mac can send
    /// to. Not "Screens": that name is Screens' own output source, and two
    /// ports with one name make Anthem and Lightkey users pick the wrong one.
    static let destinationName = "Screens In"
    private var destination = MIDIEndpointRef()
    private var destinationUID: Int32 = 0
    /// Drops a message heard twice (Anthem's source and Screens In) and
    /// anything Screens sent coming back in.
    private var inputGuard = MIDIInputGuard()
    /// Told when Anthem's source comes or goes.
    var onAnthemChange: (@Sendable (Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return anthemChange }
        set { lock.lock(); anthemChange = newValue; lock.unlock() }
    }
    private var anthemChange: (@Sendable (Bool) -> Void)?

    private init() {}

    /// Creates the client and the "Screens" destination at launch, so other
    /// apps can pick Screens before anything is set up here.
    func start() {
        lock.lock()
        _ = ensureReady()
        lock.unlock()
        syncConnections()
    }

    func setFollowAnthem(_ follow: Bool) {
        lock.lock()
        followAnthem = follow
        lock.unlock()
        syncConnections()
    }

    /// Whether a message came from Anthem's own source.
    func isAnthemSource(_ uid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return anthemUIDs.contains(uid)
    }

    /// Whether a message arrived at the Screens In destination.
    func isScreensIn(_ uid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return uid != 0 && uid == destinationUID
    }

    /// The "Screens In" destination's unique ID, so MIDI out never sends
    /// into its own input. Zero before it exists.
    var ownDestinationUID: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return destinationUID
    }

    /// What MIDIOutService just sent, so an echo of it is ignored. Called
    /// with MIDIOutService's lock held; this one is taken after it, never
    /// the other way round.
    func noteSent(_ bytes: [UInt8]) {
        lock.lock()
        inputGuard.noteSent(bytes, at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
    }

    func setHandler(_ handler: @escaping @Sendable (Int32, UInt8, UInt8, UInt8) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func setSources(_ uids: Set<Int32>) {
        lock.lock()
        wanted = uids
        lock.unlock()
        syncConnections()
    }

    private func syncConnections() {
        lock.lock()
        let hadAnthem = !anthemUIDs.isEmpty
        let change = anthemChange
        defer {
            let hasAnthem = !anthemUIDs.isEmpty
            lock.unlock()
            if hasAnthem != hadAnthem { change?(hasAnthem) }
        }

        guard !wanted.isEmpty || followAnthem || ready else { return }
        guard ensureReady() else { return }
        let ownSource = MIDIOutService.shared.ownSourceUID
        var present: [Int32: MIDIEndpointRef] = [:]
        var anthem = Set<Int32>()
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            guard source != 0 else { continue }
            var uid: Int32 = 0
            guard MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uid) == noErr,
                  ownSource == 0 || uid != ownSource
            else { continue }
            if Self.name(of: source).map(AnthemMIDI.isAnthemSource(name:)) == true {
                anthem.insert(uid)
                if followAnthem { present[uid] = source }
            }
            if wanted.contains(uid) { present[uid] = source }
        }
        anthemUIDs = anthem
        for (uid, endpoint) in connected where present[uid] != endpoint {
            MIDIPortDisconnectSource(port, endpoint)
            connected[uid] = nil
        }
        for (uid, endpoint) in present where connected[uid] == nil {

            let refCon = UnsafeMutableRawPointer(bitPattern: Int(uid))
            if MIDIPortConnectSource(port, endpoint, refCon) == noErr {
                connected[uid] = endpoint
            }
        }
    }

    private func ensureReady() -> Bool {
        if ready { return true }
        let clientStatus = MIDIClientCreateWithBlock(
            "Screens In" as CFString, &client
        ) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                self?.syncConnections()
            }
        }
        guard clientStatus == noErr,
              MIDIInputPortCreateWithBlock(
                  client, "Screens In Port" as CFString, &port,
                  { [weak self] packetList, refCon in self?.receive(packetList, refCon) }
              ) == noErr
        else { return false }
        // Messages sent to "Screens In" arrive as if from a source whose ID
        // is the destination's own. They read with Anthem's notes when
        // Settings › Anthem says so, else with the MIDI input map.
        if MIDIDestinationCreateWithBlock(
            client, Self.destinationName as CFString, &destination,
            { [weak self] packetList, _ in self?.receiveAtDestination(packetList) }
        ) == noErr {
            MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &destinationUID)
        } else {
            destination = 0
        }
        ready = true
        return true
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String? {
        var nameRef: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &nameRef) == noErr,
              let value = nameRef?.takeRetainedValue() else { return nil }
        return value as String
    }

    private func receiveAtDestination(_ packetList: UnsafePointer<MIDIPacketList>) {
        lock.lock()
        let uid = destinationUID
        lock.unlock()
        receive(packetList, UnsafeMutableRawPointer(bitPattern: Int(uid)))
    }

    private func receive(_ packetList: UnsafePointer<MIDIPacketList>, _ refCon: UnsafeMutableRawPointer?) {
        let sourceUid = Int32(truncatingIfNeeded: refCon.map { Int(bitPattern: $0) } ?? 0)
        var accepted: [MIDIParse.ChannelMessage] = []
        for packet in packetList.unsafeSequence() {
            let length = Int(packet.pointee.length)
            let bytes = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(length)) }
            accepted += MIDIParse.channelMessages(in: bytes)
        }
        lock.lock()
        let handler = handler
        let path: MIDIInputGuard.Path = anthemUIDs.contains(sourceUid) ? .anthemSource
            : sourceUid != 0 && sourceUid == destinationUID ? .screensIn : .other
        let now = ProcessInfo.processInfo.systemUptime
        accepted = accepted.filter { inputGuard.accept($0, path: path, at: now) }
        lock.unlock()
        guard let handler else { return }
        for message in accepted {
            handler(sourceUid, message.status, message.data1, message.data2)
        }
    }
}

@MainActor
final class MIDIInController {
    private let model: AppModel
    private let controls: ServiceControls
    private let router: ActionRouter

    private let bridge: AppAPIBridge

    init(model: AppModel, controls: ServiceControls, router: ActionRouter, bridge: AppAPIBridge) {
        self.model = model
        self.controls = controls
        self.router = router
        self.bridge = bridge
    }

    private var selectedServiceItemID: String?
    private var selectedMediaPlaylistID: String?
    private var selectedComboFolderID: String?

    func attach() {
        MIDIInService.shared.setHandler { sourceUid, status, data1, data2 in
            Task { @MainActor in
                self.receive(sourceUid: sourceUid, status: status, data1: data1, data2: data2)
            }
        }
        MIDIInService.shared.setSources(MIDIDeviceInventory.shared.items.inputSourceUIDs)
        MIDIInService.shared.start()
        LightkeyLink.shared.start()
    }

    private func receive(sourceUid: Int32, status: UInt8, data1: UInt8, data2: UInt8) {

        if let device = MIDIDeviceInventory.shared.items.first(where: {
            $0.sourceUID == sourceUid
        }), !device.acceptsChannel(ofStatus: status) {
            return
        }
        // Anthem counts its notes one up from ProPresenter's stock numbers.
        // Its own source reads with Anthem's map unless Settings › Anthem
        // says otherwise; so does the Screens In destination when it says
        // Anthem's notes, since that is where Anthem's MIDI out lands when
        // it is pointed at Screens. Either way it's Anthem, and picks items
        // and slides by Anthem's numbering.
        let feed = AnthemFeed.shared
        let anthemNotes = feed.followMIDI && feed.midiUsesAnthemNotes
        let fromAnthem = MIDIInService.shared.isAnthemSource(sourceUid)
            || (anthemNotes && MIDIInService.shared.isScreensIn(sourceUid))
        let map = fromAnthem && feed.midiUsesAnthemNotes
            ? MIDIInputPreset.anthem.map : MIDICommandMapStore.shared.map
        guard let (command, velocity) = map.resolve(
            status: status, data1: data1, data2: data2
        ) else { return }
        DiagnosticsStore.shared.note("midi.in", detail: "\(fromAnthem ? "anthem " : "")\(command.rawValue) v\(velocity)")
        handle(command, velocity: velocity, fromAnthem: fromAnthem)
    }

    /// `fromAnthem`: Anthem picks plan items and slides by the numbers
    /// Screens' ProPresenter answers gave it (AnthemLink), so those two
    /// commands index the same lists here.
    func handle(_ command: MIDICommand, velocity: Int, fromAnthem: Bool = false) {

        let index = velocity - 1
        switch command {
        case .clearAll:
            controls.clearAll()
        case .clearSlides:
            controls.clear(function: .slides)
        case .clearMedia:
            controls.clear(function: .media)
        case .clearAlerts:
            controls.clear(function: .alerts)
        case .videoGoToBeginning:
            for row in controls.media.rows { controls.media.resetToStart(row.id) }
        case .videoPlayPause:
            for row in controls.media.rows { controls.media.togglePlayPause(row.id) }
        case .videoPlay:
            for row in controls.media.rows where !row.state.isPlaying {
                controls.media.togglePlayPause(row.id)
            }
        case .videoPause:
            for row in controls.media.rows where row.state.isPlaying {
                controls.media.togglePlayPause(row.id)
            }
        case .nextSlide:
            bridge.advanceIgnoringErrors(steps: 1, settled: false)
        case .previousSlide:
            bridge.advanceIgnoringErrors(steps: -1, settled: false)
        case .nextServiceItem:
            try? bridge.advanceServiceItem(steps: 1)
        case .previousServiceItem:
            try? bridge.advanceServiceItem(steps: -1)
        case .selectService:
            let services = model.entries(in: .services)
            guard services.indices.contains(index) else { return miss(command, "index \(index)") }
            selectedServiceItemID = nil
            try? bridge.selectService(id: services[index].id)
        case .selectServiceItem:
            guard let items = fromAnthem ? AnthemLink.shared.playlistItems() : currentServiceItems()
            else { return miss(command, "no service") }
            guard items.indices.contains(index) else { return miss(command, "index \(index)") }
            let item = items[index]
            if item.itemKind == .media {

                selectedServiceItemID = nil
                guard let media = model.media(item.refId) else { return miss(command, "media missing") }
                controls.fire(mediaItem: media, context: .serviceItem(id: item.id))
                return
            }
            selectedServiceItemID = item.id
        case .triggerSlide:
            if fromAnthem {
                // The presentation's own slide order, as /v1/presentation
                // lists it: the same index over MIDI and over the network.
                let selection = selectedServiceItem()
                guard let presentationID = selection?.presentation.id ?? controls.livePresentationID
                else { return miss(command, "nothing live or selected") }
                if !AnthemLink.shared.cue(presentationID: presentationID, index: index, itemID: selection?.item.id) {
                    miss(command, "index \(index)")
                }
                return
            }

            if let selection = selectedServiceItem() {
                let slides = SlideSceneBuilder.arrangedSlides(
                    for: selection.presentation, arrangementId: selection.item.arrangementId)
                guard slides.indices.contains(index) else {
                    return miss(command, "index \(index)")
                }
                controls.fire(
                    slide: slides[index], in: selection.presentation,
                    arrangementId: selection.item.arrangementId,
                    contextID: selection.item.id, occurrence: index
                )
                return
            }
            guard let live = controls.state.liveSlide, let presentation = live.presentation
            else { return miss(command, "nothing live or selected") }
            let slides = SlideSceneBuilder.arrangedSlides(
                for: presentation, arrangementId: live.arrangementId)
            guard slides.indices.contains(index) else { return miss(command, "index \(index)") }
            controls.fire(
                slide: slides[index], in: presentation, arrangementId: live.arrangementId,
                contextID: controls.liveContextID, occurrence: index
            )
        case .selectMediaPlaylist:
            let playlists = model.playlists(in: .media)
            guard playlists.indices.contains(index) else { return miss(command, "index \(index)") }
            selectedMediaPlaylistID = playlists[index].id
        case .triggerMedia:
            guard let playlistID = selectedMediaPlaylistID,
                  let playlist = try? model.playlist(playlistID)
            else { return miss(command, "no playlist selected") }
            guard playlist.entries.indices.contains(index) else {
                return miss(command, "index \(index)")
            }
            guard let item = model.media(playlist.entries[index].refId) else {
                return miss(command, "mediaId")
            }
            controls.fire(mediaItem: item)
        case .fireAlert:
            let presets = model.entries(of: .alertPreset)
            guard presets.indices.contains(index) else { return miss(command, "index \(index)") }
            guard let preset = try? model.alertPreset(presets[index].id)
            else { return miss(command, "alertId") }
            controls.fire(alertPreset: preset)
        case .startTimer, .stopTimer, .resetTimer:
            let timers = controls.timers.timers
            guard timers.indices.contains(index) else { return miss(command, "index \(index)") }
            let id = timers[index].id
            switch command {
            case .startTimer: controls.timers.start(id: id)
            case .stopTimer: controls.timers.pause(id: id)
            default: controls.resetTimer(id: id)
            }
        case .selectActionComboFolder:

            let folders = model.comboBoard.orderedFolders
            guard folders.indices.contains(index) else { return miss(command, "index \(index)") }
            selectedComboFolderID = folders[index].id
        case .triggerActionCombo:
            let board = model.comboBoard
            let comboIDs: [String]
            if let folderID = selectedComboFolderID {

                guard let folder = board.folder(id: folderID) else {
                    return miss(command, "folder gone")
                }
                comboIDs = folder.itemIds
            } else {
                comboIDs = board.allItemIDs
            }
            guard comboIDs.indices.contains(index) else { return miss(command, "index \(index)") }
            router.fire(comboID: comboIDs[index])
        }
    }

    private func currentServiceItems() -> [ServiceItem]? {
        guard let serviceID = model.currentServiceID,
              let service = try? model.service(serviceID)
        else { return nil }
        return model.fireableItems(service)
    }

    private func selectedServiceItem() -> (item: ServiceItem, presentation: Presentation)? {
        guard let itemID = selectedServiceItemID,
              let item = currentServiceItems()?.first(where: { $0.id == itemID }),
              item.itemKind == .presentation,

              let presentation = model.presentation(item.refId)
        else { return nil }
        return (item, presentation)
    }

    private func miss(_ command: MIDICommand, _ detail: String) {
        DiagnosticsStore.shared.note("midi.in.skipped", detail: "\(command.rawValue) \(detail)")
    }
}
