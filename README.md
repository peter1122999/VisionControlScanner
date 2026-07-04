# Vision Control Scanner (VCS)

Vision Control Scanner (VCS) is an AI generated Claude slop app meant to improve the control of automated macOS Setup Assistant during Ci/Cd Pipelines. It's screen-understanding toolkit is  used to detect scenes, OCR text, interactive controls, and click targets from screenshots. It includes a desktop app for visual inspection, a CLI for automation pipelines, and Tart/Packer-oriented JSON output for VM provisioning workflows.

VCS is designed for macOS Setup Assistant automation where accessibility APIs may not be available or reliable. It analyzes screenshots with Apple-native Vision/CoreGraphics/AppKit code, classifies the current Setup Assistant scene, and emits structured controls such as text fields, buttons, checkboxes, radio options, toggles, and list-picker rows.

## What VCS Provides

- Desktop inspection app for opening screenshots and visually reviewing detected controls.
- CLI tool for analyzing screenshots from scripts, Packer provisioners, or Tart automation.
- Optional long-lived local server mode for faster repeated screenshot analysis.
- Tart-compatible compact JSON output with pixel-space bounding boxes.
- Scene grammar for macOS Setup Assistant screens.
- Stable text-field selector stamping for form automation.
- Click-safe control centers for interactive glyphs such as checkboxes, radio buttons, toggles, and buttons.
- Setup Assistant-specific fallbacks for tricky OCR/control cases.

## Project Layout

Typical source files:

```text
VisionControlScannerApp/
├── VisionControlScannerApp.swift
├── ContentView.swift
├── Models.swift
├── Utilities.swift
├── ImageScaling.swift
├── SceneDefinition.swift
├── SceneRegistry.swift
├── VisionControlDetector.swift
├── CLI.swift
├── Server.swift
└── Scenes/
    ├── AccessibilityScene.swift
    ├── AnalyticsScene.swift
    ├── AppleAccountSignInScene.swift
    ├── AppearanceScene.swift
    ├── ComputerAccountScene.swift
    ├── CountryRegionScene.swift
    ├── CreateMacAccountScene.swift
    ├── DataPrivacyScene.swift
    ├── FileVaultScene.swift
    ├── KeyboardScene.swift
    ├── LanguageScene.swift
    ├── LocationServicesScene.swift
    ├── MigrationScene.swift
    ├── NoICloudConfirmScene.swift
    ├── ScreenTimeScene.swift
    ├── SiriScene.swift
    ├── SoftwareUpdateScene.swift
    ├── SpokenLanguageScene.swift
    ├── TermsAndConditionsScene.swift
    ├── TimeZoneScene.swift
    ├── TouchIDScene.swift
    ├── WelcomeScene.swift
    ├── WelcomeToYourNewMacScene.swift
    ├── WiFiScene.swift
    └── WrittenLanguageScene.swift
```

## Main Components

### Desktop App

The desktop app is the visual debugging surface for VCS. It lets you open screenshots, run analysis, and inspect detected controls directly over the screenshot.

Use the desktop app when you need to:

- Confirm scene classification.
- Check OCR results.
- Inspect raw detections.
- Confirm text field selector stamping.
- Confirm checkbox/radio/toggle state.
- Confirm the click target is on the interactive glyph, not on the label.
- Debug why Tart/Packer automation clicked the wrong place.

The app displays:

- Setup summary.
- Scene title.
- Subtitle/prompt text.
- Text fields.
- Advance buttons.
- Raw detections.
- Bounding boxes over the screenshot.
- Control labels and confidence scores.

### CLI App

The CLI is the primary automation entry point. It supports screenshot analysis, folder watching, and local server mode.

General usage:

```bash
vcs analyze <image> [-o out.json] [--text] [--compact] [--max-height N | --full-resolution] [--format default|tart]
vcs watch <folder> [-o output-dir] [--max-height N | --full-resolution] [--format default|tart]
vcs serve [--socket /tmp/vcs.sock] [--max-height N]
vcs --help
```

### `analyze`

Analyze one screenshot and print JSON to stdout unless `-o` is provided.

```bash
vcs analyze ~/Desktop/screenshot.png
```

Compact JSON:

```bash
vcs analyze ~/Desktop/screenshot.png --compact
```

Human-readable text output:

```bash
vcs analyze ~/Desktop/screenshot.png --text
```

Tart-compatible output:

```bash
vcs analyze ~/Desktop/screenshot.png --format tart --compact
```

Full-resolution analysis:

```bash
vcs analyze ~/Desktop/screenshot.png --full-resolution
```

Limit working height:

```bash
vcs analyze ~/Desktop/screenshot.png --max-height 720
```

Write output to file:

