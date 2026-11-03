import AppKit
import PresenterCore
import SwiftUI

/// Lightkey's first setup, one step at a time. Lightkey learns a scene from
/// a note: put the scene's cue in MIDI learn there, press Send here, next.
/// Doing it from the note table meant reading the table, finding the row,
/// and keeping track of which were done; this walks the rows in order and
/// says what to do in each.
struct LightkeySetupSheet: View {
    let model: AppModel
    @Bindable private var link = LightkeyLink.shared
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case connect
        case cue(Int)
        case section(Int)
        case done
    }

    @State private var step: Step = .connect
    @State private var sent = false
    @State private var learned: Set<String> = []
    /// The rows as they were when Start was pressed. The table is synced and
    /// can lose a row from another Mac while the sheet is open; the steps
    /// keep to the list they started with.
    @State private var started: [LightingCue] = []

    /// The positions Lightkey should learn: every row that's on.
    private var cues: [LightingCue] {
        ServiceLighting.table(model).filter { $0.off != true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Set Up Lightkey").font(.title3.weight(.semibold))
                Spacer()
                Text(progress).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            content
                .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
            Divider()
            buttons
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: step) { _, now in
            sent = false
            // Once Lightkey has learned its notes, the scenes follow the
            // service; the switch on the last step can still turn it off.
            if now == .done, !learned.isEmpty, !link.followsService { link.followsService = true }
        }
    }

    private var progress: String {
        switch step {
        case .connect: "Step 1"
        case .cue(let index): "Scene \(index + 1) of \(started.count)"
        case .section(let index): "Section \(index + 1) of \(LightkeyLink.sectionNotes.count)"
        case .done: "Done"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .connect:
            VStack(alignment: .leading, spacing: 10) {
                Picker("Lightkey runs on", selection: $link.location) {
                    ForEach(LightkeyLink.Location.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                if link.location == .thisMac {
                    instruction(1, "Open Lightkey.")
                    instruction(2, "In Lightkey's MIDI settings, turn on the MIDI input named “Screens”.")
                    Button("Open Lightkey") { openLightkey() }
                } else {
                    instruction(1, "On the Lightkey Mac: Audio MIDI Setup › Window › Show MIDI Studio › Network. Make a session, turn it on, and let anyone connect.")
                    HStack {
                        TextField("Lightkey Mac's address", text: $link.host, prompt: Text("192.168.1.40"))
                            .frame(width: 180)
                        Button("Connect") { link.apply() }
                    }
                    instruction(2, "In Lightkey, turn on that network session as a MIDI input.")
                }
                Text(link.status).font(.caption).foregroundStyle(.secondary)
                Text("Next, Lightkey learns one note for each part of the service: \(cues.map(title).joined(separator: ", ")).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .cue(let index):
            let cue = started[index]
            learnStep(name: title(cue), note: cue.note, key: cue.position,
                      detail: "the scene Lightkey should show for \(title(cue))")
        case .section(let index):
            let section = LightkeyLink.sectionNotes[index]
            learnStep(name: section.name, note: section.note, key: "section.\(section.name)",
                      detail: "the look Lightkey should change to on a song's \(section.name)")
        case .done:
            VStack(alignment: .leading, spacing: 10) {
                Label("Lightkey has learned \(learned.count) note\(learned.count == 1 ? "" : "s").",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Toggle("Change Lightkey scenes with the service on this Mac", isOn: $link.followsService)
                Toggle("Send song sections too (Verse, Chorus, Bridge…)", isOn: $link.sendsSections)
                Text("Redo any one later from the note table in Settings › Integrations › Lightkey & MIDI (its Send button), or run this again.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func learnStep(name: String, note: Int, key: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.title2.weight(.semibold))
            instruction(1, "In Lightkey, choose \(detail) and put its cue in MIDI learn.")
            instruction(2, "Click Send. Lightkey hears note \(note) on channel \(link.channel) and learns it.")
            HStack(spacing: 10) {
                Button {
                    link.sendCue(note: note)
                    sent = true
                    learned.insert(key)
                } label: {
                    Label("Send", systemImage: "dot.radiowaves.right")
                }
                .buttonStyle(.borderedProminent)
                if sent {
                    Label("Sent. If Lightkey learned it, go on.", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            Text("No scene for this one? Skip it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 14)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack {
            if step != .connect, step != .done {
                Button("Back", action: back)
            }
            Spacer()
            Button(step == .done ? "Done" : "Cancel") { dismiss() }
            .keyboardShortcut(step == .done ? .defaultAction : .cancelAction)
            if step != .done {
                if case .connect = step {} else {
                    Button("Skip", action: next)
                }
                Button(step == .connect ? "Start" : "Next", action: next)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func next() {
        switch step {
        case .connect:
            started = cues
            step = started.isEmpty ? sectionsOrDone : .cue(0)
        case .cue(let index):
            step = index + 1 < started.count ? .cue(index + 1) : sectionsOrDone
        case .section(let index):
            step = index + 1 < LightkeyLink.sectionNotes.count ? .section(index + 1) : .done
        case .done:
            break
        }
    }

    private func back() {
        switch step {
        case .cue(let index): step = index > 0 ? .cue(index - 1) : .connect
        case .section(let index): step = index > 0 ? .section(index - 1) : (started.isEmpty ? .connect : .cue(started.count - 1))
        default: break
        }
    }

    /// Song sections only when this Mac sends them.
    private var sectionsOrDone: Step { link.sendsSections ? .section(0) : .done }

    private func title(_ cue: LightingCue) -> String {
        ServicePosition(key: cue.position)?.title ?? cue.position
    }

    private func openLightkey() {
        let candidates = ["/Applications/Lightkey.app", "\(NSHomeDirectory())/Applications/Lightkey.app"]
        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
        }
    }
}
