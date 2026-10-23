import Foundation

/// Checks a tool call's input against the tool's JSON schema before it runs.
/// Inputs stream in unbuffered (eager input streaming), so the API no longer
/// validates them; a call that fails here is answered with the error and
/// never touches the library. Covers the schema features the catalog uses:
/// type, properties, required, additionalProperties false, enum, items,
/// minItems/maxItems, minimum/maximum, minLength.
public enum AssistantToolInput {
    public static func validate(_ value: AssistantJSON, against schema: AssistantJSON) -> String? {
        check(value, schema, path: "input")
    }

    private static func check(_ value: AssistantJSON, _ schema: AssistantJSON, path: String) -> String? {
        if let options = schema["enum"]?.array, !options.contains(value) {
            let allowed = options.compactMap(\.string).joined(separator: ", ")
            return "\(path) must be one of: \(allowed)"
        }
        switch schema["type"]?.string {
        case "object":
            guard let fields = value.object else { return "\(path) must be an object" }
            let properties = schema["properties"]?.object ?? [:]
            for name in schema["required"]?.array?.compactMap(\.string) ?? [] where fields[name] == nil || fields[name] == .null {
                return "\(path).\(name) is required"
            }
            if schema["additionalProperties"] == .bool(false) {
                if let extra = fields.keys.sorted().first(where: { properties[$0] == nil }) {
                    return "\(path).\(extra) is not a known field"
                }
            }
            for name in fields.keys.sorted() {
                guard let property = properties[name], let field = fields[name] else { continue }
                // An optional field sent as null counts as left out.
                if field == .null, !(schema["required"]?.array?.contains(.string(name)) ?? false) { continue }
                if let error = check(field, property, path: "\(path).\(name)") { return error }
            }
        case "array":
            guard let items = value.array else { return "\(path) must be an array" }
            if let least = schema["minItems"]?.int, items.count < least {
                return "\(path) needs at least \(least) item\(least == 1 ? "" : "s")"
            }
            if let most = schema["maxItems"]?.int, items.count > most {
                return "\(path) takes at most \(most) items"
            }
            if let itemSchema = schema["items"] {
                for (index, item) in items.enumerated() {
                    if let error = check(item, itemSchema, path: "\(path)[\(index)]") { return error }
                }
            }
        case "string":
            guard let text = value.string else { return "\(path) must be a string" }
            if let least = schema["minLength"]?.int, text.trimmingCharacters(in: .whitespacesAndNewlines).count < least {
                return "\(path) must not be empty"
            }
        case "integer":
            guard let number = value.int else { return "\(path) must be a whole number" }
            if let error = bounds(Double(number), schema, path: path) { return error }
        case "number":
            guard let number = value.number else { return "\(path) must be a number" }
            if let error = bounds(number, schema, path: path) { return error }
        case "boolean":
            guard value.bool != nil else { return "\(path) must be true or false" }
        default:
            break
        }
        return nil
    }

    private static func bounds(_ number: Double, _ schema: AssistantJSON, path: String) -> String? {
        if let low = schema["minimum"]?.number, number < low { return "\(path) must be at least \(format(low))" }
        if let high = schema["maximum"]?.number, number > high { return "\(path) must be at most \(format(high))" }
        return nil
    }

    private static func format(_ number: Double) -> String {
        number.rounded() == number ? String(Int(number)) : String(number)
    }
}
