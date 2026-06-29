import Foundation

enum MigrationScene {
    static let definition = SceneDefinition(
        identifier: "migration",
        displayName: "Migration Assistant",
        matchKeywords: [
            "migration assistant",
            "transfer your information",
            "transfer information",
            "from a mac, time machine"
        ],
        layout: .migrationOptions
    )
}
