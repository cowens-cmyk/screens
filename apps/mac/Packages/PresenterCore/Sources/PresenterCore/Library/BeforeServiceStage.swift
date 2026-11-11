import Foundation

/// When the stage display goes to Before Service (the countdown to the next
/// service's start): the walk-in slideshow, however it goes up, and the
/// walkout. The countdown video is neither: it's a video that plays once, so
/// the stage shows the Video layout (its own time left, which is the time to
/// the service) over whatever mode it was in.
public enum BeforeServiceStage {
    /// - `slideshow`: the presentation is the walk-in slideshow, whether or
    ///   not it came from a plan item.
    /// - `item`: the plan item the slide was fired from, if it was.
    /// - `walkoutDeckID`: the Service Day's walkout presentation, so one put
    ///   up on its own (not from a plan) counts too.
    /// - `endOfPlan`: the plan's last presentation is on its last slide,
    ///   which is where one service ends and the next one's walk-in begins.
    ///   Looked at only when nothing else decided.
    public static func applies(
        slideshow: Bool, item: ServiceItem?, presentationID: String, walkoutDeckID: String?,
        endOfPlan: @autoclosure () -> Bool
    ) -> Bool {
        if slideshow || item?.isPreService == true || item?.isWalkout == true { return true }
        if let walkoutDeckID, !walkoutDeckID.isEmpty, presentationID == walkoutDeckID { return true }
        return endOfPlan()
    }
}
