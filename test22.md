import Foundation
import CoreGraphics
import Vision
import AppKit
import CoreImage

// MARK: - Free-standing model used by the detector pipeline

struct DetectedVisionControl {
    let type: String
    let label: String
    let confidence: Double
    let rect: CGRect
    let selected: Bool?
    /// Pixel-space center of the actual interactive glyph (checkbox square,
    /// radio dot, toggle pill, text-field interior). `nil` for plain text.
    let controlCenter: CGPoint?
    /// "primary" / "secondary" for buttons, else nil.
    let style: String?
}

// MARK: - Public detector

final class VisionControlDetector {

    private var workingFullRGB: RGBImage?

    func analyze(
        cgImage: CGImage,
        maxHeight: Int? = nil
    ) throws -> AnalysisResult {
        let workingFullImage: CGImage
        if let maxHeight {
            workingFullImage = ImageScaling.downscaleIfNeeded(cgImage, maxHeight: maxHeight)
        } else {
            workingFullImage = cgImage
        }
        self.workingFullRGB = makeRGBImage(from: workingFullImage)
        defer { self.workingFullRGB = nil }

        let roi = findSetupCard(in: workingFullImage)
            ?? safetyROI(for: workingFullImage)

        let workingImage = cropImage(workingFullImage, to: roi) ?? workingFullImage
        let roiControls = detectControls(in: workingImage)

        let mapped = roiControls.map { control in
            DetectedVisionControl(
                type: control.type,
                label: control.label,
                confidence: control.confidence,
                rect: control.rect.offsetBy(dx: roi.minX, dy: roi.minY),
                selected: control.selected,
                controlCenter: control.controlCenter.map {
                    CGPoint(x: $0.x + roi.minX, y: $0.y + roi.minY)
                },
                style: control.style
            )
        }

        let scene = classifyScene(controls: mapped)

        let listRestructured = recategorizeAsListOptions(mapped, scene: scene)
        let migrationRestructured = recategorizeAsMigrationOptions(listRestructured, scene: scene)
        let restructured = recategorizeAsThumbnailPicker(migrationRestructured, scene: scene)

        let filtered = applySceneFilter(restructured, scene: scene)
        let stamped = applyTextFieldSelectors(filtered, scene: scene)

        let imageWidth = CGFloat(workingFullImage.width)
        let imageHeight = CGFloat(workingFullImage.height)
        let detections = stamped.map {
            mapToDetection($0, imageWidth: imageWidth, imageHeight: imageHeight)
        }
        let summary = buildSummary(controls: stamped, scene: scene)
        return AnalysisResult(detections: detections, summary: summary)
    }

    // MARK: - Stage 1: Setup card localization

    private func findSetupCard(in image: CGImage) -> CGRect? {
        guard let rgb = makeRGBImage(from: image) else { return nil }
        let width = rgb.width
        let height = rgb.height
        let totalArea = width * height
        let minArea = totalArea / 7
        let maxArea = (totalArea * 9) / 10
        var visited = Array(repeating: false, count: width * height)
        func idx(_ x: Int, _ y: Int) -> Int { y * width + x }
        func isCard(_ p: RGBPixel) -> Bool {
            let maxC = max(p.r, max(p.g, p.b))
            let minC = min(p.r, min(p.g, p.b))
            let spread = Int(maxC) - Int(minC)
            return p.luminance >= 232 && spread <= 22
        }
        var bestRect: CGRect?
        var bestScore: Double = 0
        let seedStride = max(2, min(width, height) / 300)
        var sy = 0
        while sy < height {
            var sx = 0
            while sx < width {
                let seed = idx(sx, sy)
                if !visited[seed],
                   let p = rgb.pixel(x: sx, y: sy),
                   isCard(p) {
                    var stack: [(Int, Int)] = [(sx, sy)]
                    visited[seed] = true
                    var minX = sx, maxX = sx, minY = sy, maxY = sy
                    var count = 0
                    while let current = stack.popLast() {
                        let cx = current.0
                        let cy = current.1
                        count += 1
                        if cx < minX { minX = cx }
                        if cx > maxX { maxX = cx }
                        if cy < minY { minY = cy }
                        if cy > maxY { maxY = cy }
                        let neighbors = [
                            (cx + 1, cy), (cx - 1, cy),
                            (cx, cy + 1), (cx, cy - 1)
                        ]
                        for n in neighbors {
                            let nx = n.0
                            let ny = n.1
                            guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                            let ni = idx(nx, ny)
                            if visited[ni] { continue }
                            visited[ni] = true
                            guard let np = rgb.pixel(x: nx, y: ny),
                                  isCard(np) else { continue }
                            stack.append((nx, ny))
                        }
                    }
                    let bw = maxX - minX + 1
                    let bh = maxY - minY + 1
                    let bboxArea = bw * bh
                    let aspect = Double(bw) / Double(max(bh, 1))
                    let fillRatio = Double(count) / Double(max(bboxArea, 1))
                    if bboxArea >= minArea,
                       bboxArea <= maxArea,
                       aspect >= 0.5, aspect <= 2.8,
                       fillRatio >= 0.55 {
                        let centerX = Double(minX + maxX) / 2.0
                        let centerY = Double(minY + maxY) / 2.0
                        let dx = abs(centerX - Double(width) / 2.0) / Double(width)
                        let dy = abs(centerY - Double(height) / 2.0) / Double(height)
                        let centerBonus = 1.0 - min(1.0, dx + dy)
                        let score = Double(bboxArea) * fillRatio * (0.6 + 0.4 * centerBonus)
                        if score > bestScore {
                            bestScore = score
                            bestRect = CGRect(x: minX, y: minY, width: bw, height: bh)
                        }
                    }
                }
                sx += seedStride
            }
            sy += seedStride
        }
        guard let bestRect else { return nil }
        let pad: CGFloat = 6
        return CGRect(
            x: max(0, bestRect.minX - pad),
            y: max(0, bestRect.minY - pad),
            width: min(CGFloat(width) - max(0, bestRect.minX - pad), bestRect.width + 2 * pad),
            height: min(CGFloat(height) - max(0, bestRect.minY - pad), bestRect.height + 2 * pad)
        )
    }

    private func safetyROI(for image: CGImage) -> CGRect {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let topClip = h * 0.04
        let bottomClip = h * 0.08
        return CGRect(x: 0, y: topClip, width: w, height: max(1, h - topClip - bottomClip))
    }

    private func cropImage(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard clipped.width > 20, clipped.height > 20 else { return nil }
        return image.cropping(to: clipped)
    }

    // MARK: - Stage 4a: Scene classification

    private func classifyScene(controls: [DetectedVisionControl]) -> SceneDefinition? {
        let haystack = controls
            .filter {
                $0.type == "text" ||
                $0.type == "button" ||
                $0.type == "radio-option" ||
                $0.type == "textfield"
            }
            .map { $0.label.lowercased() }
            .joined(separator: " | ")
        return SceneRegistry.classify(haystack: haystack)
    }

    // MARK: - Stage 4b: List-picker restructuring

    private func recategorizeAsListOptions(
        _ controls: [DetectedVisionControl],
        scene: SceneDefinition?
    ) -> [DetectedVisionControl] {
        let isListPicker: Bool
        if let scene {
            isListPicker = scene.layout == .listPicker
        } else {
            isListPicker = looksLikeListPicker(controls)
        }
        guard isListPicker else { return controls }
        guard let selectedRow = controls.first(where: { $0.type == "textfield" }) else {
            return controls
        }
        let rowHeight = max(selectedRow.rect.height, 18)
        var output: [DetectedVisionControl] = []
        for control in controls {
            if control.type == "textfield",
               control.rect == selectedRow.rect {
                output.append(
                    DetectedVisionControl(
                        type: "radio-option",
                        label: control.label,
                        confidence: max(control.confidence, 0.85),
                        rect: control.rect,
                        selected: true,
                        controlCenter: CGPoint(x: control.rect.midX, y: control.rect.midY),
                        style: nil
                    )
                )
                continue
            }
            guard control.type == "text" else {
                output.append(control)
                continue
            }
            let r = control.rect
            let withinPickerColumn =
                r.minX >= selectedRow.rect.minX - 20 &&
                r.maxX <= selectedRow.rect.maxX + 20
            let sameRowHeight =
                r.height <= rowHeight * 1.25 &&
                r.height >= rowHeight * 0.55
            let notOverlapping = !r.intersects(selectedRow.rect)
            guard withinPickerColumn, sameRowHeight, notOverlapping else {
                output.append(control)
                continue
            }
            let isAbove = r.maxY <= selectedRow.rect.minY
            let isBelow = r.minY >= selectedRow.rect.maxY
            let gapAbove = isAbove ? (selectedRow.rect.minY - r.maxY) : .infinity
            let gapBelow = isBelow ? (r.minY - selectedRow.rect.maxY) : .infinity
            let acceptedAbove = isAbove && gapAbove <= rowHeight * 0.6
            let acceptedBelow = isBelow && gapBelow <= rowHeight * 40
            if acceptedAbove || acceptedBelow {
                output.append(
                    DetectedVisionControl(
                        type: "radio-option",
                        label: control.label,
                        confidence: control.confidence,
                        rect: r,
                        selected: false,
                        controlCenter: CGPoint(x: r.midX, y: r.midY),
                        style: nil
                    )
                )
            } else {
                output.append(control)
            }
        }
        return output
    }

    private func looksLikeListPicker(_ controls: [DetectedVisionControl]) -> Bool {
        guard let selectedRow = controls.first(where: { $0.type == "textfield" }) else {
            return false
        }
        let rowHeight = max(selectedRow.rect.height, 18)
        let stackedBelow = controls.filter { c -> Bool in
            guard c.type == "text" else { return false }
            let r = c.rect
            let withinPickerColumn =
                r.minX >= selectedRow.rect.minX - 20 &&
                r.maxX <= selectedRow.rect.maxX + 20
            let isBelow = r.minY >= selectedRow.rect.maxY
            let nearby = (r.minY - selectedRow.rect.maxY) <= rowHeight * 40
            let sameHeight =
                r.height <= rowHeight * 1.25 &&
                r.height >= rowHeight * 0.55
            return withinPickerColumn && isBelow && nearby && sameHeight
        }
        return stackedBelow.count >= 3
    }

    // MARK: - Stage 4b (migration)

