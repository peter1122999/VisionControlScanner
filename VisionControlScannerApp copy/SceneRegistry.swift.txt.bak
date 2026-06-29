import Foundation

enum SceneRegistry {

    static let allScenes: [SceneDefinition] = [
        CountryRegionScene.definition,
        WrittenLanguageScene.definition,
        SpokenLanguageScene.definition,
        KeyboardScene.definition,
        WiFiScene.definition,
        AccessibilityScene.definition,
        TimeZoneScene.definition,
        TermsAndConditionsScene.definition,
        AppleAccountSignInScene.definition,
        CreateMacAccountScene.definition,
        ComputerAccountScene.definition,
        LocationServicesScene.definition,
        AnalyticsScene.definition,
        SiriScene.definition,
        FileVaultScene.definition,
        TouchIDScene.definition,
        AppearanceScene.definition,
        MigrationScene.definition,
        DataPrivacyScene.definition,
        ScreenTimeScene.definition,
        WelcomeScene.definition,
        SoftwareUpdateScene.definition,
        LanguageScene.definition
    ]

    static func classify(haystack: String) -> SceneDefinition? {
        for scene in allScenes {
            if scene.matchKeywords.contains(where: { haystack.contains($0) }) {
                return scene
            }
        }
        return nil
    }
}
