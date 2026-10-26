import PresenterCore
import SwiftUI

/// The first-run welcome. The library already holds the Worship, Scripture
/// and Points themes and the Worship and Message stage layouts; this only
/// offers to bring in an existing workspace.
struct OnboardingView: View {
    let model: AppModel

    let importWorkspace: ((@escaping (ImportActivityModel?) -> Void) -> Void)?
    let close: () -> Void

    @State private var importActivity: ImportActivityModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to Screens")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            Divider()
            Group {
                if let importActivity {
                    ImportActivityView(model: importActivity) {
                        self.importActivity = nil
                    }
                } else {
                    choices
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)
            if importActivity == nil {
                Divider()
                HStack {
                    Spacer()
                    Button("Get Started") { finish() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 560)
        .frame(minHeight: 360)
        .interactiveDismissDisabled()
        .background(QuitDismissesSheet())
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your library starts with Worship, Scripture and Points themes and two stage layouts. The Audience, Livestream and Stage screens are set up in Settings › Screens.")
                .fixedSize(horizontal: false, vertical: true)
            Button {
                importWorkspace? { importActivity = $0 }
            } label: {
                Label("Import ProPresenter Workspace…", systemImage: "square.and.arrow.down")
            }
            .disabled(importWorkspace == nil)
            Spacer(minLength: 0)
            Button("Moving from another Mac? Restore a library backup…") {
                BackupTransferRunner(model: model).presentImport()
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private func finish() {
        model.finishOnboarding()
        close()
    }
}

private struct QuitDismissesSheet: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.preventsApplicationTerminationWhenModal = false }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.preventsApplicationTerminationWhenModal = false }
    }
}

struct HelpCommands: Commands {
    let model: AppModel?
    @Binding var showWelcome: Bool
    @Binding var showFeedback: Bool

    @AppStorage(PresentLayoutController.lockedKey) private var runOnly = false

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Show Welcome") { showWelcome = true }
                .disabled(model == nil || runOnly)
            Divider()
            Button("Report a Problem…") { showFeedback = true }
            Button("Save Performance Report…") { PerformanceReportWriter.save() }
                .help("Samples the app for two seconds and saves what it is doing to the Desktop")
        }
    }
}
