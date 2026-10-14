import NDIKit
import SwiftUI

struct NDINetworkScopeControl: View {
    @State private var adapters: [NDIAdapter] = []
    @State private var selection = NDINetworkScope.selectedBSDName

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            QuietMenuChip(title: chipTitle) {
                Button("All Networks") { choose("") }
                Section("Pin to") {
                    ForEach(adapters) { adapter in
                        Button("\(adapter.displayName) — \(adapter.ipv4)") {
                            choose(adapter.bsdName)
                        }
                    }
                    if adapters.isEmpty {
                        Text("No networks connected")
                    }
                }
            }
            .foregroundStyle(.secondary)
            if !selection.isEmpty,
               !adapters.contains(where: { $0.bsdName == selection }) {
                Text("Not connected — NDI is on all networks until it returns")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.8))
            }
        }
        .task {

            while !Task.isCancelled {
                adapters = await Task.detached(priority: .utility) {
                    NDIAdapterList.current()
                }.value
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private var chipTitle: String {
        guard !selection.isEmpty else { return "All Networks" }
        guard let adapter = adapters.first(where: { $0.bsdName == selection })
        else { return selection }
        return "\(adapter.displayName) — \(adapter.ipv4)"
    }

    private func choose(_ bsdName: String) {
        selection = bsdName
        NDINetworkScope.selectedBSDName = bsdName
        Task { await NDINetworkScope.applyLive() }
    }
}
