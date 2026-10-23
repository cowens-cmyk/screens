import Foundation
import Observation
import PresenterCore

/// One conversation with the Assistant: the transcript the panel shows, the
/// history sent to the API, and the tool loop that runs between them. It
/// lives as long as the app, so closing the window keeps the conversation.
@MainActor
@Observable
final class AssistantSession {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            case user(attachments: [String])
            case reply
            /// A note the model writes between tool calls.
            case progress
            case activity(failed: Bool)
            case confirmation(title: String, approved: Bool?)
            case notice
            case error
        }

        let id = UUID()
        var kind: Kind
        var text: String
    }

    private(set) var lines: [Line] = []
    private(set) var isRunning = false
    /// Pictures waiting to go with the next message.
    var pendingAttachments: [AssistantAttachment] = []
    /// Read from the Keychain when the window opens, not at launch, so a
    /// Keychain prompt never comes up before anyone asks for the Assistant.
    private(set) var hasKey = true

    @ObservationIgnored let toolbox: AssistantToolbox
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var history = AssistantHistory()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var decision: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var confirmationLine: UUID?
    @ObservationIgnored private var attachmentCount = 0
    /// Most model calls in one turn before the Assistant stops and says so.
    private static let maxRounds = 40

    init(model: AppModel, router: ActionRouter?) {
        self.model = model
        toolbox = AssistantToolbox(model: model, router: router)
    }

    var awaitingDecision: Bool { confirmationLine != nil }

    func refreshKey() {
        hasKey = AssistantPreferences.hasKey
    }

    // MARK: Attachments

    func attach(_ urls: [URL]) async -> [AssistantAttachment] {
        let made = await AssistantAttachments.prepare(urls, startingAt: attachmentCount + 1)
        attachmentCount += made.count
        pendingAttachments += made
        return made
    }

    func removeAttachment(_ id: String) {
        pendingAttachments.removeAll { $0.id == id }
    }

    // MARK: Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !trimmed.isEmpty || !pendingAttachments.isEmpty else { return }
        refreshKey()
        guard hasKey else {
            lines.append(Line(kind: .error, text: "Add your Anthropic API key in \(AssistantPreferences.keyLocation) first."))
            return
        }
        let attachments = pendingAttachments
        pendingAttachments = []
        for attachment in attachments { toolbox.attachments[attachment.id] = attachment }
        lines.append(Line(kind: .user(attachments: attachments.map(\.label)), text: trimmed))

        var content: [AssistantJSON] = [["type": "text", "text": .string(contextLine())]]
        for attachment in attachments {
            content.append(["type": "text", "text": .string("Attachment \(attachment.id): \(attachment.label)")])
            content.append(attachment.block)
        }
        if !trimmed.isEmpty { content.append(["type": "text", "text": .string(trimmed)]) }
        history.appendUser(content)

        isRunning = true
        task = Task { [weak self] in
            await self?.runLoop()
            self?.finish()
        }
    }

    func run(_ job: AssistantPrompt.Job) {
        send(job.instruction)
    }

    func stop() {
        guard isRunning else { return }
        task?.cancel()
        resolveDecision(false)
        lines.append(Line(kind: .notice, text: "Stopped."))
    }

    /// The user's answer to the open Approve/Cancel.
    func decide(_ approve: Bool) {
        resolveDecision(approve)
    }

    func newConversation() {
        guard !isRunning else { return }
        history = AssistantHistory()
        lines = []
        toolbox.attachments = [:]
        toolbox.lyricChecks = [:]
        toolbox.builtMessages = [:]
    }

    // MARK: The loop

    /// Today's date and the plan in the main window, written into each user
    /// turn rather than the system prompt so the cached prefix never changes.
    private func contextLine() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy, h:mm a"
        var line = "[Today is \(formatter.string(from: .now)) (\(DayStamp.of(.now)))."
        if let id = model.currentServiceID, let plan = try? model.service(id) {
            line += " Plan open in the main window: \"\(plan.name)\" (\(plan.serviceDate), id \(id))."
        }
        return line + "]"
    }

    private func runLoop() async {
        for _ in 0..<Self.maxRounds {
            if Task.isCancelled { return }
            let body = AssistantRequest.body(
                model: AssistantPreferences.model, instructions: AssistantPrompt.instructions,
                guide: AssistantPrompt.guide, tools: AssistantToolCatalog.all, messages: history.messages)
            var replyLine: UUID?
            var progressLines: [Int: UUID] = [:]
            let stream: AssistantStream
            do {
                stream = try await AssistantClient.stream(body) { event in
                    switch event {
                    case .text(_, let delta):
                        replyLine = append(delta, to: replyLine, kind: .reply)
                    case .progress(let index, let delta):
                        progressLines[index] = append(delta, to: progressLines[index], kind: .progress)
                    case .toolStarted, .blockFinished:
                        // Text after a tool call starts a new paragraph line.
                        replyLine = nil
                    case .fallback:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled { lines.append(Line(kind: .error, text: error.localizedDescription)) }
                return
            }
            var reply = stream
            note(reply)
            let content = reply.content()

            if reply.stopReason == "refusal" {
                // Keep the conversation valid without the declined output.
                history.appendAssistant([["type": "text", "text": "I can't help with that request."]])
                lines.append(Line(kind: .error, text: "Claude declined this request."))
                return
            }
            history.appendAssistant(content.isEmpty ? [["type": "text", "text": "(no reply)"]] : content)

            let calls = reply.toolUses()
            if calls.isEmpty {
                if reply.stopReason == "pause_turn" { continue }
                if reply.stopReason == "max_tokens" {
                    lines.append(Line(kind: .notice, text: "The reply hit its length limit."))
                }
                return
            }
            if reply.stopReason == "max_tokens" {
                history.appendUser(calls.map {
                    AssistantToolResult.error(id: $0.id, "Your output was cut off before this call finished. Try again with less in one call.").block
                })
                continue
            }
            var results: [AssistantJSON] = []
            for call in calls {
                if Task.isCancelled { break }
                results.append(await answer(call, invalid: reply.invalidInputs[call.id]).block)
            }
            if Task.isCancelled {
                // Every call still needs an answer for the next turn.
                let answered = Set(results.compactMap { $0["tool_use_id"]?.string })
                for call in calls where !answered.contains(call.id) {
                    results.append(AssistantToolResult.error(id: call.id, "Stopped by the user.").block)
                }
                history.appendUser(results)
                return
            }
            history.appendUser(results)
        }
        lines.append(Line(kind: .notice, text: "Stopped after \(Self.maxRounds) steps. Say \"continue\" to keep going."))
    }

    private func answer(_ call: (id: String, name: String, input: AssistantJSON), invalid: String?) async -> AssistantToolResult {
        if let invalid {
            return .error(id: call.id, (["INVALID_JSON": .string(invalid)] as AssistantJSON).jsonString)
        }
        guard let spec = AssistantToolCatalog.spec(call.name) else {
            return .error(id: call.id, "There is no tool named \(call.name).")
        }
        if let problem = AssistantToolInput.validate(call.input, against: spec.schema) {
            return .error(id: call.id, "Invalid input: \(problem).")
        }
        if spec.needsConfirmation {
            let ask: (title: String, detail: String)
            do {
                ask = try await toolbox.confirmation(for: call.name, input: call.input)
            } catch let failure as AssistantToolbox.Failure {
                return .error(id: call.id, failure.message)
            } catch {
                return .error(id: call.id, error.localizedDescription)
            }
            guard await confirm(ask.title, detail: ask.detail) else {
                lines.append(Line(kind: .activity(failed: true), text: "Cancelled: \(ask.title.trimmingCharacters(in: CharacterSet(charactersIn: "?")))"))
                return AssistantToolResult(id: call.id, content: "The user cancelled. Nothing was changed.")
            }
        }
        let outcome = await toolbox.run(call.name, input: call.input)
        if outcome.isError {
            lines.append(Line(kind: .activity(failed: true), text: outcome.content))
        } else if let activity = outcome.activity {
            lines.append(Line(kind: .activity(failed: false), text: activity))
        }
        return AssistantToolResult(id: call.id, content: outcome.content, isError: outcome.isError)
    }

    private func confirm(_ title: String, detail: String) async -> Bool {
        let line = Line(kind: .confirmation(title: title, approved: nil), text: detail)
        lines.append(line)
        confirmationLine = line.id
        return await withCheckedContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(returning: false)
                confirmationLine = nil
            } else {
                decision = continuation
            }
        }
    }

    private func resolveDecision(_ approve: Bool) {
        if let id = confirmationLine, let index = lines.firstIndex(where: { $0.id == id }),
           case .confirmation(let title, _) = lines[index].kind {
            lines[index].kind = .confirmation(title: title, approved: approve)
        }
        confirmationLine = nil
        let waiting = decision
        decision = nil
        waiting?.resume(returning: approve)
    }

    private func finish() {
        // A stop mid-reply can leave tool calls unanswered.
        history.closeOpenToolUses("Stopped by the user.")
        if confirmationLine != nil { resolveDecision(false) }
        isRunning = false
        task = nil
    }

    private func append(_ delta: String, to id: UUID?, kind: Line.Kind) -> UUID {
        if let id, let index = lines.firstIndex(where: { $0.id == id }) {
            lines[index].text += delta
            return id
        }
        let line = Line(kind: kind, text: delta.drop(while: \.isNewline).description)
        lines.append(line)
        return line.id
    }

    /// Token use per call, for checking that the prompt cache is hitting.
    private func note(_ stream: AssistantStream) {
        let usage = stream.usage
        func value(_ key: String) -> Int { Int(usage[key] ?? 0) }
        DiagnosticsStore.shared.note(
            "assistant.turn",
            detail: "\(stream.model ?? "") stop=\(stream.stopReason ?? "") in=\(value("input_tokens")) "
                + "cacheRead=\(value("cache_read_input_tokens")) cacheWrite=\(value("cache_creation_input_tokens")) "
                + "out=\(value("output_tokens"))")
    }
}
