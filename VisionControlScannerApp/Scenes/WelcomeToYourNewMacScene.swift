import Foundation

enum WelcomeToYourNewMacScene {
    static let definition = SceneDefinition(
        identifier: "welcome_to_your_new_mac",
        displayName: "Welcome to your new Mac",
        matchKeywords: [
            "welcome to your new mac",
            "your new mac",
            "get started"
        ],
        layout: .infoWithContinue,
        promoteToButtons: ["continue", "get started", "start"]
    )
}
