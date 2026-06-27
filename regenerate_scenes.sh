#!/usr/bin/env bash
set -euo pipefail

# Path to the folder that contains your Swift sources for the app target.
# Adjust if your layout differs.
APP_DIR="VisionControlScannerApp"
SCENES_DIR="${APP_DIR}/Scenes"

if [[ ! -d "${APP_DIR}" ]]; then
    echo "ERROR: Expected to find '${APP_DIR}/' in the current directory."
    echo "Run this script from the folder that contains VisionControlScannerApp.xcodeproj."
    exit 1
fi

mkdir -p "${SCENES_DIR}"

backup_if_exists() {
    local target="$1"
    if [[ -f "${target}" ]]; then
        cp "${target}" "${target}.bak"
    fi
}

write_file() {
    local path="$1"
    local content="$2"
    backup_if_exists "${path}"
    printf '%s' "${content}" > "${path}"
    echo "  wrote ${path}"
}

echo "Writing SceneDefinition.swift..."
write_file "${APP_DIR}/SceneDefinition.swift" 'import Foundation

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
}
'

echo "Writing SceneRegistry.swift..."
write_file "${APP_DIR}/SceneRegistry.swift" 'import Foundation

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
'

echo "Writing 23 scene files into ${SCENES_DIR}/..."

write_file "${SCENES_DIR}/CountryRegionScene.swift" 'import Foundation

enum CountryRegionScene {
    static let definition = SceneDefinition(
        identifier: "countryRegion",
        displayName: "Country or Region",
        matchKeywords: ["country or region", "select your country"],
        layout: .listPicker
    )
}
'

write_file "${SCENES_DIR}/LanguageScene.swift" 'import Foundation

enum LanguageScene {
    static let definition = SceneDefinition(
        identifier: "language",
        displayName: "Language",
        matchKeywords: [
            "english (uk)", "english (australia)", "english (india)",
            "español (ee. uu.)", "español (latinoamérica)",
            "français", "日本語", "简体中文"
        ],
        layout: .listPicker
    )
}
'

write_file "${SCENES_DIR}/WrittenLanguageScene.swift" 'import Foundation

enum WrittenLanguageScene {
    static let definition = SceneDefinition(
        identifier: "writtenLanguage",
        displayName: "Written Language",
        matchKeywords: ["written language", "preferred languages"],
        layout: .listPicker
    )
}
'

write_file "${SCENES_DIR}/SpokenLanguageScene.swift" 'import Foundation

enum SpokenLanguageScene {
    static let definition = SceneDefinition(
        identifier: "spokenLanguage",
        displayName: "Spoken Language",
        matchKeywords: ["spoken language", "select your language"],
        layout: .listPicker
    )
}
'

write_file "${SCENES_DIR}/KeyboardScene.swift" 'import Foundation

enum KeyboardScene {
    static let definition = SceneDefinition(
        identifier: "keyboard",
        displayName: "Keyboard",
        matchKeywords: ["select your keyboard", "keyboard layout"],
        layout: .listPicker
    )
}
'

write_file "${SCENES_DIR}/WiFiScene.swift" 'import Foundation

enum WiFiScene {
    static let definition = SceneDefinition(
        identifier: "wifi",
        displayName: "Wi-Fi",
        matchKeywords: ["wi-fi network", "select your wi-fi", "select your wifi"],
        layout: .listPicker
    )
}
'

write_file "${SCENES_DIR}/AccessibilityScene.swift" 'import Foundation

enum AccessibilityScene {
    static let definition = SceneDefinition(
        identifier: "accessibility",
        displayName: "Accessibility",
        matchKeywords: [
            "accessibility features adapt",
            "see what'"'"'s available in each of the categories"
        ],
        layout: .infoCardGrid,
        promoteToButtons: ["vision", "motor", "hearing", "cognitive"]
    )
}
'

write_file "${SCENES_DIR}/TimeZoneScene.swift" 'import Foundation

enum TimeZoneScene {
    static let definition = SceneDefinition(
        identifier: "timeZone",
        displayName: "Time Zone",
        matchKeywords: [
            "select your time zone",
            "set time zone automatically",
            "closest city"
        ],
        layout: .timeZone
    )
}
'

write_file "${SCENES_DIR}/TermsAndConditionsScene.swift" 'import Foundation

enum TermsAndConditionsScene {
    static let definition = SceneDefinition(
        identifier: "termsAndConditions",
        displayName: "Terms and Conditions",
        matchKeywords: [
            "terms and conditions",
            "macos software license agreement",
            "software license agreement for macos"
        ],
        layout: .agreement
    )
}
'

write_file "${SCENES_DIR}/AppleAccountSignInScene.swift" 'import Foundation

