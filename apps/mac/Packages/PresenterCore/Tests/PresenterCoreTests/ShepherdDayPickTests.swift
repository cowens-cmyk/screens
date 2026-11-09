import Foundation
import Testing

@testable import PresenterCore

/// One Screens plan per day from Shepherd, as Hope's Sundays are set up: the
/// team's "Sunday Morning Worship" plan at 8:00 and a template-only "Sunday
/// Worship" plan at 11:15 with placeholder songs and nobody on it.
struct ShepherdDayPickTests {
    private let morning = ShepherdClient.ServiceType(id: "151b", name: "Sunday Morning Worship")
    private let template = ShepherdClient.ServiceType(id: "11b0", name: "Sunday Worship")

    private func plan(_ id: String, _ type: ShepherdClient.ServiceType, _ iso: String) -> ShepherdClient.PlanSummary {
        ShepherdClient.PlanSummary(
            id: id, serviceType: type, title: nil, series: nil, seriesArtUrl: nil,
            startsAt: ISO8601DateFormatter().date(from: iso), location: nil, times: [], lengthSeconds: nil,
            liveItemId: nil, liveAt: nil, updatedAt: Date(timeIntervalSince1970: 0))
    }

    private var sundays: [ShepherdClient.PlanSummary] {
        [
            plan("m15", morning, "2026-11-15T13:00:00Z"), plan("t15", template, "2026-11-15T16:15:00Z"),
            plan("m22", morning, "2026-11-22T13:00:00Z"), plan("t22", template, "2026-11-22T16:15:00Z"),
            // Early in the week's planning: neither has songs yet.
            plan("m06", morning, "2026-12-06T13:00:00Z"), plan("t06", template, "2026-12-06T16:15:00Z"),
        ]
    }

    @Test func eachSundayKeepsTheChurchsPlan() {
        let pick = ShepherdDayPick.pick(sundays, songs: ["m15": 5, "m22": 5])
        #expect(pick.kept.map(\.id) == ["m15", "m22", "m06"])
        #expect(Set(pick.dropped.map(\.id)) == ["t15", "t22", "t06"])
        #expect(pick.mainServiceTypeName == "Sunday Morning Worship")
    }

    @Test func aDayAloneIsKeptWhateverItsType() {
        let pick = ShepherdDayPick.pick([plan("t29", template, "2026-11-29T16:15:00Z"), plan("m15", morning, "2026-11-15T13:00:00Z")], songs: [:])
        #expect(pick.kept.count == 2 && pick.dropped.isEmpty)
    }

    @Test func withNoSongsAnywhereTheEarliestWins() {
        let pick = ShepherdDayPick.pick([plan("t", template, "2026-12-06T16:15:00Z"), plan("m", morning, "2026-12-06T13:00:00Z")], songs: [:])
        #expect(pick.kept.map(\.id) == ["m"] && pick.mainServiceTypeName == nil)
    }

    @Test func importedSecondPlansAndCopiesAreTakenOut() {
        let pick = ShepherdDayPick.pick(sundays, songs: ["m15": 5, "m22": 5])
        func service(_ id: String, plan: String, date: String, type: String, paused: Bool = false) -> Service {
            var s = Service(id: id, name: id, serviceDate: date, items: [], origin: ShepherdPlanSync.origin, mxuPlanHexId: plan, mxuServiceTypeName: type)
            if paused { s.mxuSyncPaused = true }
            return s
        }
        let library = [
            service("A", plan: "m15", date: "2026-11-15", type: morning.name),
            service("B", plan: "t15", date: "2026-11-15", type: template.name),
            service("C", plan: "t22", date: "2026-11-22", type: template.name, paused: true),
            // Two Macs imported m22 at once.
            service("shepherd-m22", plan: "m22", date: "2026-11-22", type: morning.name),
            service("Z", plan: "m22", date: "2026-11-22", type: morning.name),
            // A past Sunday, outside what was read from Shepherd.
            service("P1", plan: "m01", date: "2026-11-01", type: morning.name),
            service("P2", plan: "t01", date: "2026-11-01", type: template.name),
            // A past day with only the other type stays.
            service("Q", plan: "t25", date: "2026-10-25", type: template.name),
            Service(id: "mine", name: "Made here", serviceDate: "2026-11-15", items: []),
        ]
        let out = ShepherdDayPick.duplicates(in: library, pick: pick, keep: [])
        #expect(Set(out) == ["B", "Z", "P2"])
        #expect(!ShepherdDayPick.duplicates(in: library, pick: pick, keep: ["B"]).contains("B"), "the plan open on this Mac stays")
    }

    @Test func withinTheWindowOnlyShepherdsPlansStay() {
        let pick = ShepherdDayPick.pick(sundays, songs: ["m15": 5, "m22": 5])
        func service(_ id: String, plan: String, date: String) -> Service {
            Service(id: id, name: id, serviceDate: date, items: [], origin: ShepherdPlanSync.origin, mxuPlanHexId: plan, mxuServiceTypeName: "Sunday Morning Worship")
        }
        let library = [
            service("A", plan: "m15", date: "2026-11-15"),
            // An earlier import of a plan Shepherd has since replaced.
            service("OLD", plan: "gone-15", date: "2026-11-15"),
            // A Wednesday import from before Sundays only.
            service("WED", plan: "students", date: "2026-11-18"),
            // Past the window: left to the other rules.
            service("LATER", plan: "gone-27", date: "2026-12-27"),
            Service(id: "mine", name: "Made here", serviceDate: "2026-11-15", items: []),
        ]
        let out = ShepherdDayPick.duplicates(in: library, pick: pick, keep: [], window: "2026-11-09"..."2026-12-07")
        #expect(Set(out) == ["OLD", "WED"])
        let none = ShepherdDayPick.Pick(kept: [], dropped: [], mainServiceTypeName: nil)
        #expect(ShepherdDayPick.duplicates(in: library, pick: none, keep: [], window: "2026-11-09"..."2026-12-07").isEmpty,
                "an empty answer from Shepherd takes nothing")
    }

    @Test func everyMacNamesAnImportedPlanTheSame() {
        #expect(ShepherdDayPick.serviceID(forPlan: "a49a4154-a9ac-4219-b035-20dca8f0614c") == "shepherd-a49a4154-a9ac-4219-b035-20dca8f0614c")
    }
}
