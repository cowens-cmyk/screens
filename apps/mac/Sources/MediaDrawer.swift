import SwiftUI

/// The media bin, opened from Media in the toolbar: it rises from the
/// bottom of the window under the plan instead of replacing it, so a
/// background can be dragged straight onto a slide, a song or the plan.
/// Its top edge drags to resize; the chevron or Media again folds it away.
/// (Esc is left alone: it's the operator's to map.)
struct MediaDrawer: View {
    let model: AppModel
    /// The height of the area the bin rises into, once known.
    var roomHeight: CGFloat?
    @AppStorage(Self.openKey) private var open = false
    @AppStorage("mediaBin.height") private var height = 320.0
    @State private var dragStartHeight: Double?

    static let openKey = "mediaBin.open"

    var body: some View {
        if open {
            VStack(spacing: 0) {
                handle
                HStack(spacing: 8) {
                    Text("Media").font(.headline)
                    Text("Drag onto or between slides, a song or the plan")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { withAnimation(.easeOut(duration: 0.2)) { open = false } } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help("Fold the media bin away")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                Divider()
                MediaLibraryView(model: model, embedded: true)
            }
            .frame(height: shownHeight)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The saved height, kept inside the room there is now. A height dragged
    /// out on a big display would otherwise run past the top of a smaller
    /// window, taking the handle and the chevron with it. The saved height
    /// is left alone, so a bigger window gets it back.
    private var shownHeight: Double {
        min(max(height, Self.minHeight), Self.maxHeight(room: roomHeight))
    }

    static let minHeight = 180.0

    /// Tallest the bin may be: some of the plan stays in view above it, and
    /// in a very short window it never goes past the top.
    static func maxHeight(room: CGFloat?) -> Double {
        guard let room, room > 0 else { return (NSScreen.main?.visibleFrame.height ?? 900) * 0.75 }
        return max(min(minHeight, Double(room)), Double(room) - 100)
    }

    /// Dragged up or down to make the bin taller or shorter.
    private var handle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 44, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? shownHeight
                        dragStartHeight = start
                        height = min(max(start - value.translation.height, Self.minHeight), Self.maxHeight(room: roomHeight))
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .help("Drag to resize")
    }
}
