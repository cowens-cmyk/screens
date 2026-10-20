import PresenterCore
import SwiftUI

/// Hope Church's colors for the app: the brand navy and blue from the
/// website, the light blue the site uses on dark, and the purple and amber of
/// the room's stage lights. Each kind of plan item has its own color so a
/// plan reads at a glance: songs purple, the message amber, video light
/// blue, slideshows teal, other presentations Hope blue.
enum HopeStyle {
    static let navy = Color(red: 0 / 255, green: 74 / 255, blue: 152 / 255)           // #004A98
    static let blue = Color(red: 0 / 255, green: 130 / 255, blue: 202 / 255)          // #0082CA
    static let lightBlue = Color(red: 107 / 255, green: 196 / 255, blue: 232 / 255)   // #6BC4E8
    static let stagePurple = Color(red: 168 / 255, green: 92 / 255, blue: 246 / 255)
    static let amber = Color(red: 245 / 255, green: 166 / 255, blue: 36 / 255)
    static let teal = Color(red: 45 / 255, green: 200 / 255, blue: 180 / 255)
    static let live = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)

    /// The deep navy behind the slides and the screens: the room, not gray.
    static let stage = LinearGradient(
        colors: [Color(red: 14 / 255, green: 22 / 255, blue: 38 / 255), Color(red: 9 / 255, green: 14 / 255, blue: 26 / 255)],
        startPoint: .top, endPoint: .bottom)

    /// A shade lighter than `stage`, for the sidebar and the plan column, so
    /// the columns read as one room but stay distinct.
    static let panel = LinearGradient(
        colors: [Color(red: 20 / 255, green: 30 / 255, blue: 50 / 255), Color(red: 14 / 255, green: 21 / 255, blue: 37 / 255)],
        startPoint: .top, endPoint: .bottom)

    enum ItemKind {
        case header, song, message, slideshow, video, presentation, audio, other

        var color: Color {
            switch self {
            case .song: stagePurple
            case .message: amber
            case .slideshow: teal
            case .video: lightBlue
            case .presentation: blue
            case .audio: Color.pink
            case .header, .other: Color.secondary
            }
        }

        var symbol: String {
            switch self {
            case .header: "textformat"
            case .song: "music.note"
            case .message: "text.book.closed.fill"
            case .slideshow: "play.rectangle.on.rectangle.fill"
            case .video: "film.fill"
            case .presentation: "rectangle.on.rectangle"
            case .audio: "waveform"
            case .other: "questionmark.square.dashed"
            }
        }
    }

    /// What kind of item a plan row is, from the item and (when loaded) the
    /// presentation it points to.
    static func kind(of item: ServiceItem, presentation: Presentation?) -> ItemKind {
        switch item.itemKind {
        case .header: return .header
        case .media: return .video
        case .audio, .playlist: return .audio
        case .presentation:
            guard let presentation else { return .presentation }
            if PresentationTypes.category(of: presentation) == PresentationTypes.sermon { return .message }
            if presentation.presentationKind == .song { return .song }
            if presentation.autoAdvance != nil { return .slideshow }
            return .presentation
        default:
            return item.mxuSongTitle != nil ? .song : .other
        }
    }
}

/// A small rounded badge in an item's color with its symbol. It hops once
/// and glows when its item goes live, the way a tally light comes on.
struct ItemKindBadge: View {
    let kind: HopeStyle.ItemKind
    var live = false

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.bounce.up, options: .speed(1.2), value: live)
            .frame(width: 20, height: 20)
            .background(kind.color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: live ? kind.color.opacity(0.7) : .clear, radius: 5)
            .scaleEffect(live ? 1.08 : 1)
            .animation(HopeMotion.ui, value: live)
    }
}

/// An empty column: a big symbol in a Hope gradient that breathes slowly,
/// a title and one plain line, and an optional button.
struct HopeEmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    var message: String = ""
    var colors: [Color] = [HopeStyle.lightBlue, HopeStyle.stagePurple]
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .symbolEffect(.breathe.pulse, options: .repeat(.continuous))
                .padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold))
            if !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            actions()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension HopeEmptyState where Actions == EmptyView {
    init(title: String, symbol: String, message: String = "", colors: [Color] = [HopeStyle.lightBlue, HopeStyle.stagePurple]) {
        self.init(title: title, symbol: symbol, message: message, colors: colors) { EmptyView() }
    }
}

/// The NEXT tag on the coming plan: a capsule with a faint light that
/// crosses it once when it appears.
struct NextTag: View {
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("NEXT")
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(LinearGradient(colors: [HopeStyle.blue, HopeStyle.lightBlue], startPoint: .leading, endPoint: .trailing),
                        in: Capsule())
            .overlay {
                if !reduceMotion {
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 14)
                        .offset(x: sweep ? 26 : -26)
                        .clipShape(Capsule())
                        .allowsHitTesting(false)
                }
            }
            .clipShape(Capsule())
            .foregroundStyle(.white)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).delay(0.6)) { sweep = true }
            }
    }
}

/// Motion, after Apple's fluid-interface guidance: springs, which can be
/// grabbed and reversed mid-flight and always start from what's on screen,
/// with a subtle settle (a touch of overshoot) everywhere things change.
/// With Reduce Motion, a short cross-fade instead.
enum HopeMotion {
    /// Everyday UI: about a third of a second, with a slight bounce.
    static let ui = Animation.spring(response: 0.35, dampingFraction: 0.82)
    /// Only for motion a gesture threw: a little overshoot.
    static let flick = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let fade = Animation.easeOut(duration: 0.15)

    static func ui(reduced: Bool) -> Animation { reduced ? fade : ui }
}
