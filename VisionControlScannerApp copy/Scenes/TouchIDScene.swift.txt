import Foundation

enum TouchIDScene {
    static let definition = SceneDefinition(
        identifier: "touchID",
        displayName: "Touch ID",
        matchKeywords: ["touch id", "add a fingerprint"],
        layout: .infoWithContinue
    )
}
