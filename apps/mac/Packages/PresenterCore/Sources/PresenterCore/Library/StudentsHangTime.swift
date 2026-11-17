import Foundation

/// The slideshow Hope Students' doors-open time shows: the artwork of every
/// Hope Students event coming up on hopejc.org (the students calendar),
/// 1920×1080 pictures only, ten seconds a slide, round and round. The website
/// events sync keeps it as it keeps the pre-service slideshow
/// (WebsiteEvents), and a Wednesday Night plan's "Students Hang Time" item
/// links to it with the Walk-in lighting look and full screen on the
/// livestream (StudentsNight).
///
/// There is one for the whole library, with a fixed id, so two Macs that
/// make it at once make one.
public enum StudentsHangTime {
    public static let presentationID = "students-hang-time"
    public static let presentationName = "Students Hang Time"
    /// The website calendar its events come from.
    public static let calendar = "students"
    /// Only artwork this size is shown: the screens are 1920×1080 and a
    /// square or portrait picture would show with bars.
    public static let width = 1920
    public static let height = 1080

    /// The slideshow made when the library has none: empty, ten seconds a
    /// slide, starting over at the end.
    public static func newSlideshow() -> Presentation {
        var deck = PreServiceSlides.newSlideshow(id: presentationID)
        deck.name = presentationName
        return deck
    }

    /// The slideshow in the library: the one with the fixed id, else one
    /// named Students Hang Time.
    public static func find(ids: [(id: String, name: String)]) -> String? {
        if ids.contains(where: { $0.id == presentationID }) { return presentationID }
        return ids.filter { letters($0.name) == letters(presentationName) }.map(\.id).sorted().first
    }

    /// A plan item standing for doors-open time: "Students Hang Time",
    /// "Hang Time", "HANG TIME".
    public static func isHangTimeItem(_ item: ServiceItem) -> Bool {
        item.itemKind != .header && letters(item.name).contains("hangtime")
    }

    /// Whether a picture is the size the slideshow takes.
    public static func fits(width: Int?, height: Int?) -> Bool {
        width == Self.width && height == Self.height
    }

    private static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter }
    }
}
