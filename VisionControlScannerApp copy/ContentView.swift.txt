import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var imageURL: URL?
    @Published var image: NSImage?
    @Published var cgImage: CGImage?
    @Published var detections: [Detection] = []
    @Published var allDetections: [Detection] = []
    @Published var summary: SetupScreenSummary?
    @Published var isAnalyzing = false
    @Published var status = "Choose a screenshot to begin."
    @Published var showText = false

    func openScreenshot() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .bmp]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open Screenshot"

        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func load(url: URL) {
        imageURL = url
        image = NSImage(contentsOf: url)
        cgImage = loadCGImage(from: url)
        detections = []
        allDetections = []
        summary = nil
        status = "Loaded \(url.lastPathComponent). Click Analyze."
    }

    func analyze() {
        guard let cgImage else {
            status = "Open an image first."
            return
        }

        isAnalyzing = true
        status = "Analyzing screenshot…"

        let detector = VisionControlDetector()

        Task {
            do {
                let result = try detector.analyze(cgImage: cgImage)
                self.allDetections = result.detections
                self.detections = showText
                    ? result.detections
                    : result.detections.filter { $0.kind != .text }
                self.summary = result.summary

                let controls = result.detections.filter { $0.kind != .text }.count
                let texts = result.detections.filter { $0.kind == .text }.count
                self.status = "Found \(controls) control candidate(s) and \(texts) text region(s)."
            } catch {
                self.allDetections = []
                self.detections = []
                self.summary = nil
                self.status = "Analysis failed: \(error.localizedDescription)"
            }

            self.isAnalyzing = false
        }
    }

    func refreshVisibleDetections() {
        detections = showText
            ? allDetections
            : allDetections.filter { $0.kind != .text }
    }
}


struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 340, ideal: 430)
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open Screenshot") {
                    model.openScreenshot()
                }

                Button(model.isAnalyzing ? "Analyzing…" : "Analyze") {
                    model.analyze()
                }
                .disabled(model.isAnalyzing || model.cgImage == nil)

                Toggle("Show OCR text", isOn: $model.showText)
                    .onChange(of: model.showText) { _, _ in
                        model.refreshVisibleDetections()
                    }
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Detections")
                    .font(.title2.bold())

                Text(model.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = model.imageURL {
                    Text(url.lastPathComponent)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if let summary = model.summary {
                    summarySection(summary)
                }

                Divider()

                if model.detections.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)

                        Text("No detections yet")
                            .font(.headline)

                        Text("Open a screenshot, then click Analyze.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    rawDetectionsSection
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func summarySection(_ summary: SetupScreenSummary) -> some View {
        Divider()

        Text("Setup Summary")
            .font(.headline)

        if let title = summary.title, !title.isEmpty {
            Text("Title: \(title)")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let subtitle = summary.subtitle, !subtitle.isEmpty {
            Text("Subtitle: \(subtitle)")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        
        if !summary.textFields.isEmpty {
            Text("Text Fields:")
                .font(.subheadline.weight(.semibold))
            ForEach(summary.textFields) { field in
                Text("- \(field.label)\(field.focused ? " [focused]" : "")")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }


        if let prompt = summary.prompt, !prompt.isEmpty {
            Text("Prompt: \(prompt)")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !summary.options.isEmpty {
            Text("Options:")
                .font(.subheadline.weight(.semibold))

            ForEach(summary.options) { option in
                Text("- \(option.text)\(option.selected ? " [selected]" : "")")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        let advanceButtons = summary.buttons.filter { $0.role == .advance }
        if !advanceButtons.isEmpty {
            Text("Advance Buttons:")
                .font(.subheadline.weight(.semibold))

            ForEach(advanceButtons) { button in
                Text("- \(button.text) [\(button.enabled ? "enabled" : "disabled")]")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        let backButtons = summary.buttons.filter { $0.role == .back }
        if !backButtons.isEmpty {
            Text("Back:")
                .font(.subheadline.weight(.semibold))

            ForEach(backButtons) { button in
                Text("- \(button.text) [\(button.enabled ? "enabled" : "disabled")]")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var rawDetectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Raw Detections")
                .font(.headline)

            ForEach(model.detections) { detection in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(detection.kind.rawValue)
                            .font(.headline)
                        Spacer()
                        Text(String(format: "%.2f", detection.confidence))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if let label = detection.label, !label.isEmpty {
                        Text(label)
                            .font(.subheadline)
                    }

                    Text("Value: \(detection.value)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(
                        String(
                            format: "box: x=%.3f y=%.3f w=%.3f h=%.3f",
                            detection.boundingBox.minX,
                            detection.boundingBox.minY,
                            detection.boundingBox.width,
                            detection.boundingBox.height
                        )
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)

                Divider()
            }
        }
    }

    private var detailView: some View {
        ZStack {
            Color.black.opacity(0.04)

            if let image = model.image {
                GeometryReader { proxy in
                    let fitted = aspectFitRect(imageSize: image.size, in: proxy.size)

                    VStack {
                        Spacer(minLength: 0)

                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: fitted.width, height: fitted.height)
                            .overlay(alignment: .topLeading) {
                                DetectionOverlay(
                                    detections: model.detections,
                                    imageRect: CGRect(origin: .zero, size: fitted.size)
                                )
                            }

                        Spacer(minLength: 0)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)

                    Text("Open a screenshot")
                        .font(.headline)

                    Text("The selected image will appear here with red detection boxes.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct DetectionOverlay: View {
    let detections: [Detection]
    let imageRect: CGRect

    var body: some View {
        Canvas { context, _ in
            for detection in detections {
                let rect = viewRect(from: detection.boundingBox, imageRect: imageRect)
                let path = Path(roundedRect: rect, cornerRadius: 4)

                context.stroke(path, with: .color(.red), lineWidth: 2)

                let labelText: String
                if let label = detection.label, !label.isEmpty {
                    labelText = "\(detection.kind.rawValue) • \(label)"
                } else {
                    labelText = "\(detection.kind.rawValue) • \(detection.value)"
                }

                let label = Text(labelText)
                    .font(.caption2.bold())
                    .foregroundColor(.red)

                context.draw(
                    label,
                    at: CGPoint(x: rect.minX + 4, y: max(8, rect.minY - 10)),
                    anchor: .bottomLeading
                )
            }
        }
        .allowsHitTesting(false)
    }
}