    private func recategorizeAsMigrationOptions(
        _ controls: [DetectedVisionControl],
        scene: SceneDefinition?
    ) -> [DetectedVisionControl] {
        guard scene?.layout == .migrationOptions else { return controls }
        let texts = controls
            .filter { $0.type == "text" }
            .sorted { $0.rect.minY < $1.rect.minY }
        guard let header = texts.last(where: {
            $0.label.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        }) else {
            return controls.filter { $0.type != "radio-option" }
        }
        let optionRows = texts.filter {
            $0.rect.minY > header.rect.maxY - 4 &&
            !$0.rect.intersects(header.rect)
        }
        guard optionRows.count >= 2 else {
            return controls.filter { $0.type != "radio-option" }
        }
        let radioColumn = optionRows.map { $0.rect.minX }.min() ?? 0
        let optionRects = Set(optionRows.map { $0.rect })
        var output: [DetectedVisionControl] = []
        for control in controls {
            if control.type == "radio-option" { continue }
            if control.type == "radio" { continue }
            if control.type == "text", optionRects.contains(control.rect) {
                let selected = migrationOptionLooksSelected(
                    optionRect: control.rect,
                    radioColumn: radioColumn,
                    in: workingFullRGB
                )
                let cleanLabel: String = {
                    var s = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
                    while s.hasPrefix("•") || s.hasPrefix("·") || s.hasPrefix("-") {
                        s.removeFirst()
                        s = s.trimmingCharacters(in: .whitespaces)
                    }
                    return s
                }()
                output.append(DetectedVisionControl(
                    type: "radio-option",
                    label: cleanLabel,
                    confidence: max(control.confidence, 0.80),
                    rect: control.rect,
                    selected: selected,
                    controlCenter: CGPoint(x: control.rect.midX, y: control.rect.midY),
                    style: nil
                ))
                continue
            }
            output.append(control)
        }
        return output
    }

    private func migrationOptionLooksSelected(
        optionRect: CGRect,
        radioColumn: CGFloat,
        in image: RGBImage?
    ) -> Bool {
        guard let image else { return false }
        let rowH = max(optionRect.height, 18)
        let sampleRect = CGRect(
            x: radioColumn - rowH * 0.2,
            y: optionRect.midY - rowH * 0.6,
            width: rowH * 1.4,
            height: rowH * 1.2
        )
        let minX = max(0, Int(sampleRect.minX.rounded()))
        let maxX = min(image.width - 1, Int(sampleRect.maxX.rounded()))
        let minY = max(0, Int(sampleRect.minY.rounded()))
        let maxY = min(image.height - 1, Int(sampleRect.maxY.rounded()))
        guard maxX > minX, maxY > minY else { return false }
        var blue = 0
        var total = 0
        for y in minY...maxY {
            for x in minX...maxX {
                guard let p = image.pixel(x: x, y: y) else { continue }
                total += 1
                if p.isBlue { blue += 1 }
            }
        }
        return Double(blue) / Double(max(total, 1)) >= 0.08
    }

    // MARK: - Stage 4c: thumbnail picker + scene filter

    private func recategorizeAsThumbnailPicker(
        _ controls: [DetectedVisionControl],
        scene: SceneDefinition?
    ) -> [DetectedVisionControl] {
        guard scene?.layout == .thumbnailPicker else { return controls }
        guard let rgb = workingFullRGB else { return controls }

        let components = findConnectedComponents(in: rgb)
        let selection = components
            .filter {
                let r = $0.rect
                let aspect = r.width / max(r.height, 1)
                return $0.blueRatio >= 0.30 &&
                       r.width >= 60 && r.height >= 40 &&
                       aspect >= 1.0 && aspect <= 2.0
            }
            .max(by: { $0.pixelCount < $1.pixelCount })

        let texts = controls.filter { $0.type == "text" }
        guard let promptBottom = texts.map({ $0.rect.maxY }).max() else { return controls }
        let candidates = texts
            .filter {
                let r = $0.rect
                let clean = $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                return r.minY > promptBottom * 0.6 &&
                       clean.count <= 14 &&
                       clean.count >= 2 &&
                       !clean.contains(" ")
            }
        guard let yRef = candidates.first?.rect.midY else { return controls }
        let optionRow = candidates.filter { abs($0.rect.midY - yRef) <= 30 }
        guard optionRow.count >= 2 else { return controls }
        let optionRects = Set(optionRow.map { $0.rect })

        var output: [DetectedVisionControl] = []
        for control in controls {
            if control.type == "radio" { continue }
            if control.type == "text" {
                let clean = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.count <= 1 { continue }
            }
            if control.type == "text", optionRects.contains(control.rect) {
                let selected: Bool
                if let sel = selection {
                    let distance = abs(control.rect.midX - sel.rect.midX)
                    let labelWidth = control.rect.width
                    selected = distance <= max(labelWidth, sel.rect.width * 0.6)
                } else {
                    selected = false
                }
                output.append(DetectedVisionControl(
                    type: "radio-option",
                    label: control.label,
                    confidence: max(control.confidence, 0.85),
                    rect: control.rect,
                    selected: selected,
                    controlCenter: CGPoint(x: control.rect.midX, y: control.rect.midY),
                    style: nil
                ))
                continue
            }
            output.append(control)
        }
        return output
    }

    private func applySceneFilter(
        _ controls: [DetectedVisionControl],
        scene: SceneDefinition?
    ) -> [DetectedVisionControl] {
        guard let scene else { return controls }
        let layoutFiltered: [DetectedVisionControl]
        switch scene.layout {
        case .thumbnailPicker:
            layoutFiltered = controls.filter {
                $0.type != "checkbox" && $0.type != "toggle" &&
                $0.type != "radio" && $0.type != "textfield"
            }
        case .listPicker:
            layoutFiltered = controls.filter {
                $0.type != "checkbox" && $0.type != "toggle" &&
                $0.type != "radio" && $0.type != "textfield"
            }
        case .infoCardGrid,
             .infoWithContinue,
             .agreement:
            layoutFiltered = controls.filter {
                $0.type != "radio" && $0.type != "checkbox" &&
                $0.type != "toggle" && $0.type != "textfield"
            }
        case .checkboxList:
            layoutFiltered = controls.filter {
                $0.type != "radio" && $0.type != "toggle" &&
                $0.type != "textfield"
            }
        case .form:
            layoutFiltered = controls.filter {
                $0.type != "radio" && $0.type != "toggle"
            }
        case .timeZone:
            layoutFiltered = controls.filter {
                $0.type != "radio" && $0.type != "checkbox"
            }
        case .migrationOptions:
            layoutFiltered = controls.filter {
                $0.type != "checkbox" && $0.type != "toggle"
            }
        case .unknown:
            layoutFiltered = controls
        }
        guard !scene.promoteToButtons.isEmpty else {
            return layoutFiltered
        }
        return layoutFiltered.map { control in
            guard control.type == "text" else { return control }
            let normalized = control.label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if scene.promoteToButtons.contains(normalized) {
                return DetectedVisionControl(
                    type: "button",
                    label: control.label,
                    confidence: max(control.confidence, 0.75),
                    rect: control.rect,
                    selected: nil,
                    controlCenter: CGPoint(x: control.rect.midX, y: control.rect.midY),
                    style: "secondary"
                )
            }
            return control
        }
    }

    // MARK: - Stage 4d: text_field_by_position selector stamping

    private func applyTextFieldSelectors(
        _ controls: [DetectedVisionControl],
        scene: SceneDefinition?
    ) -> [DetectedVisionControl] {
        guard let scene, !scene.textFieldSelectors.isEmpty else { return controls }

        let textfields = controls.filter { $0.type == "textfield" }
        let rows = groupIntoRows(textfields)

        var rowIndexByRect: [CGRect: (row: Int, col: Int, colCount: Int)] = [:]
        for (rIdx, row) in rows.enumerated() {
            let cols = row.sorted { $0.rect.minX < $1.rect.minX }
            for (cIdx, c) in cols.enumerated() {
                rowIndexByRect[c.rect] = (rIdx + 1, cIdx + 1, cols.count)
            }
        }

        return controls.map { control in
            guard control.type == "textfield" else { return control }
            let label = control.label
            if label.contains("[@") { return control }

            // Score every grammar entry; pick the highest-scoring match. Scoring:
            //   positional substring match           → 100
            //   labelHint substring match            → length of the hint
            //   (row, col, colCount) triple match    → 50
            // First-match-wins caused "Password" hint to swallow "Verify Password"
            // because the substring matches both. Longest-hint-wins eliminates
            // that ambiguity without forcing users to manually order the grammar.
            let triple = rowIndexByRect[control.rect]
            var bestScore = 0
            var match: SceneTextFieldSelector?
            for grammar in scene.textFieldSelectors {
                var score = 0
                if let pos = grammar.positional,
                   label.range(of: pos, options: .caseInsensitive) != nil {
                    score = max(score, 100)
                }
                for hint in grammar.labelHints {
                    if label.range(of: hint, options: .caseInsensitive) != nil {
                        score = max(score, hint.count)
                    }
                }
                if let triple,
                   grammar.row == triple.row,
                   grammar.column == triple.col,
                   grammar.columnCount == triple.colCount {
                    score = max(score, 50)
                }
                if score > bestScore {
                    bestScore = score
                    match = grammar
                }
            }

            guard let match else { return control }

            let newLabel = label.isEmpty
                ? "[@\(match.selector)]"
                : "\(label) [@\(match.selector)]"

            return DetectedVisionControl(
                type: control.type,
                label: newLabel,
                confidence: control.confidence,
                rect: control.rect,
                selected: control.selected,
                controlCenter: control.controlCenter,
                style: control.style
            )
        }
    }

    private func groupIntoRows(
        _ controls: [DetectedVisionControl]
    ) -> [[DetectedVisionControl]] {
        let sorted = controls.sorted { $0.rect.minY < $1.rect.minY }
        var rows: [[DetectedVisionControl]] = []
        for c in sorted {
            if let firstInLastRow = rows.last?.first,
               abs(c.rect.midY - firstInLastRow.rect.midY) <= 18 {
                rows[rows.count - 1].append(c)
            } else {
                rows.append([c])
            }
        }
        return rows
    }

    // MARK: - DetectedVisionControl → Detection

