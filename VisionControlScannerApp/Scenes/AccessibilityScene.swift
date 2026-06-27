import Foundation

enum AccessibilityScene {
    static let definition = SceneDefinition(
        identifier: "accessibility",
        displayName: "Accessibility",
        matchKeywords: [
            "accessibility features adapt",
            "see what's available in each of the categories"
        ],
        layout: .infoCardGrid,
        promoteToButtons: ["vision", "motor", "hearing", "cognitive"]
    )
}
