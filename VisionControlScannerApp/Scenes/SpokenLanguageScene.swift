import Foundation

enum SpokenLanguageScene {
    static let definition = SceneDefinition(
        identifier: "spokenLanguage",
        displayName: "Spoken Language",
        matchKeywords: [
            "spoken language",
            "written and spoken languages",
            "written language",
            "preferred languages"
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
        //
        // 2026-07-03: this used to be two separate scene definitions
        // (SpokenLanguageScene + WrittenLanguageScene) for what the comment
        // above already says is ONE real screen. SceneRegistry.classify()
        // is deterministic first-match-wins, and WrittenLanguageScene was
        // registered before this one with its own "preferred languages"
        // keyword — meaning this scene ("Spoken Language") could NEVER
        // actually be reached; every real run classified the combined
        // screen as "Written Language" instead, confirmed via a real
        // packer build's wait_for_scene timeout log ("last=Written
        // Language") and its failure screenshot. Merged
        // WrittenLanguageScene's keywords in here and deleted that file —
        // one real screen now has exactly one scene definition instead of
        // two competing for it.
        layout: .infoWithContinue
    )
}
