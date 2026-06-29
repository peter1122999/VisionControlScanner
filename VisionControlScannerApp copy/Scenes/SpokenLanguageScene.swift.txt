import Foundation

enum SpokenLanguageScene {
    static let definition = SceneDefinition(
        identifier: "spokenLanguage",
        displayName: "Spoken Language",
        matchKeywords: ["spoken language", "select your language"],
        layout: .listPicker
    )
}