    private func mapToDetection(
        _ control: DetectedVisionControl,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> Detection {
        let kind = mapKind(control.type)
        let normalizedBox = normalizedRect(
            from: control.rect,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let normalizedCenter: CGPoint?
        if let center = control.controlCenter,
           imageWidth > 0, imageHeight > 0 {
            normalizedCenter = CGPoint(
                x: center.x / imageWidth,
                y: 1.0 - (center.y / imageHeight)
            )
        } else {
            normalizedCenter = nil
        }
        let value: String
        if control.type == "button" {
            value = (control.selected == false) ? "disabled" : "enabled"
        } else if let selected = control.selected {
            value = selected ? "selected" : "unselected"
        } else {
            value = control.label
        }
        let cleanLabel = control.label
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Detection(
            kind: kind,
            boundingBox: normalizedBox,
            controlCenter: normalizedCenter,
            value: value,
            confidence: Float(control.confidence),
            label: cleanLabel.isEmpty ? nil : cleanLabel,
            style: control.style
        )
    }

    private func mapKind(_ type: String) -> Detection.Kind {
        switch type {
        case "button":       return .button
        case "checkbox":     return .checkbox
        case "radio":        return .radioButton
        case "radio-option": return .radioOption
        case "toggle":       return .toggleSwitch
        case "text":         return .text
        case "textfield":    return .textField
        default:             return .unknown
        }
    }

    private func normalizedRect(
        from pixelRect: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let normalizedHeight = pixelRect.height / imageHeight
        let normalizedY = 1.0 - (pixelRect.maxY / imageHeight)
        return CGRect(
            x: pixelRect.minX / imageWidth,
            y: normalizedY,
            width: pixelRect.width / imageWidth,
            height: normalizedHeight
        ).clampedToUnit()
    }

    // MARK: - SetupScreenSummary builder

    private func buildSummary(
        controls: [DetectedVisionControl],
        scene: SceneDefinition?
    ) -> SetupScreenSummary {
        let isListPicker = scene?.layout == .listPicker

        let optionRects = controls
            .filter { $0.type == "radio-option" || $0.type == "radio" }
            .map { $0.rect }

        let textControls = controls
            .filter { $0.type == "text" }
            .filter { textRect in
                !optionRects.contains(where: { $0.intersects(textRect.rect) })
            }
            .filter {
                let clean = $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.count >= 2
            }
            .sorted { $0.rect.minY < $1.rect.minY }

        let topText = textControls.first?.label.nilIfEmpty
        let title: String?
        if let scene {
            if let topText {
                title = "[\(scene.displayName)] \(topText)"
            } else {
                title = "[\(scene.displayName)]"
            }
        } else {
            title = topText
        }

        let subtitle: String?
        let prompt: String?
        if isListPicker {
            subtitle = nil
            prompt = nil
        } else {
            subtitle = textControls.dropFirst().first?.label.nilIfEmpty
            prompt = textControls.dropFirst(2).first?.label.nilIfEmpty
        }

        let radios = controls.filter {
            $0.type == "radio" || $0.type == "radio-option"
        }
        let options = radios.map {
            SetupOption(text: $0.label, selected: $0.selected ?? false)
        }

        let buttons = controls
            .filter { $0.type == "button" }
            .map { control -> SetupButton in
                SetupButton(
                    text: control.label,
                    enabled: control.selected ?? true,
                    role: buttonRole(for: control.label)
                )
            }

        let textFields = controls
            .filter { $0.type == "textfield" }
            .sorted { $0.rect.minY < $1.rect.minY }
            .map { SetupTextField(label: $0.label, focused: $0.selected ?? false) }

        return SetupScreenSummary(
            title: title,
            subtitle: subtitle,
            prompt: prompt,
            options: options,
            buttons: buttons,
            textFields: textFields
        )
    }

    private func buttonRole(for label: String) -> SetupButton.Role {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let backKeywords: Set<String> = ["back", "cancel", "previous", "not now",
                                          "disagree", "skip"]
        if backKeywords.contains(normalized) {
            return .back
        }
        let advanceKeywords: Set<String> = [
            "continue", "next", "done", "finish", "ok",
            "agree", "accept", "allow", "install", "submit",
            "save", "start", "create", "open", "setup", "yes",
            "→", "next →"
        ]
        if advanceKeywords.contains(normalized) {
            return .advance
        }
        return .secondary
    }

    // MARK: - Pipeline

    func detectControls(in image: CGImage) -> [DetectedVisionControl] {
        let rawLabels = recognizeText(in: image)
        let rgb = makeRGBImage(from: image)

        let labels = dropChevronOCRGarbage(
            labels: rawLabels,
            imageWidth: image.width,
            imageHeight: image.height
        )

        var controls: [DetectedVisionControl] = []

        if let rgb,
           let chevron = detectChevronButton(in: rgb) {
            controls.append(chevron)
        }

        if let rgb {
            controls.append(contentsOf: detectTextFields(
                originalImage: image,
                in: rgb,
                labels: labels
            ))
        }
        controls.append(contentsOf: classifyTextControls(labels, image: rgb))

        if let rgb {
            let components = findConnectedComponents(in: rgb)
            controls.append(contentsOf: detectRadioButtons(
                in: rgb, components: components, labels: labels))
            controls.append(contentsOf: detectToggles(
                in: rgb, components: components, labels: labels))
            controls.append(contentsOf: detectCheckboxes(
                in: rgb, components: components, labels: labels))
            controls.append(contentsOf: detectArrowContinueButton(
                in: rgb, components: components, existingControls: controls))
        }

        var merged = mergeControls(controls)

        let hasButton = merged.contains { $0.type == "button" }
        if !hasButton, sceneRequiresNextChevron(ocrLabels: labels.map { $0.text }) {
            merged.append(syntheticChevronButton(
                imageWidth: image.width,
                imageHeight: image.height
            ))
        }
        return merged
    }

    // MARK: - OCR

    private struct TextLabel {
        let text: String
        let confidence: Double
        let rect: CGRect
    }

    private func recognizeText(in image: CGImage) -> [TextLabel] {
        var output: [TextLabel] = []
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            let width = CGFloat(image.width)
            let height = CGFloat(image.height)
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let rect = CGRect(
                    x: observation.boundingBox.minX * width,
                    y: (1.0 - observation.boundingBox.maxY) * height,
                    width: observation.boundingBox.width * width,
                    height: observation.boundingBox.height * height
                )
                output.append(TextLabel(
                    text: text,
                    confidence: Double(candidate.confidence),
                    rect: rect
                ))
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        return mergeNearbyText(output)
    }

    private func mergeNearbyText(_ labels: [TextLabel]) -> [TextLabel] {
        guard !labels.isEmpty else { return [] }
        let sorted = labels.sorted {
            if abs($0.rect.midY - $1.rect.midY) < 10 {
                return $0.rect.minX < $1.rect.minX
            }
            return $0.rect.minY < $1.rect.minY
        }
        var merged: [TextLabel] = []
        for label in sorted {
            guard let last = merged.last else {
                merged.append(label)
                continue
            }
            let sameLine = abs(last.rect.midY - label.rect.midY) < 10
            let close = label.rect.minX - last.rect.maxX < 28
            if sameLine && close {
                _ = merged.popLast()
                merged.append(TextLabel(
                    text: "\(last.text) \(label.text)",
                    confidence: max(last.confidence, label.confidence),
                    rect: last.rect.union(label.rect)
                ))
            } else {
                merged.append(label)
            }
        }
        return merged
    }

    // MARK: - RGB

    private struct RGBPixel {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
        var luminance: Double {
            0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        }
        var isDark: Bool { luminance < 90 }
        var isBlue: Bool {
            Double(b) > 135 &&
            Double(b) > Double(r) * 1.25 &&
            Double(b) > Double(g) * 1.02
        }
        var isGreen: Bool {
            Double(g) > 120 &&
            Double(g) > Double(r) * 1.18 &&
            Double(g) > Double(b) * 1.02
        }
        /// macOS system blue (~RGB 0,122,255) used for filled checkboxes,
        /// primary buttons, and focused borders.
        var isSystemBlue: Bool {
            let rd = Double(r), gd = Double(g), bd = Double(b)
            return bd >= 180 &&
                   bd > rd * 1.6 &&
                   bd > gd * 1.25 &&
                   rd <= 100
        }
        /// White / near-white interior pixel (checkmark glyph, button fill).
        var isNearWhite: Bool { luminance >= 235 }
        /// Thin gray checkbox border (~RGB 200,200,200).
        var isCheckboxEmptyBorder: Bool {
            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let spread = Int(maxC) - Int(minC)
            return luminance >= 180 && luminance <= 222 && spread <= 15
        }
        var isTextFieldBorder: Bool {
            let maxChannel = max(r, max(g, b))
            let minChannel = min(r, min(g, b))
            let spread = Int(maxChannel) - Int(minChannel)
            let palePalette =
                luminance >= 215 && luminance <= 250 && spread <= 14
            let neutralLightGray =
                luminance >= 170 && luminance <= 215 && spread <= 24
            let focusBlue =
                Double(b) > 145 &&
                Double(b) > Double(r) * 1.20 &&
                Double(b) > Double(g) * 1.02
            return palePalette || neutralLightGray || focusBlue
        }
        var isTextFieldInterior: Bool { luminance >= 238 }
        var isControlLike: Bool { isDark || isBlue || isGreen }
        var isChevronStroke: Bool {
            let lum = luminance
            guard lum >= 55, lum <= 165 else { return false }
            let maxChannel = max(r, max(g, b))
            let minChannel = min(r, min(g, b))
            let spread = Int(maxChannel) - Int(minChannel)
            return spread <= 22
        }
    }

    private struct RGBImage {
        let width: Int
        let height: Int
        let pixels: [RGBPixel]
        func pixel(x: Int, y: Int) -> RGBPixel? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            return pixels[y * width + x]
        }
    }

    private func makeRGBImage(from image: CGImage) -> RGBImage? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var raw = Array(repeating: UInt8(0), count: height * bytesPerRow)
        guard let context = CGContext(
            data: &raw,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var pixels: [RGBPixel] = []
        pixels.reserveCapacity(width * height)
        var index = 0
        while index + 3 < raw.count {
            pixels.append(RGBPixel(
                r: raw[index],
                g: raw[index + 1],
                b: raw[index + 2],
                a: raw[index + 3]
            ))
            index += 4
        }
        return RGBImage(width: width, height: height, pixels: pixels)
    }

    // MARK: - Components

    private struct ConnectedComponent {
        let rect: CGRect
        let pixelCount: Int
        let fillRatio: Double
        let darkRatio: Double
        let blueRatio: Double
        let greenRatio: Double
    }

    private func findConnectedComponents(in image: RGBImage) -> [ConnectedComponent] {
        let width = image.width
        let height = image.height
        var visited = Array(repeating: false, count: width * height)
        func index(_ x: Int, _ y: Int) -> Int { y * width + x }

        var components: [ConnectedComponent] = []
        for y in 0..<height {
            for x in 0..<width {
                let start = index(x, y)
                if visited[start] { continue }
                visited[start] = true
                guard let startPixel = image.pixel(x: x, y: y),
                      startPixel.isControlLike else { continue }

                var stack: [(Int, Int)] = [(x, y)]
                var minX = x, maxX = x, minY = y, maxY = y
                var count = 0, dark = 0, blue = 0, green = 0
                while let current = stack.popLast() {
                    let cx = current.0
                    let cy = current.1
                    guard let pixel = image.pixel(x: cx, y: cy) else { continue }
                    count += 1
                    if pixel.isDark { dark += 1 }
                    if pixel.isBlue { blue += 1 }
                    if pixel.isGreen { green += 1 }
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)
                    let neighbors = [
                        (cx + 1, cy), (cx - 1, cy),
                        (cx, cy + 1), (cx, cy - 1)
                    ]
                    for neighbor in neighbors {
                        let nx = neighbor.0
                        let ny = neighbor.1
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let ni = index(nx, ny)
                        if visited[ni] { continue }
                        visited[ni] = true
                        guard let nextPixel = image.pixel(x: nx, y: ny),
                              nextPixel.isControlLike else { continue }
                        stack.append((nx, ny))
                    }
                }

                let componentWidth = maxX - minX + 1
                let componentHeight = maxY - minY + 1
                guard componentWidth >= 4, componentHeight >= 4, count >= 8 else { continue }
                let area = componentWidth * componentHeight
                let fillRatio = Double(count) / Double(max(area, 1))
                components.append(ConnectedComponent(
                    rect: CGRect(x: minX, y: minY, width: componentWidth, height: componentHeight),
                    pixelCount: count,
                    fillRatio: fillRatio,
                    darkRatio: Double(dark) / Double(max(count, 1)),
                    blueRatio: Double(blue) / Double(max(count, 1)),
                    greenRatio: Double(green) / Double(max(count, 1))
                ))
            }
        }
        return components
    }

