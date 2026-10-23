import AppKit
import LocalAPI
import Observation
import SwiftUI

/// Notes to the booth from the phone remote's stage view ("Mic issue",
/// "Ready", …). The newest shows as a banner over the main window until
/// someone dismisses it; every note is kept for the session (newest first)
/// and written to Diagnostics, so "did the pastor ask for something?" has an
/// answer after the service.
@MainActor
@Observable
final class BoothMessages {
    static let shared = BoothMessages()

    private(set) var log: [APIBoothMessage] = []
    /// The note on the banner now; nil once dismissed.
    private(set) var showing: APIBoothMessage?

    private static let kept = 50

    @discardableResult
    func receive(_ command: APIBoothMessageCommand, at date: Date = Date()) -> APIBoothMessage {
        let message = APIBoothMessage(id: UUID().uuidString, text: command.text, from: command.from, sentAt: date)
        log.insert(message, at: 0)
        if log.count > Self.kept { log.removeLast(log.count - Self.kept) }
        showing = message
        DiagnosticsStore.shared.note("booth.message", detail: "\(command.from ?? "Remote"): \(command.text)")
        // The booth may be looking at another app; the Dock icon bounces once.
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        return message
    }

    func dismiss() { showing = nil }
}

/// The note across the top of the main window: big enough to read from the
/// booth chair, and it stays until someone clicks it away.
struct BoothMessageBanner: View {
    private let messages = BoothMessages.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            if let message = messages.showing {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(HopeStyle.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("From \(message.from ?? "the remote") · \(message.sentAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(message.text)
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    // No key of its own: Escape and the arrows belong to the show.
                    Button("Dismiss") { messages.dismiss() }
                        .controlSize(.large)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: 640)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HopeStyle.amber, lineWidth: 2))
                .shadow(radius: 12, y: 4)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(message.id)
            }
        }
        .animation(HopeMotion.ui(reduced: reduceMotion), value: messages.showing?.id)
    }
}
