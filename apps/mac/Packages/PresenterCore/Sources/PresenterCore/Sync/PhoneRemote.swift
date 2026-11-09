import Foundation

/// The phone remote in the CMS (Sunday › Screens › Remote) works from
/// anywhere: it sends its taps to the hub, and the hub hands them to the
/// Macs over the sync socket. Only the Mac that runs the service (Run on this
/// Mac) follows them; it answers each one, and keeps the hub told what's
/// live so the phone can show it. docs/cloud-sync.md has the messages.
public enum PhoneRemote {
    /// One tap from the phone, as the hub sends it:
    /// `{"t":"remote","id":…,"cmd":…,"args":{…}}`.
    public struct Request: Equatable, Sendable {
        public var id: String
        /// What to do, or why it can't be done (`ok: false` with that text).
        public var command: Result<Command, Failure>

        public init(id: String, command: Result<Command, Failure>) {
            self.id = id
            self.command = command
        }
    }

    public struct Failure: Error, Equatable, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
    }

    public enum TimerAction: String, Equatable, Sendable {
        case start, stop, reset
    }

    public enum Command: Equatable, Sendable {
        case advance(steps: Int)
        /// A slide put live. With an item, in its plan's place (the item's
        /// arrangement, lights and screens); `index` is where in the item's
        /// arranged slides, for a slide that comes more than once.
        case slide(presentationId: String, slideId: String, serviceId: String?, itemId: String?, index: Int?)
        /// A plan item from its start.
        case item(serviceId: String, itemId: String)
        /// A ShowFunction's raw value (slides, media, overlays, audio,
        /// alerts, signage), or "all".
        case clear(function: String)
        case timer(id: String, action: TimerAction)
        case combo(id: String)
        case alert(message: String)
        case alertDismiss
        case service(id: String)
    }

    /// The clear functions the phone may name, and what each is here. The
    /// Local API's own names come first; the rest are the words people use.
    public static let clearFunctions: [String: String] = [
        "slides": "slides", "slide": "slides",
        "media": "media",
        "overlays": "overlays", "props": "overlays",
        "audio": "audio",
        "alerts": "alerts", "messages": "alerts",
        "signage": "signage",
        "all": "all",
    ]

    /// The hub's message read; nil when it isn't a remote message with an id.
    public static func request(_ object: [String: Any]) -> Request? {
        guard object["t"] as? String == "remote", let id = object["id"] as? String, !id.isEmpty, id.count <= 100 else { return nil }
        let args = object["args"] as? [String: Any] ?? [:]
        return Request(id: id, command: command(object["cmd"] as? String ?? "", args: args))
    }

    static func command(_ name: String, args: [String: Any]) -> Result<Command, Failure> {
        func text(_ key: String) -> String? {
            guard let value = args[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.count > 200 ? nil : trimmed
        }
        func number(_ key: String) -> Int? {
            guard let value = args[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.intValue
        }
        switch name {
        case "advance":
            guard let steps = number("steps"), steps != 0, abs(steps) <= 50 else { return .failure(Failure("Say how many slides to move.")) }
            return .success(.advance(steps: steps))
        case "slide":
            guard let presentation = text("presentationId"), let slide = text("slideId") else {
                return .failure(Failure("Say which slide."))
            }
            let item = text("itemId")
            let index = number("index").flatMap { $0 >= 0 ? $0 : nil }
            return .success(.slide(presentationId: presentation, slideId: slide, serviceId: text("serviceId"), itemId: item, index: index))
        case "item":
            guard let service = text("serviceId"), let item = text("itemId") else { return .failure(Failure("Say which plan item.")) }
            return .success(.item(serviceId: service, itemId: item))
        case "clear":
            guard let raw = text("function"), let function = clearFunctions[raw.lowercased()] else {
                return .failure(Failure("Say what to clear."))
            }
            return .success(.clear(function: function))
        case "timer":
            guard let id = text("id") else { return .failure(Failure("Say which timer.")) }
            guard let action = text("action").flatMap(TimerAction.init(rawValue:)) else {
                return .failure(Failure("Timers start, stop or reset."))
            }
            return .success(.timer(id: id, action: action))
        case "combo":
            guard let id = text("id") else { return .failure(Failure("Say which action.")) }
            return .success(.combo(id: id))
        case "alert":
            guard let raw = args["message"] as? String else { return .failure(Failure("Write a message.")) }
            let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return .failure(Failure("Write a message.")) }
            guard message.count <= 300 else { return .failure(Failure("Write a message of up to 300 characters.")) }
            return .success(.alert(message: message))
        case "alertDismiss":
            return .success(.alertDismiss)
        case "service":
            guard let id = text("id") else { return .failure(Failure("Say which plan.")) }
            return .success(.service(id: id))
        default:
            return .failure(Failure("Unknown command."))
        }
    }

    /// What's live, by id, for the phone to mark it: nulls when nothing is.
    public struct LiveIDs: Encodable, Equatable, Sendable {
        public var serviceId: String?
        public var itemId: String?
        public var presentationId: String?
        public var slideId: String?
        public var slideIndex: Int?

        public init(serviceId: String? = nil, itemId: String? = nil, presentationId: String? = nil, slideId: String? = nil, slideIndex: Int? = nil) {
            self.serviceId = serviceId
            self.itemId = itemId
            self.presentationId = presentationId
            self.slideId = slideId
            self.slideIndex = slideIndex
        }

        enum CodingKeys: String, CodingKey { case serviceId, itemId, presentationId, slideId, slideIndex }

        // Written out, nulls included, so the phone never has to tell a
        // missing key from nothing live.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(serviceId, forKey: .serviceId)
            try c.encode(itemId, forKey: .itemId)
            try c.encode(presentationId, forKey: .presentationId)
            try c.encode(slideId, forKey: .slideId)
            try c.encode(slideIndex, forKey: .slideIndex)
        }
    }

    public struct Combo: Encodable, Equatable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The most action combos the phone is sent.
    public static let comboLimit = 40
    /// The hub keeps a live state up to this size.
    public static let liveLimit = 64 * 1024
    /// Sent at least this often while connected, so the phone can tell a
    /// quiet show from a Mac that's gone.
    public static let heartbeatSeconds: TimeInterval = 5
}