    // MARK: - Chevron "Next" Button Detection

    private struct ChevronCandidate {
        let rect: CGRect
        let pixelCount: Int
        let fillRatio: Double
        let pointinessScore: Double
        let confidence: Double
    }

    private func chevronSearchRegion(imageWidth: Int, imageHeight: Int) -> CGRect {
        let w = CGFloat(imageWidth)
        let h = CGFloat(imageHeight)
        let xStart = w * 0.72
        let yStart = h * 0.55
        return CGRect(
            x: xStart,
            y: yStart,
            width: w - xStart,
            height: h - yStart
        )
        .intersection(CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func detectChevronButton(in image: RGBImage) -> DetectedVisionControl? {
        let region = chevronSearchRegion(
            imageWidth: image.width,
            imageHeight: image.height
        )
        let candidates = findChevronCandidates(in: image, region: region)

        guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else {
            return nil
        }

        let padded = best.rect.insetBy(dx: -6, dy: -6)
        let glyphCenter = CGPoint(x: best.rect.midX, y: best.rect.midY)
        return DetectedVisionControl(
            type: "button",
            label: "→",
            confidence: best.confidence,
            rect: padded,
            selected: true,
            controlCenter: glyphCenter,
            style: "secondary"
        )
    }

    private func findChevronCandidates(
        in image: RGBImage,
        region: CGRect
    ) -> [ChevronCandidate] {
        let minX = max(0, Int(region.minX.rounded()))
        let maxX = min(image.width - 1, Int(region.maxX.rounded()))
        let minY = max(0, Int(region.minY.rounded()))
        let maxY = min(image.height - 1, Int(region.maxY.rounded()))
        guard maxX > minX, maxY > minY else { return [] }

        var visited = Array(repeating: false, count: image.width * image.height)
        func index(_ x: Int, _ y: Int) -> Int { y * image.width + x }

        var candidates: [ChevronCandidate] = []

        for y in minY...maxY {
            for x in minX...maxX {
                let startIdx = index(x, y)
                if visited[startIdx] { continue }
                visited[startIdx] = true
                guard let startPixel = image.pixel(x: x, y: y),
                      startPixel.isChevronStroke else { continue }

                var stack: [(Int, Int)] = [(x, y)]
                var componentMinX = x
                var componentMaxX = x
                var componentMinY = y
                var componentMaxY = y
                var count = 0
                var spanPerX: [Int: (minY: Int, maxY: Int)] = [:]

                while let current = stack.popLast() {
                    let cx = current.0
                    let cy = current.1
                    guard let p = image.pixel(x: cx, y: cy),
                          p.isChevronStroke else { continue }
                    count += 1
                    if componentMinX > cx { componentMinX = cx }
                    if componentMaxX < cx { componentMaxX = cx }
                    if componentMinY > cy { componentMinY = cy }
                    if componentMaxY < cy { componentMaxY = cy }

                    if let existing = spanPerX[cx] {
                        spanPerX[cx] = (
                            min(existing.minY, cy),
                            max(existing.maxY, cy)
                        )
                    } else {
                        spanPerX[cx] = (cy, cy)
                    }

                    let neighbors = [
                        (cx + 1, cy), (cx - 1, cy),
                        (cx, cy + 1), (cx, cy - 1),
                        (cx + 1, cy + 1), (cx - 1, cy + 1),
                        (cx + 1, cy - 1), (cx - 1, cy - 1)
                    ]
                    for n in neighbors {
                        let nx = n.0
                        let ny = n.1
                        guard nx >= minX, ny >= minY,
                              nx <= maxX, ny <= maxY else { continue }
                        let ni = index(nx, ny)
                        if visited[ni] { continue }
                        visited[ni] = true
                        guard let np = image.pixel(x: nx, y: ny),
                              np.isChevronStroke else { continue }
                        stack.append((nx, ny))
                    }
                }

                let width = componentMaxX - componentMinX + 1
                let height = componentMaxY - componentMinY + 1
                guard width >= 10, width <= 40,
                      height >= 10, height <= 38,
                      count >= 8 else { continue }
                let aspect = Double(width) / Double(max(height, 1))
                guard aspect >= 0.55, aspect <= 1.6 else { continue }
                let fillRatio = Double(count) / Double(max(width * height, 1))
                guard fillRatio >= 0.10, fillRatio <= 0.45 else { continue }

                let pointiness = pointinessScore(
                    spanPerX: spanPerX,
                    minX: componentMinX,
                    maxX: componentMaxX,
                    minY: componentMinY,
                    maxY: componentMaxY
                )
                guard pointiness >= 0.45 else { continue }

                let rect = CGRect(
                    x: componentMinX,
                    y: componentMinY,
                    width: width,
                    height: height
                )
                let confidence = chevronConfidence(
                    fillRatio: fillRatio,
                    aspect: aspect,
                    pointiness: pointiness,
                    pixelCount: count
                )
                candidates.append(ChevronCandidate(
                    rect: rect,
                    pixelCount: count,
                    fillRatio: fillRatio,
                    pointinessScore: pointiness,
                    confidence: confidence
                ))
            }
        }
        return candidates
    }

    private func pointinessScore(
        spanPerX: [Int: (minY: Int, maxY: Int)],
        minX: Int,
        maxX: Int,
        minY: Int,
        maxY: Int
    ) -> Double {
        guard let leftSpan = spanPerX[minX],
              let rightSpan = spanPerX[maxX] else { return 0 }
        let leftHeight = Double(leftSpan.maxY - leftSpan.minY + 1)
        let rightHeight = Double(rightSpan.maxY - rightSpan.minY + 1)
        let totalHeight = Double(maxY - minY + 1)
        guard totalHeight > 0 else { return 0 }
        let leftRatio = leftHeight / totalHeight
        let rightRatio = rightHeight / totalHeight
        if leftRatio >= 0.55 && rightRatio <= 0.45 {
            return min(1.0, leftRatio - rightRatio + 0.4)
        }
        return 0
    }

    private func chevronConfidence(
        fillRatio: Double,
        aspect: Double,
        pointiness: Double,
        pixelCount: Int
    ) -> Double {
        let fillScore = 1.0 - abs(fillRatio - 0.20) / 0.20
        let aspectScore = 1.0 - abs(aspect - 1.0) / 1.0
        let sizeScore = min(1.0, Double(pixelCount) / 60.0)
        let raw =
            (pointiness * 0.45) +
            (max(0, fillScore) * 0.25) +
            (max(0, aspectScore) * 0.15) +
            (sizeScore * 0.15)
        return min(0.93, max(0.60, raw))
    }

    // MARK: - Chevron OCR garbage filter

    private func dropChevronOCRGarbage(
        labels: [TextLabel],
        imageWidth: Int,
        imageHeight: Int
    ) -> [TextLabel] {
        let region = chevronSearchRegion(
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let garbageFragments: [String] = [
            "9x", "x (*)", "x(*)", "x (7)", "x(7)",
            "(*)", "(7)"
        ]
        return labels.filter { label in
            guard region.intersects(label.rect) else { return true }
            let raw = label.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = raw.lowercased()
            if raw.count <= 2 { return false }
            for fragment in garbageFragments {
                if normalized.contains(fragment) { return false }
            }
            let alphaCount = raw.unicodeScalars.filter {
                CharacterSet.letters.contains($0)
            }.count
            let alphaRatio = Double(alphaCount) / Double(max(raw.count, 1))
            if alphaRatio < 0.3 { return false }
            return true
        }
    }

    private func sceneRequiresNextChevron(ocrLabels: [String]) -> Bool {
        let triggers: [String] = [
            "language",
            "select your language",
            "country",
            "country or region",
            "select your country",
            "written language",
            "spoken language",
            "wi-fi",
            "select a wi-fi",
            "select your wi-fi"
        ]
        for raw in ocrLabels {
            let normalized = raw.lowercased()
            for trigger in triggers {
                if normalized.contains(trigger) { return true }
            }
        }
        return false
    }

    private func syntheticChevronButton(
        imageWidth: Int,
        imageHeight: Int
    ) -> DetectedVisionControl {
        let w = CGFloat(imageWidth)
        let h = CGFloat(imageHeight)
        let glyphW: CGFloat = 28
        let glyphH: CGFloat = 26
        let x = max(0, w - 24 - glyphW)
        let y = max(0, h - 24 - glyphH)
        let rect = CGRect(x: x, y: y, width: glyphW, height: glyphH)
        return DetectedVisionControl(
            type: "button",
            label: "→",
            confidence: 0.55,
            rect: rect,
            selected: true,
            controlCenter: CGPoint(x: rect.midX, y: rect.midY),
            style: "secondary"
        )
    }

    // MARK: - Text Controls

    private func classifyTextControls(
        _ labels: [TextLabel],
        image: RGBImage?
    ) -> [DetectedVisionControl] {
        labels.map { label in
            let type = classifyTextType(label.text)

            let selected: Bool?
            let style: String?
            if type == "button", let image {
                let app = buttonAppearance(textRect: label.rect, image: image)
                selected = app.enabled
                style = app.style
            } else {
                selected = nil
                style = nil
            }
            let center: CGPoint? = (type == "button")
                ? CGPoint(x: label.rect.midX, y: label.rect.midY) : nil

            return DetectedVisionControl(
                type: type,
                label: label.text,
                confidence: label.confidence,
                rect: label.rect.insetBy(dx: -12, dy: -8),
                selected: selected,
                controlCenter: center,
                style: style
            )
        }
    }

    /// Returns (enabled, style) for a button rect. The text-color check is
    /// the only reliable signal for disabled buttons on macOS 26 SA, which
    /// uses identical button geometry for both states.
    private func buttonAppearance(
        textRect: CGRect,
        image: RGBImage
    ) -> (enabled: Bool, style: String) {
        let bg = textRect.insetBy(dx: -6, dy: -4)
        let bgMinX = max(0, Int(bg.minX.rounded()))
        let bgMaxX = min(image.width - 1, Int(bg.maxX.rounded()))
        let bgMinY = max(0, Int(bg.minY.rounded()))
        let bgMaxY = min(image.height - 1, Int(bg.maxY.rounded()))
        guard bgMaxX > bgMinX, bgMaxY > bgMinY else { return (true, "secondary") }

        var veryDark = 0
        var lightInk = 0
        var whiteText = 0
        var bluePixels = 0
        var total = 0

        for y in bgMinY...bgMaxY {
            for x in bgMinX...bgMaxX {
                guard let pixel = image.pixel(x: x, y: y) else { continue }
                total += 1
                let lum = pixel.luminance
                if pixel.isSystemBlue { bluePixels += 1 }
                if lum < 60 { veryDark += 1 }
                else if lum >= 235 { whiteText += 1 }
                else if lum < 220 { lightInk += 1 }
            }
        }
        guard total > 0 else { return (true, "secondary") }

        let blueRatio  = Double(bluePixels) / Double(total)
        let darkRatio  = Double(veryDark)   / Double(total)
        let lightRatio = Double(lightInk)   / Double(total)
        let whiteRatio = Double(whiteText)  / Double(total)

        if blueRatio >= 0.25 && whiteRatio >= 0.02 {
            return (true, "primary")
        }
        if darkRatio >= 0.03 {
            return (true, "secondary")
        }
        if lightRatio >= 0.04 {
            return (false, "secondary")
        }
        return (true, "secondary")
    }

    private func classifyTextType(_ text: String) -> String {
        var normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "⌄", with: "")
            .replacingOccurrences(of: "▾", with: "")
            .replacingOccurrences(of: "›", with: "")
            .replacingOccurrences(of: "ˇ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let lastSpace = normalized.lastIndex(of: " "),
           normalized.distance(from: lastSpace, to: normalized.endIndex) == 2 {
            let tail = normalized[normalized.index(after: lastSpace)...]
            if ["v", "y", "u", "w"].contains(String(tail)) {
                normalized = String(normalized[..<lastSpace])
            }
        }
        let exactButtons: Set<String> = [
            "ok", "yes", "no", "done", "next", "back", "skip",
            "cancel", "close", "allow", "deny", "install",
            "continue", "submit", "save", "open", "choose",
            "setup", "finish", "agree", "accept", "decline",
            "create", "start", "stop", "retry", "disagree",
            "not now", "browse"
        ]
        if exactButtons.contains(normalized) {
            return "button"
        }
        let prefixButtons: [String] = [
            "other sign-in options",
            "use existing apple account",
            "set up later",
            "set up without an apple account",
            "don't sign in",
            "create new apple account",
            "forgot password",
            "skip sign in",
            "see how your data is managed"
        ]
        for p in prefixButtons {
            if normalized.hasPrefix(p) { return "button" }
        }
        return "text"
    }

    // MARK: - Text Fields

    private func detectTextFields(
        originalImage: CGImage,
        in image: RGBImage,
        labels: [TextLabel]
    ) -> [DetectedVisionControl] {
        var horizontalRuns = findTextFieldHorizontalRuns(in: image)

        if horizontalRuns.count <= 2,
           let amplifiedCG = amplifyTextFieldBorders(originalImage),
           let amplifiedRGB = makeRGBImage(from: amplifiedCG) {
            let extra = findTextFieldHorizontalRuns(in: amplifiedRGB)
            horizontalRuns = collapseNearbyRuns(horizontalRuns + extra)
        }

        let rects = pairRunsByColumn(horizontalRuns, image: image)

        let controls = rects.compactMap { rect -> DetectedVisionControl? in
            guard textFieldInteriorLooksValid(rect, image: image) else { return nil }
            let label = bestTextFieldLabel(for: rect, labels: labels)
            let detectedLabel = label?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalLabel = (detectedLabel?.isEmpty == false) ? detectedLabel! : ""
            return DetectedVisionControl(
                type: "textfield",
                label: finalLabel,
                confidence: max(label?.confidence ?? 0.78, 0.78),
                rect: rect.insetBy(dx: -4, dy: -4),
                selected: textFieldLooksFocused(rect, image: image),
                controlCenter: CGPoint(x: rect.midX, y: rect.midY),
                style: nil
            )
        }
        

        let aligned = alignSiblingTextFieldsByRow(controls)
        let deduped = dedupeTextFieldsKeepingSiblings(aligned)
        return assignPositionalLabels(deduped)
    }
    /// If two textfields belong to the same visual row (their vertical
    /// centers are within 18 px), force them to use the median top/bottom
    /// of the row so a sibling whose top got "stretched up" by a stray
    /// caption-line run collapses back to its true bounds.
    private func alignSiblingTextFieldsByRow(
        _ controls: [DetectedVisionControl]
    ) -> [DetectedVisionControl] {
        guard controls.count >= 2 else { return controls }
        var output = controls
        var changed = true

        // Iterate until stable — one snap can expose another sibling pair.
        while changed {
            changed = false
            for i in 0..<output.count {
                for j in (i + 1)..<output.count {
                    let a = output[i].rect
                    let b = output[j].rect

                    // 1. X-adjacent: one ends near the other's start, no
                    //    significant horizontal overlap.
                    let leftRect  = a.minX < b.minX ? a : b
                    let rightRect = a.minX < b.minX ? b : a
                    let xGap = rightRect.minX - leftRect.maxX
                    guard xGap >= -10, xGap <= 40 else { continue }

                    // 2. Y ranges overlap by at least 4 px.
                    let yOverlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
                    guard yOverlap >= 4 else { continue }

                    // 3. Trust the smaller box — too-tall boxes come from
                    //    pairing with a stray caption-line run.
                    let smaller = a.height <= b.height ? a : b
                    let snapY = smaller.minY
                    let snapH = smaller.height

                    // Skip if both already match.
                    if abs(a.minY - snapY) < 1, abs(a.height - snapH) < 1,
                       abs(b.minY - snapY) < 1, abs(b.height - snapH) < 1 {
                        continue
                    }

                    let newA = CGRect(x: a.minX, y: snapY, width: a.width, height: snapH)
                    let newB = CGRect(x: b.minX, y: snapY, width: b.width, height: snapH)

                    output[i] = DetectedVisionControl(
                        type: output[i].type,
                        label: output[i].label,
                        confidence: output[i].confidence,
                        rect: newA,
                        selected: output[i].selected,
                        controlCenter: CGPoint(x: newA.midX, y: newA.midY),
                        style: output[i].style
                    )
                    output[j] = DetectedVisionControl(
                        type: output[j].type,
                        label: output[j].label,
                        confidence: output[j].confidence,
                        rect: newB,
                        selected: output[j].selected,
                        controlCenter: CGPoint(x: newB.midX, y: newB.midY),
                        style: output[j].style
                    )
                    changed = true
                }
            }
        }
        return output
    }
    private func amplifyTextFieldBorders(_ cgImage: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)

        let color = CIFilter(name: "CIColorControls")!
        color.setValue(ci, forKey: kCIInputImageKey)
        color.setValue(1.5, forKey: kCIInputContrastKey)
        color.setValue(0.0, forKey: kCIInputBrightnessKey)
        color.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let contrasted = color.outputImage else { return nil }

        let sharpen = CIFilter(name: "CIUnsharpMask")!
        sharpen.setValue(contrasted, forKey: kCIInputImageKey)
        sharpen.setValue(1.2, forKey: kCIInputRadiusKey)
        sharpen.setValue(0.8, forKey: kCIInputIntensityKey)
        guard let sharpened = sharpen.outputImage else { return nil }

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(sharpened, from: sharpened.extent)
    }

    private struct HorizontalRun {
        let y: Int
        let minX: Int
        let maxX: Int
        var width: Int { maxX - minX + 1 }
        var rect: CGRect { CGRect(x: minX, y: y, width: width, height: 1) }
    }

    private func findTextFieldHorizontalRuns(in image: RGBImage) -> [HorizontalRun] {
        var runs: [HorizontalRun] = []
        for y in 0..<image.height {
            var x = 0
            while x < image.width {
                guard let pixel = image.pixel(x: x, y: y),
                      pixel.isTextFieldBorder else {
                    x += 1
                    continue
                }
                let startX = x
                var endX = x
                var allowedGap = 0
                var borderPixels = 0
                while x < image.width {
                    guard let current = image.pixel(x: x, y: y) else { break }
                    if current.isTextFieldBorder {
                        endX = x
                        borderPixels += 1
                        allowedGap = 0
                    } else if allowedGap < 6 {
                        allowedGap += 1
                    } else {
                        break
                    }
                    x += 1
                }
                let width = endX - startX + 1
                let density = Double(borderPixels) / Double(max(width, 1))
                if width >= 160,
                   width <= min(image.width - 40, 900),
                   density >= 0.42 {
                    runs.append(HorizontalRun(y: y, minX: startX, maxX: endX))
                }
            }
        }
        return collapseNearbyRuns(runs)
    }

    private func collapseNearbyRuns(_ runs: [HorizontalRun]) -> [HorizontalRun] {
        guard !runs.isEmpty else { return [] }
        let sorted = runs.sorted {
            if abs($0.y - $1.y) <= 2 { return $0.minX < $1.minX }
            return $0.y < $1.y
        }
        var output: [HorizontalRun] = []
        for run in sorted {
            if let last = output.last,
               abs(last.y - run.y) <= 2,
                              last.maxX >= run.minX - 4,
                              last.minX <= run.maxX + 4,
                              abs(last.minX - run.minX) <= 12,
                              abs(last.maxX - run.maxX) <= 12 {
                               let merged = HorizontalRun(
                                   y: min(last.y, run.y),
                                   minX: min(last.minX, run.minX),
                                   maxX: max(last.maxX, run.maxX)
                               )
                               output.removeLast()
                               output.append(merged)
                           } else {
                               output.append(run)
                           }
                       }
                       return output
                   }

                   private func pairRunsByColumn(
                       _ runs: [HorizontalRun],
                       image: RGBImage
                   ) -> [CGRect] {
                       guard !runs.isEmpty else { return [] }

                       let byXThenY = runs.sorted {
                           if $0.minX == $1.minX { return $0.y < $1.y }
                           return $0.minX < $1.minX
                       }
                       var columns: [[HorizontalRun]] = []
                       for run in byXThenY {
                           let matchIdx = columns.firstIndex { col in
                               col.contains { other in runsShareColumn(other, run) }
                           }
                           if let i = matchIdx {
                               columns[i].append(run)
                           } else {
                               columns.append([run])
                           }
                       }

                       var rects: [CGRect] = []
                       for col in columns {
                           let byY = col.sorted { $0.y < $1.y }
                           var consumed = Array(repeating: false, count: byY.count)

                           for i in 0..<byY.count where !consumed[i] {
                               let top = byY[i]
                               for j in (i + 1)..<byY.count where !consumed[j] {
                                   let bottom = byY[j]
                                   let h = bottom.y - top.y + 1
                                   if h < 18 { continue }
                                   if h > 42 { break }
                                   let leftDelta = abs(top.minX - bottom.minX)
                                   let rightDelta = abs(top.maxX - bottom.maxX)
                                   let widthDelta = abs(top.width - bottom.width)
                                   guard leftDelta <= 18,
                                         rightDelta <= 18,
                                         widthDelta <= 28 else { continue }
                                   let minX = min(top.minX, bottom.minX)
                                   let maxX = max(top.maxX, bottom.maxX)
                                   let rect = CGRect(
                                       x: minX, y: top.y,
                                       width: maxX - minX + 1, height: h
                                   )
                                   guard verticalTextFieldEdgesLookValid(rect, image: image) else { continue }
                                   rects.append(rect)
                                   consumed[i] = true
                                   consumed[j] = true
                                   break
                               }
                           }
                       }
                       return rects
                   }

                   private func runsShareColumn(_ a: HorizontalRun, _ b: HorizontalRun) -> Bool {
                       let overlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX) + 1)
                       let smallerWidth = min(a.width, b.width)
                       guard smallerWidth > 0 else { return false }
                       return Double(overlap) / Double(smallerWidth) >= 0.70
                   }

