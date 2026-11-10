import SwiftUI

/// Settings › Integrations › Sync (the church library): linking this Mac to the hub in
/// the CMS, and where syncing stands.
struct CloudSettingsForm: View {
    @State private var sync = CloudSync.shared
    @State private var code = ""
    @State private var name = Host.current().localizedName ?? "This Mac"
    @State private var confirmingUnlink = false
    @AppStorage(PhoneRemoteController.enabledKey) private var phoneRemote = true
    @AppStorage(ClaudeRelay.enabledKey) private var claude = false
    @AppStorage(ServiceStation.runsServiceKey) private var runsHere = false

    var body: some View {
        Form {
            Section {
                if sync.isLinked {
                    LabeledContent("This Mac") { Text(sync.deviceName ?? "Linked") }
                    LabeledContent("Status") { status }
                    if case .needsJoin(let documents) = sync.status {
                        joinPrompt(documents)
                    }
                    if sync.files.downloading + sync.files.uploading + sync.files.waitingForHub > 0 {
                        LabeledContent("Media files") { Text(filesText).foregroundStyle(.secondary) }
                    }
                    if let last = sync.lastActivity {
                        LabeledContent("Last change") {
                            Text(last.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Phone remote: take commands from the CMS", isOn: $phoneRemote)
                    Text(runsHere
                        ? "Sunday › Screens › Remote in the CMS can move slides, fire plan items, clear, run timers and send stage messages on this Mac, from anywhere."
                        : "Only the Mac with Run on this Mac on (Service Day) follows the phone remote. This one doesn't.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Claude: build presentations when asked through the CMS", isOn: $claude)
                    Text(!claude
                        ? "Off. When on, Claude connected at dashboard.hopejc.org/screens/mcp (by an admin) can read and change the library through this Mac."
                        : runsHere
                            ? "Claude connected at dashboard.hopejc.org/screens/mcp can read and change the library through this Mac: songs, slides, plans, the message and the stage display. Admins see and end connections in the CMS under Screens › Macs."
                            : "On, but only the Mac with Run on this Mac on (Service Day) answers Claude. This one doesn't.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                        .disabled(code.filter { $0.isLetter || $0.isNumber }.count < 8 || name.isEmpty || sync.isLinking)
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

    private var filesText: String {
        var parts: [String] = []
        if sync.files.downloading > 0 { parts.append("Downloading \(sync.files.downloading)") }
        if sync.files.uploading > 0 { parts.append("Uploading \(sync.files.uploading)") }
        if sync.files.waitingForHub > 0 { parts.append("\(sync.files.waitingForHub) not on the hub yet") }
        return parts.joined(separator: " · ")
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
