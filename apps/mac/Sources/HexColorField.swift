import AppKit
import PresenterCore
import SwiftUI

/// A color as the system color well plus its hex code, so a color from a
/// brand guide or a Claude Design export can be matched exactly. Type or
/// paste "#1E2A44", "1E2A44", "#FFF" or "#1E2A44CC" and press Return (or
/// click away); anything that isn't a color is outlined in red and left
/// for fixing. `hex` is the app's stored "#RRGGBBAA".
struct HexColorField: View {
    let label: String
    @Binding var hex: String
    /// Off for colors that are always opaque (series text, a bar): the well
    /// hides its opacity slider and the field shows six digits.
    var supportsOpacity = true
    var labelHidden = false

    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if labelHidden {
                controls
            } else {
                LabeledContent(label) { controls }
            }
        }
        .onAppear { draft = shown(hex) }
        .onChange(of: hex) { _, newValue in
            if !focused {
                draft = shown(newValue)
                invalid = false
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit(leaving: true) }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            ColorPicker(label, selection: colorBinding, supportsOpacity: supportsOpacity)
                .labelsHidden()
            TextField(supportsOpacity ? "#RRGGBBAA" : "#RRGGBB", text: $draft)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .frame(width: supportsOpacity ? 92 : 78)
                .focused($focused)
                .onSubmit { commit(leaving: false) }
                .onChange(of: draft) { _, _ in invalid = false }
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.red, lineWidth: 1.5)
                        .opacity(invalid ? 1 : 0)
                        .allowsHitTesting(false))
                .help(invalid ? "Not a color. Use #RRGGBB\(supportsOpacity ? " or #RRGGBBAA" : "")."
                              : "Hex color: #RRGGBB\(supportsOpacity ? " or #RRGGBBAA" : ""). Press Return to apply.")
                .accessibilityLabel("\(label) hex")
        }
        .fixedSize()
    }

    /// Return keeps a mistyped code on screen, outlined, to fix; clicking
    /// away puts the current color back.
    private func commit(leaving: Bool) {
        guard var parsed = HexColor(draft) else {
            if leaving || draft.trimmingCharacters(in: .whitespaces).isEmpty {
                draft = shown(hex)
                invalid = false
            } else {
                invalid = true
            }
            return
        }
        if !supportsOpacity { parsed = parsed.opaque }
        if HexColor(hex) != parsed { hex = parsed.stored }
        draft = parsed.display(allowsAlpha: supportsOpacity)
        invalid = false
    }

    private func shown(_ stored: String) -> String {
        HexColor(stored)?.display(allowsAlpha: supportsOpacity) ?? stored
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let color = HexColor(hex) ?? HexColor(red: 1, green: 1, blue: 1)
                return Color(.sRGB, red: color.red, green: color.green, blue: color.blue,
                             opacity: supportsOpacity ? color.alpha : 1)
            },
            set: { picked in
                let ns = NSColor(picked).usingColorSpace(.sRGB) ?? .white
                let color = HexColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent,
                                     alpha: supportsOpacity ? ns.alphaComponent : 1)
                if HexColor(hex) != color { hex = color.stored }
            })
    }
}

extension HexColorField {
    /// A series color (always opaque) edited as hex.
    static func binding(_ color: Binding<SeriesColor>) -> Binding<String> {
        Binding(
            get: { color.wrappedValue.hex() },
            set: { hex in if let picked = SeriesColor(hex: hex) { color.wrappedValue = picked } })
    }
}
