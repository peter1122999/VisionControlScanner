import Foundation

enum AccessibilityScene {
    static let definition = SceneDefinition(
        identifier: "accessibility",
        displayName: "Accessibility",
        matchKeywords: [
            "accessibility",
            "vision",
            "motor",
            "hearing",
            "cognitive"
        ],
        layout: .infoCardGrid,
        promoteToButtons: ["not now", "continue"]
    )
}
