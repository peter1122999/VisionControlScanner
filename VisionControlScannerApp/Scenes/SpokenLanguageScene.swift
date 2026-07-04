import Foundation

enum SpokenLanguageScene {
    static let definition = SceneDefinition(
        identifier: "spokenLanguage",
        displayName: "Spoken Language",
        matchKeywords: [
            "spoken language",
            "written and spoken languages"
        ],
        // macOS 26 merged "Written Language" and "Spoken Language" into one
        // combined "Written and Spoken Languages" READ-ONLY SUMMARY screen
        // (Preferred Languages / Input Sources / Dictation rows + a
        // "Customize Settings" button) — not a selectable list. .listPicker
        // ran recategorizeAsListOptions's row-inference on this screen's
        // label/sublabel text, which isn't list-row-shaped, corrupting most
        // of it (a body-copy fragment got promoted to a fake selected
        // option; the real rows mostly vanished as failed row-synthesis
        // silently consumed their source text). .infoWithContinue keeps
        // plain text + the Continue/Customize Settings buttons untouched.
        layout: .infoWithContinue
    )
}
