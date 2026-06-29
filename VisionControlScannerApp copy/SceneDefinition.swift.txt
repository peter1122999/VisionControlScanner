import Foundation

struct SceneDefinition {
    let identifier: String
    let displayName: String
    let matchKeywords: [String]
    let layout: SceneLayout
    let promoteToButtons: [String]

    init(
        identifier: String,
        displayName: String,
        matchKeywords: [String],
        layout: SceneLayout,
        promoteToButtons: [String] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.matchKeywords = matchKeywords
        self.layout = layout
        self.promoteToButtons = promoteToButtons
    }
}

enum SceneLayout {
    case listPicker
    case infoCardGrid
    case infoWithContinue
    case agreement
    case checkboxList
    case form
    case timeZone
    case migrationOptions
    case unknown
    case thumbnailPicker
}
