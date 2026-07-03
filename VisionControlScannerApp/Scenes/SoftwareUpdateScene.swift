import Foundation

enum SoftwareUpdateScene {
    static let definition = SceneDefinition(
        identifier: "softwareUpdate",
        displayName: "Software Update",
        matchKeywords: [
            "software update available",
            "is available and will be",
            // macOS 26 variant shown after Appearance:
            "update mac automatically",
            "future software updates",
            "software update settings",
            "only download automatically"
        ],
        layout: .infoWithContinue
    )
}
