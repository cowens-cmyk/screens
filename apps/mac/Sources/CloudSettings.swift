import SwiftUI

/// Settings › Integrations › Church Library: linking this Mac to the hub in
/// the CMS, and where syncing stands.
struct CloudSettingsForm: View {
    @State private var sync = CloudSync.shared
    @State private var code = ""
    @State private var name = Host.current().localizedName ?? "This Mac"
    @State private var confirmingUnlink = false

    var body: some View {
        Form {
            Section {
                if sync.isLinked {
                    LabeledContent("This Mac") { Text(sync.deviceName ?? "Linked") }
                    LabeledContent("Status") { status }
                    if case .needsJoin(let documents) = sync.status {
                        joinPrompt(documents)
                    }
                    if let last = sync.lastActivity {
                        LabeledContent("Last change") {
                            Text(last.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Unlink This Mac…") { confirmingUnlink = true }
                    }
                } else {
                    Text("Link this Mac to keep its plans, songs, slides, themes and media the same as every other Mac at church. Make a code in the CMS under Screens › Link a Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Code", text: $code)
                        .font(.body.monospaced())
                    TextField("Name", text: $name)
                    HStack {
                        Spacer()
                        Button("Link") {
                            Task { await sync.link(code: code, name: name) }
                        }
                        .disabled(code.trimmingCharacters(in: .whitespaces).count < 8 || name.isEmpty || sync.isLinking)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                if let problem = sync.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Church Library")
            } footer: {
                Text("Outputs, MIDI devices and Run on this Mac stay separate on each Mac.")
            }
        }
        .settingsForm()
        .confirmationDialog("Unlink this Mac?", isPresented: $confirmingUnlink) {
            Button("Unlink", role: .destructive) { sync.unlink() }
        } message: {
            Text("This Mac keeps its library as it is now but stops getting changes from the other Macs.")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch sync.status {
        case .notLinked: Text("Not linked").foregroundStyle(.secondary)
        case .connecting: Text("Connecting…").foregroundStyle(.secondary)
        case .needsJoin: Text("Waiting for you to join").foregroundStyle(.orange)
        case .joining: Text("Joining…").foregroundStyle(.secondary)
        case .catchingUp: Text("Catching up…").foregroundStyle(.secondary)
        case .live: Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .offline(let reason): Text("Offline. Trying again. (\(reason))").foregroundStyle(.secondary)
        case .unlinked: Text("This Mac was unlinked in the CMS.").foregroundStyle(.orange)
        }
    }

    private func joinPrompt(_ documents: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The church library has \(documents) items. Joining replaces this Mac's plans, songs, slides and themes with the church's. A copy of this Mac's library is saved first in Application Support › Screens › Backups.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Join Church Library") {
                    Task { await sync.joinChurchLibrary() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
