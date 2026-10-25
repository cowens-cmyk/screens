import PresenterCore
import SwiftUI

/// Shown across the top of the slides while Screens is listening to a
/// microphone, so nobody has to hover over a toolbar icon to know: a red
/// pulsing mic, what it's listening for, the input level, the passage it
/// last heard (click to show it, with the other readings beside it), and
/// Stop.
struct LiveListeningBar: View {
    @Bindable private var assist = LiveAssist.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showing: String?

    var body: some View {
        if assist.listening || assist.starting {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(HopeStyle.live, in: Circle())
                    .symbolEffect(.pulse, options: .repeating, isActive: assist.listening && !reduceMotion)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(assist.starting ? "Starting…" : assist.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                LevelMeter(level: assist.level)
                    .frame(width: 54, height: 6)
                    .help("Microphone level")

                if assist.mode == .sermon, let heard = assist.detected.first {
                    Divider().frame(height: 22)
                    heardButton(heard.reference, primary: true)
                    ForEach(heard.alternatives.prefix(2), id: \.display) { alternative in
                        heardButton(alternative, primary: false)
                    }
                }

                Spacer(minLength: 8)

                if assist.mode == .sermon {
                    Toggle("Show automatically", isOn: $assist.showsAutomatically)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("Put each passage on screen as soon as it's heard")
                }

                Button("Stop", systemImage: "stop.fill") { assist.stop() }
                    .buttonStyle(.glassProminent)
                    .tint(HopeStyle.live)
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(HopeStyle.live.opacity(0.12))
            .overlay(alignment: .bottom) { Rectangle().fill(HopeStyle.live.opacity(0.5)).frame(height: 1) }
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }

    private var title: String {
        switch assist.mode {
        case .sermon: "Listening for scripture"
        case .worship: "Listening to the singing"
        }
    }

    /// The passage heard, as a button that puts it on screen.
    private func heardButton(_ reference: BibleReference, primary: Bool) -> some View {
        Button {
            showing = reference.display
            Task {
                try? await assist.show(reference)
                showing = nil
            }
        } label: {
            HStack(spacing: 4) {
                if primary { Image(systemName: "book.fill").font(.system(size: 10)) }
                Text(reference.display)
                    .font(.callout.weight(primary ? .semibold : .regular))
                    .lineLimit(1)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(showing != nil)
        .help(primary ? "Heard most recently. Click to show it." : "Another way it could have been heard. Click to show it.")
    }
}

/// A thin input level bar.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.85 ? Color.red : HopeStyle.teal)
                    .frame(width: proxy.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