                   private func verticalTextFieldEdgesLookValid(_ rect: CGRect, image: RGBImage) -> Bool {
                       let minX = max(0, Int(rect.minX.rounded()))
                       let maxX = min(image.width - 1, Int(rect.maxX.rounded()))
                       let minY = max(0, Int(rect.minY.rounded()))
                       let maxY = min(image.height - 1, Int(rect.maxY.rounded()))
                       guard maxY > minY, maxX > minX else { return false }
                       var leftHits = 0, rightHits = 0, total = 0
                       for y in minY...maxY {
                           total += 1
                           let leftRange = max(0, minX - 3)...min(image.width - 1, minX + 8)
                           let rightRange = max(0, maxX - 8)...min(image.width - 1, maxX + 3)
                           if leftRange.contains(where: { x in
                               image.pixel(x: x, y: y)?.isTextFieldBorder == true
                           }) { leftHits += 1 }
                           if rightRange.contains(where: { x in
                               image.pixel(x: x, y: y)?.isTextFieldBorder == true
                           }) { rightHits += 1 }
                       }
                       let leftRatio = Double(leftHits) / Double(max(total, 1))
                       let rightRatio = Double(rightHits) / Double(max(total, 1))
                       return leftRatio >= 0.12 && rightRatio >= 0.12
                   }

