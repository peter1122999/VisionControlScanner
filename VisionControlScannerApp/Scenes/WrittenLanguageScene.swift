import Foundation

enum WrittenLanguageScene {
    static let definition = SceneDefinition(
        identifier: "writtenLanguage",
        displayName: "Written Language",
        matchKeywords: ["written language", "preferred languages"],
        // Same combined read-only summary screen as SpokenLanguageScene (see
        // its comment) — macOS 26 has no separate selectable Written
        // Language list. .listPicker's row-inference corrupted this screen's
        // label/sublabel text.
        layout: .infoWithContinue
    )
}
