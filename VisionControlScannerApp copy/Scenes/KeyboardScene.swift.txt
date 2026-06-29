import Foundation

enum KeyboardScene {
    static let definition = SceneDefinition(
        identifier: "keyboard",
        displayName: "Keyboard",
        matchKeywords: ["select your keyboard", "keyboard layout"],
        layout: .listPicker
    )
}
