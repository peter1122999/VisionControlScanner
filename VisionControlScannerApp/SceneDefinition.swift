import Foundation

struct SceneDefinition {
    let identifier: String
    let displayName: String
    let matchKeywords: [String]
    let layout: SceneLayout
    let promoteToButtons: [String]

    /// Position-stable text-field selectors for this scene.
    ///
    /// The detector ships positional labels like `field-1-of-5` and
    /// `left-of-row-3`. This grammar maps those labels (and OCR-recovered
    /// label hints like "Full Name") to a stable selector name your HCL
    /// can target by, e.g. `text_field_by_position = "full_name"` or
    /// `text_field_by_position = "left-of-row-3"`. Empty grammars are
    /// treated as "no positional mapping required for this scene".
    let textFieldSelectors: [SceneTextFieldSelector]

    init(
        identifier: String,
        displayName: String,
        matchKeywords: [String],
        layout: SceneLayout,
        promoteToButtons: [String] = [],
        textFieldSelectors: [SceneTextFieldSelector] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.matchKeywords = matchKeywords
        self.layout = layout
        self.promoteToButtons = promoteToButtons
        self.textFieldSelectors = textFieldSelectors
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

/// One entry in a scene's `text_field_by_position` grammar.
///
/// The detector matches a detected textfield to a selector if ANY of:
///   1. The detected label contains `positional` (e.g. "left-of-row-3"), or
///   2. The detected label contains any string in `labelHints`
///      (case-insensitive, e.g. "Full Name"), or
///   3. The detected (row, column, columnCount) triple matches.
///
/// On match, the selector name is stamped into the textfield label as
/// `[@selector]` so the JSON output carries it verbatim:
///
///     "label": "Full Name (field-1-of-5) [@full_name]"
struct SceneTextFieldSelector: Hashable {
    /// Stable identifier used by HCL (e.g. "full_name", "verify_password").
    let selector: String

    /// Expected positional label produced by `assignPositionalLabels`.
    /// `nil` means "match by hint or (row, col) only".
    let positional: String?

    /// OCR label fragments that should also resolve to this selector.
    let labelHints: [String]

    /// 1-based row index in the form's textfield rows.
    let row: Int

    /// 1-based column within the row.
    let column: Int

    /// Total columns in the row (1 for single-field rows, 2 for siblings).
    let columnCount: Int
}
