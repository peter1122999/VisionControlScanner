import Foundation

enum SoftwareUpdateScene {
    static let definition = SceneDefinition(
        identifier: "softwareUpdate",
        displayName: "Software Update",
        matchKeywords: ["software update available", "is available and will be"],
        layout: .infoWithContinue
    )
}
