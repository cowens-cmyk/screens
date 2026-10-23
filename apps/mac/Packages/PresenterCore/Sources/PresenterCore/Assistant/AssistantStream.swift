import Foundation

/// Assembles a streamed Messages API reply (server-sent events) into the
/// finished content blocks, and reports what changed as it goes so the
/// panel can show text and progress notes while the model works.
public struct AssistantStream: Sendable {
    public enum Event: Equatable, Sendable {
        case text(index: Int, delta: String)
        /// A progress note between tool calls (thinking display "updates").
        case progress(index: Int, delta: String)
        case toolStarted(index: Int, name: String)
        case blockFinished(index: Int)
        case fallback(from: String, to: String)
    }

    public struct StreamError: Error, Equatable, Sendable {
        public var type: String
        public var message: String
    }

    private var blocks: [Int: AssistantJSON] = [:]
    private var text: [Int: String] = [:]
    private var thinking: [Int: String] = [:]
    private var signature: [Int: String] = [:]
    private var partialInput: [Int: String] = [:]
    private var closed: Set<Int> = []
    /// Tool calls whose input did not parse as a JSON object.
    public private(set) var invalidInputs: [String: String] = [:]

    public private(set) var model: String?
    public private(set) var stopReason: String?
    public private(set) var stopDetails: AssistantJSON?
    public private(set) var usage: [String: Double] = [:]
    public private(set) var finished = false

    public init() {}

    /// Feeds one line of the response body. Only `data:` lines carry
    /// anything; `event:` names repeat the payload's own type.
    public mutating func feed(line: String) throws -> [Event] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, let event = try? AssistantJSON.parse(payload) else { return [] }
        return try feed(event)
    }

    public mutating func feed(_ event: AssistantJSON) throws -> [Event] {
        switch event["type"]?.string {
        case "message_start":
            model = event["message"]?["model"]?.string
            mergeUsage(event["message"]?["usage"])
            return []
        case "content_block_start":
            guard let index = event["index"]?.int, let block = event["content_block"] else { return [] }
            blocks[index] = block
            switch block["type"]?.string {
            case "text":
                text[index] = block["text"]?.string ?? ""
            case "thinking":
                thinking[index] = block["thinking"]?.string ?? ""
                signature[index] = block["signature"]?.string ?? ""
            case "tool_use":
                partialInput[index] = ""
                return [.toolStarted(index: index, name: block["name"]?.string ?? "")]
            case "fallback":
                return [.fallback(from: block["from"]?["model"]?.string ?? "", to: block["to"]?["model"]?.string ?? "")]
            default:
                break
            }
            return []
        case "content_block_delta":
            guard let index = event["index"]?.int, let delta = event["delta"] else { return [] }
            switch delta["type"]?.string {
            case "text_delta":
                let piece = delta["text"]?.string ?? ""
                text[index, default: ""] += piece
                return piece.isEmpty ? [] : [.text(index: index, delta: piece)]
            case "thinking_delta":
                let piece = delta["thinking"]?.string ?? ""
                thinking[index, default: ""] += piece
                return piece.isEmpty ? [] : [.progress(index: index, delta: piece)]
            case "signature_delta":
                signature[index, default: ""] += delta["signature"]?.string ?? ""
            case "input_json_delta":
                partialInput[index, default: ""] += delta["partial_json"]?.string ?? ""
            default:
                break
            }
            return []
        case "content_block_stop":
            guard let index = event["index"]?.int else { return [] }
            finish(index)
            return [.blockFinished(index: index)]
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.string { stopReason = reason }
            if let details = event["delta"]?["stop_details"], !details.isNull { stopDetails = details }
            mergeUsage(event["usage"])
            return []
        case "message_stop":
            finished = true
            return []
        case "error":
            throw StreamError(
                type: event["error"]?["type"]?.string ?? "error",
                message: event["error"]?["message"]?.string ?? "The stream ended with an error.")
        default:
            return []
        }
    }

    private mutating func finish(_ index: Int) {
        guard var block = blocks[index], !closed.contains(index) else { return }
        closed.insert(index)
        switch block["type"]?.string {
        case "text":
            block = block.setting("text", .string(text[index] ?? ""))
        case "thinking":
            block = block.setting("thinking", .string(thinking[index] ?? ""))
                .setting("signature", .string(signature[index] ?? ""))
        case "tool_use":
            let raw = partialInput[index] ?? ""
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                block = block.setting("input", [:])
            } else if let parsed = try? AssistantJSON.parse(raw), parsed.object != nil {
                block = block.setting("input", parsed)
            } else {
                // Echoed with an empty input; the call is answered with an
                // INVALID_JSON error instead of being run.
                block = block.setting("input", [:])
                if let id = block["id"]?.string { invalidInputs[id] = raw }
            }
        default:
            break
        }
        blocks[index] = block
    }

    private mutating func mergeUsage(_ value: AssistantJSON?) {
        guard let fields = value?.object else { return }
        for (key, field) in fields {
            if let number = field.number { usage[key] = number }
        }
    }

    /// The reply's content blocks in order. Blocks still open (a cancelled
    /// stream) are finished as they stand.
    public mutating func content() -> [AssistantJSON] {
        for index in blocks.keys.sorted() { finish(index) }
        return blocks.keys.sorted().compactMap { blocks[$0] }
    }

    /// The tool calls in the finished reply.
    public mutating func toolUses() -> [(id: String, name: String, input: AssistantJSON)] {
        content().compactMap { block in
            guard block["type"]?.string == "tool_use", let id = block["id"]?.string else { return nil }
            return (id, block["name"]?.string ?? "", block["input"] ?? [:])
        }
    }

    /// The reply's visible text, joined.
    public mutating func replyText() -> String {
        content().filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
    }
}