```bash
vcs analyze ~/Desktop/screenshot.png -o result.json
```

### `watch`

Watch a folder for new screenshots and analyze each new image.

```bash
vcs watch ~/Desktop/ui-artifacts/macos26_local --format tart -o ~/Desktop/vcs-json
```

This is useful when another tool continuously writes screenshots during an automation run.

### `serve`

Run VCS as a local long-lived scanner process.

```bash
vcs serve --socket /tmp/vcs.sock --max-height 720
```

When `/tmp/vcs.sock` exists, `vcs analyze` can delegate to the server automatically. Set `VCS_SOCKET=""` to force local in-process analysis.

```bash
VCS_SOCKET="" vcs analyze ~/Desktop/screenshot.png --format tart --compact
```

## Output Formats

### Default JSON

Default JSON is useful for desktop tooling and detailed debugging. It includes:

- `source`
- `summary`
- `detections`
- normalized bounding boxes
- normalized click points where available

Example:

```bash
vcs analyze ~/Desktop/screenshot.png --compact | jq .
```

### Tart JSON

Tart JSON is intended for VM automation and Packer/Tart runners. It emits pixel-space coordinates with a top-left origin.

Top-level fields:

```json
{
  "source": "...",
  "screen": {
    "width": 1920,
    "height": 1080
  },
  "scene": "Create a Mac Account",
  "controls": [],
  "ocr": []
}
```

Control fields:

```json
{
  "role": "checkbox",
  "label": "Allow computer account password to be reset with your Apple",
  "value": "selected",
  "selected": true,
  "enabled": null,
  "style": null,
  "bbox": {
    "x": 337,
    "y": 318,
    "w": 302,
    "h": 30
  },
  "controlCenter": {
    "x": 411,
    "y": 539
  },
  "click": {
    "x": 411,
    "y": 539
  },
  "confidence": 1.0
}
```

Important:

- `bbox` may include both the interactive glyph and label text.
- `controlCenter` is the intended click target for the actual interactive element.
- `click` mirrors `controlCenter` for runner compatibility.
- Runners should prefer `click`, then `controlCenter`, then fallback to `bbox` center.

Recommended runner click priority:

```go
if control.Click != nil {
    x = control.Click.X
    y = control.Click.Y
} else if control.ControlCenter != nil {
    x = control.ControlCenter.X
    y = control.ControlCenter.Y
} else {
    x = control.BBox.X + control.BBox.W/2
    y = control.BBox.Y + control.BBox.H/2
}
```

## Detected Control Roles

VCS maps internal detections to automation-friendly roles.

| Internal Kind | Tart Role | Notes |
|---|---|---|
| Button | `button` | Includes text buttons and detected/synthetic continue arrows. |
| Checkbox | `checkbox` | Includes selected/unselected state and glyph click target. |
| Radio | `radio` | Physical radio glyph. |
| Option | `option` | Scene-restructured list/radio option row. |
| Switch | `switch` | Toggle switch. |
| TextField | `textfield` | Form fields, often stamped with stable selectors. |
| Text | `text` | OCR text appears under `ocr` in Tart format. |
| Unknown | `unknown` | Fallback role. |

## Scene Grammar

Scenes are defined in `Scenes/*.swift` and registered in `SceneRegistry.swift`.

Each scene has:

- `identifier`
- `displayName`
- `matchKeywords`
- `layout`
- optional `promoteToButtons`
- optional `textFieldSelectors`

Example scene definition pattern:

```swift
enum ExampleScene {
    static let definition = SceneDefinition(
        identifier: "example",
        displayName: "Example",
        matchKeywords: [
            "example setup assistant text"
        ],
        layout: .infoWithContinue,
        promoteToButtons: ["continue"]
    )
}
```

## Scene Layouts

Supported layout categories:

- `.listPicker`
- `.infoCardGrid`
- `.infoWithContinue`
- `.agreement`
- `.checkboxList`
- `.form`
- `.timeZone`
- `.migrationOptions`
- `.thumbnailPicker`
- `.unknown`

The layout controls how raw OCR and detections are filtered or restructured.

For example:

- `.listPicker` converts list rows into selectable options.
- `.migrationOptions` restructures text rows into migration radio options.
- `.thumbnailPicker` restructures avatar/appearance picker options.
- `.form` keeps text fields, buttons, and checkboxes while filtering radio/toggle noise.

## Text Field Selectors

Form scenes can define stable field selectors so automation does not depend on fragile OCR text.

For example, the Create a Mac Account scene can stamp labels like:

```text
Full Name (field-1-of-5) [@full_name]
Account Name (field-2-of-5) [@account_name]
Password (left-of-row-3) [@password]
Verify Password (right-of-row-3) [@verify_password]
Hint (Optional) (field-5-of-5) [@hint]
```

