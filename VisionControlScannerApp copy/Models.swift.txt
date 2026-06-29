import Foundation
import CoreGraphics

struct Detection: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Hashable {
        case button = "Button"
        case checkbox = "Checkbox"
        case radioButton = "Radio"
        case radioOption = "Option"
        case toggleSwitch = "Switch"
        case textField = "TextField"
        case text = "Text"
        case unknown = "Unknown"
    }
    let id = UUID()
    let kind: Kind
    let boundingBox: CGRect
    /// Normalized (0…1) click target for the interactive glyph itself
    /// (checkbox square, radio dot, toggle pill, text-field interior, etc.),
    /// as opposed to `boundingBox` which may also include the adjacent label.
    /// `nil` for plain text detections.
    let controlCenter: CGPoint?
    let value: String
    let confidence: Float
    let label: String?
}

struct TextLabel: Hashable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

struct RasterStats {
    let averageBrightness: Double
    let averageSaturation: Double
    let darkRatio: Double
    let leftSaturation: Double
    let rightSaturation: Double
    let blueRatio: Double
}

struct ConnectedComponent {
    let bounds: CGRect
    let area: Int
    let fillRatio: Double
}

struct SetupOption: Hashable, Identifiable {
    let id = UUID()
    let text: String
    let selected: Bool
}

struct SetupButton: Hashable, Identifiable {
    enum Role: String, Hashable {
        case back = "Back"
        case advance = "Advance"
        case secondary = "Secondary"
    }
    let id = UUID()
    let text: String
    let enabled: Bool
    let role: Role
}

struct SetupTextField: Hashable, Identifiable {
    let id = UUID()
    let label: String
    let focused: Bool
}

struct SetupScreenSummary {
    let title: String?
    let subtitle: String?
    let prompt: String?
    let options: [SetupOption]
    let buttons: [SetupButton]
    let textFields: [SetupTextField]
    var selectedOption: String? {
        options.first(where: { $0.selected })?.text
    }
}

struct AnalysisResult {
    let detections: [Detection]
    let summary: SetupScreenSummary
}
