import Foundation

/// Uses the same service ordering and re-sync behavior as Planning Center.
public enum ShepherdPlanSync {
    public static let origin = "shepherd"

    public static func serviceName(for plan: ShepherdClient.PlanSummary) -> String {
        name(title: plan.title, date: serviceDate(for: plan), serviceType: plan.serviceType.name)
    }

    public static func serviceName(for plan: ShepherdClient.PlanDetail) -> String {
        name(title: plan.title, date: serviceDate(for: plan), serviceType: plan.serviceType.name)
    }

    public static func serviceDate(for plan: ShepherdClient.PlanSummary) -> String {
        dateString(plan.startsAt)
    }

    public static func serviceDate(for plan: ShepherdClient.PlanDetail) -> String {
        dateString(plan.startsAt)
    }

    private static func name(title: String?, date: String, serviceType: String) -> String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let label = title.isEmpty ? serviceType : title
        return date.isEmpty ? label : "\(date) — \(label)"
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `songRef` only looks up presentations already in the library; it must not
    /// import or create songs. Nil leaves an info item with song metadata for the UI.
    public static func items(
        for plan: ShepherdClient.PlanDetail,
        serviceTypeName: String? = nil,
        rules: ServiceLinkRules,
        existing: [ServiceItem],
        songRef: (PCOClient.Item) -> (refId: String, arrangementId: String?)?
    ) -> [ServiceItem] {
        let mapped = plan.items.sorted { $0.position < $1.position }.map { item in
            PCOClient.Item(
                id: item.id, title: item.title, itemType: item.kind, sequence: item.position,
                description: item.description, keyName: item.song?.key,
                length: item.lengthSeconds, servicePosition: nil,
                customArrangementSequence: item.song?.sequence, updatedAt: "",
                song: item.song.map {
                    PCOClient.Song(
                        id: $0.id, title: $0.title, author: $0.author, copyright: $0.copyright,
                        ccliNumber: $0.ccliNumber.flatMap(Int.init))
                },
                arrangement: item.song.flatMap { song in
                    song.arrangementId.map {
                        PCOClient.Arrangement(
                            id: $0, name: song.arrangement ?? "", lyrics: nil, chordChart: nil,
                            chordChartKey: song.key, sequence: song.sequence,
                            bpm: song.tempo, meter: song.timeSignature, updatedAt: nil)
                    }
                },
                key: nil)
        }
        var result = PCOPlanSync.items(
            for: mapped, serviceTypeName: serviceTypeName ?? plan.serviceType.name,
            rules: rules, existing: existing, songRef: { _ in nil })
        // PCO allows name rules and previous links to bypass songRef. Shepherd
        // requires the caller's library lookup to validate every song link.
        for song in mapped where song.itemType == "song" {
            guard let index = result.firstIndex(where: { $0.mxuPcoItemId == song.id }) else { continue }
            let link = songRef(song)
            result[index].itemKind = link == nil ? .info : .presentation
            result[index].refId = link?.refId ?? ""
            result[index].arrangementId = link?.arrangementId
        }
        return result
    }
}