                   private func textFieldInteriorLooksValid(_ rect: CGRect, image: RGBImage) -> Bool {
                       let inset = rect.insetBy(dx: 8, dy: 6)
                       let minX = max(0, Int(inset.minX.rounded()))
                       let maxX = min(image.width - 1, Int(inset.maxX.rounded()))
                       let minY = max(0, Int(inset.minY.rounded()))
                       let maxY = min(image.height - 1, Int(inset.maxY.rounded()))
                       guard maxX > minX, maxY > minY else { return false }
                       var total = 0, interior = 0
                       let strideX = max(1, (maxX - minX) / 80)
                       let strideY = max(1, (maxY - minY) / 12)
                       var y = minY
                       while y <= maxY {
                           var x = minX
                           while x <= maxX {
                               if let pixel = image.pixel(x: x, y: y) {
                                   total += 1
                                   if pixel.isTextFieldInterior || pixel.isDark { interior += 1 }
                               }
                               x += strideX
                           }
                           y += strideY
                       }
                       return Double(interior) / Double(max(total, 1)) >= 0.62
                   }

                   private func textFieldLooksFocused(_ rect: CGRect, image: RGBImage) -> Bool {
                       let expanded = rect.insetBy(dx: -4, dy: -4)
                       let minX = max(0, Int(expanded.minX.rounded()))
                       let maxX = min(image.width - 1, Int(expanded.maxX.rounded()))
                       let minY = max(0, Int(expanded.minY.rounded()))
                       let maxY = min(image.height - 1, Int(expanded.maxY.rounded()))
                       var total = 0, blue = 0
                       for y in minY...maxY {
                           for x in minX...maxX {
                               guard y == minY || y == maxY || x == minX || x == maxX else { continue }
                               guard let pixel = image.pixel(x: x, y: y) else { continue }
                               total += 1
                               if pixel.isBlue { blue += 1 }
                           }
                       }
                       return Double(blue) / Double(max(total, 1)) >= 0.08
                   }

                   private func bestTextFieldLabel(for rect: CGRect, labels: [TextLabel]) -> TextLabel? {
                       let inside = labels
                           .filter {
                               rect.insetBy(dx: -8, dy: -8).intersects($0.rect) &&
                               isPlausibleTextFieldLabel($0.text)
                           }
                           .sorted {
                               let lhsIntersection = rect.intersection($0.rect)
                               let rhsIntersection = rect.intersection($1.rect)
                               let lhsArea = lhsIntersection.width * lhsIntersection.height
                               let rhsArea = rhsIntersection.width * rhsIntersection.height
                               if lhsArea == rhsArea { return $0.confidence > $1.confidence }
                               return lhsArea > rhsArea
                           }
                           .first
                       if let inside { return inside }
                       return labels
                           .filter {
                               isPlausibleTextFieldLabel($0.text) &&
                               abs($0.rect.midY - rect.midY) <= 38 &&
                               horizontalGap(between: rect, and: $0.rect) <= 140
                           }
                           .min {
                               horizontalGap(between: rect, and: $0.rect) <
                               horizontalGap(between: rect, and: $1.rect)
                           }
                   }

                   private func isPlausibleTextFieldLabel(_ text: String) -> Bool {
                       let normalized = text
                           .trimmingCharacters(in: .whitespacesAndNewlines)
                           .lowercased()
                       guard !normalized.isEmpty else { return false }
                       if normalized.count > 42 { return false }
                       let rejectExact: Set<String> = [
                           "continue", "back", "next", "done", "cancel",
                           "ok", "yes", "no", "allow", "deny",
                           "agree", "accept", "decline", "disagree", "not now"
                       ]
                       if rejectExact.contains(normalized) { return false }
                       let rejectFragments = [
                           "this will be", "used to", "sign in", "you must",
                           "allow computer", "apple account", "home folder"
                       ]
                       if rejectFragments.contains(where: { normalized.contains($0) }) { return false }
                       return true
                   }

                   private func dedupeTextFieldsKeepingSiblings(
                       _ controls: [DetectedVisionControl]
                   ) -> [DetectedVisionControl] {
                       var output: [DetectedVisionControl] = []
                       for control in controls.sorted(by: {
                           if abs($0.rect.minY - $1.rect.minY) < 4 {
                               return $0.rect.minX < $1.rect.minX
                           }
                           return $0.rect.minY < $1.rect.minY
                       }) {
                           let duplicateIndex = output.firstIndex { existing in
                               let inter = existing.rect.intersection(control.rect)
                               guard !inter.isNull, !inter.isEmpty else { return false }
                               let hOverlap = inter.width  / min(existing.rect.width,  control.rect.width)
                               let vOverlap = inter.height / min(existing.rect.height, control.rect.height)
                               return hOverlap >= 0.60 && vOverlap >= 0.60
                           }
                           if let duplicateIndex {
                               let existing = output[duplicateIndex]
                               let preferred = (existing.label.isEmpty || existing.label == "Text Field")
                                   ? control : existing
                               output[duplicateIndex] = DetectedVisionControl(
                                   type: "textfield",
                                   label: preferred.label,
                                   confidence: max(existing.confidence, control.confidence),
                                   rect: existing.rect.union(control.rect),
                                   selected: (existing.selected == true || control.selected == true),
                                   controlCenter: preferred.controlCenter ?? control.controlCenter,
                                   style: nil
                               )
                           } else {
                               output.append(control)
                           }
                       }
                       return output
                   }

                   private func assignPositionalLabels(
                       _ controls: [DetectedVisionControl]
                   ) -> [DetectedVisionControl] {
                       guard !controls.isEmpty else { return controls }

                       let sortedTopToBottom = controls.sorted { $0.rect.minY < $1.rect.minY }
                       let total = sortedTopToBottom.count

                       var rows: [[DetectedVisionControl]] = []
                       for c in sortedTopToBottom {
                           if let firstInLastRow = rows.last?.first,
                              abs(c.rect.midY - firstInLastRow.rect.midY) <= 8 {
                               rows[rows.count - 1].append(c)
                           } else {
                               rows.append([c])
                           }
                       }

                       var ordered: [DetectedVisionControl] = []
                       var runningIndex = 0
                       for (rowIdx, row) in rows.enumerated() {
                           let leftToRight = row.sorted { $0.rect.minX < $1.rect.minX }
                           let colCount = leftToRight.count
                           for (colIdx, c) in leftToRight.enumerated() {
                               runningIndex += 1
                               let isGeneric = c.label.isEmpty || c.label == "Text Field"
                               let positional = makePositionalLabel(
                                   rowIdx: rowIdx,
                                   colIdx: colIdx,
                                   colCount: colCount,
                                   indexInAll: runningIndex,
                                   totalAll: total
                               )
                               let newLabel: String
                               if isGeneric {
                                   newLabel = positional
                               } else {
                                   newLabel = "\(c.label) (\(positional))"
                               }
                               ordered.append(DetectedVisionControl(
                                   type: c.type,
                                   label: newLabel,
                                   confidence: c.confidence,
                                   rect: c.rect,
                                   selected: c.selected,
                                   controlCenter: c.controlCenter,
                                   style: c.style
                               ))
                           }
                       }
                       return ordered
                   }

