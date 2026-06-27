import Foundation
import CoreGraphics
import Vision
import AppKit

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
}

// MARK: - Public detector

final class VisionControlDetector {

    /// Cached full-image RGB used by restructuring stages (e.g. migration
    /// "filled-blue radio to the left of the label" selection check).
    /// Populated at the top of `analyze(...)` and cleared on exit.
    private var workingFullRGB: RGBImage?

    // MARK: Public entry point — staged pipeline

    func analyze(
        cgImage: CGImage,
        maxHeight: Int? = nil
    ) throws -> AnalysisResult {// Stage 0: Optionally downscale.
        let workingFullImage: CGImage
        if let maxHeight {
            workingFullImage = ImageScaling.downscaleIfNeeded(cgImage, maxHeight: maxHeight)
        } else {
            workingFullImage = cgImage
        }

        // Cache full-image RGB for restructuring stages.
        self.workingFullRGB = makeRGBImage(from: workingFullImage)
        defer { self.workingFullRGB = nil }

        // Stage 1: Locate the Setup Assistant card.
        let roi = findSetupCard(in: workingFullImage)
            ?? safetyROI(for: workingFullImage)

        // Stage 2: Crop to ROI and run the pipeline against ONLY that region.
        let workingImage = cropImage(workingFullImage, to: roi) ?? workingFullImage
        let roiControls = detectControls(in: workingImage)

        // Stage 3: Offset ROI-local rects + centers back to full-image coords.
        let mapped = roiControls.map { control in
            DetectedVisionControl(
                type: control.type,
                label: control.label,
                confidence: control.confidence,
                rect: control.rect.offsetBy(dx: roi.minX, dy: roi.minY),
                selected: control.selected,
                controlCenter: control.controlCenter.map {
                    CGPoint(x: $0.x + roi.minX, y: $0.y + roi.minY)
                }
            )
        }

        // Stage 4a: Classify scene.
        let scene = classifyScene(controls: mapped)

        // Stage 4b: Layout-specific restructuring (list → migration → thumbnail).
        let listRestructured = recategorizeAsListOptions(mapped, scene: scene)
        let migrationRestructured = recategorizeAsMigrationOptions(listRestructured, scene: scene)
        let restructured = recategorizeAsThumbnailPicker(migrationRestructured, scene: scene)

        // Stage 4c: Drop controls that don't belong in this scene's layout.
        let filtered = applySceneFilter(restructured, scene: scene)

        // Stage 5: Public AnalysisResult.
        let imageWidth = CGFloat(workingFullImage.width)
        let imageHeight = CGFloat(workingFullImage.height)

        let detections = filtered.map {
            mapToDetection($0, imageWidth: imageWidth, imageHeight: imageHeight)
        }

        let summary = buildSummary(controls: filtered, scene: scene)

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
                        controlCenter: CGPoint(x: control.rect.midX, y: control.rect.midY)
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
                        controlCenter: CGPoint(x: r.midX, y: r.midY)
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

    // MARK: - Stage 4b (migration): header-anchored option detection

    /// On `.migrationOptions` scenes, anchor on the question header (a text label
    /// ending in "?") and promote the stacked, consistent-height text labels
    /// below it to radio-options. Selected option is detected by checking for
    /// filled-blue pixels immediately to the LEFT of each label — works whether
    /// or not the radio glyph was found by the component-based detectors.
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

        // Everything text below the question header is an option label on
        // migration-style scenes — body paragraph and title both sit ABOVE the
        // header, and Continue is type "button". No geometric gates needed.
        let optionRows = texts.filter {
            $0.rect.minY > header.rect.maxY - 4 &&
            !$0.rect.intersects(header.rect)
        }
        guard optionRows.count >= 2 else {
            return controls.filter { $0.type != "radio-option" }
        }

        // Radio glyph column = leftmost minX across all rows. OCR-bulleted rows
        // include the radio in their bbox (so their minX IS the radio's left edge);
        // unbulleted rows start at the label (radio is to their left). Taking the
        // min gives the actual radio column regardless of row OCR variation.
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
                    controlCenter: CGPoint(x: control.rect.midX, y: control.rect.midY)
                ))
                continue
            }
            output.append(control)
        }
        return output
    }

    /// Sample a tight square centered on the radio glyph's column at the row's
    /// vertical midpoint. Works for both bulleted and unbulleted OCR rows because
    /// `radioColumn` is computed across all rows.
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
        // Filled radio ≈ ~15–20% blue inside this box. Empty radio ≈ ~0%.
        return Double(blue) / Double(max(total, 1)) >= 0.08
    }
    
    
    // MARK: - Stage 4c: Scene filter + button promotion
    /// On `.thumbnailPicker` scenes (e.g. Appearance), the options are a row of
    /// image thumbnails with labels beneath them, and one thumbnail is highlighted
    /// by a blue outline rectangle. Anchor on that outline rect, then convert each
    /// text label that sits beneath a thumbnail into a radio-option.
    private func recategorizeAsThumbnailPicker(
        _ controls: [DetectedVisionControl],
        scene: SceneDefinition?
    ) -> [DetectedVisionControl] {
        guard scene?.layout == .thumbnailPicker else { return controls }
        guard let rgb = workingFullRGB else { return controls }

        // Find the blue selection outline. We look at every connected blue
        // component, take the largest, and require it to be wider than it is
        // tall (thumbnails are landscape).
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

        // Candidate labels: short text controls below the largest text block
        // (the prompt). Sorted left-to-right.
        let texts = controls.filter { $0.type == "text" }
        guard let promptBottom = texts.map({ $0.rect.maxY }).max() else { return controls }

        let candidates = texts
            .filter {
                let r = $0.rect
                let clean = $0.label.trimmingCharacters(in: .whitespacesAndNewlines)
                return r.minY > promptBottom * 0.6 &&    // below the prompt area
                       clean.count <= 14 &&               // short labels only
                       clean.count >= 2 &&
                       !clean.contains(" ")               // single-word
            }

        // Group by Y (same row).
        guard let yRef = candidates.first?.rect.midY else { return controls }
        let optionRow = candidates.filter { abs($0.rect.midY - yRef) <= 30 }
        guard optionRow.count >= 2 else { return controls }

        let optionRects = Set(optionRow.map { $0.rect })

        var output: [DetectedVisionControl] = []
        for control in controls {
            // Strip out the bogus radio + back-chevron junk.
            if control.type == "radio" { continue }

            // Strip single-char or single-symbol text (back arrow, etc.).
            if control.type == "text" {
                let clean = control.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.count <= 1 { continue }
            }

            if control.type == "text", optionRects.contains(control.rect) {
                let selected: Bool
                if let sel = selection {
                    // Each label sits under one thumbnail. The selected label is
                    // the one whose midX is closest to the selection rect's midX.
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
                    controlCenter: CGPoint(x: control.rect.midX, y: control.rect.midY)
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
                    controlCenter: CGPoint(x: control.rect.midX, y: control.rect.midY)
                )
            }
            return control
        }
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
            label: cleanLabel.isEmpty ? nil : cleanLabel
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
                // Reject 1-char glyphs (back arrows, chevrons, etc.) from title pool.
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
            "save", "start", "create", "open", "setup", "yes"
        ]
        if advanceKeywords.contains(normalized) {
            return .advance
        }

        return .secondary
    }

    // MARK: - Pipeline

    func detectControls(in image: CGImage) -> [DetectedVisionControl] {
        let labels = recognizeText(in: image)
        let rgb = makeRGBImage(from: image)

        var controls: [DetectedVisionControl] = []

        if let rgb {
            controls.append(contentsOf: detectTextFields(in: rgb, labels: labels))
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

        return mergeControls(controls)
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

        var isTextFieldBorder: Bool {
            let maxChannel = max(r, max(g, b))
            let minChannel = min(r, min(g, b))
            let spread = Int(maxChannel) - Int(minChannel)
            let neutralLightGray =
                luminance >= 175 && luminance <= 248 && spread <= 28
            let focusBlue =
                Double(b) > 145 &&
                Double(b) > Double(r) * 1.20 &&
                Double(b) > Double(g) * 1.02
            return neutralLightGray || focusBlue
        }

        var isTextFieldInterior: Bool { luminance >= 238 }
        var isControlLike: Bool { isDark || isBlue || isGreen }
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

    // MARK: - Text Controls (+ button enabled detection)

    private func classifyTextControls(
        _ labels: [TextLabel],
        image: RGBImage?
    ) -> [DetectedVisionControl] {
        labels.map { label in
            let type = classifyTextType(label.text)
            let selected: Bool?
            if type == "button", let image {
                selected = buttonLooksEnabled(textRect: label.rect, image: image)
            } else {
                selected = nil
            }
            let center: CGPoint?
            if type == "button" {
                center = CGPoint(x: label.rect.midX, y: label.rect.midY)
            } else {
                center = nil
            }
            return DetectedVisionControl(
                type: type,
                label: label.text,
                confidence: label.confidence,
                rect: label.rect.insetBy(dx: -12, dy: -8),
                selected: selected,
                controlCenter: center
            )
        }
    }

    private func buttonLooksEnabled(textRect: CGRect, image: RGBImage) -> Bool {
        let minX = max(0, Int(textRect.minX.rounded()))
        let maxX = min(image.width - 1, Int(textRect.maxX.rounded()))
        let minY = max(0, Int(textRect.minY.rounded()))
        let maxY = min(image.height - 1, Int(textRect.maxY.rounded()))

        guard maxX > minX, maxY > minY else { return true }

        var veryDark = 0
        var lightInk = 0
        var total = 0

        for y in minY...maxY {
            for x in minX...maxX {
                guard let pixel = image.pixel(x: x, y: y) else { continue }
                total += 1
                let lum = pixel.luminance
                if lum < 60 {
                    veryDark += 1
                } else if lum < 220 {
                    lightInk += 1
                }
            }
        }

        guard total > 0 else { return true }

        let darkRatio = Double(veryDark) / Double(total)
        let inkRatio = Double(lightInk) / Double(total)

        if darkRatio >= 0.03 { return true }
        if inkRatio >= 0.04 { return false }
        return true
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

        // Strip a trailing single-letter token that's almost always an OCR'd
        // chevron (most commonly "v" for ⌄).
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

        // Prefix-matched buttons for multi-word labels that vary across scenes.
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
        in image: RGBImage,
        labels: [TextLabel]
    ) -> [DetectedVisionControl] {
        let horizontalRuns = findTextFieldHorizontalRuns(in: image)
        let rects = pairTextFieldRuns(horizontalRuns, image: image)

        let controls = rects.compactMap { rect -> DetectedVisionControl? in
            guard textFieldInteriorLooksValid(rect, image: image) else { return nil }

            let label = bestTextFieldLabel(for: rect, labels: labels)
            let detectedLabel = label?.text.trimmingCharacters(in: .whitespacesAndNewlines)

            let finalLabel: String
            if let detectedLabel, !detectedLabel.isEmpty {
                finalLabel = detectedLabel
            } else {
                finalLabel = "Text Field"
            }

            return DetectedVisionControl(
                type: "textfield",
                label: finalLabel,
                confidence: max(label?.confidence ?? 0.78, 0.78),
                rect: rect.insetBy(dx: -4, dy: -4),
                selected: textFieldLooksFocused(rect, image: image),
                controlCenter: CGPoint(x: rect.midX, y: rect.midY)
            )
        }

        return dedupeTextFields(controls)
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
                    } else if allowedGap < 5 {
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
                   density >= 0.52 {
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
               abs(last.minX - run.minX) <= 8,
               abs(last.maxX - run.maxX) <= 8 {
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

    private func pairTextFieldRuns(_ runs: [HorizontalRun], image: RGBImage) -> [CGRect] {
        var rects: [CGRect] = []

        for top in runs {
            for bottom in runs {
                guard bottom.y > top.y else { continue }

                let height = bottom.y - top.y + 1
                guard height >= 24, height <= 62 else { continue }

                let leftDelta = abs(top.minX - bottom.minX)
                let rightDelta = abs(top.maxX - bottom.maxX)
                let widthDelta = abs(top.width - bottom.width)

                guard leftDelta <= 16, rightDelta <= 16, widthDelta <= 24 else { continue }

                let minX = min(top.minX, bottom.minX)
                let maxX = max(top.maxX, bottom.maxX)
                let rect = CGRect(
                    x: minX, y: top.y,
                    width: maxX - minX + 1, height: height
                )

                guard verticalTextFieldEdgesLookValid(rect, image: image) else { continue }
                rects.append(rect)
            }
        }

        return mergeTextFieldRects(rects)
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

        return leftRatio >= 0.18 && rightRatio >= 0.18
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

        return Double(interior) / Double(max(total, 1)) >= 0.68
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

    private func mergeTextFieldRects(_ rects: [CGRect]) -> [CGRect] {
        var output: [CGRect] = []

        for rect in rects.sorted(by: {
            if abs($0.minY - $1.minY) < 8 { return $0.minX < $1.minX }
            return $0.minY < $1.minY
        }) {
            let duplicateIndex = output.firstIndex {
                $0.intersects(rect) && intersectionRatio($0, rect) > 0.35
            }
            if let duplicateIndex {
                output[duplicateIndex] = output[duplicateIndex].union(rect)
            } else {
                output.append(rect)
            }
        }

        return output
    }

    private func dedupeTextFields(_ controls: [DetectedVisionControl]) -> [DetectedVisionControl] {
        var output: [DetectedVisionControl] = []

        for control in controls.sorted(by: {
            if abs($0.rect.minY - $1.rect.minY) < 8 {
                return $0.rect.minX < $1.rect.minX
            }
            return $0.rect.minY < $1.rect.minY
        }) {
            let duplicateIndex = output.firstIndex {
                $0.rect.intersects(control.rect) &&
                intersectionRatio($0.rect, control.rect) > 0.35
            }

            if let duplicateIndex {
                let existing = output[duplicateIndex]
                let mergedRect = existing.rect.union(control.rect)
                let preferred = existing.label == "Text Field" ? control : existing
                output[duplicateIndex] = DetectedVisionControl(
                    type: "textfield",
                    label: preferred.label,
                    confidence: max(existing.confidence, control.confidence),
                    rect: mergedRect,
                    selected: (existing.selected == true || control.selected == true),
                    controlCenter: existing.controlCenter ?? control.controlCenter
                )
            } else {
                output.append(control)
            }
        }

        return output
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

            // Shape gate: glyph must actually be circular, not a rounded square.
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
                controlCenter: glyphCenter
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
                controlCenter: glyphCenter
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
        var output: [DetectedVisionControl] = []

        for component in components {
            let rect = component.rect
            let w = rect.width
            let h = rect.height
            let aspect = w / max(h, 1)

            guard w >= 9, w <= 34, h >= 9, h <= 34,
                  aspect >= 0.72, aspect <= 1.30 else { continue }

            let looksUnchecked =
                component.fillRatio >= 0.05 &&
                component.fillRatio <= 0.55

            // Filled checkbox: high fill, high blue, AND non-circular corners.
            // The corner check rules out filled radios masquerading as filled boxes.
            let looksCheckedFilled =
                component.fillRatio >= 0.55 &&
                component.blueRatio >= 0.45 &&
                !looksCircular(rect: rect, in: image)

            guard looksUnchecked || looksCheckedFilled else { continue }

            guard let label = nearestLabelToRight(
                of: rect, labels: labels,
                maxDistance: 480, verticalTolerance: 36
            ) else { continue }

            let selected: Bool
            if looksCheckedFilled {
                selected = true
            } else {
                selected = checkboxLooksSelected(image: image, rect: rect)
            }

            let glyphCenter = CGPoint(x: rect.midX, y: rect.midY)

            output.append(DetectedVisionControl(
                type: "checkbox",
                label: label.text,
                confidence: max(label.confidence, 0.72),
                rect: rect.union(label.rect).insetBy(dx: -8, dy: -6),
                selected: selected,
                controlCenter: glyphCenter
            ))
        }

        return dedupe(output)
    }

    private func checkboxLooksSelected(image: RGBImage, rect: CGRect) -> Bool {
        let minX = max(0, Int(rect.minX.rounded()))
        let maxX = min(image.width - 1, Int(rect.maxX.rounded()))
        let minY = max(0, Int(rect.minY.rounded()))
        let maxY = min(image.height - 1, Int(rect.maxY.rounded()))

        var total = 0, marked = 0

        for y in minY...maxY {
            for x in minX...maxX {
                guard let pixel = image.pixel(x: x, y: y) else { continue }
                total += 1
                if pixel.isDark || pixel.isBlue { marked += 1 }
            }
        }

        return Double(marked) / Double(max(total, 1)) > 0.23
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
                controlCenter: glyphCenter
            )
        ]
    }

    // MARK: - Shape discriminator

    /// True when the four corners of `rect` in `image` are mostly background-bright,
    /// meaning the filled blob inside is a circle (radio). False when the corners are
    /// filled, meaning it's a rounded square (checkbox).
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
