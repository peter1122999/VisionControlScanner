import Foundation

enum LocationServicesScene {
    static let definition = SceneDefinition(
        identifier: "locationServices",
        displayName: "Location Services",
        matchKeywords: [
            "enable location services",
            "location services allows apps",
            "about location services & privacy"
        ],
        layout: .checkboxList
    )
}
