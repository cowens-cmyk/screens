import Foundation

/// Which screen a render on this thread is for: a preview, an output port,
/// a screen's own render. The media a scene draws reads it to note which
/// screen was given which video frame (MediaEngine's CadenceProbe), so the
/// booth's breadcrumbs say which screens show a video unevenly.
public enum RenderConsumer {
    private static let key = "screens.renderConsumer"

    public static func with<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[key]
        dictionary[key] = label
        defer { dictionary[key] = previous }
        return try body()
    }

    public static var current: String? {
        Thread.current.threadDictionary[key] as? String
    }
}
