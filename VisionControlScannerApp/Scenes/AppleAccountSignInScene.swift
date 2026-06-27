import Foundation

enum AppleAccountSignInScene {
    static let definition = SceneDefinition(
        identifier: "appleAccountSignIn",
        displayName: "Apple Account",
        matchKeywords: [
            "sign in to your apple account",
            "sign in to use icloud",
            "other sign-in options",
            "create new apple account"
        ],
        layout: .form
    )
}
