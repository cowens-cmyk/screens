import Foundation
import UniformTypeIdentifiers

/// The Media Library's categories. Each is a folder in Media (Audio is the
/// Audio library), so filing something under one is an ordinary move and
/// syncs like any other: nothing new is stored to say what's in a category.
/// Countdowns is the folder the plan's countdown already looks in;
/// Announcements is where the hopejc.org event artwork is brought in.
public enum MediaLibraryCategory: String, CaseIterable, Identifiable, Sendable {
    case worshipBackgrounds
    case countdowns
    case videos
    case sermonSlides
    case announcements
    case images
    case audio

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .worshipBackgrounds: "Worship Backgrounds"
        case .countdowns: "Countdowns"
        case .videos: "Videos"
        case .sermonSlides: "Sermon Slides"
        case .announcements: "Announcements"
        case .images: "Images"
        case .audio: "Audio"
        }
    }

    /// The Media folder the category is; nil for Audio, which is its own
    /// library.
    public var folder: String? {
        switch self {
        case .countdowns: ServiceCountdown.folder
        case .audio: nil
        default: title
        }
    }

    /// Worship backgrounds run under the songs for as long as they're up;
    /// everything else plays once. A video's own choice (right-click › When
    /// It Ends) overrides this.
    public var loopsByDefault: Bool { self == .worshipBackgrounds }

    /// The category whose folder holds this path: the folder itself or one
    /// inside it. Matched without regard to case, so a "Worship backgrounds"
    /// folder made by hand counts.
    public static func containing(folder path: String?) -> MediaLibraryCategory? {
        guard let path, !path.isEmpty else { return nil }
        if ServiceCountdown.isCountdownFolder(path) { return .countdowns }
        let top = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
        return allCases.first { category in
            category.folder.map { $0.caseInsensitiveCompare(top) == .orderedSame } ?? false
        }
    }

    /// Where a file dropped on All Media is filed: videos under Videos,
    /// pictures under Images, music in Audio. Anything else (a PDF or a
    /// Keynote deck, which become presentations) has no category.
    public static func forImportedFile(_ url: URL) -> MediaLibraryCategory? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .videos }
        return nil
    }
}

/// Right-click › When It Ends on a video. Loop keeps it going; the others
/// play it once and then: go on to the next item in the plan, leave the
/// last frame up, fade the layer to black, or take it down at once.
public enum MediaEndChoice: String, CaseIterable, Identifiable, Sendable {
    case loop
    case next
    case hold
    case fadeToBlack
    case stop

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .loop: "Loop"
        case .next: "Next Item"
        case .hold: "Hold Last Frame"
        case .fadeToBlack: "Fade to Black"
        case .stop: "Stop"
        }
    }

    public var endAction: MediaEndAction? {
        switch self {
        case .loop: nil
        case .next: .next
        case .hold: .hold
        case .fadeToBlack: .fadeToBlack
        case .stop: .stop
        }
    }

    init(_ action: MediaEndAction) {
        switch action {
        case .next: self = .next
        case .hold: self = .hold
        case .fadeToBlack: self = .fadeToBlack
        case .stop: self = .stop
        }
    }
}

extension MediaItem {
    /// The Media Library category the item is filed under, if any.
    public var libraryCategory: MediaLibraryCategory? {
        MediaLibraryCategory.containing(folder: folder)
    }

    /// Whether someone chose to loop this video, or chose not to; nil when
    /// nothing's been chosen and its category decides. Items saved before
    /// there was a choice to record count as chosen when they say so:
    /// imports start out not looping, so one marked as looping, or given
    /// an ending of its own, was set that way by hand.
    public var loopChoice: Bool? {
        if let loopOverride { return loopOverride }
        if loops { return true }
        if endAction != nil { return false }
        return nil
    }

    /// Whether the video loops wherever it plays and nothing on the slide
    /// says otherwise: its own choice, else its category's default (only
    /// worship backgrounds loop). A still never loops.
    public var playsLooping: Bool {
        guard mediaKind == .video else { return false }
        return loopChoice ?? (libraryCategory?.loopsByDefault ?? false)
    }

    /// What the category alone would have it do at its end.
    public var defaultEndChoice: MediaEndChoice {
        libraryCategory?.loopsByDefault == true ? .loop : .next
    }

    /// What the video does at its end as things stand: nil for a still,
    /// and for a video that plays once and moves on by its own auto-advance.
    public var endChoice: MediaEndChoice? {
        guard mediaKind == .video else { return nil }
        if playsLooping { return .loop }
        return resolvedEndAction.map(MediaEndChoice.init)
    }

    /// Records a choice from When It Ends; nil goes back to the category's
    /// default. `loops` is kept in step for Macs on an older build, which
    /// read only that.
    public mutating func choose(_ choice: MediaEndChoice?) {
        switch choice {
        case nil:
            loopOverride = nil
            loops = false
            endAction = nil
        case .loop?:
            loopOverride = true
            loops = true
            endAction = nil
        case let choice?:
            loopOverride = false
            loops = false
            endAction = choice.endAction
        }
    }

    /// A Loops switch turned on or off: off keeps whatever ending was set.
    public mutating func setLoops(_ on: Bool) {
        if on {
            choose(.loop)
        } else {
            loopOverride = false
            loops = false
        }
    }

    /// The inspectors' Loops switch: shows what the video does now, and
    /// turning it records a choice.
    public var loopsSetting: Bool {
        get { playsLooping }
        set { setLoops(newValue) }
    }

    /// What a slide placing this video records about looping: nil when the
    /// video's choice or category decides, so changing it in the library
    /// changes it on every slide; otherwise the placement's own default, as
    /// before there were categories.
    public func loopsWhenPlaced(otherwise: Bool) -> Bool? {
        guard mediaKind == .video else { return nil }
        return loopChoice == nil && libraryCategory == nil ? otherwise : nil
    }
}