                   private func makePositionalLabel(
                       rowIdx: Int,
                       colIdx: Int,
                       colCount: Int,
                       indexInAll: Int,
                       totalAll: Int
                   ) -> String {
                       if colCount > 1 {
                           let side: String
                           if colIdx == 0 {
                               side = "left"
                           } else if colIdx == colCount - 1 {
                               side = "right"
                           } else {
                               side = "middle-\(colIdx + 1)"
                           }
                           return "\(side)-of-row-\(rowIdx + 1)"
                       }
                       return "field-\(indexInAll)-of-\(totalAll)"
                   }

                   // MARK: - Radios

                   private func detectRadioButtons(
                       in image: RGBImage,
                       components: [ConnectedComponent],
                       labels: [TextLabel]
                   ) -> [DetectedVisionControl] {
                       var output: [DetectedVisionControl] = []
                       for component in components {
                           let rect = component.rect
                           let w = rect.width
                           let h = rect.height
                           let aspect = w / max(h, 1)
                           guard w >= 8, w <= 34, h >= 8, h <= 34,
                                 aspect >= 0.65, aspect <= 1.35,
                                 component.fillRatio >= 0.04,
                                 component.fillRatio <= 0.85 else { continue }
                           guard looksCircular(rect: rect, in: image) else { continue }
                           guard let label = nearestLabelToRight(
                               of: rect, labels: labels,
                               maxDistance: 420, verticalTolerance: 30
                           ) else { continue }
                           let selected = radioLooksSelected(image: image, rect: rect)
                           let glyphCenter = CGPoint(x: rect.midX, y: rect.midY)
                           output.append(DetectedVisionControl(
                               type: "radio",
                               label: label.text,
                               confidence: max(label.confidence, 0.72),
                               rect: rect.union(label.rect).insetBy(dx: -8, dy: -6),
                               selected: selected,
                               controlCenter: glyphCenter,
                               style: nil
                           ))
                       }
                       return dedupe(output)
                   }

                   private func radioLooksSelected(image: RGBImage, rect: CGRect) -> Bool {
                       let centerX = Int(rect.midX.rounded())
                       let centerY = Int(rect.midY.rounded())
                       let radius = max(2, Int(min(rect.width, rect.height) * 0.28))
                       var total = 0, filled = 0
                       for y in (centerY - radius)...(centerY + radius) {
                           for x in (centerX - radius)...(centerX + radius) {
                               guard let pixel = image.pixel(x: x, y: y) else { continue }
                               total += 1
                               if pixel.isDark || pixel.isBlue { filled += 1 }
                           }
                       }
                       return Double(filled) / Double(max(total, 1)) > 0.16
                   }

                   // MARK: - Toggles

                   private func detectToggles(
                       in image: RGBImage,
                       components: [ConnectedComponent],
                       labels: [TextLabel]
                   ) -> [DetectedVisionControl] {
                       var output: [DetectedVisionControl] = []
                       for component in components {
                           let rect = component.rect
                           let w = rect.width
                           let h = rect.height
                           let aspect = w / max(h, 1)
                           guard w >= 28, w <= 120, h >= 12, h <= 50,
                                 aspect >= 1.45, aspect <= 5.2,
                                 component.fillRatio >= 0.04 else { continue }
                           let selected = toggleLooksEnabled(image: image, rect: rect)
                           let label = nearestLabelLeftOrRight(
                               of: rect, labels: labels,
                               maxDistance: 320, verticalTolerance: 36
                           )
                           let glyphCenter = CGPoint(x: rect.midX, y: rect.midY)
                           output.append(DetectedVisionControl(
                               type: "toggle",
                               label: label?.text ?? "Toggle",
                               confidence: max(label?.confidence ?? 0.70, 0.70),
                               rect: (label.map { rect.union($0.rect) } ?? rect).insetBy(dx: -8, dy: -6),
                               selected: selected,
                               controlCenter: glyphCenter,
                               style: nil
                           ))
                       }
                       return dedupe(output)
                   }

                   private func toggleLooksEnabled(image: RGBImage, rect: CGRect) -> Bool {
                       let minX = max(0, Int(rect.minX.rounded()))
                       let maxX = min(image.width - 1, Int(rect.maxX.rounded()))
                       let minY = max(0, Int(rect.minY.rounded()))
                       let maxY = min(image.height - 1, Int(rect.maxY.rounded()))
                       var total = 0, active = 0
                       for y in minY...maxY {
                           for x in minX...maxX {
                               guard let pixel = image.pixel(x: x, y: y) else { continue }
                               total += 1
                               if pixel.isBlue || pixel.isGreen { active += 1 }
                           }
                       }
                       return Double(active) / Double(max(total, 1)) > 0.18
                   }

                   // MARK: - Checkboxes

                   private func detectCheckboxes(
                       in image: RGBImage,
                       components: [ConnectedComponent],
                       labels: [TextLabel]
                   ) -> [DetectedVisionControl] {
                       var glyphRects: [(rect: CGRect, filled: Bool, confidence: Double)] = []

                       // A) Filled checkboxes via connected components.
                       // A) Filled checkboxes via connected components.
                       for component in components {
                           let rect = component.rect
                           let w = rect.width
                           let h = rect.height
                           let aspect = w / max(h, 1)
                           // Widened from 13-22 → 12-26 to handle Retina captures and
                           // sub-pixel bbox snapping.
                           guard w >= 12, w <= 26, h >= 12, h <= 26,
                                 aspect >= 0.78, aspect <= 1.28 else { continue }
                           // Lowered from 0.30 → 0.20 — the white checkmark "hole" can
                           // drop blueRatio below 0.30 on small glyphs.
                           guard component.blueRatio >= 0.20 else { continue }
                           // Lowered from 0.55 → 0.45 for the same reason.
                           guard component.fillRatio >= 0.45 else { continue }
                           // Use the existing circle discriminator instead of corner
                           // sampling. Rounded-corner checkboxes have BRIGHT corner pixels
                           // (the rounded corner falls outside the blue) but the SIDES of
                           // the bbox are solidly blue. `looksCircular` returns true only
                           // when 3+ corners are bright AND the bbox is small enough that
                           // the inscribed-circle assumption holds. We invert: if it's not
                           // circular, treat as a square = checkbox.
                           if looksCircular(rect: rect, in: image) { continue }

                           // A) Filled checkboxes via dedicated border scan.
                           glyphRects.append(contentsOf: findFilledCheckboxes(in: image))

                           // B) Empty checkboxes via border scan.
                           glyphRects.append(contentsOf: findEmptyCheckboxes(in: image))
                       }

                       // B) Empty checkboxes via border scan.
                       glyphRects.append(contentsOf: findEmptyCheckboxes(in: image))

                       // De-dupe glyphs (filled wins over empty).
                       let glyphs = mergeCheckboxGlyphs(glyphRects)

                       // C) Label association + multi-line assembly.
                       // C) Label association + multi-line assembly.
                       var output: [DetectedVisionControl] = []
                       var fallbackIndex = 0
                       for glyph in glyphs {
                           let labelInfo = checkboxLabel(for: glyph.rect, labels: labels)
                           fallbackIndex += 1
                           let labelText: String
                           let labelConfidence: Double
                           if let labelInfo {
                               labelText = labelInfo.text
                               labelConfidence = labelInfo.confidence
                           } else {
                               // No nearby OCR text — emit anyway with a positional fallback so
                               // the runner can still target it.
                               labelText = "checkbox-\(fallbackIndex)"
                               labelConfidence = 0.60
                           }
                           let glyphCenter = CGPoint(x: glyph.rect.midX, y: glyph.rect.midY)
                           output.append(DetectedVisionControl(
                               type: "checkbox",
                               label: labelText,
                               confidence: max(labelConfidence, glyph.confidence),
                               rect: glyph.rect,
                               selected: glyph.filled,
                               controlCenter: glyphCenter,
                               style: nil
                           ))
                       }
                       return dedupe(output)
                   }

                   private func findEmptyCheckboxes(
                       in image: RGBImage
                   ) -> [(rect: CGRect, filled: Bool, confidence: Double)] {
                       var results: [(rect: CGRect, filled: Bool, confidence: Double)] = []
                       let stride = 2
                       var y = 0
                       while y < image.height - 20 {
                           var x = 0
                           while x < image.width - 20 {
                               if let cand = scanEmptyCheckboxAt(x: x, y: y, in: image) {
                                   results.append((cand, false, 0.74))
                               }
                               x += stride
                           }
                           y += stride
                       }
                       return results
                   }
    private func findFilledCheckboxes(
        in image: RGBImage
    ) -> [(rect: CGRect, filled: Bool, confidence: Double)] {
        var results: [(rect: CGRect, filled: Bool, confidence: Double)] = []
        let stride = 3
        var y = 0
        while y < image.height - 22 {
            var x = 0
            while x < image.width - 22 {
                if let cand = scanFilledCheckboxAt(x: x, y: y, in: image) {
                    results.append((cand, true, 0.82))
                }
                x += stride
            }
            y += stride
        }
        return results
    }

    private func scanFilledCheckboxAt(
        x originX: Int,
        y originY: Int,
        in image: RGBImage
    ) -> CGRect? {
        for size in [12, 14, 16, 18, 20, 22] {            // ← added 12, 22
            let minX = originX
            let maxX = originX + size - 1
            let minY = originY
            let maxY = originY + size - 1
            guard maxX < image.width, maxY < image.height else { continue }

            var blueCount = 0, whiteCount = 0, total = 0
            for ys in minY...maxY {
                for xs in minX...maxX {
                    guard let p = image.pixel(x: xs, y: ys) else { continue }
                    total += 1
                    if p.isSystemBlue || p.isBlue { blueCount += 1 }
                    else if p.isNearWhite { whiteCount += 1 }
                }
            }
            guard total > 0 else { continue }
            let blueRatio  = Double(blueCount)  / Double(total)
            let whiteRatio = Double(whiteCount) / Double(total)

            // Filled checkbox: ≥45 % blue (was 55 %), white checkmark optional.
            guard blueRatio  >= 0.45, blueRatio  <= 0.98 else { continue }
            guard whiteRatio <= 0.45 else { continue }    // ← removed lower bound

            // 3+ of the 4 inset corners must be blue. Sampling 3 px in to
            // safely clear the rounded-corner antialias band.
            let inset = 3
            let corners = [
                (minX + inset, minY + inset),
                (maxX - inset, minY + inset),
                (minX + inset, maxY - inset),
                (maxX - inset, maxY - inset)
            ]
            var blueCorners = 0
            for (cx, cy) in corners {
                guard let p = image.pixel(x: cx, y: cy) else { continue }
                if p.isSystemBlue || p.isBlue { blueCorners += 1 }
            }
            guard blueCorners >= 3 else { continue }

            return CGRect(x: minX, y: minY, width: size, height: size)
        }
        return nil
    }

