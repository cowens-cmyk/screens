import Foundation

/// Which logo a plan shows beside its name in the plan list, so a Hope
/// Students night is told from a Sunday at a glance.
public enum PlanBrand: Equatable, Sendable {
    case hope
    case students

    /// Students for a plan of the Wednesday Night type (`midweekServiceType`:
    /// from Shepherd, or made from the Students template) and for a
    /// template named for Students; Hope for every other plan, so a plan
    /// made by hand shows the Hope logo.
    public static func of(_ service: Service, midweekServiceType: String) -> PlanBrand {
        let type = midweekServiceType.trimmingCharacters(in: .whitespaces)
        if !type.isEmpty,
           service.mxuServiceTypeName?.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(type) == .orderedSame {
            return .students
        }
        return service.isTemplate == true && service.name.lowercased().contains("students") ? .students : .hope
    }
}
