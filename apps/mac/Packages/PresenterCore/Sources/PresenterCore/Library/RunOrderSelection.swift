import Foundation

public enum RunOrderSelection {

    public static func surfaceItem(
        selection: Set<String>, current: String?, rows: [ServiceItem]
    ) -> String? {
        guard !selection.isEmpty else { return nil }
        if let current, selection.contains(current) { return current }
        return rows.first { selection.contains($0.id) && $0.itemKind != .header }?.id ?? current
    }

    public static func isReselect(
        pressed: String, current: String?, command: Bool, shift: Bool, control: Bool
    ) -> Bool {
        pressed == current && !command && !shift && !control
    }

    /// Whether a mouse press on a plan row sends a header's lighting cue: a
    /// plain click on a header, while presenting, not on its disclosure
    /// chevron. Only a click does — the selection moving by arrow keys, or
    /// coming back when the plan appears, never reaches here.
    public static func isHeaderCueClick(
        pressed: ServiceItem?, presenting: Bool, command: Bool, shift: Bool, control: Bool,
        onDisclosure: Bool
    ) -> Bool {
        pressed?.itemKind == .header && presenting && !command && !shift && !control && !onDisclosure
    }

    public static func swept(
        frames: [String: CGRect], band: CGRect, keeping: Set<String> = []
    ) -> Set<String> {
        keeping.union(frames.filter { $0.value.intersects(band) }.map(\.key))
    }

    public struct Removal: Equatable {
        public var local: [ServiceItem]
        public var synced: [ServiceItem]

        public init(local: [ServiceItem] = [], synced: [ServiceItem] = []) {
            self.local = local
            self.synced = synced
        }

        public var ids: [String] { (local + synced).map(\.id) }
        public var count: Int { local.count + synced.count }
    }

    public static func removal(
        of ids: some Collection<String>, in items: [ServiceItem]
    ) -> Removal {
        let targets = Set(ids)
        var removal = Removal()
        for item in items where targets.contains(item.id) {
            if item.mxuItemHexId != nil, item.itemKind != .header {
                removal.synced.append(item)
            } else {
                removal.local.append(item)
            }
        }
        return removal
    }
}
