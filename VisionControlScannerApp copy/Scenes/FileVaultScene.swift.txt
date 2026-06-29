import Foundation

enum FileVaultScene {
    static let definition = SceneDefinition(
        identifier: "fileVault",
        displayName: "FileVault",
        matchKeywords: ["filevault", "disk encryption", "turn on filevault"],
        layout: .checkboxList
    )
}
