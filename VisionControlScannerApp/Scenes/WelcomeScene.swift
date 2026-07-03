import Foundation

enum WelcomeScene {
    static let definition = SceneDefinition(
        identifier: "welcome",
        displayName: "Welcome",
        matchKeywords: ["you're all set"],
        layout: .infoWithContinue
    )
}