Automation can target:

```hcl
text_field_by_position = "full_name"
text_field_by_position = "account_name"
text_field_by_position = "password"
text_field_by_position = "verify_password"
text_field_by_position = "hint"
```

Selectors are resolved by:

1. positional label match,
2. OCR label hint match,
3. row/column/column-count match.

## Tart / Packer Addons

VCS is intended to be consumed by a Tart/Packer UI automation runner.

Recommended flow:

1. Tart VM boots into macOS Setup Assistant.
2. Runner captures screenshot.
3. Runner calls `vcs-noserver analyze <screenshot> --format tart --compact`.
4. Runner reads `scene` and `controls`.
5. Runner chooses an action based on scene grammar and HCL config.
6. Runner clicks or types using returned `click`, `controlCenter`, or `bbox` fallback.
7. Runner repeats until Setup Assistant completes.

Example verification command:

```bash
vcs-noserver analyze ~/Desktop/ui-Auto-test/ui-artifacts/macos26_local/failure-last-screen.png --format tart --compact \
| jq '.scene, [.controls[] | select(.role=="checkbox" or .role=="textfield" or .role=="button")]'
```

Recommended checkbox verification:

```bash
vcs-noserver analyze ~/Desktop/ui-Auto-test/ui-artifacts/macos26_local/failure-last-screen.png --format tart --compact \
| jq '.controls[] | select(.role=="checkbox")'
```

Expected checkbox output includes:

- `role: "checkbox"`
- useful `label`
- correct `selected`
- `bbox`
- `controlCenter`
- `click`

## Click Target Rules

Automation should not blindly click the center of `bbox`.

For controls with labels, the bounding box may intentionally include both the glyph and the label. This improves matching and debugging, but the midpoint of that full rectangle may land on non-clickable label text.

Always prefer:

1. `click`
2. `controlCenter`
3. `bbox` center

This matters most for:

- checkboxes,
- radio buttons,
- toggles,
- chevron buttons,
- wide labeled controls.

## Create a Mac Account Scene

The Create a Mac Account scene is a `.form` scene. It commonly includes:

- Full Name field
- Account Name field
- Password field
- Verify Password field
- Hint field
- Apple Account reset checkbox
- Continue button

The Apple Account reset checkbox can be difficult to detect because OCR may swallow the checked glyph into the label line or omit the glyph entirely.

VCS includes a scene-specific fallback that synthesizes the checkbox when OCR sees Apple reset text such as:

- `allow computer account password`
- `allow computer account password to be reset`
- `password to be reset`
- `reset with your apple account`
- `use this feature` when Apple reset context exists

The fallback:

- creates a checkbox control from OCR geometry,
- computes a glyph-centered `controlCenter`,
- emits `selected` based on OCR glyph hints and pixel sampling,
- merges/replaces an existing incorrect Apple reset checkbox detection,
- keeps the wide bbox for label matching/debugging.

Selected-state logic:

```text
selected = OCR leading glyph says checked OR pixel sample over glyphRect detects checked blue glyph
```

Recognized OCR checked glyphs:

```text
/
✓
✔
☑
```

The pixel sampler is intentionally scoped to this Apple reset checkbox fallback. Generic checkbox detection is not globally relaxed.

## Common Commands

Analyze a failed Setup Assistant screen:

```bash
vcs-noserver analyze ~/Desktop/ui-Auto-test/ui-artifacts/macos26_local/failure-last-screen.png --format tart --compact | jq .
```

Show only scene and actionable controls:

```bash
vcs-noserver analyze ~/Desktop/ui-Auto-test/ui-artifacts/macos26_local/failure-last-screen.png --format tart --compact \
| jq '{scene, controls: [.controls[] | select(.role=="checkbox" or .role=="textfield" or .role=="button" or .role=="option")]}'
```

Show only text fields:

```bash
vcs-noserver analyze ~/Desktop/ui-Auto-test/ui-artifacts/macos26_local/failure-last-screen.png --format tart --compact \
| jq '.controls[] | select(.role=="textfield")'
```

Show only buttons:

```bash
vcs-noserver analyze ~/Desktop/ui-Auto-test/ui-artifacts/macos26_local/failure-last-screen.png --format tart --compact \
| jq '.controls[] | select(.role=="button")'
```

Show only checkboxes:

```bash
vcs-noserver analyze ~/Desktop/ui-Auto-test/ui-artifacts/macos26_local/failure-last-screen.png --format tart --compact \
| jq '.controls[] | select(.role=="checkbox")'
```

Batch-check common Create a Mac Account screenshots:

