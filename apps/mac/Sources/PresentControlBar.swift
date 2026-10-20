import PresenterCore
import SwiftUI

/// The floating glass bar over the slides in Present: what's live and
/// what's next, with Back, Next and Clear, like Keynote's play controls.
/// Next and Back act exactly like the arrow keys.
struct PresentControlBar: View {
    let controls: ServiceControls
    var showsStatus = true
    @State private var nextTaps = 0
    @State private var backTaps = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var live: (title: String, detail: String)? {
        guard let slide = controls.state.liveSlide else { return nil }
        let name = slide.slide.name.isEmpty ? "Slide" : slide.slide.name
        return (name, slide.presentation?.name ?? "")
    }

    var body: some View {
        // The whole bar where it fits; just the buttons in a narrow window
        // (the window measures the room and says which).
        bar(showsStatus: showsStatus)
            .padding(.horizontal, 16)
        .animation(HopeMotion.ui(reduced: reduceMotion), value: live?.title)
    }

    private func bar(showsStatus: Bool) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if showsStatus { status }
                Button {
                    backTaps += 1
                    KeyInController.current?.perform(.previousSlide)
                } label: {
                    Image(systemName: "chevron.left").font(.title3.weight(.semibold)).frame(width: 30, height: 30)
                        .symbolEffect(.bounce.down, options: .speed(1.4), value: backTaps)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(nil)
                .help("Back (←)")

                Button {
                    nextTaps += 1
                    KeyInController.current?.perform(.nextSlide)
                } label: {
                    Image(systemName: "chevron.right").font(.title3.weight(.semibold)).frame(width: 44, height: 30)
                        .symbolEffect(.bounce.down, options: .speed(1.4), value: nextTaps)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(HopeStyle.blue)
                .help("Next (→ or Space)")

                Button { controls.clearAll() } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(nil)
                .help("Clear everything")
            }
            .fixedSize()
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(live == nil ? Color.secondary.opacity(0.5) : HopeStyle.live)
                .frame(width: 8, height: 8)
                .shadow(color: live == nil ? .clear : HopeStyle.live.opacity(0.8), radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(live?.title ?? "Nothing live")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(nextLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }

    private var nextLine: String {
        if let next = controls.nextSlideText?.split(separator: "\n").first, !next.isEmpty {
            return "Next: " + next
        }
        return live?.detail ?? "Pick a slide to go live"
    }
}
