import PresenterCore
import SwiftUI

/// Shown across the top of the slides while Screens is listening to a
/// microphone, so nobody has to hover over a toolbar icon to know: a red
/// pulsing mic, which input it's hearing (click to change it), the level,
/// the words as they're heard, the passage it last heard (click to show it,
/// with the other readings beside it), and Stop. When the input has carried
/// no sound for a few seconds it says so, since a wrong input otherwise looks
/// exactly like a quiet room.
struct LiveListeningBar: View {
    @Bindable private var assist = LiveAssist.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showing: String?
    @State private var devices: [(uid: String, name: String, channels: Int)] = []

    var body: some View {
        if assist.listening || assist.starting {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(HopeStyle.live, in: Circle())
                        .symbolEffect(.pulse, options: .repeating, isActive: assist.listening && !reduceMotion)

                    Text(title).font(.callout.weight(.semibold))
                    inputMenu

                    LevelMeter(level: assist.level)
                        .frame(width: 110, height: 8)
                        .help("Microphone level")

                    if assist.mode == .sermon, let heard = assist.detected.first {
                        Divider().frame(height: 22)
                        heardButton(heard.reference, primary: true)
                        ForEach(Array(heard.alternatives.prefix(2).enumerated()), id: \.offset) { _, alternative in
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
                // Once a second is enough to notice silence.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    heardLine(now: context.date)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(HopeStyle.live.opacity(0.12))
            .overlay(alignment: .bottom) { Rectangle().fill(HopeStyle.live.opacity(0.5)).frame(height: 1) }
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            .onAppear { devices = LiveTranscriber.inputDevices() }
        }
    }

    private var title: String {
        switch assist.mode {
        case .sermon: "Listening for scripture"
        case .worship: "Listening to the singing"
        }
    }

    /// The input being heard; choosing another restarts listening on it.
    private var inputMenu: some View {
        Menu {
            Button {
                assist.deviceUID = ""
            } label: {
                let title = LiveAssistInputPicker.macInputTitle(devices)
                if assist.deviceUID.isEmpty { Label(title, systemImage: "checkmark") } else { Text(title) }
            }
            Divider()
            ForEach(devices, id: \.uid) { device in
                Button {
                    assist.deviceUID = device.uid
                } label: {
                    if device.uid == assist.deviceUID { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                }
            }
        } label: {
            Label(assist.inputName.isEmpty ? "Choose input" : assist.inputName, systemImage: "waveform")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("The input Screens is listening to")
    }

    /// What it's hearing, word by word; or why nothing is happening.
    @ViewBuilder
    private func heardLine(now: Date) -> some View {
        if assist.starting {
            Text(assist.status).font(.callout).foregroundStyle(.secondary)
        } else if silent(now: now) {
            Label("No sound from \(assist.inputName.isEmpty ? "this input" : assist.inputName). Choose the input the mic is on.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
        } else if let problem = assist.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
        } else {
            Text(heardText)
                .font(.callout)
                .foregroundStyle(assist.transcript.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heardText: String {
        let words = assist.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? "Hearing sound. Words will show here." : words
    }

    /// Four seconds with nothing above room noise.
    private func silent(now: Date) -> Bool {
        guard assist.listening else { return false }
        let since = assist.lastSound ?? assist.listeningSince ?? now
        return now.timeIntervalSince(since) > 4
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

/// The input level in decibels (see `LiveAssist.meterFill`). Green for
/// speech, yellow when hot, red when clipping.
private struct LevelMeter: View {
    let level: Float

    private var fill: CGFloat { CGFloat(LiveAssist.meterFill(level)) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(fill > 0.95 ? Color.red : fill > 0.8 ? Color.yellow : Color.green)
                    .frame(width: proxy.size.width * fill)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}
