import Foundation

enum WiFiScene {
    static let definition = SceneDefinition(
        identifier: "wifi",
        displayName: "Wi-Fi",
        matchKeywords: ["wi-fi network", "select your wi-fi", "select your wifi"],
        layout: .listPicker
    )
}
