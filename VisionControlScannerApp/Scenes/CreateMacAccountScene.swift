//
//  CreateMacAccountScene 2.swift
//  VisionControlScannerApp
//
//  Created by Avery Varney on 6/29/26.
//


//
//  CreateMacAccountScene.swift
//  VisionControlScannerApp
//
//  Defines the macOS Setup Assistant "Create a Mac Account" scene and the
//  position-stable text_field_by_position selector grammar used by the
//  packer-plugin-tart-uiautomate HCL.
//

import Foundation

enum CreateMacAccountScene {
    static let definition = SceneDefinition(
        identifier: "create-mac-account",
        displayName: "Create a Mac Account",
        matchKeywords: [
            "create a mac account",
            "create a computer account",
            "the password you create here will be used to log in",
            "the password you create here",
            "this will be the name of your home folder",
            "allow computer account password to be reset with your apple"
        ],
        layout: .form,
        promoteToButtons: [
            "continue",
            "back",
            "skip"
        ],
        textFieldSelectors: selectorGrammar
    )

    // MARK: - text_field_by_position selector grammar
    //
    // The Create a Mac Account screen on macOS 26 has FIVE textfields laid
    // out as four visual rows:
    //
    //   Row 1: [ Full Name                                              ]
    //   Row 2: [ Account Name                                           ]
    //          (caption: "This will be the name of your home folder.")
    //   Row 3: [ Password                ] [ Verify Password            ]
    //   Row 4: [ Hint (Optional)                                        ]
    //
    // The detector emits positional labels like:
    //   - "field-1-of-5"     (Full Name)
    //   - "field-2-of-5"     (Account Name)
    //   - "left-of-row-3"    (Password)
    //   - "right-of-row-3"   (Verify Password)
    //   - "field-5-of-5"     (Hint (Optional))
    //
    // The grammar below maps those labels — AND the OCR-recovered labels
    // like "Full Name" — to a stable HCL selector. The detector stamps
    // `[@selector]` into the textfield label so HCL can grep it from JSON.
    static let selectorGrammar: [SceneTextFieldSelector] = [
        SceneTextFieldSelector(
            selector: "verify_password",
            positional: "right-of-row-3",
            labelHints: ["Verify Password", "Verify"],
            row: 3, column: 2, columnCount: 2
        ),
        SceneTextFieldSelector(
            selector: "account_name",
            positional: "field-2-of-5",
            labelHints: ["Account Name"],
            row: 2, column: 1, columnCount: 1
        ),
        SceneTextFieldSelector(
            selector: "full_name",
            positional: "field-1-of-5",
            labelHints: ["Full Name"],
            row: 1, column: 1, columnCount: 1
        ),
        SceneTextFieldSelector(
            selector: "password",
            positional: "left-of-row-3",
            labelHints: ["Password"],
            row: 3, column: 1, columnCount: 2
        ),
        SceneTextFieldSelector(
            selector: "hint",
            positional: "field-5-of-5",
            labelHints: ["Hint (Optional)", "Hint"],
            row: 4, column: 1, columnCount: 1
        )
    ]
    /// Convenience for HCL code-gen / unit tests: returns the canonical
    /// click order the build should drive on this scene.
    static let typingOrder: [String] = [
        "full_name",
        "account_name",
        "password",
        "verify_password"
        // "hint" intentionally skipped — Apple does not require it.
    ]
}
