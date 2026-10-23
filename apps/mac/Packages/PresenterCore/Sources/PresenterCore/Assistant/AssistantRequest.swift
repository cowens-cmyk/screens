import Foundation

/// The models the Assistant can run on. Opus is the default; Sonnet answers
/// faster for simple jobs.
public enum AssistantModel: String, CaseIterable, Sendable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"

    public var id: String { rawValue }

    public static let defaultsKey = "assistant.model"

    public var title: String {
        switch self {
        case .opus: "Claude Opus 5.5"
        case .sonnet: "Claude Sonnet 5.5"
        }
    }

    public var detail: String {
        switch self {
        case .opus: "Most careful. Best for multi-step jobs."
        case .sonnet: "Faster and cheaper. Fine for quick edits and questions."
        }
    }

    /// Opus 5.5 defaults to medium effort; the Assistant's jobs are
    /// multi-step tool work, so it runs at high. Sonnet's levels are
    /// recalibrated and medium is its recommended start for tool use.
    public var effort: String {
        switch self {
        case .opus: "high"
        case .sonnet: "medium"
        }
    }

    public static func stored(_ raw: String?) -> AssistantModel {
        raw.flatMap(AssistantModel.init(rawValue:)) ?? .opus
    }
}

/// One tool the model can call: the definition sent to the API.
public struct AssistantToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var schema: AssistantJSON
    /// Destructive tools stop for the user's Approve before they run.
    public var needsConfirmation: Bool
    /// Tools that add, and only sometimes replace: the app works out from
    /// the input and the library whether this call replaces something, and
    /// asks for Approve only then.
    public var confirmsWhenReplacing: Bool

    public init(
        name: String, description: String, schema: AssistantJSON, needsConfirmation: Bool = false,
        confirmsWhenReplacing: Bool = false
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.needsConfirmation = needsConfirmation
        self.confirmsWhenReplacing = confirmsWhenReplacing
    }

    /// Streamed requests set eager input streaming on every client tool, so
    /// large inputs arrive as they're written; the app validates each input
    /// against `schema` itself before running anything.
    public var definition: AssistantJSON {
        ["name": .string(name), "description": .string(description), "input_schema": schema,
         "eager_input_streaming": true]
    }
}

/// Builds Messages API requests. Pure: no network, no keys.
public enum AssistantRequest {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    /// Server-side refusal fallback ("default" routing) and progress notes
    /// between tool calls (thinking display "updates").
    public static let betas = ["server-side-fallback-2026-07-01", "thinking-display-updates-2026-08-18"]
    public static let maxTokens = 64000

    /// The request body. The system prompt is two blocks: the short standing
    /// instructions, then the Screens guide carrying the cache breakpoint,
    /// so tools + system are cached together and survive every turn. The
    /// top-level cache_control caches the growing conversation as well.
    /// Nothing volatile (dates, the current plan) belongs in either block;
    /// that context goes into the user turn.
    public static func body(
        model: AssistantModel, instructions: String, guide: String,
        tools: [AssistantToolSpec], messages: [AssistantJSON], stream: Bool = true
    ) -> AssistantJSON {
        var system: [AssistantJSON] = [["type": "text", "text": .string(instructions)]]
        if !guide.isEmpty {
            system.append(["type": "text", "text": .string(guide), "cache_control": ["type": "ephemeral"]])
        } else {
            system[0] = system[0].setting("cache_control", ["type": "ephemeral"])
        }
        return [
            "model": .string(model.rawValue),
            "max_tokens": .number(Double(maxTokens)),
            "stream": .bool(stream),
            "thinking": ["type": "adaptive", "display": "updates"],
            "output_config": ["effort": .string(model.effort)],
            "fallbacks": "default",
            "cache_control": ["type": "ephemeral"],
            "system": .array(system),
            "tools": .array(tools.map(\.definition)),
            "messages": .array(messages),
        ]
    }

    /// Header names and values except the key, which the caller adds.
    public static var headers: [String: String] {
        [
            "content-type": "application/json",
            "anthropic-version": apiVersion,
            "anthropic-beta": betas.joined(separator: ","),
        ]
    }
}

/// The conversation as sent to the API. Append-only: earlier turns are never
/// rewritten, so thinking blocks stay valid and the cache keeps hitting.
public struct AssistantHistory: Sendable, Equatable {
    public private(set) var messages: [AssistantJSON] = []

    public init(messages: [AssistantJSON] = []) {
        self.messages = messages
    }

    public var isEmpty: Bool { messages.isEmpty }

    var lastRole: String? { messages.last?["role"]?.string }

    /// A user turn. When the last turn is also the user's (a reply was
    /// stopped before it started), the new blocks join it: nothing has
    /// answered that turn yet, so no earlier block is affected.
    public mutating func appendUser(_ content: [AssistantJSON]) {
        guard !content.isEmpty else { return }
        if lastRole == "user", let previous = messages.last?["content"]?.array {
            messages[messages.count - 1] = ["role": "user", "content": .array(previous + content)]
        } else {
            messages.append(["role": "user", "content": .array(content)])
        }
    }

    public mutating func appendUserText(_ text: String) {
        appendUser([["type": "text", "text": .string(text)]])
    }

    /// The assistant's reply, as received (see `echo`).
    public mutating func appendAssistant(_ content: [AssistantJSON]) {
        messages.append(["role": "assistant", "content": .array(AssistantHistory.echo(content))])
    }

    /// The tool_use blocks in the last assistant turn that have no result yet.
    public var unansweredToolUses: [(id: String, name: String)] {
        guard lastRole == "assistant", let content = messages.last?["content"]?.array else { return [] }
        return content.compactMap { block in
            guard block["type"]?.string == "tool_use", let id = block["id"]?.string else { return nil }
            return (id, block["name"]?.string ?? "")
        }
    }

    /// Answers every open tool call with the same message, so a stopped turn
    /// still leaves a valid conversation.
    public mutating func closeOpenToolUses(_ message: String) {
        let open = unansweredToolUses
        guard !open.isEmpty else { return }
        appendUser(open.map { AssistantToolResult.error(id: $0.id, message).block })
    }

    /// What goes back to the API from a reply. After a mid-output fallback,
    /// the declined model's thinking and tool calls before the last fallback
    /// marker are dropped (its text stays); everything else is echoed as is.
    public static func echo(_ content: [AssistantJSON]) -> [AssistantJSON] {
        guard let boundary = content.lastIndex(where: { $0["type"]?.string == "fallback" }) else {
            return content
        }
        let dropped: Set<String> = ["thinking", "redacted_thinking", "tool_use", "server_tool_use"]
        return content.enumerated().compactMap { index, block in
            if index < boundary, let type = block["type"]?.string, dropped.contains(type) { return nil }
            return block
        }
    }
}

/// A tool_result block.
public struct AssistantToolResult: Sendable, Equatable {
    public var id: String
    public var content: String
    public var isError: Bool

    public init(id: String, content: String, isError: Bool = false) {
        self.id = id
        self.content = content
        self.isError = isError
    }

    public static func error(id: String, _ message: String) -> AssistantToolResult {
        AssistantToolResult(id: id, content: message, isError: true)
    }

    public var block: AssistantJSON {
        var fields: [String: AssistantJSON] = [
            "type": "tool_result", "tool_use_id": .string(id), "content": .string(content),
        ]
        if isError { fields["is_error"] = true }
        return .object(fields)
    }
}
