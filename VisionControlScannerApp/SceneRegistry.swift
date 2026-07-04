import Foundation

/// Full-bleed "hello" greeting screen (no white card): shown before Language at
/// first boot and again at the very end of Setup Assistant. The greeting cycles
/// through languages, so match any of the localized strings; OCR garbles some
/// frames, but wait_for_scene polls and only needs one frame to hit. Registered
/// LAST so a card screen whose body text happens to contain a greeting always
/// classifies as its real scene first.
enum HelloScene {
    static let definition = SceneDefinition(
        identifier: "hello",
        displayName: "Welcome",
        matchKeywords: [
            // Greetings — the big cursive text; OCR only reads it on some frames.
            "hello", "hola", "bonjour", "hallo", "ciao", "olá",
            "hej", "hei", "namaste", "salut", "merhaba", "marhaba",
            "xin chào", "chào", "privet", "cześć", "czesc", "szia",
            "dobar dan", "aloha", "kamusta", "sawasdee",
            "こんにちは", "你好", "您好", "안녕하세요", "नमस्ते",
            "مرحبا", "שלום", "привет", "здравствуйте",
            // Localized "Continue" button — OCRs far more reliably than the
            // stylized greeting, and localized UI only exists on these
            // pre-language-selection screens (bare English "continue" is
            // deliberately absent: every card screen has that button).
            "continuar", "continuer", "continua", "fortfahren", "fortsätt",
            "fortsett", "fortsæt", "fortsat", "jatka", "dalej",
            "pokračovat", "pokračovať", "продолжить", "продовжити",
            "sürdür", "lanjutkan", "teruskan", "folytatás",
            "continuați", "tiếp tục", "doorgaan", "συνέχεια",
            "続ける", "계속", "继续", "繼續", "جارٍ", "متابعة", "המשך"
        ],
        layout: .infoWithContinue
    )
}

enum SceneRegistry {
    static let allScenes: [SceneDefinition] = [
        // More-specific scenes first so generic Welcome doesn't swallow them
        WelcomeToYourNewMacScene.definition,
        NoICloudConfirmScene.definition,
        LocationConfirmModalScene.definition,   // before LocationServicesScene
        CreateMacAccountScene.definition,
        ComputerAccountScene.definition,
        AppleAccountSignInScene.definition,

        // List pickers
        AgeRangeScene.definition,               // NEW — before generic pickers
        CountryRegionScene.definition,
        SpokenLanguageScene.definition,          // covers the combined Written+Spoken screen (see its own comment)
        KeyboardScene.definition,
        WiFiScene.definition,
        LanguageScene.definition,

        // Info / picker / form scenes
        AccessibilityScene.definition,
        TimeZoneScene.definition,
        TermsAndConditionsScene.definition,
        LocationServicesScene.definition,
        AnalyticsScene.definition,
        SiriScene.definition,
        FileVaultScene.definition,
        TouchIDScene.definition,
        AppearanceScene.definition,
        MigrationScene.definition,
        DataPrivacyScene.definition,
        ScreenTimeScene.definition,
        SoftwareUpdateScene.definition,

        // Generic Welcome last — falls through only if nothing else matches
        WelcomeScene.definition,
        HelloScene.definition
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