                   private func scanEmptyCheckboxAt(
                       x originX: Int,
                       y originY: Int,
                       in image: RGBImage
                   ) -> CGRect? {
                       for size in [14, 16, 18, 20] {
                           let minX = originX
                           let maxX = originX + size - 1
                           let minY = originY
                           let maxY = originY + size - 1
                           guard maxX < image.width, maxY < image.height else { continue }

                           if !edgeIsBorder(image: image, fromX: minX, toX: maxX, y: minY) { continue }
                           if !edgeIsBorder(image: image, fromX: minX, toX: maxX, y: maxY) { continue }
                           if !edgeIsBorderVertical(image: image, x: minX, fromY: minY, toY: maxY) { continue }
                           if !edgeIsBorderVertical(image: image, x: maxX, fromY: minY, toY: maxY) { continue }

                           var interior = 0, total = 0
                           for ys in (minY + 2)...(maxY - 2) {
                               for xs in (minX + 2)...(maxX - 2) {
                                   guard let p = image.pixel(x: xs, y: ys) else { continue }
                                   total += 1
                                   if p.isNearWhite { interior += 1 }
                               }
                           }
                           if total > 0, Double(interior) / Double(total) >= 0.80 {
                               return CGRect(x: minX, y: minY, width: size, height: size)
                           }
                       }
                       return nil
                   }

                   private func edgeIsBorder(
                       image: RGBImage, fromX: Int, toX: Int, y: Int
                   ) -> Bool {
                       var hits = 0, total = 0
                       for x in fromX...toX {
                           guard let p = image.pixel(x: x, y: y) else { continue }
                           total += 1
                           if p.isCheckboxEmptyBorder { hits += 1 }
                       }
                       return total > 0 && Double(hits) / Double(total) >= 0.60
                   }

                   private func edgeIsBorderVertical(
                       image: RGBImage, x: Int, fromY: Int, toY: Int
                   ) -> Bool {
                       var hits = 0, total = 0
                       for y in fromY...toY {
                           guard let p = image.pixel(x: x, y: y) else { continue }
                           total += 1
                           if p.isCheckboxEmptyBorder { hits += 1 }
                       }
                       return total > 0 && Double(hits) / Double(total) >= 0.60
                   }

                   private func mergeCheckboxGlyphs(
                       _ candidates: [(rect: CGRect, filled: Bool, confidence: Double)]
                   ) -> [(rect: CGRect, filled: Bool, confidence: Double)] {
                       var output: [(rect: CGRect, filled: Bool, confidence: Double)] = []
                       for c in candidates {
                           if let i = output.firstIndex(where: {
                               intersectionRatio($0.rect, c.rect) > 0.45
                           }) {
                               let existing = output[i]
                               if c.filled && !existing.filled {
                                   output[i] = c
                               } else if c.confidence > existing.confidence {
                                   output[i] = c
                               }
                           } else {
                               output.append(c)
                           }
                       }
                       return output
                   }

                   private func checkboxLabel(
                       for glyphRect: CGRect,
                       labels: [TextLabel]
                   ) -> (text: String, confidence: Double, rect: CGRect)? {
                       let firstLine = labels
                           .filter {
                               let leftGap = $0.rect.minX - glyphRect.maxX
                               return leftGap >= 6 && leftGap <= 60 &&
                                      abs($0.rect.midY - glyphRect.midY) <= 24
                           }
                           .min { $0.rect.minX < $1.rect.minX }

                       guard let first = firstLine else { return nil }

                       let lineH = max(first.rect.height, 14)
                       let continuations = labels
                           .filter { l in
                               guard l.rect.minY > first.rect.minY else { return false }
                               guard abs(l.rect.minX - first.rect.minX) <= 12 else { return false }
                               return true
                           }
                           .sorted { $0.rect.minY < $1.rect.minY }

                       var assembled = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
                       var accumRect = first.rect
                       var lastBottom = first.rect.maxY
                       var confidence = first.confidence
                       for cont in continuations {
                           let gap = cont.rect.minY - lastBottom
                           if gap > lineH * 1.4 { break }
                           let piece = cont.text.trimmingCharacters(in: .whitespacesAndNewlines)
                           if piece.isEmpty { continue }
                           assembled += " " + piece
                           accumRect = accumRect.union(cont.rect)
                           lastBottom = cont.rect.maxY
                           confidence = max(confidence, cont.confidence)
                       }

                       return (assembled, confidence, accumRect)
                   }

                   // MARK: - Arrow Continue Button

                   private func detectArrowContinueButton(
                       in image: RGBImage,
                       components: [ConnectedComponent],
                       existingControls: [DetectedVisionControl]
                   ) -> [DetectedVisionControl] {
                       let imageW = CGFloat(image.width)
                       let imageH = CGFloat(image.height)
                       let rightThreshold = imageW * 0.55
                       let bottomThreshold = imageH * 0.78

                       let hasExisting = existingControls.contains { c in
                           c.type == "button" &&
                           c.rect.midX >= rightThreshold &&
                           c.rect.midY >= bottomThreshold
                       }
                       if hasExisting { return [] }

                       var best: ConnectedComponent?
                       for component in components {
                           let r = component.rect
                           let w = r.width
                           let h = r.height
                           let aspect = w / max(h, 1)
                           guard r.midX >= rightThreshold, r.midY >= bottomThreshold else { continue }
                           guard w >= 6, w <= 50, h >= 6, h <= 40,
                                 aspect >= 0.4, aspect <= 3.5,
                                 component.darkRatio >= 0.35 else { continue }
                           if best == nil || component.pixelCount > best!.pixelCount {
                               best = component
                           }
                       }
                       guard let arrow = best else { return [] }
                       let enabled = arrow.darkRatio >= 0.45
                       let glyphCenter = CGPoint(x: arrow.rect.midX, y: arrow.rect.midY)
                       return [
                           DetectedVisionControl(
                               type: "button",
                               label: "Continue",
                               confidence: 0.72,
                               rect: arrow.rect.insetBy(dx: -20, dy: -12),
                               selected: enabled,
                               controlCenter: glyphCenter,
                               style: "secondary"
                           )
                       ]
                   }

                   // MARK: - Shape discriminator

                   private func looksCircular(rect: CGRect, in image: RGBImage) -> Bool {
                       let minX = max(0, Int(rect.minX.rounded()))
                       let maxX = min(image.width - 1, Int(rect.maxX.rounded()))
                       let minY = max(0, Int(rect.minY.rounded()))
                       let maxY = min(image.height - 1, Int(rect.maxY.rounded()))
                       guard maxX > minX + 2, maxY > minY + 2 else { return false }
                       let corners = [
                           (minX + 1, minY + 1),
                           (maxX - 1, minY + 1),
                           (minX + 1, maxY - 1),
                           (maxX - 1, maxY - 1)
                       ]
                       var brightCorners = 0
                       for (x, y) in corners {
                           guard let p = image.pixel(x: x, y: y) else { continue }
                           if p.luminance >= 200 { brightCorners += 1 }
                       }
                       return brightCorners >= 3
                   }

                   // MARK: - Association / Merge

                   private func nearestLabelToRight(
                       of rect: CGRect,
                       labels: [TextLabel],
                       maxDistance: CGFloat,
                       verticalTolerance: CGFloat
                   ) -> TextLabel? {
                       labels
                           .filter {
                               $0.rect.minX >= rect.maxX - 4 &&
                               abs($0.rect.midY - rect.midY) <= verticalTolerance &&
                               $0.rect.minX - rect.maxX <= maxDistance
                           }
                           .min {
                               abs($0.rect.minX - rect.maxX) <
                               abs($1.rect.minX - rect.maxX)
                           }
                   }

                   private func nearestLabelLeftOrRight(
                       of rect: CGRect,
                       labels: [TextLabel],
                       maxDistance: CGFloat,
                       verticalTolerance: CGFloat
                   ) -> TextLabel? {
                       labels
                           .filter {
                               abs($0.rect.midY - rect.midY) <= verticalTolerance &&
                               horizontalGap(between: rect, and: $0.rect) <= maxDistance
                           }
                           .min {
                               horizontalGap(between: rect, and: $0.rect) <
                               horizontalGap(between: rect, and: $1.rect)
                           }
                   }

                   private func horizontalGap(between a: CGRect, and b: CGRect) -> CGFloat {
                       if a.intersects(b) { return 0 }
                       if b.minX > a.maxX { return b.minX - a.maxX }
                       return a.minX - b.maxX
                   }

                   private func mergeControls(_ controls: [DetectedVisionControl]) -> [DetectedVisionControl] {
                       let priority: [String: Int] = [
                           "button": 10,
                           "radio": 9,
                           "toggle": 8,
                           "checkbox": 8,
                           "textfield": 7,
                           "radio-option": 5,
                           "text": 1
                       ]
                       let sorted = controls.sorted {
                           let lhs = priority[$0.type] ?? 0
                           let rhs = priority[$1.type] ?? 0
                           if lhs == rhs { return $0.confidence > $1.confidence }
                           return lhs > rhs
                       }
                       var output: [DetectedVisionControl] = []
                       for control in sorted {
                           let duplicate = output.contains {
                               $0.rect.intersects(control.rect) &&
                               intersectionRatio($0.rect, control.rect) > 0.45
                           }
                           if !duplicate { output.append(control) }
                       }
                       return output.sorted {
                           if abs($0.rect.minY - $1.rect.minY) < 12 {
                               return $0.rect.minX < $1.rect.minX
                           }
                           return $0.rect.minY < $1.rect.minY
                       }
                   }

                   private func dedupe(_ controls: [DetectedVisionControl]) -> [DetectedVisionControl] {
                       var output: [DetectedVisionControl] = []
                       for control in controls {
                           let duplicate = output.contains {
                               intersectionRatio($0.rect, control.rect) > 0.55
                           }
                           if !duplicate { output.append(control) }
                       }
                       return output
                   }

                   private func intersectionRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
                       let intersection = a.intersection(b)
                       if intersection.isNull || intersection.isEmpty { return 0 }
                       let intersectionArea = intersection.width * intersection.height
                       let smallerArea = min(a.width * a.height, b.width * b.height)
                       return intersectionArea / max(smallerArea, 1)
                   }
               }
