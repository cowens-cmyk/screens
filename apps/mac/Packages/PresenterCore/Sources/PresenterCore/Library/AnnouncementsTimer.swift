import Foundation

/// The announcements' time: 90 seconds, started each time an Announcements
/// presentation goes live. The Announcements stage layout shows it, and it
/// keeps counting past 0:00 so whoever is speaking sees how far over.
public enum AnnouncementsTimer {
    public static let name = "Announcements"
    /// Fixed so the Announcements layout can name it.
    public static let id = "screens.timer.announcements"
    public static let seconds: Double = 90
}
