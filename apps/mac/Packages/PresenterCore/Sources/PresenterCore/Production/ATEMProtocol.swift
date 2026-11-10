import Foundation

/// The parts of the ATEM switcher protocol Screens needs to put the
/// livestream graphics on and off air: the UDP packet framing, the commands
/// in a packet, and the few state messages worth keeping (product name, input
/// names, keyer on-air and sources). Pure functions, so the framing can be
/// tested without a switcher; ATEMLink owns the socket.
///
/// A packet is a 12-byte header and then commands. The header's first word
/// is five flag bits and an 11-bit length; then the session id, the id of
/// the packet being acknowledged, four unused bytes, and this packet's id.
/// A command is a 2-byte length (header included), two unused bytes, a
/// four-letter name and its payload.
public enum ATEMProtocol {
    public static let port: UInt16 = 9910
    static let headerLength = 12

    public struct Flags: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let ackRequest = Flags(rawValue: 0x01)
        public static let hello = Flags(rawValue: 0x02)
        public static let retransmit = Flags(rawValue: 0x04)
        public static let retransmitRequest = Flags(rawValue: 0x08)
        public static let ackReply = Flags(rawValue: 0x10)
    }

    public struct Packet: Sendable, Equatable {
        public var flags: Flags
        public var sessionID: UInt16
        public var ackID: UInt16
        public var packetID: UInt16
        public var payload: Data

        public init(flags: Flags, sessionID: UInt16, ackID: UInt16 = 0, packetID: UInt16 = 0, payload: Data = Data()) {
            self.flags = flags
            self.sessionID = sessionID
            self.ackID = ackID
            self.packetID = packetID
            self.payload = payload
        }

        public var encoded: Data {
            let length = headerLength + payload.count
            var data = Data(capacity: length)
            let word = UInt16(flags.rawValue) << 11 | UInt16(length & 0x7FF)
            data.appendBigEndian(word)
            data.appendBigEndian(sessionID)
            data.appendBigEndian(ackID)
            data.append(contentsOf: [0, 0, 0, 0])
            data.appendBigEndian(packetID)
            data.append(payload)
            return data
        }

        public static func decode(_ data: Data) -> Packet? {
            let bytes = [UInt8](data)
            guard bytes.count >= headerLength else { return nil }
            let word = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let length = Int(word & 0x7FF)
            guard length >= headerLength, length <= bytes.count else { return nil }
            return Packet(
                flags: Flags(rawValue: UInt8(word >> 11)),
                sessionID: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
                ackID: UInt16(bytes[4]) << 8 | UInt16(bytes[5]),
                packetID: UInt16(bytes[10]) << 8 | UInt16(bytes[11]),
                payload: Data(bytes[headerLength..<length]))
        }
    }

    /// The first packet of a connection. The switcher answers with its own
    /// hello, and from then on uses a session id of its choosing.
    public static func hello(sessionID: UInt16) -> Packet {
        Packet(flags: .hello, sessionID: sessionID, payload: Data([0x01, 0, 0, 0, 0, 0, 0, 0]))
    }

    public static func ack(sessionID: UInt16, packetID: UInt16) -> Packet {
        Packet(flags: .ackReply, sessionID: sessionID, ackID: packetID)
    }

    public struct Command: Sendable, Equatable {
        public var name: String
        public var payload: Data

        public init(name: String, payload: Data) {
            self.name = name
            self.payload = payload
        }

        var encoded: Data {
            var data = Data()
            data.appendBigEndian(UInt16(8 + payload.count))
            data.append(contentsOf: [0, 0])
            data.append(contentsOf: Array(name.utf8.prefix(4)))
            data.append(payload)
            return data
        }
    }

    public static func encode(_ commands: [Command]) -> Data {
        commands.reduce(into: Data()) { $0.append($1.encoded) }
    }

    public static func commands(in payload: Data) -> [Command] {
        let bytes = [UInt8](payload)
        var result: [Command] = []
        var index = 0
        while index + 8 <= bytes.count {
            let length = Int(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            guard length >= 8, index + length <= bytes.count else { break }
            let name = String(decoding: bytes[(index + 4)..<(index + 8)], as: UTF8.self)
            result.append(Command(name: name, payload: Data(bytes[(index + 8)..<(index + length)])))
            index += length
        }
        return result
    }

    // MARK: Keyers

    /// A keyer that can carry Screens' Fill and Key: one of an M/E's
    /// upstream keyers, or a downstream keyer.
    public enum Keyer: Hashable, Sendable, Codable {
        case upstream(me: Int, keyer: Int)
        case downstream(Int)

        public var title: String {
            switch self {
            case .upstream(let me, let keyer): "ME \(me + 1) Key \(keyer + 1)"
            case .downstream(let index): "DSK \(index + 1)"
            }
        }

        /// Stored per Mac as a short string ("usk:0:0", "dsk:1").
        public var storageKey: String {
            switch self {
            case .upstream(let me, let keyer): "usk:\(me):\(keyer)"
            case .downstream(let index): "dsk:\(index)"
            }
        }

        public init?(storageKey: String) {
            let parts = storageKey.split(separator: ":").map(String.init)
            switch (parts.first, parts.count) {
            case ("usk", 3):
                guard let me = Int(parts[1]), let keyer = Int(parts[2]) else { return nil }
                self = .upstream(me: me, keyer: keyer)
            case ("dsk", 2):
                guard let index = Int(parts[1]) else { return nil }
                self = .downstream(index)
            default:
                return nil
            }
        }
    }

    /// Cuts a keyer on or off air.
    public static func setOnAir(_ keyer: Keyer, _ onAir: Bool) -> Command {
        switch keyer {
        case .upstream(let me, let index):
            Command(name: "CKOn", payload: Data([UInt8(me), UInt8(index), onAir ? 1 : 0, 0]))
        case .downstream(let index):
            Command(name: "CDsL", payload: Data([UInt8(index), onAir ? 1 : 0, 0, 0]))
        }
    }

    // MARK: State

    public struct Input: Sendable, Equatable {
        public var longName: String
        public var shortName: String
    }

    public struct KeyerSources: Sendable, Equatable {
        public var fill: UInt16
        public var key: UInt16
    }

    /// What the switcher has told us that the settings and the monitor show.
    public struct State: Sendable, Equatable {
        public var productName: String?
        public var meCount = 0
        public var inputs: [UInt16: Input] = [:]
        public var onAir: [Keyer: Bool] = [:]
        public var sources: [Keyer: KeyerSources] = [:]
        /// The first state dump has finished (the switcher sends InCm).
        public var initialized = false

        public init() {}

        public func inputName(_ id: UInt16) -> String {
            inputs[id]?.longName ?? "Input \(id)"
        }

        /// Every keyer the switcher has reported, in panel order.
        public var keyers: [Keyer] {
            sources.keys.sorted { a, b in
                switch (a, b) {
                case let (.upstream(m1, k1), .upstream(m2, k2)): (m1, k1) < (m2, k2)
                case (.upstream, .downstream): true
                case (.downstream, .upstream): false
                case let (.downstream(d1), .downstream(d2)): d1 < d2
                }
            }
        }

        public mutating func apply(_ command: Command) {
            let p = [UInt8](command.payload)
            func u16(_ at: Int) -> UInt16 { UInt16(p[at]) << 8 | UInt16(p[at + 1]) }
            func text(_ range: Range<Int>) -> String {
                let slice = p[range].prefix { $0 != 0 }
                return String(decoding: slice, as: UTF8.self)
            }
            switch command.name {
            case "_pin" where !p.isEmpty:
                productName = text(0..<min(p.count, 44))
            case "_top" where !p.isEmpty:
                meCount = Int(p[0])
            case "InPr" where p.count >= 26:
                inputs[u16(0)] = Input(longName: text(2..<22), shortName: text(22..<26))
            case "KeOn" where p.count >= 3:
                onAir[.upstream(me: Int(p[0]), keyer: Int(p[1]))] = p[2] != 0
            case "KeBP" where p.count >= 10:
                sources[.upstream(me: Int(p[0]), keyer: Int(p[1]))] = KeyerSources(fill: u16(6), key: u16(8))
            case "DskB" where p.count >= 6:
                sources[.downstream(Int(p[0]))] = KeyerSources(fill: u16(2), key: u16(4))
            case "DskS" where p.count >= 2:
                onAir[.downstream(Int(p[0]))] = p[1] != 0
            case "InCm":
                initialized = true
            default:
                break
            }
        }
    }
}

/// When the livestream graphics should be on air, from what Screens' stream
/// output shows. On as soon as there's something to show. Off only once it
/// has been empty for a moment, so the slide's own fade out finishes over
/// the camera before the keyer is cut. Both cuts happen while the key
/// signal is clear, so neither shows on the stream.
public struct ATEMKeyFollower: Sendable, Equatable {
    public static let offDelay: TimeInterval = 1.5

    public private(set) var wanted = false
    private var clearSince: Date?

    public init() {}

    /// Returns the new on-air state when it changes.
    public mutating func update(showing: Bool, at now: Date) -> Bool? {
        if showing {
            clearSince = nil
            guard !wanted else { return nil }
            wanted = true
            return true
        }
        guard wanted else { return nil }
        let since = clearSince ?? now
        clearSince = since
        guard now.timeIntervalSince(since) >= Self.offDelay else { return nil }
        wanted = false
        clearSince = nil
        return false
    }
}

extension Data {
    fileprivate mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }
}
