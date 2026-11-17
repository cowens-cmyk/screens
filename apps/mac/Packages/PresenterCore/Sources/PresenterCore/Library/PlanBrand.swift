import Foundation

/// Which logo a plan shows beside its name in the plan list, so a Hope
/// Students night is told from a Sunday at a glance.
public enum PlanBrand: Equatable, Sendable {
    case hope
    case students

    /// Students for a plan of the Wednesday Night type (`midweekServiceType`,
    /// from Shepherd) or one named for Students (the Hope Students template
    /// and plans made from it by hand); Hope for every other plan.
    public static func of(_ service: Service, midweekServiceType: String) -> PlanBrand {
        let type = midweekServiceType.trimmingCharacters(in: .whitespaces)
        if !type.isEmpty,
           service.mxuServiceTypeName?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(type) == .orderedSame {
            return .students
        }
        return service.name.lowercased().contains("students") ? .students : .hope
    }
}
