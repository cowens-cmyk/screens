import Foundation
import Testing
@testable import PresenterCore

/// Bytes here are what Hope's ATEM 2 M/E Constellation HD (protocol 2.30)
/// sent on 2026-11-10.
@Suite struct ATEMProtocolTests {
    private func hex(_ string: String) -> Data {
        Data(string.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    @Test func helloMatchesWhatTheSwitcherAccepts() {
        let packet = ATEMProtocol.hello(sessionID: 0x53AB)
        #expect(packet.encoded == hex("10 14 53 ab 00 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00"))
    }

    @Test func decodesTheSwitchersHelloReply() throws {
        let packet = try #require(ATEMProtocol.Packet.decode(hex("10 14 53 ab 00 00 00 00 00 ab 00 00 02 00 00 00 00 00 00 00")))
        #expect(packet.flags == .hello)
        #expect(packet.sessionID == 0x53AB)
        #expect(packet.payload.count == 8)
    }

    @Test func ackCarriesThePacketIDBeingAcknowledged() {
        let ack = ATEMProtocol.ack(sessionID: 0x8123, packetID: 7)
        #expect(ack.encoded == hex("80 0c 81 23 00 07 00 00 00 00 00 00"))
    }

    @Test func aCommandPacketRoundTrips() throws {
        let commands = [ATEMProtocol.setOnAir(.upstream(me: 0, keyer: 0), true)]
        let packet = ATEMProtocol.Packet(
            flags: .ackRequest, sessionID: 0x8001, packetID: 5, payload: ATEMProtocol.encode(commands))
        let decoded = try #require(ATEMProtocol.Packet.decode(packet.encoded))
        #expect(decoded.flags == .ackRequest)
        #expect(decoded.packetID == 5)
        #expect(ATEMProtocol.commands(in: decoded.payload) == commands)
        #expect(packet.encoded.count == 12 + 12)
    }

    @Test func onAirCommandsForEachKind() {
        #expect(ATEMProtocol.setOnAir(.upstream(me: 1, keyer: 2), true).payload == Data([1, 2, 1, 0]))
        #expect(ATEMProtocol.setOnAir(.upstream(me: 0, keyer: 0), false).name == "CKOn")
        #expect(ATEMProtocol.setOnAir(.downstream(1), true) == .init(name: "CDsL", payload: Data([1, 1, 0, 0])))
    }

    @Test func aTruncatedCommandStopsTheWalk() {
        var payload = ATEMProtocol.encode([.init(name: "InCm", payload: Data([1, 0, 0, 0]))])
        payload.append(contentsOf: [0x00, 0x40, 0, 0, 0x4B])
        #expect(ATEMProtocol.commands(in: payload).map(\.name) == ["InCm"])
    }

    @Test func stateFromTheRealDump() {
        var state = ATEMProtocol.State()
        var inPr = Data([0x00, 0x07]) + Data("Fill".utf8) + Data(repeating: 0, count: 16)
        inPr += Data("FILL".utf8)
        inPr += Data(repeating: 0, count: 10)
        let dump: [ATEMProtocol.Command] = [
            .init(name: "_pin", payload: Data("ATEM 2 M/E Constellation HD".utf8) + Data(repeating: 0, count: 17)),
            .init(name: "_top", payload: hex("02 39 02 0c 0c 02 02 00")),
            .init(name: "InPr", payload: inPr),
            .init(name: "KeOn", payload: hex("00 00 01 43")),
            .init(name: "KeBP", payload: hex("00 00 00 01 01 00 00 07 00 06 00 72 23 28 dc d8 c1 80 3e 80")),
            .init(name: "KeOn", payload: hex("00 01 00 00")),
            .init(name: "KeBP", payload: hex("00 01 00 01 01 00 0b c2 0b c3 00 06 23 28 dc d8 c1 80 3e 80")),
            .init(name: "DskB", payload: hex("00 00 00 07 00 06 00 32")),
            .init(name: "DskS", payload: hex("00 00 00 00 01 1e 00 e8")),
            .init(name: "InCm", payload: hex("01 00 00 00")),
        ]
        for command in dump { state.apply(command) }

        #expect(state.productName == "ATEM 2 M/E Constellation HD")
        #expect(state.meCount == 2)
        #expect(state.inputName(7) == "Fill")
        #expect(state.inputs[7]?.shortName == "FILL")
        #expect(state.onAir[.upstream(me: 0, keyer: 0)] == true)
        #expect(state.onAir[.upstream(me: 0, keyer: 1)] == false)
        #expect(state.sources[.upstream(me: 0, keyer: 0)] == .init(fill: 7, key: 6))
        #expect(state.sources[.upstream(me: 0, keyer: 1)] == .init(fill: 3010, key: 3011))
        #expect(state.sources[.downstream(0)] == .init(fill: 7, key: 6))
        #expect(state.onAir[.downstream(0)] == false)
        #expect(state.keyers == [.upstream(me: 0, keyer: 0), .upstream(me: 0, keyer: 1), .downstream(0)])
        #expect(state.initialized)
    }

    @Test func keyerStorageRoundTrips() {
        for keyer in [ATEMProtocol.Keyer.upstream(me: 1, keyer: 3), .downstream(1)] {
            #expect(ATEMProtocol.Keyer(storageKey: keyer.storageKey) == keyer)
        }
        #expect(ATEMProtocol.Keyer(storageKey: "usk:x") == nil)
        #expect(ATEMProtocol.Keyer.upstream(me: 0, keyer: 0).title == "ME 1 Key 1")
    }

    @Test func followerCutsOnAtOnceAndOffAfterTheDelay() {
        var follower = ATEMKeyFollower()
        let start = Date(timeIntervalSince1970: 1000)
        #expect(follower.update(showing: false, at: start) == nil)
        #expect(follower.update(showing: true, at: start) == true)
        #expect(follower.update(showing: true, at: start + 1) == nil)
        #expect(follower.update(showing: false, at: start + 2) == nil)
        #expect(follower.update(showing: false, at: start + 3) == nil)
        #expect(follower.update(showing: false, at: start + 3.5) == false)
        #expect(follower.update(showing: false, at: start + 10) == nil)
    }

    @Test func aShortGapDoesNotCutTheKeyerOff() {
        var follower = ATEMKeyFollower()
        let start = Date(timeIntervalSince1970: 1000)
        _ = follower.update(showing: true, at: start)
        #expect(follower.update(showing: false, at: start + 1) == nil)
        #expect(follower.update(showing: true, at: start + 2) == nil)
        #expect(follower.update(showing: false, at: start + 2.5) == nil)
        #expect(follower.update(showing: false, at: start + 3.5) == nil)
        #expect(follower.wanted)
    }
}
