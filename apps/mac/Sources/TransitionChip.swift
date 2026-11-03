import MediaEngine
import PresenterCore
import SwiftUI

/// Slides change with a short dissolve unless the church picks otherwise: a
/// cut between lyric slides reads as a flicker on the big screens, and 0.2s
/// is quick enough that the words never trail the singers.
enum SlideTransitionDefault {
    static let kindKey = "transition.slide.kind"
    static let durationKey = "transition.slide.duration"
    static let kind = TransitionKind.dissolve
    static let duration = 0.2

    /// The default used to be a cut, so a Mac that still has one moves to
    /// the dissolve once. Choosing Cut again afterwards sticks.
    static func migrateFromCut() {
        let defaults = UserDefaults.standard
        let flag = "transition.slide.dissolveDefaultApplied"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        let stored = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[kindKey] as? String
        guard stored == nil || stored == "" || stored == TransitionKind.cut.rawValue else { return }
        defaults.set(kind.rawValue, forKey: kindKey)
        defaults.set(duration, forKey: durationKey)
    }
}

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
    /// Names the transition beside the glyph ("Dissolve 0.2s").
    var showsName = false
    /// Drawn as one of the top bar's cells: the glyph with the name under it.
    var inTopBar = false

    var body: some View {
        HStack(spacing: 5) {
            Button {
                reload()
                open = true
            } label: {
                if inTopBar {
                    TopBarCellLabel(title: kindName + (kindRaw.isEmpty ? "" : String(format: " %.2gs", duration))) {
                        Glyph(kind: glyph, size: 14)
                    }
                    .monospacedDigit()
                    .modifier(TopBarMenuHover())
                } else if showsName {
                    // Looks like the top bar's other buttons, so it reads as
                    // one: "Dissolve 0.2s" on a rounded plate.
                    HStack(spacing: 4) {
                        Glyph(kind: glyph, size: 12)
                        Text(kindName + (kindRaw.isEmpty ? "" : String(format: " %.2gs", duration)))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                } else {
                    Glyph(kind: glyph, size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
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
        // From the top bar it opens down into the window.
        .popover(isPresented: $open, arrowEdge: inTopBar ? .bottom : .top) {
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
