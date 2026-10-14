import SwiftUI

enum ServiceControlsModule: String, Codable, CaseIterable, Sendable {
    case timers
    case alerts
    case combos
    case confidence

    static let defaultOrder: [ServiceControlsModule] = [
        .combos, .timers, .alerts, .confidence,
    ]

    var title: String {
        switch self {
        case .timers: "Timers"
        case .alerts: "Alerts"
        case .combos: "Macros"
        case .confidence: "Confidence Monitor"
        }
    }

    var glyph: GlyphKind {
        switch self {
        case .timers: .timers
        case .alerts: .alerts
        case .combos: .combos
        case .confidence: .confidence
        }
    }
}

extension View {

    @ViewBuilder
    func draggablePayload(_ payload: String?) -> some View {
        if let payload {
            draggable(payload)
        } else {
            self
        }
    }
}

extension EnvironmentValues {

    @Entry var moduleCompact: Bool = true

    @Entry var runOnly: Bool = false
}
