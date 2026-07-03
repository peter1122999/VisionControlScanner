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

// MARK: - Debug logging (set VCS_DEBUG=1; temporary instrumentation)

func vcsDebug(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["VCS_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data("[vcs-debug] \(message())\n".utf8))
}

// MARK: - Public detector

final class VisionControlDetector {

    private var workingFullRGB: RGBImage?

    private var workingFullCGImage: CGImage?
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
        self.workingFullCGImage = workingFullImage
        defer {
            self.workingFullRGB = nil
            self.workingFullCGImage = nil
        }

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
        let withHelloButton = promoteHelloBottomCenterButton(
            stamped,
            scene: scene,
            imageWidth: CGFloat(workingFullImage.width),
            imageHeight: CGFloat(workingFullImage.height)
        )

        let imageWidth = CGFloat(workingFullImage.width)
        let imageHeight = CGFloat(workingFullImage.height)
        let detections = withHelloButton.map {
            mapToDetection($0, imageWidth: imageWidth, imageHeight: imageHeight)
        }
        let summary = buildSummary(controls: withHelloButton, scene: scene)
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
        // Checkbox/toggle labels must be part of the haystack: mergeControls
        // consumes the OCR text line INTO the control, so on screens whose only
        // distinctive phrase is a checkbox label ("Enable Ask Siri"), excluding
        // them left nothing for the keywords to match and the scene came back
        // nil — wait_for_scene "Siri" then timed out.
        let haystack = controls
            .filter {
                $0.type == "text" ||
                $0.type == "button" ||
                $0.type == "radio-option" ||
                $0.type == "textfield" ||
                $0.type == "checkbox" ||
                $0.type == "toggle"
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

        // Chevron nav rows (Age Range) already arrive as pixel-anchored options
        // with correct row bands; re-inferring rows from OCR text would replace
        // them with worse guesses (merged title/subtitle bands, dropped rows).
        if controls.filter({ $0.type == "radio-option" }).count >= 2 {
            return controls
        }

        // Prefer OCR/text-row inference for macOS 26 list pickers.
        // If the selected row renders as white text on blue/gray selection, Vision may
        // miss that text entirely. The text-only path can synthesize the missing selected
        // top row from the highlighted row immediately above the first detected option.
        let textOnly = recategorizeTextOnlyListOptions(controls, scene: scene)
        let textOnlyOptionCount = textOnly.filter { $0.type == "radio-option" }.count
        vcsDebug("listOptions in=\(controls.count) (options=\(controls.filter { $0.type == "radio-option" }.count)) textOnly=\(textOnly.count) textOnlyOptions=\(textOnlyOptionCount)")
        if textOnlyOptionCount >= 2 {
            return textOnly
        }

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

    private struct TextOnlyListRow {
        let source: DetectedVisionControl
        let label: String
        let rowRect: CGRect
        let selected: Bool
    }

    /// Text-field-free list-picker recovery path.
    /// For Country/Region and similar macOS 26 Setup Assistant list pickers, rows can
    /// appear as OCR text only. The selected row can be worse: white text on blue/gray
    /// highlight may disappear from OCR entirely. This method emits visible OCR rows as
    /// option controls and can synthesize a missing highlighted selected row immediately
    /// above the first detected row.
    private func recategorizeTextOnlyListOptions(
        _ controls: [DetectedVisionControl],
        scene: SceneDefinition?
    ) -> [DetectedVisionControl] {
        guard scene?.layout == .listPicker || looksLikeTextOnlyListPicker(controls) else {
            return controls
        }

        let rows = inferTextOnlyListRows(controls, scene: scene)
        guard rows.count >= 2 else { return controls }

        let sourceRects = rows.map { $0.source.rect }
        var output: [DetectedVisionControl] = []

        for control in controls {
            if control.type == "textfield" || control.type == "radio" || control.type == "radio-option" {
                continue
            }
            if control.type == "text",
               sourceRects.contains(where: { intersectionRatio($0, control.rect) > 0.45 }) {
                continue
            }
            output.append(control)
        }

        output.append(contentsOf: rows.map { row in
            DetectedVisionControl(
                type: "radio-option",
                label: row.label,
                confidence: max(row.source.confidence, 0.88),
                rect: row.rowRect,
                selected: row.selected,
                controlCenter: CGPoint(x: row.rowRect.midX, y: row.rowRect.midY),
                style: nil
            )
        })

        return output.sorted {
            if abs($0.rect.minY - $1.rect.minY) < 12 { return $0.rect.minX < $1.rect.minX }
            return $0.rect.minY < $1.rect.minY
        }
    }

    private func looksLikeTextOnlyListPicker(_ controls: [DetectedVisionControl]) -> Bool {
        let texts = controls.filter { $0.type == "text" && isPlausibleListOptionText($0.label) }
        guard texts.count >= 3 else { return false }

        let clusters = Dictionary(grouping: texts) { control -> Int in
            Int((control.rect.minX / 12.0).rounded())
        }

        return clusters.values.contains { group in
            guard group.count >= 3 else { return false }
            let mids = group.map { $0.rect.midY }.sorted()
            let gaps = zip(mids.dropFirst(), mids).map { $0 - $1 }.filter { $0 >= 10 && $0 <= 60 }
            return gaps.count >= 2
        }
    }

    private func inferTextOnlyListRows(
        _ controls: [DetectedVisionControl],
        scene: SceneDefinition?
    ) -> [TextOnlyListRow] {
        let titleBottom = likelyListTitleBottom(in: controls, scene: scene)
        let candidates = controls
            .filter { $0.type == "text" }
            .filter { isPlausibleListOptionText($0.label) }
            .filter { !isBodyCopyListLeak($0, allControls: controls) }
            .filter { $0.rect.minY > titleBottom + 4 }
            .sorted { $0.rect.minY < $1.rect.minY }

        guard candidates.count >= 2 else { return [] }

        let leftX = dominantListLeftCluster(candidates)
        let aligned = candidates.filter { abs($0.rect.minX - leftX) <= 30 }
        guard aligned.count >= 2 else { return [] }

        let mids = aligned.map { $0.rect.midY }.sorted()
        let gaps = zip(mids.dropFirst(), mids).map { $0 - $1 }.filter { $0 >= 10 && $0 <= 60 }
        let medianGap = median(gaps)
        // FIX (BUG 3): row height used to equal the row *pitch*, so rects touched and
        // any mid-Y drift put the bbox on the neighboring row. Cap to ~72% of pitch.
        let pitch = medianGap == 0 ? 22.0 : medianGap
        let textHeights = aligned.map { $0.rect.height }.sorted()
        let medianTextH = textHeights.isEmpty ? 18.0 : textHeights[textHeights.count / 2]
        let rowHeight = max(16.0, min(pitch * 0.72, medianTextH * 1.35))
        // FIX (BUG 2): classifyTextControls already inset text rects by dx:-12.
        // Subtracting another 8 put rowLeft ~20 px left of the visible text and
        // ~150 px left of the visible (centered) list column. Add 12 back + 4 pad.
        let visibleLeftX = leftX + 12
        let rowLeft = max(0, visibleLeftX - 4)
        let rowRight = inferListRightEdge(from: aligned, controls: controls, rowLeft: rowLeft)
        let rowWidth = max(160, rowRight - rowLeft)

        // FIX: snap each row's Y to a rigid pitch grid anchored on
        // the first aligned row. Raw OCR midY drifts by 3-10 px per
        // row due to accent/descender variance, which stacks up.
        let anchorMidY = aligned.first?.rect.midY ?? 0
        var rows = aligned.map { text -> TextOnlyListRow in
            let rawOffset = text.rect.midY - anchorMidY
            let snappedIndex = (rawOffset / pitch).rounded()
            let snappedMidY = anchorMidY + snappedIndex * pitch
            let rowRect = CGRect(
                x: rowLeft,
                y: snappedMidY - rowHeight / 2.0,
                width: rowWidth,
                height: rowHeight
            )
            return TextOnlyListRow(
                source: text,
                label: cleanListOptionLabel(text.label),
                rowRect: rowRect,
                selected: listRowLooksSelected(rowRect, in: workingFullRGB)
            )
        }

        rows = insertMissingSelectedListRowIfFound(
            rows,
            pitch: pitch,
            rowHeight: rowHeight,
            rowLeft: rowLeft,
            rowWidth: rowWidth
        )

        // Legacy top-row fallback only when the grid scan found nothing: its
        // pale-blue/fill heuristics can mistake the list's focus ring for a
        // selection (fabricated a selected "Tristan da Cunha" on the Country
        // screen while the real selection sat at the bottom of the list).
        if !rows.contains(where: { $0.selected }) {
            rows = synthesizeMissingSelectedTopListRowIfNeeded(
                rows,
                controls: controls,
                scene: scene,
                rowHeight: rowHeight,
                rowLeft: rowLeft,
                rowWidth: rowWidth
            )
        }

        return rows
    }

    /// The selected list row renders white-on-saturated-blue, which the primary
    /// OCR pass usually drops, so it is missing from `rows` — and it can be ANY
    /// row, not just the one above the first OCR hit: type-select leaves it at
    /// the bottom (Country → "United States"), and scrolling can leave it mid-list.
    /// Scan the pitch grid from one row above the first OCR row to one row below
    /// the last, including interior gaps, for a saturated-blue band with white
    /// text; OCR it contrast-inverted and insert it as the selected option.
    private func insertMissingSelectedListRowIfFound(
        _ rows: [TextOnlyListRow],
        pitch: CGFloat,
        rowHeight: CGFloat,
        rowLeft: CGFloat,
        rowWidth: CGFloat
    ) -> [TextOnlyListRow] {
        guard let first = rows.first, let last = rows.last, pitch > 8 else { return rows }
        guard !rows.contains(where: { $0.selected }) else { return rows }

        var midY = first.rowRect.midY - pitch
        let endMidY = last.rowRect.midY + pitch
        while midY <= endMidY + 0.5 {
            defer { midY += pitch }
            if rows.contains(where: { abs($0.rowRect.midY - midY) < pitch * 0.5 }) {
                continue
            }
            let band = CGRect(
                x: rowLeft,
                y: midY - rowHeight / 2.0,
                width: rowWidth,
                height: rowHeight
            )
            let appearance = listRowSelectionAppearance(band, in: workingFullRGB)
            vcsDebug("selScan band=\(band) satBlue=\(appearance.isSaturatedBlue) white=\(appearance.hasWhiteText)")
            guard appearance.isSaturatedBlue, appearance.hasWhiteText else { continue }
            let ocr = ocrSelectedListRowWhiteText(band)
            vcsDebug("selScan OCR=\(ocr ?? "nil")")
            guard let label = ocr,
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let source = DetectedVisionControl(
                type: "text",
                label: label,
                confidence: 0.95,
                rect: band,
                selected: true,
                controlCenter: CGPoint(x: band.midX, y: band.midY),
                style: nil
            )
            let inserted = TextOnlyListRow(
                source: source, label: label, rowRect: band, selected: true
            )
            return (rows + [inserted]).sorted { $0.rowRect.minY < $1.rowRect.minY }
        }
        return rows
    }


    private func synthesizeMissingSelectedTopListRowIfNeeded(
        _ rows: [TextOnlyListRow],
        controls: [DetectedVisionControl],
        scene: SceneDefinition?,
        rowHeight: CGFloat,
        rowLeft: CGFloat,
        rowWidth: CGFloat
    ) -> [TextOnlyListRow] {
        guard let first = rows.first else { return rows }
        guard first.selected == false else { return rows }

        let titleBottom = likelyListTitleBottom(in: controls, scene: scene)
        guard let label = defaultSelectedTopRowLabel(for: scene),
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return rows
        }

        // IMPORTANT:
        // Do not attach the synthetic "English" label to the extrapolated OCR row.
        // First find the actual saturated-blue/pale-blue selected-row fill, then
        // use that highlight rectangle as the option bbox.
        let highlightedRect = selectedTopListRowHighlightRect(
            above: first.rowRect,
            rowHeight: rowHeight,
            rowLeft: rowLeft,
            rowWidth: rowWidth,
            controls: controls,
            scene: scene
        )

        let fallbackWidth = min(max(rowWidth, 210), 280)
        let fallbackX = max(0, rowLeft - min(110, fallbackWidth * 0.45))
        let fallbackRect = CGRect(
            x: fallbackX,
            y: first.rowRect.minY - rowHeight,
            width: fallbackWidth,
            height: min(max(rowHeight, 22), 32)
        )

        let candidateRect = highlightedRect ?? fallbackRect

        guard candidateRect.minY > titleBottom else { return rows }

        // Require a real visual selected-row signal. This prevents the known-default
        // path from inventing "English" at the wrong y-coordinate.
        let looksSelected =
            highlightedRect != nil ||
            listRowLooksSelected(candidateRect, in: workingFullRGB) ||
            selectedTopListRowFillLooksPresent(candidateRect, in: workingFullRGB)

        guard looksSelected else { return rows }

        // Prefer the label actually rendered on the selected row. That row is white text
        // on a saturated-blue/gray highlight, which the primary Vision OCR pass normally
        // drops entirely. ocrSelectedListRowWhiteText re-runs OCR on a contrast-inverted
        // crop of just this rect (makeDarkerTextOCRImage). Only fall back to the per-scene
        // default label if that targeted OCR yields nothing usable. This is strictly
        // additive: when OCR fails, behavior matches the previous hardcoded-label path.
        let resolvedLabel: String
        if let ocrLabel = ocrSelectedListRowWhiteText(candidateRect),
           !ocrLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedLabel = ocrLabel
        } else {
            resolvedLabel = label
        }

        let syntheticSource = DetectedVisionControl(
            type: "text",
            label: resolvedLabel,
            confidence: highlightedRect != nil ? 0.96 : 0.88,
            rect: candidateRect,
            selected: true,
            controlCenter: CGPoint(x: candidateRect.midX, y: candidateRect.midY),
            style: nil
        )

        return [TextOnlyListRow(source: syntheticSource, label: resolvedLabel, rowRect: candidateRect, selected: true)] + rows
    }


    private func selectedTopListRowFillLooksPresent(_ rect: CGRect, in image: RGBImage?) -> Bool {
        guard let image else { return false }

        // Wider than the OCR text row. The inferred row may start at text-left,
        // while the real blue rounded selection starts farther left and ends
        // before the scrollbar. Expanding both directions catches the fill.
        let sample = rect.insetBy(dx: -42, dy: -4)

        let minX = max(0, Int(sample.minX.rounded()))
        let maxX = min(image.width - 1, Int(sample.maxX.rounded()))
        let minY = max(0, Int(sample.minY.rounded()))
        let maxY = min(image.height - 1, Int(sample.maxY.rounded()))

        guard maxX > minX && maxY > minY else { return false }

        var total = 0
        var saturatedBlue = 0
        var paleBlue = 0
        var selectedGray = 0
        var whiteText = 0

        let strideX = max(1, (maxX - minX) / 140)
        let strideY = max(1, (maxY - minY) / 14)

        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                if let p = image.pixel(x: x, y: y) {
                    total += 1

                    let r = Int(p.r)
                    let g = Int(p.g)
                    let b = Int(p.b)
                    let spread = max(r, max(g, b)) - min(r, min(g, b))

                    // Existing pale selected row.
                    if r >= 205 && r <= 240 &&
                       g >= 220 && g <= 248 &&
                       b >= 238 && b <= 255 {
                        paleBlue += 1
                    }

                    // macOS saturated selected row, around RGB 0,122,255.
                    if r <= 50 &&
                       g >= 100 && g <= 140 &&
                       b >= 240 {
                        saturatedBlue += 1
                    }

                    // Inactive-window gray selected row.
                    if p.luminance >= 185 && p.luminance <= 232 && spread <= 22 {
                        selectedGray += 1
                    }

                    // White glyphs on selected blue.
                    if r >= 235 && g >= 235 && b >= 235 && spread <= 24 {
                        whiteText += 1
                    }
                }
                x += strideX
            }
            y += strideY
        }

        guard total > 0 else { return false }

        let saturatedBlueRatio = Double(saturatedBlue) / Double(total)
        let paleBlueRatio = Double(paleBlue) / Double(total)
        let selectedGrayRatio = Double(selectedGray) / Double(total)
        let whiteTextRatio = Double(whiteText) / Double(total)

        return
            paleBlueRatio >= 0.08 ||
            selectedGrayRatio >= 0.20 ||
            (saturatedBlueRatio >= 0.08 && whiteTextRatio >= 0.002)
    }



    private func selectedTopListRowHighlightRect(
        above firstRowRect: CGRect,
        rowHeight: CGFloat,
        rowLeft: CGFloat,
        rowWidth: CGFloat,
        controls: [DetectedVisionControl],
        scene: SceneDefinition?
    ) -> CGRect? {
        guard let image = workingFullRGB else { return nil }

        let titleBottom = likelyListTitleBottom(in: controls, scene: scene)

        // Search between the title and the first OCR-visible row. This avoids the
        // globe/icon blue above the title and avoids rows below the selected row.
        let searchTop = max(0, Int((titleBottom + 2).rounded(.down)))
        let searchBottom = min(
            image.height - 1,
            Int((firstRowRect.minY + max(rowHeight * 0.35, 8)).rounded(.up))
        )

        // rowLeft is usually OCR text-left, not list-left. Expand left enough to
        // include the actual blue rounded rectangle. Cap right so scrollbar/globe
        // junk cannot stretch the bbox to ~397px again.
        let searchLeft = max(0, Int((rowLeft - max(95, rowHeight * 4.5)).rounded(.down)))
        let searchRight = min(
            image.width - 1,
            Int((rowLeft + min(max(rowWidth, 240), 360)).rounded(.up))
        )

        guard searchBottom > searchTop, searchRight > searchLeft else { return nil }

        var found = false
        var minBlueX = image.width
        var maxBlueX = 0
        var minBlueY = image.height
        var maxBlueY = 0

        var y = searchTop
        while y <= searchBottom {
            var x = searchLeft
            while x <= searchRight {
                if let p = image.pixel(x: x, y: y) {
                    let r = Int(p.r)
                    let g = Int(p.g)
                    let b = Int(p.b)

                    let saturatedBlue =
                        r <= 70 &&
                        g >= 90 && g <= 165 &&
                        b >= 205 &&
                        b > r + 120 &&
                        b > g + 70

                    let paleBlue =
                        r >= 205 && r <= 245 &&
                        g >= 220 && g <= 252 &&
                        b >= 235 && b <= 255

                    if saturatedBlue || paleBlue {
                        found = true
                        if x < minBlueX { minBlueX = x }
                        if x > maxBlueX { maxBlueX = x }
                        if y < minBlueY { minBlueY = y }
                        if y > maxBlueY { maxBlueY = y }
                    }
                }
                x += 1
            }
            y += 1
        }

        guard found else { return nil }

        let rawWidth = maxBlueX - minBlueX + 1
        let rawHeight = maxBlueY - minBlueY + 1

        // Reject tiny glyph/icon fragments and over-wide accidental captures.
        guard rawWidth >= 90,
              rawWidth <= 320,
              rawHeight >= 8,
              rawHeight <= Int(max(rowHeight * 2.0, 44))
        else {
            return nil
        }

        let targetHeight = min(max(CGFloat(rawHeight), max(rowHeight, 22)), 34)
        let centerY = (CGFloat(minBlueY) + CGFloat(maxBlueY)) / 2.0
        let y0 = max(titleBottom + 1, centerY - targetHeight / 2.0)

        return CGRect(
            x: CGFloat(minBlueX),
            y: y0,
            width: CGFloat(rawWidth),
            height: targetHeight
        )
    }




    private func defaultSelectedTopRowLabel(for scene: SceneDefinition?) -> String? {
        let name = scene?.displayName.lowercased() ?? ""

        if name.contains("language") && !name.contains("written") && !name.contains("spoken") {
            return "English"
        }

        if name.contains("country") || name.contains("region") {
            return "United States"
        }

        if name.contains("written language") {
            return "English"
        }

        if name.contains("spoken language") {
            return "English"
        }

        return nil
    }

    private func likelyListTitleBottom(in controls: [DetectedVisionControl], scene: SceneDefinition?) -> CGFloat {
        let sceneName = scene?.displayName.lowercased() ?? ""
        let titles = controls.filter { control in
            guard control.type == "text" else { return false }
            let normalized = control.label.lowercased()
            if !sceneName.isEmpty && normalized.contains(sceneName) { return true }
            return normalized.contains("select your") || normalized.contains("country or region") ||
                   normalized.contains("written language") || normalized.contains("spoken language") ||
                   normalized.contains("keyboard") || normalized.contains("wi-fi") || normalized.contains("time zone")
        }
        return titles.map { $0.rect.maxY }.max() ?? 0
    }

    private func dominantListLeftCluster(_ controls: [DetectedVisionControl]) -> CGFloat {
        let buckets = Dictionary(grouping: controls) { control -> Int in Int((control.rect.minX / 10.0).rounded()) }
        let best = buckets.max { lhs, rhs in
            if lhs.value.count == rhs.value.count {
                let lhsAverage = lhs.value.map { $0.rect.minX }.reduce(0, +) / CGFloat(max(lhs.value.count, 1))
                let rhsAverage = rhs.value.map { $0.rect.minX }.reduce(0, +) / CGFloat(max(rhs.value.count, 1))
                return lhsAverage > rhsAverage
            }
            return lhs.value.count < rhs.value.count
        }?.value ?? controls
        return best.map { $0.rect.minX }.reduce(0, +) / CGFloat(max(best.count, 1))
    }

    private func inferListRightEdge(from rows: [DetectedVisionControl], controls: [DetectedVisionControl], rowLeft: CGFloat) -> CGFloat {
        // FIX (BUG 1): The old version considered EVERY control on the row Y band,
        // so the chevron "Next" button pushed the column to the card's right edge.
        // Anchor purely to the text extents + a scrollbar gutter, clamped to a
        // max column width (largest observed SA list column at 1280x800).
        let textRight = rows.map { $0.rect.maxX }.max() ?? (rowLeft + 240)
        let scrollbarGutter: CGFloat = 24
        let maxColumnWidth: CGFloat = 340
        let cappedRight = min(textRight + scrollbarGutter, rowLeft + maxColumnWidth)
        return max(cappedRight, textRight + 8)
    }

    private func isPlausibleListOptionText(_ raw: String) -> Bool {
        let text = cleanListOptionLabel(raw)
        guard text.count >= 2 && text.count <= 64 else { return false }
        let lowered = text.lowercased()
        let rejectExact: Set<String> = [
            "continue", "back", "next", "done", "cancel", "ok", "yes", "no",
            "select your country or region", "select your language", "select your keyboard"
        ]
        if rejectExact.contains(lowered) { return false }
        let rejectFragments = [
            "press the escape key", "command-option-f5", "voiceover", "accessibility options",
            "create a mac account", "password", "terms and conditions",
            "customize", "you can", "your mac will", "tap to", "click to", "select to"
        ]
        if rejectFragments.contains(where: { lowered.contains($0) }) { return false }
        if startsWithLowercaseLetter(text) { return false }
        if containsWrappedSentencePunctuation(text) { return false }
        let scalars = text.unicodeScalars
        let letters = scalars.filter { CharacterSet.letters.contains($0) }.count
        let visible = scalars.filter { !$0.properties.isWhitespace }.count
        guard visible > 0 else { return false }
        return Double(letters) / Double(visible) >= 0.45
    }

    private func isBodyCopyListLeak(_ control: DetectedVisionControl, allControls: [DetectedVisionControl]) -> Bool {
        let text = cleanListOptionLabel(control.label)
        let normalized = text.lowercased()
        if ["customize", "you can", "your mac will", "tap to", "click to", "select to"].contains(where: { normalized.contains($0) }) {
            return true
        }
        if startsWithLowercaseLetter(text) { return true }
        if containsWrappedSentencePunctuation(text) { return true }

        let cardWidth = likelyContentWidth(from: allControls)
        if cardWidth > 0, control.rect.width > cardWidth * 0.60 {
            let expectedPitch: CGFloat = 44
            let hasPeerBelow = allControls.contains { other in
                guard other.type == "text", other.rect != control.rect else { return false }
                guard isPlausibleListOptionText(other.label) else { return false }
                return abs(other.rect.minX - control.rect.minX) <= 20 &&
                       abs((other.rect.midY - control.rect.midY) - expectedPitch) <= 12
            }
            if !hasPeerBelow { return true }
        }
        return false
    }

    private func startsWithLowercaseLetter(_ text: String) -> Bool {
        guard let scalar = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.first else { return false }
        return CharacterSet.lowercaseLetters.contains(scalar)
    }

    private func containsWrappedSentencePunctuation(_ text: String) -> Bool {
        text.range(of: #"[a-z][.!?]\s+[a-z]"#, options: [.regularExpression]) != nil
    }

    private func likelyContentWidth(from controls: [DetectedVisionControl]) -> CGFloat {
        let rects = controls.map { $0.rect }
        guard let minX = rects.map({ $0.minX }).min(), let maxX = rects.map({ $0.maxX }).max() else { return 0 }
        return maxX - minX
    }

    private func cleanListOptionLabel(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "â", with: "")
            .replacingOccurrences(of: "â¾", with: "")
            .replacingOccurrences(of: "âº", with: "")
            .replacingOccurrences(of: "Ë", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ListRowSelectionAppearance {
        let isSelected: Bool
        let isPaleBlue: Bool
        let isSaturatedBlue: Bool
        let isSelectedGray: Bool
        let hasWhiteText: Bool
    }

    private func listRowLooksSelected(_ rect: CGRect, in image: RGBImage?) -> Bool {
        listRowSelectionAppearance(rect, in: image).isSelected
    }

    private func listRowSelectionAppearance(_ rect: CGRect, in image: RGBImage?) -> ListRowSelectionAppearance {
        guard let image else {
            return ListRowSelectionAppearance(
                isSelected: false,
                isPaleBlue: false,
                isSaturatedBlue: false,
                isSelectedGray: false,
                hasWhiteText: false
            )
        }

        let inset = rect.insetBy(dx: 3, dy: 2)
        let minX = max(0, Int(inset.minX.rounded()))
        let maxX = min(image.width - 1, Int(inset.maxX.rounded()))
        let minY = max(0, Int(inset.minY.rounded()))
        let maxY = min(image.height - 1, Int(inset.maxY.rounded()))

        guard maxX > minX && maxY > minY else {
            return ListRowSelectionAppearance(
                isSelected: false,
                isPaleBlue: false,
                isSaturatedBlue: false,
                isSelectedGray: false,
                hasWhiteText: false
            )
        }

        var total = 0
        var saturatedBlue = 0
        var paleBlue = 0
        var selectedGray = 0
        var whiteText = 0

        let strideX = max(1, (maxX - minX) / 100)
        let strideY = max(1, (maxY - minY) / 10)

        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                if let p = image.pixel(x: x, y: y) {
                    total += 1

                    let r = Int(p.r)
                    let g = Int(p.g)
                    let b = Int(p.b)
                    let spread = max(r, max(g, b)) - min(r, min(g, b))

                    // Existing pale-blue selection fill.
                    if r >= 205 && r <= 240 &&
                       g >= 220 && g <= 248 &&
                       b >= 238 && b <= 255 {
                        paleBlue += 1
                    }

                    // New macOS 26 active selected-row fill: controlAccentColor
                    // blue. Renders as ~(0,122,255) in direct captures but as a
                    // darker ~(0,85,197) in Tart VNC framebuffer grabs (gamma /
                    // color-profile shift), so accept the full range — blue must
                    // still clearly dominate green.
                    if r <= 50 &&
                       g >= 60 && g <= 150 &&
                       b >= 180 &&
                       b > g + 40 {
                        saturatedBlue += 1
                    }

                    // Existing inactive-window gray selected row.
                    if p.luminance >= 185 && p.luminance <= 232 && spread <= 20 {
                        selectedGray += 1
                    }

                    // White text on saturated blue. VNC framebuffer grabs render
                    // it antialiased and blue-tinted (~(210,230,248)), never pure
                    // white, so accept bright blue-leaning whites. Card background
                    // still can't qualify a row on its own because whiteText is
                    // only consulted together with the saturated-blue fill gate.
                    if r >= 150 && g >= 180 && b >= 220 {
                        whiteText += 1
                    }
                }
                x += strideX
            }
            y += strideY
        }

        guard total > 0 else {
            return ListRowSelectionAppearance(
                isSelected: false,
                isPaleBlue: false,
                isSaturatedBlue: false,
                isSelectedGray: false,
                hasWhiteText: false
            )
        }

        let saturatedBlueRatio = Double(saturatedBlue) / Double(total)
        let paleBlueRatio = Double(paleBlue) / Double(total)
        let selectedGrayRatio = Double(selectedGray) / Double(total)
        let whiteTextRatio = Double(whiteText) / Double(total)

        let hasSaturatedBlue = saturatedBlueRatio >= 0.18
        let hasPaleBlue = paleBlueRatio >= 0.18
        let hasSelectedGray = selectedGrayRatio >= 0.28
        let hasWhiteText = whiteTextRatio >= 0.006

        // Saturated blue needs white text confirmation. Pale blue and inactive gray
        // keep the older behavior because their text may be dark or antialiased.
        let selected =
            hasPaleBlue ||
            hasSelectedGray ||
            (hasSaturatedBlue && hasWhiteText)

        return ListRowSelectionAppearance(
            isSelected: selected,
            isPaleBlue: hasPaleBlue,
            isSaturatedBlue: hasSaturatedBlue,
            isSelectedGray: hasSelectedGray,
            hasWhiteText: hasWhiteText
        )
    }

    private func ocrSelectedListRowWhiteText(_ rect: CGRect) -> String? {
        guard let image = workingFullCGImage else { return nil }

        let expanded = rect.insetBy(dx: -4, dy: -2).integral
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cropRect = expanded.intersection(bounds)

        guard cropRect.width >= 20,
              cropRect.height >= 10,
              let crop = image.cropping(to: cropRect)
        else {
            return nil
        }

        // Vision reads white-on-blue selection text directly from the raw band
        // crop. The binarizing makeDarkerTextOCRImage pass erases antialiased
        // glyph pixels (VNC framebuffer text is blue-tinted, never pure white)
        // and turned "United States" into "UrhadiStatie" or nothing — keep it
        // only as a fallback for palettes the raw pass can't handle.
        if let label = runSelectedRowOCR(on: crop) {
            return label
        }
        guard let prepared = makeDarkerTextOCRImage(from: crop) else { return nil }
        return runSelectedRowOCR(on: prepared)
    }

    private func runSelectedRowOCR(on cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.05

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let candidates = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { cleanListOptionLabel($0) }
            .filter { !$0.isEmpty }
            .filter { isPlausibleListOptionText($0) }

        if let exact = candidates.first(where: { !$0.contains("\n") && $0.count <= 40 }) {
            return exact
        }

        return candidates.first
    }

    private func makeDarkerTextOCRImage(from image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height

        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var src = [UInt8](repeating: 0, count: height * bytesPerRow)

guard let srcContext = CGContext(
            data: &src,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        srcContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var dst = Array(repeating: UInt8(255), count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * bytesPerPixel
                let r = Int(src[i])
                let g = Int(src[i + 1])
                let b = Int(src[i + 2])
                let spread = max(r, max(g, b)) - min(r, min(g, b))

                let isWhiteGlyph =
                    r >= 220 &&
                    g >= 220 &&
                    b >= 220 &&
                    spread <= 35

                let isSaturatedSelection =
                    r <= 70 &&
                    g >= 85 && g <= 160 &&
                    b >= 210

                let isPaleSelection =
                    r >= 205 && r <= 245 &&
                    g >= 220 && g <= 252 &&
                    b >= 235 && b <= 255

                // Produce high-contrast black text on white background.
                // This is the inverted/darker-text pass for white glyphs.
                if isWhiteGlyph {
                    dst[i] = 0
                    dst[i + 1] = 0
                    dst[i + 2] = 0
                    dst[i + 3] = 255
                } else if isSaturatedSelection || isPaleSelection {
                    dst[i] = 255
                    dst[i + 1] = 255
                    dst[i + 2] = 255
                    dst[i + 3] = 255
                } else {
                    dst[i] = 255
                    dst[i + 1] = 255
                    dst[i + 2] = 255
                    dst[i + 3] = 255
                }
            }
        }

        guard let dstContext = CGContext(
            data: &dst,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        return dstContext.makeImage()
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted(); let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
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

    // MARK: - Stage 4c2: full-bleed hello screen button promotion

    /// The full-bleed hello screens have exactly one control: a pill button at
    /// bottom-center whose label is LOCALIZED while the greeting animation
    /// cycles ("Fortsätt", "Continuer", …), so the exact-label button table
    /// can't know it. When the scene classified as the hello screen and no
    /// button was detected, promote the short OCR text sitting in the
    /// bottom-center band to a button so click_control(role: button) works.
    private func promoteHelloBottomCenterButton(
        _ controls: [DetectedVisionControl],
        scene: SceneDefinition?,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> [DetectedVisionControl] {
        guard scene?.identifier == "hello" else { return controls }
        guard !controls.contains(where: { $0.type == "button" }) else { return controls }
        guard let candidate = controls
            .filter({ control in
                control.type == "text" &&
                control.rect.midY >= imageHeight * 0.72 &&
                abs(control.rect.midX - imageWidth / 2) <= imageWidth * 0.22 &&
                control.rect.width <= imageWidth * 0.25 &&
                control.label.count >= 2 && control.label.count <= 24
            })
            .min(by: { abs($0.rect.midX - imageWidth / 2) < abs($1.rect.midX - imageWidth / 2) })
        else { return controls }

        return controls.map { control in
            guard control.type == "text", control.rect == candidate.rect else { return control }
            let padded = control.rect.insetBy(dx: -14, dy: -8)
            return DetectedVisionControl(
                type: "button",
                label: control.label,
                confidence: max(control.confidence, 0.85),
                rect: padded,
                selected: nil,
                controlCenter: CGPoint(x: padded.midX, y: padded.midY),
                style: "secondary"
            )
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
        case "menuitem":     return .menuItem
        case "toggle":       return .toggleSwitch
        case "text":         return .text
        case "textfield":    return .textField
        case "menubar-item": return .menuBarItem
        case "dock-item":    return .dockItem
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
        let textControls = classifyTextControls(labels, image: rgb)
        controls.append(contentsOf: textControls)

        if let rgb {
            controls.append(contentsOf: detectPopoverMenuItems(
                labels: labels,
                existingControls: controls,
                image: rgb
            ))
            let components = findConnectedComponents(in: rgb)
            controls.append(contentsOf: detectRadioButtons(
                in: rgb, components: components, labels: labels))
            controls.append(contentsOf: detectToggles(
                in: rgb, components: components, labels: labels))
            controls.append(contentsOf: detectCheckboxes(
                in: rgb, components: components, labels: labels))
            controls.append(contentsOf: detectArrowContinueButton(
                in: rgb, components: components, existingControls: controls))

            // Chevron navigation rows (e.g. Age Range: Child/Teen/Adult ›). The
            // x-aligned, row-pitched chevron column is a stronger signal than a
            // stray radio hit, so when at least two rows fire they own their row
            // bands: any "radio" detected inside a band is really the row's
            // leading icon (Age Range's blue person glyphs), not a radio button.
            let navRows = detectChevronNavRows(in: rgb, labels: labels)
                .filter { row in
                    !controls.contains {
                        $0.type == "button" &&
                        intersectionRatio($0.rect, row.rect) > 0.3
                    }
                }
            vcsDebug("chevRows filtered=\(navRows.count)")
            if navRows.count >= 2 {
                // Radios/checkboxes in a band are the rows' leading icons;
                // textfields are the rows' light-gray fills misread as fields.
                // All of these outrank the nav row in mergeControls and would
                // erase it.
                let evicted: Set<String> = ["radio", "checkbox", "toggle", "textfield"]
                controls.removeAll { control in
                    evicted.contains(control.type) &&
                    navRows.contains { row in
                        control.rect.midY >= row.rect.minY &&
                        control.rect.midY <= row.rect.maxY
                    }
                }
                controls.append(contentsOf: navRows)
            }
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
        region: CGRect,
        minWidth: Int = 10,
        maxWidth: Int = 40,
        minHeight: Int = 10,
        maxHeight: Int = 38,
        minCount: Int = 8,
        minAspect: Double = 0.55,
        maxAspect: Double = 1.6,
        minPointiness: Double = 0.45
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
                guard width >= minWidth, width <= maxWidth,
                      height >= minHeight, height <= maxHeight,
                      count >= minCount else { continue }
                let aspect = Double(width) / Double(max(height, 1))
                guard aspect >= minAspect, aspect <= maxAspect else { continue }
                let fillRatio = Double(count) / Double(max(width * height, 1))
                guard fillRatio >= 0.10, fillRatio <= 0.45 else { continue }

                let pointiness = pointinessScore(
                    spanPerX: spanPerX,
                    minX: componentMinX,
                    maxX: componentMaxX,
                    minY: componentMinY,
                    maxY: componentMaxY
                )
                guard pointiness >= minPointiness else { continue }

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

    // MARK: - Chevron Navigation Rows (e.g. Age Range: Child / Teen / Adult ›)
    //
    // Some macOS 26 Setup Assistant screens present choices as full-width rows with
    // a right-aligned chevron (›) rather than radios or buttons. The single "Next"
    // chevron detector above only scans the bottom-right corner and returns one
    // glyph, so these screens previously yielded zero controls. This finds every
    // right-pointing chevron sitting near the right edge of the card, pairs each
    // with the left-aligned OCR text on the same row, and emits them as options
    // (type "radio-option" → role "option"). Callers should only invoke this when
    // no option/radio controls were already found, so it can't fight the normal
    // list-picker path.
    private func detectChevronNavRows(
        in image: RGBImage,
        labels: [TextLabel]
    ) -> [DetectedVisionControl] {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        // Right ~45% of the card, skipping the very top and bottom margins where a
        // back-chevron or Next-arrow would live.
        let region = CGRect(x: w * 0.55, y: h * 0.12, width: w * 0.45, height: h * 0.80)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        let chevrons = findChevronCandidates(
            in: image,
            region: region,
            minWidth: 5, maxWidth: 30,
            minHeight: 7, maxHeight: 30,
            minCount: 5,
            minAspect: 0.30, maxAspect: 1.7,
            minPointiness: 0.38
        ).sorted { $0.rect.minY < $1.rect.minY }
        vcsDebug("chevNav image=\(image.width)x\(image.height) region=\(region) candidates=\(chevrons.count)")
        for c in chevrons { vcsDebug("  cand rect=\(c.rect) count=\(c.pixelCount) fill=\(c.fillRatio) point=\(c.pointinessScore)") }
        // Need at least two chevrons to look like a row list rather than a stray glyph.
        guard chevrons.count >= 2 else { return [] }

        // Real navigation rows share a right-aligned chevron column (same x within a
        // small tolerance). Requiring that column rejects incidental gray strokes
        // (text serifs, icons) that the relaxed size bounds would otherwise admit.
        // Cluster by midX and take the largest cluster (rightmost on ties): body
        // text can contribute more stray candidates than there are real rows, so
        // a median would land in the noise.
        var clusters: [[ChevronCandidate]] = []
        for cand in chevrons.sorted(by: { $0.rect.midX < $1.rect.midX }) {
            if var last = clusters.last,
               let anchor = last.first,
               abs(cand.rect.midX - anchor.rect.midX) <= 8 {
                last.append(cand)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([cand])
            }
        }
        let column = (clusters.max { a, b in
            if a.count != b.count { return a.count < b.count }
            return a[0].rect.midX < b[0].rect.midX
        } ?? [])
            .sorted { $0.rect.minY < $1.rect.minY }
        vcsDebug("chevNav column=\(column.count) clusters=\(clusters.map { $0.count })")
        guard column.count >= 2 else { return [] }

        // The column must be spaced like stacked rows, not clustered curves within
        // a single icon or scattered text strokes: EVERY consecutive vertical gap
        // must be in the row-pitch range. Body-text noise produces overlapping or
        // wildly uneven gaps (Accessibility icon grid: [19.5, 117.5, -3, 47]),
        // while real nav rows are uniform (Age Range: [59, 60]).
        let ys = column.map { $0.rect.midY }
        let gaps = zip(ys.dropFirst(), ys).map { $0 - $1 }
        vcsDebug("chevNav gaps=\(gaps)")
        guard gaps.allSatisfy({ $0 >= 28 && $0 <= 140 }) else { return [] }

        // Find the left-aligned title text for each column chevron (same row, to its
        // left). Require at least one chevron to have a real title — icon grids (e.g.
        // Accessibility: Vision/Motor/Hearing/Cognitive) put their labels *below* the
        // icon, not to the left, so this rejects them while keeping Age Range, whose
        // "Adult" title sits to the left even when OCR drops the Child/Teen rows.
        func titleFor(_ chevron: ChevronCandidate) -> (text: String, minX: CGFloat, conf: Double)? {
            let tol = max(chevron.rect.height, 16)
            let onRow = labels.filter {
                abs($0.rect.midY - chevron.rect.midY) <= tol &&
                $0.rect.maxX < chevron.rect.minX - 4
            }
            // A row renders title above its subtitle with the chevron centered
            // between them, so the title is the label at-or-above the chevron's
            // midY; the subtitle ("18 or older") is below. Fall back to the
            // closest label when nothing sits above.
            let above = onRow.filter { $0.rect.midY <= chevron.rect.midY + 2 }
            let pool = above.isEmpty ? onRow : above
            guard let best = pool.min(by: {
                abs($0.rect.midY - chevron.rect.midY) < abs($1.rect.midY - chevron.rect.midY)
            }) else { return nil }
            // OCR can absorb the row's leading icon into the text ("* Child").
            var cleaned = cleanListOptionLabel(best.text)
            while let first = cleaned.first, !first.isLetter, !first.isNumber {
                cleaned.removeFirst()
                cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            }
            guard !cleaned.isEmpty else { return nil }
            return (cleaned, best.rect.minX, best.confidence)
        }
        let titles = column.map { titleFor($0) }
        vcsDebug("chevNav titles=\(titles.map { $0?.text ?? "nil" })")
        guard titles.contains(where: { $0 != nil }) else { return [] }

        // Shared left edge for the row rectangles: the leftmost real title we found.
        let columnLeft = titles.compactMap { $0?.minX }.min()
            ?? max(0, column[0].rect.midX - w * 0.30)

        var rows: [DetectedVisionControl] = []
        for (i, chevron) in column.enumerated() {
            let tolerance = max(chevron.rect.height, 16)
            let title = titles[i]?.text ?? "option-\(i + 1)"
            let labelConfidence = titles[i]?.conf ?? 0.60
            let rowLeft = max(0, columnLeft - 8)
            let rowRight = min(w - 1, chevron.rect.maxX + 6)
            let rowTop = max(0, chevron.rect.minY - tolerance)
            let rowBottom = min(h - 1, chevron.rect.maxY + tolerance)
            let rowRect = CGRect(
                x: rowLeft,
                y: rowTop,
                width: max(80, rowRight - rowLeft),
                height: max(24, rowBottom - rowTop)
            )
            rows.append(DetectedVisionControl(
                type: "radio-option",
                label: title,
                confidence: max(chevron.confidence, labelConfidence),
                rect: rowRect,
                selected: false,
                controlCenter: CGPoint(x: chevron.rect.midX, y: chevron.rect.midY),
                style: nil
            ))
        }
        guard rows.count >= 2 else { return [] }
        return rows
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
            var type = classifyTextType(label.text)
            let cleanedLabel = cleanButtonLabel(label.text)
            if isKnownPopoverMenuItemLabel(cleanedLabel) {
                type = "menuitem"
            }
            let selected: Bool?
            let style: String?
            if type == "button", let image {
                let app = buttonAppearance(textRect: label.rect, image: image)
                selected = app.enabled
                style = isDropdownButtonLabel(raw: label.text, cleaned: cleanedLabel) ? "dropdown" : app.style
            } else if type == "menuitem" {
                selected = false
                style = nil
            } else {
                selected = nil
                style = nil
            }
            let center: CGPoint? = (type == "button" || type == "menuitem")
                ? CGPoint(x: label.rect.midX, y: label.rect.midY) : nil
            let emittedLabel = (type == "button" || type == "menuitem") ? cleanedLabel : label.text
            return DetectedVisionControl(
                type: type,
                label: emittedLabel,
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
        var bluishPixels = 0
        var total = 0

        for y in bgMinY...bgMaxY {
            for x in bgMinX...bgMaxX {
                guard let pixel = image.pixel(x: x, y: y) else { continue }
                total += 1
                let lum = pixel.luminance
                if pixel.isSystemBlue { bluePixels += 1 }
                // Downscale-tolerant blue: Lanczos downscaling (default 720px) blends
                // white button text into the blue fill, producing light-blue pixels
                // (r > 100) that fail the strict isSystemBlue test. This relaxed bucket
                // still recognizes the fill so blue PRIMARY buttons (e.g. the Location
                // "Don't Use" sheet button) aren't misread as disabled secondary.
                let rr = Double(pixel.r), gg = Double(pixel.g), bb = Double(pixel.b)
                if bb >= 150 && bb > rr + 40 && bb > gg + 25 { bluishPixels += 1 }
                if lum < 60 { veryDark += 1 }
                else if lum >= 235 { whiteText += 1 }
                else if lum < 220 { lightInk += 1 }
            }
        }
        guard total > 0 else { return (true, "secondary") }

        let blueRatio   = Double(bluePixels)   / Double(total)
        let bluishRatio = Double(bluishPixels) / Double(total)
        let darkRatio   = Double(veryDark)     / Double(total)
        let lightRatio  = Double(lightInk)     / Double(total)
        let whiteRatio  = Double(whiteText)    / Double(total)

        // A predominantly blue fill is a primary button, regardless of how much of
        // the white glyph survived downscaling.
        if bluishRatio >= 0.40 {
            return (true, "primary")
        }
        if blueRatio >= 0.25 && whiteRatio >= 0.02 {
            return (true, "primary")
        }
        if darkRatio >= 0.03 {
            return (true, "secondary")
        }
        // Modal buttons rendered over a dimmed/blurred backdrop (e.g. the Terms &
        // Conditions "Agree"/"Disagree" sheet) have anti-aliased text whose glyph ink
        // lands mostly in the mid-tone (lightInk) bucket rather than the very-dark one.
        // The old rule declared any such button disabled as soon as lightRatio >= 0.04,
        // which mis-reported clearly-clickable modal buttons as enabled:false.
        // A genuinely disabled button has essentially NO dark ink core; a live button —
        // even a dimmed one — almost always keeps a few sub-60-luminance pixels at glyph
        // centers. So only call it disabled when dark ink is essentially absent.
        let hasDarkInkCore = darkRatio >= 0.008
        if lightRatio >= 0.04 && !hasDarkInkCore {
            return (false, "secondary")
        }
        return (true, "secondary")
    }

    private func classifyTextType(_ text: String) -> String {
        var normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "â", with: "")
            .replacingOccurrences(of: "â¾", with: "")
            .replacingOccurrences(of: "âº", with: "")
            .replacingOccurrences(of: "Ë", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let lastSpace = normalized.lastIndex(of: " "),
           normalized.distance(from: lastSpace, to: normalized.endIndex) == 2 {
            let tail = normalized[normalized.index(after: lastSpace)...]
            if ["v", "y", "u", "w"].contains(String(tail)) {
                normalized = String(normalized[..<lastSpace])
            }
        }
        if isKnownMacOSDropdownButtonLabel(normalized) {
            return "button"
        }
        let exactButtons: Set<String> = [
            "ok", "yes", "no", "done", "next", "back", "skip",
            "cancel", "close", "allow", "deny", "install",
            "continue", "submit", "save", "open", "choose",
            "setup", "finish", "agree", "accept", "decline",
            "create", "start", "stop", "retry", "disagree",
            "not now", "browse", "don't use", "dont use",
            "turn on", "turn off", "set up later",
            "only download automatically"
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
            "see how your data is managed",
            "use location services"
        ]
        for p in prefixButtons {
            if normalized.hasPrefix(p) { return "button" }
        }
        return "text"
    }

    private func isPrivateUseUnicodeScalar(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0xE000...0xF8FF).contains(value) ||
               (0xF0000...0xFFFFD).contains(value) ||
               (0x100000...0x10FFFD).contains(value)
    }

    private func cleanButtonLabel(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"\.{4,}"#, with: "…", options: .regularExpression)
        while let first = text.unicodeScalars.first,
              CharacterSet.symbols.contains(first) || isPrivateUseUnicodeScalar(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacingOccurrences(of: #"^\d\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(li|f|g|&)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "Sign-li", with: "Sign-In")
        text = text.replacingOccurrences(of: "Sign li", with: "Sign-In")
        text = text.replacingOccurrences(of: "Sign A Options", with: "Sign-In Options")
        text = text.replacingOccurrences(of: "Sign A", with: "Sign-In")
        text = text.replacingOccurrences(of: "Sign-l", with: "Sign-I")
        if isKnownMacOSDropdownButtonLabel(text) {
            text = canonicalMacOSDropdownButtonLabel(text)
        } else {
            text = text
                .replacingOccurrences(of: "▾", with: "")
                .replacingOccurrences(of: "⌄", with: "")
                .replacingOccurrences(of: "∨", with: "")
                .replacingOccurrences(of: "›", with: "")
                .replacingOccurrences(of: "ˇ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func normalizedDropdownButtonLabel(_ text: String) -> String {
        var normalized = text.lowercased()
            .replacingOccurrences(of: "▾", with: "")
            .replacingOccurrences(of: "⌄", with: "")
            .replacingOccurrences(of: "∨", with: "")
            .replacingOccurrences(of: "›", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "ˇ", with: "")
            .replacingOccurrences(of: "sign-li", with: "sign in")
            .replacingOccurrences(of: "sign li", with: "sign in")
            .replacingOccurrences(of: "sign a options", with: "sign in options")
            .replacingOccurrences(of: "sign-in", with: "sign in")
            .replacingOccurrences(of: "-", with: " ")
        normalized = normalized.replacingOccurrences(of: #"^\d\s+"#, with: "", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"^(li|f|g|&)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        normalized = normalized.replacingOccurrences(of: #"\s+v(\s|$)"#, with: " ", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"\s*\(field-[^)]+\)"#, with: "", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"\s*\[@[^\]]+\]"#, with: "", options: .regularExpression)
        while normalized.contains("  ") { normalized = normalized.replacingOccurrences(of: "  ", with: " ") }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func isKnownMacOSDropdownButtonLabel(_ text: String) -> Bool {
        let normalized = normalizedDropdownButtonLabel(text)
        return normalized.contains("other sign in options") || normalized.contains("other sign options")
    }
    private func canonicalMacOSDropdownButtonLabel(_ text: String) -> String {
        let normalized = normalizedDropdownButtonLabel(text)
        if normalized.contains("other sign") && normalized.contains("options") { return "Other Sign-In Options" }
        return text.replacingOccurrences(of: "▾", with: "").replacingOccurrences(of: "⌄", with: "").replacingOccurrences(of: "∨", with: "").replacingOccurrences(of: "›", with: "").replacingOccurrences(of: "ˇ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func normalizedMenuItemLabel(_ text: String) -> String {
        cleanButtonLabel(text).lowercased().replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func isKnownPopoverMenuItemLabel(_ text: String) -> Bool {
        let normalized = normalizedMenuItemLabel(text)
        return normalized == "use multiple accounts" || normalized == "sign in later in settings" || normalized.contains("use multiple accounts") || normalized.contains("sign in later")
    }
    private func isDropdownButtonLabel(raw: String, cleaned: String) -> Bool {
        if isKnownMacOSDropdownButtonLabel(raw) || isKnownMacOSDropdownButtonLabel(cleaned) { return true }
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return rawTrimmed.hasSuffix(" v") || rawTrimmed.hasSuffix("▾") || rawTrimmed.hasSuffix("⌄") || rawTrimmed.hasSuffix("∨") || rawTrimmed.hasSuffix("›") || rawTrimmed.hasSuffix("↓")
    }
    private func shouldPromoteTextFieldCandidateToDropdownButton(label: String, rect: CGRect, image: RGBImage) -> Bool {
        guard isKnownMacOSDropdownButtonLabel(label) else { return false }
        let aspect = rect.width / max(rect.height, 1)
        let buttonSized = rect.height >= 24 && rect.height <= 52 && rect.width >= 110 && rect.width <= 360 && aspect >= 2.8 && aspect <= 9.0
        guard buttonSized else { return false }
        let interior = rect.insetBy(dx: max(8, rect.width * 0.06), dy: max(5, rect.height * 0.20))
        let minX = max(0, Int(interior.minX.rounded()))
        let maxX = min(image.width - 1, Int(interior.maxX.rounded()))
        let minY = max(0, Int(interior.minY.rounded()))
        let maxY = min(image.height - 1, Int(interior.maxY.rounded()))
        guard maxX > minX, maxY > minY else { return true }
        var total = 0, nearWhite = 0, glyph = 0
        let strideX = max(1, (maxX - minX) / 90)
        let strideY = max(1, (maxY - minY) / 10)
        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                if let p = image.pixel(x: x, y: y) {
                    total += 1
                    if p.isNearWhite { nearWhite += 1 }
                    if p.luminance < 190 { glyph += 1 }
                }
                x += strideX
            }
            y += strideY
        }
        guard total > 0 else { return true }
        let nearWhiteRatio = Double(nearWhite) / Double(total)
        let glyphRatio = Double(glyph) / Double(total)
        return glyphRatio >= 0.025 || nearWhiteRatio < 0.94
    }
    private func promoteKnownAppleAccountDropdownButtons(_ controls: [DetectedVisionControl]) -> [DetectedVisionControl] {
        controls.map { control in
            guard control.type == "textfield", isKnownMacOSDropdownButtonLabel(control.label) else { return control }
            return DetectedVisionControl(type: "button", label: canonicalMacOSDropdownButtonLabel(control.label), confidence: max(control.confidence, 0.90), rect: control.rect, selected: true, controlCenter: control.controlCenter ?? CGPoint(x: control.rect.midX, y: control.rect.midY), style: "dropdown")
        }
    }
    private func detectPopoverMenuItems(labels: [TextLabel], existingControls: [DetectedVisionControl], image: RGBImage) -> [DetectedVisionControl] {
        var output: [DetectedVisionControl] = []
        let existingMenuItems = existingControls.filter { $0.type == "menuitem" }
        let allCandidates = existingControls + labels.map { label in
            DetectedVisionControl(type: "text", label: label.text, confidence: label.confidence, rect: label.rect.insetBy(dx: -12, dy: -8), selected: nil, controlCenter: nil, style: nil)
        }
        let useMultiple = allCandidates.first { normalizedMenuItemLabel($0.label).contains("use multiple accounts") }
        if let useMultiple {
            if !existingMenuItems.contains(where: { normalizedMenuItemLabel($0.label).contains("use multiple accounts") }) {
                output.append(DetectedVisionControl(type: "menuitem", label: "Use Multiple Accounts", confidence: max(useMultiple.confidence, 0.88), rect: useMultiple.rect, selected: false, controlCenter: CGPoint(x: useMultiple.rect.midX, y: useMultiple.rect.midY), style: nil))
            }
            let hasSignLater = existingMenuItems.contains { normalizedMenuItemLabel($0.label).contains("sign in later") } || labels.contains { normalizedMenuItemLabel($0.text).contains("sign in later") }
            if !hasSignLater {
                let rowHeight = max(useMultiple.rect.height, 31)
                let synthesizedRect = CGRect(x: useMultiple.rect.minX, y: useMultiple.rect.minY + rowHeight - 1, width: max(useMultiple.rect.width, 184), height: rowHeight)
                output.append(DetectedVisionControl(type: "menuitem", label: "Sign in Later in Settings", confidence: 0.86, rect: synthesizedRect, selected: false, controlCenter: CGPoint(x: synthesizedRect.midX, y: synthesizedRect.midY), style: nil))
            }
        }
        return output
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
            let paddedRect = rect.insetBy(dx: -4, dy: -4)
            if shouldPromoteTextFieldCandidateToDropdownButton(label: finalLabel, rect: paddedRect, image: image) {
                return DetectedVisionControl(type: "button", label: canonicalMacOSDropdownButtonLabel(finalLabel), confidence: max(label?.confidence ?? 0.90, 0.90), rect: paddedRect, selected: true, controlCenter: CGPoint(x: paddedRect.midX, y: paddedRect.midY), style: "dropdown")
            }
            return DetectedVisionControl(
                type: "textfield",
                label: finalLabel,
                confidence: max(label?.confidence ?? 0.78, 0.78),
                rect: paddedRect,
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

        // MUST be bounded: with 3+ interacting rects (e.g. the tall scrollable
        // Language list, whose stacked rows + scrollbar all read as adjacent
        // textfield candidates), snapping pair (A,B) can re-create overlap for
        // (B,C), whose snap re-creates (A,B), cycling forever. This hung the
        // Packer wait_for_scene loop for 5 minutes on 2026-07-01. Any
        // legitimate cascade settles in a handful of passes.
        var passes = 0

        // Iterate until stable â one snap can expose another sibling pair.
        while changed, passes < 8 {
            passes += 1
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

                    // 3. Trust the smaller box â too-tall boxes come from
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
                   ) -> [DetectedVisionControl] {                       var glyphRects: [(rect: CGRect, filled: Bool, confidence: Double)] = []
                       // A) Filled checkboxes via connected components.
                       for component in components {
                           let rect = component.rect
                           let w = rect.width
                           let h = rect.height
                           let aspect = w / max(h, 1)
                           guard w >= 12, w <= 26, h >= 12, h <= 26,
                                 aspect >= 0.78, aspect <= 1.28 else { continue }
                           guard component.blueRatio >= 0.20 else { continue }
                           guard component.fillRatio >= 0.45 else { continue }
                           if looksCircular(rect: rect, in: image) { continue }
                           // Same bounding-ring guard as the sliding-window scan: reject
                           // blue blobs that are part of a larger blue field (photographic
                           // water/sky on the "hello" transition frames, primary buttons).
                           if blueRingRatio(
                               image: image,
                               minX: Int(rect.minX.rounded()), minY: Int(rect.minY.rounded()),
                               maxX: Int(rect.maxX.rounded()), maxY: Int(rect.maxY.rounded()),
                               gap: 3
                           ) >= 0.5 {
                               continue
                           }
                           guard filledCheckboxInteriorPasses(
                               image: image,
                               minX: Int(rect.minX.rounded()), minY: Int(rect.minY.rounded()),
                               maxX: Int(rect.maxX.rounded()), maxY: Int(rect.maxY.rounded())
                           ) else { continue }
                           glyphRects.append((rect, true, 0.84))
                       }
                       // B) Dedicated full-frame scans. These MUST be outside the component loop;
                       // otherwise no glyphs are emitted if component filtering rejects every candidate.
                       glyphRects.append(contentsOf: findFilledCheckboxes(in: image))
                       glyphRects.append(contentsOf: findEmptyCheckboxes(in: image))
                       // De-dupe glyphs (filled wins over empty).
                       let glyphs = mergeCheckboxGlyphs(glyphRects)

                       // C) Label association + multi-line assembly.
                       // C) Label association + multi-line assembly.
                       var output: [DetectedVisionControl] = []
                       var fallbackIndex = 0
                       for glyph in glyphs {
                           let labelInfo = checkboxLabel(for: glyph.rect, labels: labels)
                           // Every real filled (checked) Setup Assistant checkbox has its
                           // label text directly to the right. Filled candidates with no
                           // such text are windows into decorative artwork — the Location
                           // arrow icon, the Siri orb, avatar icons — that survive the
                           // pixel gates because they genuinely are system blue + white.
                           if glyph.filled && labelInfo == nil {
                               vcsDebug("filled glyph dropped (no label) rect=\(glyph.rect); nearest right-labels: " +
                                   labels.filter { abs($0.rect.midY - glyph.rect.midY) <= 40 }
                                       .map { "'\($0.text)' minX=\($0.rect.minX) midY=\($0.rect.midY) (glyph maxX=\(glyph.rect.maxX) midY=\(glyph.rect.midY))" }
                                       .joined(separator: "; "))
                               continue
                           }
                           fallbackIndex += 1
                           let labelText: String
                           let labelConfidence: Double
                           if let labelInfo {
                               labelText = labelInfo.text
                               labelConfidence = labelInfo.confidence
                           } else {
                               // No nearby OCR text â emit anyway with a positional fallback so
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
                       if let synthetic = synthesizeAppleAccountResetCheckboxFromOCR(labels: labels, image: image) {
                           if let existingIndex = output.firstIndex(where: { $0.type == "checkbox" && ($0.label.lowercased().contains("allow computer account password") || $0.label.lowercased().contains("password to be reset") || $0.label.lowercased().contains("reset with your apple account")) }) {
                               let existing = output[existingIndex]
                               // Prefer the synthetic's label when it carries more of
                               // the wrapped checkbox sentence — the glyph-associated
                               // label is often just the merged first OCR line
                               // ("Hint (Optional) Allow computer account password…"),
                               // which loses the "sign in with your Apple Account"
                               // clause the automation grammar matches on.
                               let mergedLabel = synthetic.label.count > existing.label.count
                                   ? synthetic.label : existing.label
                               output[existingIndex] = DetectedVisionControl(type: existing.type, label: mergedLabel, confidence: max(existing.confidence, synthetic.confidence), rect: existing.rect.union(synthetic.rect), selected: (existing.selected == true || synthetic.selected == true), controlCenter: synthetic.controlCenter ?? existing.controlCenter, style: existing.style)
                           } else { output.append(synthetic) }
                       }
                       return dedupe(output)
                   }
                   private func synthesizeActionVerbCheckboxesFromOCR(labels: [TextLabel], image: RGBImage, existing: [DetectedVisionControl]) -> [DetectedVisionControl] {
                       let actionPrefixes = [
                           "enable ask siri",
                           "enable location services on this mac"
                       ]
                       var output: [DetectedVisionControl] = []
                       for label in labels {
                           let stripped = stripLeadingCheckboxGlyph(label.text)
                           let normalized = stripped.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                           guard actionPrefixes.contains(where: { normalized.contains($0) }) else { continue }
                           let glyphSize = max(12.0, min(18.0, label.rect.height * 0.55))
                           let glyphX: CGFloat
                           if stripped.hadGlyph {
                               glyphX = max(0, label.rect.minX + 2)
                           } else {
                               glyphX = max(0, label.rect.minX - glyphSize - 7)
                           }
                           let glyphRect = CGRect(x: glyphX, y: label.rect.midY - glyphSize / 2.0, width: glyphSize, height: glyphSize)
                           if existing.contains(where: { $0.type == "checkbox" && intersectionRatio($0.rect, glyphRect) > 0.25 }) { continue }
                           let probe = probeCheckboxGlyph(glyphRect, in: image)
                           let selected = stripped.hadCheckedGlyph || probe.filled
                           let combinedRect = glyphRect.union(label.rect).insetBy(dx: -4, dy: -4)
                           output.append(DetectedVisionControl(
                               type: "checkbox",
                               label: stripped.text,
                               confidence: max(label.confidence, probe.confidence),
                               rect: combinedRect,
                               selected: selected,
                               controlCenter: CGPoint(x: glyphRect.midX, y: glyphRect.midY),
                               style: nil
                           ))
                       }
                       return output
                   }
                   private func stripLeadingCheckboxGlyph(_ raw: String) -> (text: String, hadGlyph: Bool, hadCheckedGlyph: Bool) {
                       var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                       let glyphs: Set<Character> = ["J", "/", "✓", "✔", "☑", "☒", "□", "■", "☐"]
                       var hadGlyph = false
                       var hadCheckedGlyph = false
                       while let first = text.first, glyphs.contains(first) {
                           hadGlyph = true
                           if first != "□" && first != "☐" { hadCheckedGlyph = true }
                           text.removeFirst()
                           text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                       }
                       return (text, hadGlyph, hadCheckedGlyph)
                   }
                   private func probeCheckboxGlyph(_ glyphRect: CGRect, in image: RGBImage) -> (filled: Bool, confidence: Double, blueRatio: Double, whiteRatio: Double) {
                       let sample = glyphRect.insetBy(dx: -2, dy: -2)
                       let minX = max(0, Int(sample.minX.rounded()))
                       let maxX = min(image.width - 1, Int(sample.maxX.rounded()))
                       let minY = max(0, Int(sample.minY.rounded()))
                       let maxY = min(image.height - 1, Int(sample.maxY.rounded()))
                       guard maxX > minX, maxY > minY else { return (false, 0.55, 0, 0) }
                       var total = 0, blue = 0, white = 0, border = 0
                       for y in minY...maxY {
                           for x in minX...maxX {
                               guard let p = image.pixel(x: x, y: y) else { continue }
                               total += 1
                               if p.isSystemBlue || p.isBlue { blue += 1 }
                               if p.isNearWhite { white += 1 }
                               if p.isCheckboxEmptyBorder { border += 1 }
                           }
                       }
                       guard total > 0 else { return (false, 0.55, 0, 0) }
                       let blueRatio = Double(blue) / Double(total)
                       let whiteRatio = Double(white) / Double(total)
                       let borderRatio = Double(border) / Double(total)
                       let filled = blueRatio >= 0.08 || (blueRatio >= 0.045 && whiteRatio >= 0.08)
                       let confidence = filled ? min(0.92, 0.70 + blueRatio) : (borderRatio >= 0.08 ? 0.74 : 0.64)
                       return (filled, confidence, blueRatio, whiteRatio)
                   }
                   private func synthesizeAppleAccountResetCheckboxFromOCR(labels: [TextLabel], image: RGBImage) -> DetectedVisionControl? {
                       let haystack = labels.map { $0.text.lowercased() }.joined(separator: " | ")
                       let strongAnchors = ["allow computer account password", "allow computer account password to be reset", "password to be reset", "reset with your apple account"]
                       let appleResetContextExists = strongAnchors.contains { haystack.contains($0) }
                       let matches = labels.filter { label in
                           let normalized = label.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                           if strongAnchors.contains(where: { normalized.contains($0) }) { return true }
                           if appleResetContextExists && normalized.contains("use this feature") { return true }
                           return false
                       }
                       guard let first = matches.sorted(by: { $0.rect.minY < $1.rect.minY }).first else { return nil }
                       let raw = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
                       let glyphChars: Set<Character> = ["/", "✓", "✔", "☑"]
                       let trimmedRaw = raw.drop(while: { $0.isWhitespace })
                       let firstGlyphIsInOCRLine = trimmedRaw.first.map { glyphChars.contains($0) } ?? false
                       var clean = raw.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: "✓", with: "").replacingOccurrences(of: "✔", with: "").replacingOccurrences(of: "☑", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                       // OCR can merge the Hint field's placeholder into the anchor
                       // line ("Hint (Optional) Allow computer account password…").
                       // Cut everything before the sentence start so downstream
                       // label_contains matching sees the real checkbox text.
                       if let anchorRange = clean.range(of: "allow computer account password", options: .caseInsensitive),
                          anchorRange.lowerBound != clean.startIndex {
                           clean = String(clean[anchorRange.lowerBound...])
                       }
                       // The checkbox text wraps over ~3 OCR lines; the anchor line
                       // alone drops "You must sign in with your Apple Account…",
                       // which the automation grammar matches on. Chain the lines
                       // directly below the anchor that share its text column.
                       var blockBottom = first.rect
                       var lastRect = first.rect
                       let continuations = labels
                           .filter { $0.rect.minY > first.rect.minY + 2 }
                           .sorted { $0.rect.minY < $1.rect.minY }
                       for line in continuations {
                           let sameColumn = line.rect.minX > first.rect.minX - 30 &&
                                            line.rect.minX < first.rect.minX + 60
                           let verticallyChained = line.rect.minY < lastRect.maxY + lastRect.height * 1.2
                           guard sameColumn, verticallyChained else { continue }
                           let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                           guard !text.isEmpty else { continue }
                           vcsDebug("resetCbx chained line=\(text) rect=\(line.rect)")
                           clean += " " + text
                           lastRect = line.rect
                           blockBottom = blockBottom.union(line.rect)
                       }
                       vcsDebug("resetCbx label=\(clean) anchorRect=\(first.rect) blockRect=\(blockBottom)")
                       let glyphSize: CGFloat = 16
                       let glyphX: CGFloat = firstGlyphIsInOCRLine ? first.rect.minX + 2 : max(0, first.rect.minX - glyphSize - 6)
                       let glyphRect = CGRect(x: glyphX, y: first.rect.midY - glyphSize / 2, width: glyphSize, height: glyphSize)
                       let combinedRect = glyphRect.union(blockBottom).insetBy(dx: -4, dy: -4)
                       let pixelSampleSaysChecked = appleResetCheckboxGlyphLooksSelected(glyphRect: glyphRect, in: image)
                       return DetectedVisionControl(type: "checkbox", label: clean, confidence: max(first.confidence, 0.80), rect: combinedRect, selected: firstGlyphIsInOCRLine || pixelSampleSaysChecked, controlCenter: CGPoint(x: glyphRect.midX, y: glyphRect.midY), style: nil)
                   }
                   private func appleResetCheckboxGlyphLooksSelected(glyphRect: CGRect, in image: RGBImage) -> Bool {
                       let sample = glyphRect.insetBy(dx: 2, dy: 2)
                       let minX = max(0, Int(sample.minX.rounded())), maxX = min(image.width - 1, Int(sample.maxX.rounded()))
                       let minY = max(0, Int(sample.minY.rounded())), maxY = min(image.height - 1, Int(sample.maxY.rounded()))
                       guard maxX > minX, maxY > minY else { return false }
                       var total = 0, blue = 0, white = 0
                       for y in minY...maxY { for x in minX...maxX { guard let p = image.pixel(x: x, y: y) else { continue }; total += 1; if p.isSystemBlue || p.isBlue { blue += 1 }; if p.isNearWhite { white += 1 } } }
                       guard total > 0 else { return false }
                       let blueRatio = Double(blue) / Double(total), whiteRatio = Double(white) / Double(total)
                       return blueRatio >= 0.18 || (blueRatio >= 0.10 && whiteRatio >= 0.10)
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

            guard filledCheckboxInteriorPasses(
                image: image, minX: minX, minY: minY, maxX: maxX, maxY: maxY
            ) else { continue }

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

            // Reject windows carved out of a larger blue shape — a saturated-blue
            // primary button ("Don't Use"), the blue menu bar, etc. A real filled
            // checkbox is a small blue square bounded by the white card, so the thin
            // ring just outside it is mostly non-blue. If that ring is itself heavily
            // blue, this candidate is interior to a big blue region, not a checkbox.
            // Without this, one blue button was shredded into dozens of phantom
            // "checkbox" controls.
            if blueRingRatio(
                image: image,
                minX: minX, minY: minY, maxX: maxX, maxY: maxY, gap: 3
            ) >= 0.5 {
                continue
            }

            return CGRect(x: minX, y: minY, width: size, height: size)
        }
        return nil
    }

    /// A real filled checkbox is flat macOS *system* blue carrying a white
    /// checkmark, and contains almost nothing else. Measured on real scenes
    /// (sysBlue/blue, white, other): genuine boxes ≈ (0.77+, 0.25–0.38, ≤0.03);
    /// photographic wallpaper ≈ (0.00–0.04, 0.00, high); avatar icons and the
    /// Siri orb ≈ (0.00–0.39, —, ≥0.11). These gates took the photographic
    /// "hello" frames from ~338 phantom checkboxes to 0 while keeping the
    /// genuine Siri/Location boxes.
    private func filledCheckboxInteriorPasses(
        image: RGBImage, minX: Int, minY: Int, maxX: Int, maxY: Int
    ) -> Bool {
        var blue = 0, sysBlue = 0, white = 0, total = 0
        for y in minY...maxY {
            for x in minX...maxX {
                guard let p = image.pixel(x: x, y: y) else { continue }
                total += 1
                if p.isSystemBlue || p.isBlue {
                    blue += 1
                    if p.isSystemBlue { sysBlue += 1 }
                } else if p.isNearWhite {
                    white += 1
                }
            }
        }
        guard total > 0, blue > 0 else { return false }
        let blueRatio = Double(blue) / Double(total)
        let whiteRatio = Double(white) / Double(total)
        let systemBlueShare = Double(sysBlue) / Double(blue)
        let otherRatio = 1.0 - blueRatio - whiteRatio
        guard blueRatio >= 0.45, blueRatio <= 0.98,
              whiteRatio >= 0.10, whiteRatio <= 0.45,
              systemBlueShare >= 0.5,
              otherRatio <= 0.08 else { return false }

        // A real checkbox is bounded by the card on BOTH sides. A window carved
        // from a wide blue shape (primary button around its white text, the card's
        // rounded corner against blue wallpaper) has blue continuing past its left
        // or right edge, even when the overall ring reads < 0.5.
        var leftBlue = 0, leftTotal = 0, rightBlue = 0, rightTotal = 0
        for y in (minY - 3)...(maxY + 3) {
            if let p = image.pixel(x: minX - 3, y: y) {
                leftTotal += 1
                if p.isSystemBlue || p.isBlue { leftBlue += 1 }
            }
            if let p = image.pixel(x: maxX + 3, y: y) {
                rightTotal += 1
                if p.isSystemBlue || p.isBlue { rightBlue += 1 }
            }
        }
        let leftRatio = leftTotal > 0 ? Double(leftBlue) / Double(leftTotal) : 1
        let rightRatio = rightTotal > 0 ? Double(rightBlue) / Double(rightTotal) : 1
        return leftRatio <= 0.5 && rightRatio <= 0.5
    }

    /// Fraction of pixels in a thin ring `gap` px outside the given square that read
    /// as blue. Used to distinguish a bounded blue checkbox glyph (ring mostly white
    /// card) from a window interior to a larger blue shape (ring also blue).
    private func blueRingRatio(
        image: RGBImage, minX: Int, minY: Int, maxX: Int, maxY: Int, gap: Int
    ) -> Double {
        var blue = 0, total = 0
        let ax0 = minX - gap, ax1 = maxX + gap
        let ay0 = minY - gap, ay1 = maxY + gap
        func sample(_ x: Int, _ y: Int) {
            guard let p = image.pixel(x: x, y: y) else { return }
            total += 1
            if p.isSystemBlue || p.isBlue { blue += 1 }
        }
        var x = ax0
        while x <= ax1 { sample(x, ay0); sample(x, ay1); x += 1 }
        var y = ay0
        while y <= ay1 { sample(ax0, y); sample(ax1, y); y += 1 }
        return total > 0 ? Double(blue) / Double(total) : 0
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
                               guard abs($0.rect.midY - glyphRect.midY) <= 24 else { return false }
                               let leftGap = $0.rect.minX - glyphRect.maxX
                               if leftGap >= 6 && leftGap <= 60 { return true }
                               // OCR can absorb the checkmark into the text line
                               // ("J Enable Ask Siri"), making the line START inside
                               // the glyph instead of to its right.
                               return $0.rect.minX >= glyphRect.minX - 4 &&
                                      $0.rect.minX <= glyphRect.maxX + 5
                           }
                           .min { $0.rect.minX < $1.rect.minX }

                       guard let first = firstLine else { return nil }
                       let firstText: String
                       if first.rect.minX < glyphRect.maxX {
                           firstText = stripLeadingCheckboxGlyph(first.text).text
                       } else {
                           firstText = first.text
                       }

                       let lineH = max(first.rect.height, 14)
                       let continuations = labels
                           .filter { l in
                               guard l.rect.minY > first.rect.minY else { return false }
                               guard abs(l.rect.minX - first.rect.minX) <= 12 else { return false }
                               return true
                           }
                           .sorted { $0.rect.minY < $1.rect.minY }

                       var assembled = firstText.trimmingCharacters(in: .whitespacesAndNewlines)
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
