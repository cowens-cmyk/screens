import PresenterCore
import SwiftUI

/// Under the Audience preview in the Screens panel: how far through a
/// playing video is, with a bar to click or drag to another moment, and how
/// long the slide on screen has before it moves on by itself (a slideshow
/// such as the pre-service slides). Nothing shows when neither is going.
struct ScreensProgressBars: View {
    let controls: ServiceControls

    var body: some View {
        let video = controls.media.showsTransport ? controls.media.target : nil
        // A slide that waits for its video shows the video's bar alone:
        // the two would count the same time.
        let waitsOnVideo = controls.autoAdvancePending.map { $0.firesAt == nil && $0.mediaID == video?.id } ?? false
        let advancing = controls.autoAdvancePending != nil && !(video != nil && waitsOnVideo)
        if video != nil || advancing {
            VStack(alignment: .leading, spacing: 10) {
                if let video { videoBar(video) }
                if advancing { advanceBar }
            }
            .screenCard(HopeStyle.blue)
        }
    }

    // MARK: The video

    private func videoBar(_ row: MediaTransportController.Row) -> some View {
        let media = controls.media
        let finished = MediaTransportController.isFinished(row.state, at: Date())
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if finished { media.resetToStart(row.id) } else { media.togglePlayPause(row.id) }
                } label: {
                    Image(systemName: finished ? "arrow.counterclockwise" : (row.state.isPlaying ? "pause.fill" : "play.fill"))
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(finished ? "Back to the start" : (row.state.isPlaying ? "Pause the video" : "Play the video"))
                Text(row.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    Text("-" + ScrubBar.timecode(row.state.wallClockRemaining(at: context.date)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("Time left")
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !row.state.isPlaying)) { context in
                ScrubBar(
                    elapsed: row.state.position(at: context.date),
                    duration: row.state.duration,
                    isPlaying: row.state.isPlaying,
                    showsTimes: true,
                    trackHeight: 6
                ) { seconds, final in
                    media.seek(row.id, to: seconds, final: final)
                }
                .frame(height: 18)
            }
            .help("Click or drag to move to another point in the video")
        }
    }

    // MARK: The slide's own advance

    private var advanceBar: some View {
        let paused = controls.autoAdvancePaused
        return TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: paused)) { context in
            let remaining = controls.autoAdvanceRemaining(at: context.date)
            let progress = controls.autoAdvanceProgress(at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        controls.setAutoAdvancePaused(!paused)
                    } label: {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(paused ? "Let the slides move on again" : "Hold on this slide")
                    Text(paused ? "Held on this slide" : "Next slide in")
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 4)
                    Text(remaining.map(Self.timecode) ?? "–:––")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(paused ? Color.secondary : HopeStyle.blue)
                            .frame(width: max(0, geo.size.width * (progress ?? 0)))
                    }
                }
                .frame(height: 6)
                .accessibilityLabel("Time until the next slide")
                .accessibilityValue(remaining.map(Self.timecode) ?? "")
            }
        }
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let whole = max(Int(seconds.rounded(.up)), 0)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
