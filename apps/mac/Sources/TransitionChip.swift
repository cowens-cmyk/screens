import MediaEngine
import PresenterCore
import SwiftUI

struct TransitionChip: View {
    let glyph: GlyphKind
    let kindKey: String
    let durationKey: String
    var fallbackKind = ""
    var fallbackDuration = 0.5

    @State private var open = false
    @State private var kindRaw = ""
    @State private var duration = 0.5

    private var kindName: String {
        switch TransitionKind(rawValue: kindRaw) {
        case .dissolve: "Dissolve"
        case .fadeBlack: "Fade Black"
        case .fadeWhite: "Fade White"
        case .fadeColor: "Fade Color"
        case .blurDissolve: "Blur Dslv"
        case .filmBurn: "Film Burn"
        case .cut, nil: "Cut"
        }
    }

    var showSlider = true

    var body: some View {
        HStack(spacing: 5) {
            Button {
                reload()
                open = true
            } label: {
                Glyph(kind: glyph, size: 12)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(kindName)\(kindRaw.isEmpty ? "" : String(format: " %.2gs", duration)) — this layer's default; items with their own always win")
            if showSlider, !kindRaw.isEmpty {
                Slider(value: storedDuration, in: 0 ... 5)
                    .controlSize(.mini)
                    .tint(Color.primary.opacity(0.2))
                    .frame(width: 56)
            }
        }
        .onAppear(perform: reload)
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {

                Picker("Transition", selection: storedKind) {
                    Text("Cut").tag("")
                    Text("Dissolve").tag(TransitionKind.dissolve.rawValue)
                    Text("Fade Black").tag(TransitionKind.fadeBlack.rawValue)
                    Text("Fade White").tag(TransitionKind.fadeWhite.rawValue)
                    Text("Blur Dissolve").tag(TransitionKind.blurDissolve.rawValue)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if !kindRaw.isEmpty {
                    BoundedSliderRow(
                        label: "Duration", value: storedDuration, range: 0 ... 5, step: 0.05
                    )
                }
            }
            .padding(12)
            .frame(width: 220)
        }
    }

    private var storedKind: Binding<String> {
        Binding(
            get: { kindRaw },
            set: { v in
                kindRaw = v
                UserDefaults.standard.set(v, forKey: kindKey)
            }
        )
    }

    private var storedDuration: Binding<Double> {
        Binding(
            get: { duration },
            set: { v in
                duration = v
                UserDefaults.standard.set(v, forKey: durationKey)
            }
        )
    }

    private func reload() {
        kindRaw = UserDefaults.standard.string(forKey: kindKey) ?? fallbackKind
        let stored = UserDefaults.standard.double(forKey: durationKey)
        duration = stored > 0 ? stored : fallbackDuration
    }
}