enum AppleAccountSignInScene {
    static let definition = SceneDefinition(
        identifier: "appleAccountSignIn",
        displayName: "Apple Account",
        matchKeywords: [
            "sign in to your apple account",
            "sign in to use icloud",
            "other sign-in options",
            "create new apple account"
        ],
        layout: .form
    )
}
'

write_file "${SCENES_DIR}/CreateMacAccountScene.swift" 'import Foundation

enum CreateMacAccountScene {
    static let definition = SceneDefinition(
        identifier: "createMacAccount",
        displayName: "Create a Mac Account",
        matchKeywords: [
            "create a mac account",
            "password you create here will be used"
        ],
        layout: .form
    )
}
'

write_file "${SCENES_DIR}/ComputerAccountScene.swift" 'import Foundation

enum ComputerAccountScene {
    static let definition = SceneDefinition(
        identifier: "computerAccount",
        displayName: "Computer Account",
        matchKeywords: [
            "create a computer account",
            "create your computer account"
        ],
        layout: .form
    )
}
'

write_file "${SCENES_DIR}/LocationServicesScene.swift" 'import Foundation

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
'

write_file "${SCENES_DIR}/AnalyticsScene.swift" 'import Foundation

enum AnalyticsScene {
    static let definition = SceneDefinition(
        identifier: "analytics",
        displayName: "Analytics",
        matchKeywords: [
            "share mac analytics with apple",
            "help apple and app developers improve",
            "share crash and usage data with app developers"
        ],
        layout: .checkboxList
    )
}
'

write_file "${SCENES_DIR}/SiriScene.swift" 'import Foundation

enum SiriScene {
    static let definition = SceneDefinition(
        identifier: "siri",
        displayName: "Siri",
        matchKeywords: ["enable ask siri", "hey siri", "siri can help you"],
        layout: .checkboxList
    )
}
'

write_file "${SCENES_DIR}/FileVaultScene.swift" 'import Foundation

enum FileVaultScene {
    static let definition = SceneDefinition(
        identifier: "fileVault",
        displayName: "FileVault",
        matchKeywords: ["filevault", "disk encryption", "turn on filevault"],
        layout: .checkboxList
    )
}
'

write_file "${SCENES_DIR}/TouchIDScene.swift" 'import Foundation

enum TouchIDScene {
    static let definition = SceneDefinition(
        identifier: "touchID",
        displayName: "Touch ID",
        matchKeywords: ["touch id", "add a fingerprint"],
        layout: .infoWithContinue
    )
}
'

write_file "${SCENES_DIR}/AppearanceScene.swift" 'import Foundation

enum AppearanceScene {
    static let definition = SceneDefinition(
        identifier: "appearance",
        displayName: "Appearance",
        matchKeywords: ["choose your look", "select your appearance"],
        layout: .migrationOptions
    )
}
'

write_file "${SCENES_DIR}/MigrationScene.swift" 'import Foundation

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
'

write_file "${SCENES_DIR}/DataPrivacyScene.swift" 'import Foundation

enum DataPrivacyScene {
    static let definition = SceneDefinition(
        identifier: "dataPrivacy",
        displayName: "Data & Privacy",
        matchKeywords: ["data & privacy", "data and privacy"],
        layout: .infoWithContinue
    )
}
'

write_file "${SCENES_DIR}/ScreenTimeScene.swift" 'import Foundation

enum ScreenTimeScene {
    static let definition = SceneDefinition(
        identifier: "screenTime",
        displayName: "Screen Time",
        matchKeywords: ["screen time"],
        layout: .infoWithContinue
    )
}
'

write_file "${SCENES_DIR}/WelcomeScene.swift" 'import Foundation

enum WelcomeScene {
    static let definition = SceneDefinition(
        identifier: "welcome",
        displayName: "Welcome",
        matchKeywords: ["welcome to mac", "you'"'"'re all set"],
        layout: .infoWithContinue
    )
}
'

write_file "${SCENES_DIR}/SoftwareUpdateScene.swift" 'import Foundation

enum SoftwareUpdateScene {
    static let definition = SceneDefinition(
        identifier: "softwareUpdate",
        displayName: "Software Update",
        matchKeywords: ["software update available", "is available and will be"],
        layout: .infoWithContinue
    )
}
'

echo ""
echo "Done."
echo ""
echo "Backups (if any) saved as <filename>.bak next to each original."
echo ""
echo "Next steps in Xcode:"
echo "  1. Switch back to Xcode — it should pick up the file changes automatically."
echo "  2. If you don't already see the files in the navigator, drag the Scenes/"
echo "     folder into the project navigator and confirm 'Add to target:"
echo "     VisionControlScannerApp' is checked."
echo "  3. Product → Clean Build Folder (Shift-Cmd-K), then Build (Cmd-B)."