```bash
for img in \
  "$HOME/Desktop/ui-Auto-test/ui-artifacts/macos26_local/0026-detect.png" \
  "$HOME/Desktop/ui-Auto-test/ui-artifacts/macos26_local/failure-last-screen.png" \
  "$HOME/Desktop/test22-screens/create-mac-account-unchecked.png"
do
  [ -f "$img" ] || continue
  echo "=== $img ==="
  vcs-noserver analyze "$img" --format tart --compact \
  | jq '{scene, controls: [.controls[] | select(.role=="checkbox" or .role=="textfield" or .role=="button")]}'
done
```

## Installing the CLI

If the built CLI binary is named `vcs`, install it somewhere in `PATH`:

```bash
sudo install -m 0755 vcs /usr/local/bin/vcs
```

If you maintain a no-server alias or wrapper:

```bash
sudo install -m 0755 vcs /usr/local/bin/vcs-noserver
```

If `VisionControlService` or the app bundle is installed under `/Applications`, keep CLI wrappers explicit about which binary is being called.

## Suggested Runner Contract

A Tart/Packer runner consuming VCS should expect:

```json
{
  "scene": "Create a Mac Account",
  "controls": [
    {
      "role": "textfield",
      "label": "Full Name (field-1-of-5) [@full_name]",
      "bbox": { "x": 323, "y": 512, "w": 351, "h": 42 },
      "click": { "x": 498, "y": 533 }
    },
    {
      "role": "checkbox",
      "label": "Allow computer account password to be reset with your Apple",
      "selected": true,
      "bbox": { "x": 337, "y": 318, "w": 302, "h": 30 },
      "click": { "x": 411, "y": 539 }
    },
    {
      "role": "button",
      "label": "Continue",
      "enabled": true,
      "bbox": { "x": 715, "y": 119, "w": 64, "h": 52 },
      "click": { "x": 747, "y": 145 }
    }
  ]
}
```

Runner recommendations:

- Use `scene` to choose the action plan.
- Prefer selector-stamped text fields over raw labels.
- Prefer `click` over `bbox` center.
- Treat `selected` as the source of truth for checkbox/radio/toggle state.
- Re-analyze after every click or typed form submission.
- Keep screenshots and JSON artifacts for failed steps.

## Troubleshooting

### VCS sees checkbox label but clicks the label instead of the square

Cause: runner is using `bbox` midpoint.

Fix: runner should use `click` or `controlCenter` first.

### Checkbox appears visually selected but VCS says `selected=false`

Cause: OCR may not include the leading checked glyph.

Fix: ensure the Apple reset fallback uses pixel sampling over `glyphRect` and merges/replaces any existing incorrect checkbox detection.

### Text fields are detected but labels are wrong

Use scene-specific `textFieldSelectors` and verify stamped selectors in output.

```bash
vcs-noserver analyze <image> --format tart --compact \
| jq '.controls[] | select(.role=="textfield") | .label'
```

### Continue button is disabled even when visually enabled

Check button appearance logic and verify OCR text color/blue fill detection.

```bash
vcs-noserver analyze <image> --format tart --compact \
| jq '.controls[] | select(.role=="button")'
```

### Scene is classified incorrectly

Check OCR text and scene match keywords.

```bash
vcs-noserver analyze <image> --compact | jq '.summary, .detections[] | select(.kind=="Text")'
```

Then adjust the relevant `Scenes/*.swift` file or `SceneRegistry.swift` ordering.

## Development Notes

- Scene registry order matters. More specific scenes should appear before generic scenes.
- Keep fallback logic scoped to the smallest possible scene or OCR signature.
- Avoid relaxing global detectors for one problematic screen.
- Use wide bboxes for semantic matching and explicit click points for interaction.
- Store screenshots and compact JSON from failed builds to reproduce detector issues.
- Prefer complete replacement files during rapid iteration to avoid patch drift.

## Quick Validation Checklist

Before using a new VCS build in Tart/Packer automation:

```bash
vcs-noserver analyze <screenshot> --format tart --compact | jq .scene
vcs-noserver analyze <screenshot> --format tart --compact | jq '.controls[] | select(.role=="textfield")'
vcs-noserver analyze <screenshot> --format tart --compact | jq '.controls[] | select(.role=="checkbox")'
vcs-noserver analyze <screenshot> --format tart --compact | jq '.controls[] | select(.role=="button")'
```

Confirm:

- Scene name is correct.
- Expected text fields are present.
- Expected checkbox/radio/toggle state is correct.
- Every clickable control has `click` or `controlCenter`.
- Continue/Next/Back buttons have correct enabled state.
- Runner prefers `click` over `bbox` center.

## License

Add your project license here.

## Maintainers

Add maintainers/contact info here.
