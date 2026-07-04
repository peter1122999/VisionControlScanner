import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum CLI {
    /// Returns true if CLI mode handled the invocation (caller should NOT
    /// start the SwiftUI app). Returns false if no CLI args were given.
    @discardableResult
    static func runIfNeeded() -> Bool {
        if CLI.findCardRunIfNeeded(CommandLine.arguments) { return true }
        let args = CommandLine.arguments
        guard args.count > 1 else { return false }
        // Strip Xcode debugger noise.
        let userArgs = Array(args.dropFirst()).filter {
            !$0.hasPrefix("-NSDocumentRevisionsDebugMode") &&
            !$0.hasPrefix("YES")
        }
        guard let command = userArgs.first else { return false }
        switch command {
        case "analyze":
            analyze(Array(userArgs.dropFirst()))
        case "watch":
            watch(Array(userArgs.dropFirst()))
        case "serve":
            serve(Array(userArgs.dropFirst()))
        case "vnc-screenshot":
            vncScreenshot(Array(userArgs.dropFirst()))
        case "vnc-watch":
            vncWatch(Array(userArgs.dropFirst()))
        case "--help", "-h", "help":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data(
                "Unknown command: \(command)\n".utf8
            ))
            printUsage()
            exit(2)
        }
        return true
    }

    // MARK: - analyze

    private static func analyze(_ args: [String]) {
        var inputPath: String?
        var outputPath: String?
        var jsonMode = true
        var prettyPrint = true
        var maxHeight: Int = 720
        var format: String = "default"   // "default" | "tart"
        var includeChrome = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-o", "--output":
                guard i + 1 < args.count else { fatal("Missing value for \(arg)") }
                outputPath = args[i + 1]; i += 2
            case "--text":
                jsonMode = false; i += 1
            case "--compact":
                prettyPrint = false; i += 1
            case "--max-height":
                guard i + 1 < args.count, let h = Int(args[i + 1]) else {
                    fatal("Missing or invalid value for --max-height")
                }
                maxHeight = h; i += 2
            case "--full-resolution":
                maxHeight = 0; i += 1
            case "--include-chrome":
                includeChrome = true; i += 1
            case "--format":
                guard i + 1 < args.count else { fatal("Missing value for --format") }
                format = args[i + 1].lowercased()
                guard format == "default" || format == "tart" else {
                    fatal("--format must be 'default' or 'tart'")
                }
                i += 2
            default:
                if inputPath == nil { inputPath = arg }
                else { fatal("Unexpected argument: \(arg)") }
                i += 1
            }
        }
        guard let inputPath else {
            fatal("analyze requires an input image path")
        }
        let url = URL(fileURLWithPath: inputPath)
        guard let cgImage = loadCGImage(from: url) else {
            fatal("Could not load image at \(inputPath)")
        }
        let cap = maxHeight > 0 ? maxHeight : nil
        let result = analyzeViaServerOrLocal(
            imagePath: inputPath,
            cgImage: cgImage,
            maxHeight: cap,
            includeChrome: includeChrome
        )
        let payload: String
        if jsonMode {
            switch format {
            case "tart":
                payload = encodeTartJSON(
                    result: result,
                    sourcePath: inputPath,
                    imageWidth: cgImage.width,
                    imageHeight: cgImage.height,
                    pretty: prettyPrint,
                    cgImage: cgImage
                )
            default:
                payload = encodeJSON(
                    result: result,
                    sourcePath: inputPath,
                    pretty: prettyPrint
                )
            }
        } else {
            payload = encodeText(result: result, sourcePath: inputPath)
        }
        write(payload, to: outputPath)
    }

    /// Try the server socket first; fall back to in-process if anything fails.
    private static func analyzeViaServerOrLocal(
        imagePath: String,
        cgImage: CGImage,
        maxHeight: Int?,
        includeChrome: Bool = false
    ) -> AnalysisResult {
        let env = ProcessInfo.processInfo.environment
        let envSocket = env["VCS_SOCKET"]
        let socketPath: String?
        if envSocket == "" {
            socketPath = nil
        } else {
            socketPath = envSocket ?? "/tmp/vcs.sock"
        }
        if let sp = socketPath, FileManager.default.fileExists(atPath: sp) {
            if let serverResult = ServerClient.analyze(
                socketPath: sp,
                imagePath: imagePath,
                maxHeight: maxHeight,
                includeChrome: includeChrome
            ) {
                return serverResult
            }
        }
        let detector = VisionControlDetector()
        do {
            return try detector.analyze(cgImage: cgImage, maxHeight: maxHeight, includeChrome: includeChrome)
        } catch {
            fatal("Analysis failed: \(error.localizedDescription)")
        }
    }

    // MARK: - watch

    private static func watch(_ args: [String]) {
        var folder: String?
        var outputDir: String?
        var maxHeight: Int = 720
        var format: String = "default"
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-o", "--output":
                guard i + 1 < args.count else { fatal("Missing value for \(arg)") }
                outputDir = args[i + 1]; i += 2
            case "--max-height":
                guard i + 1 < args.count, let h = Int(args[i + 1]) else {
                    fatal("Missing or invalid value for --max-height")
                }
                maxHeight = h; i += 2
            case "--full-resolution":
                maxHeight = 0; i += 1
            case "--format":
                guard i + 1 < args.count else { fatal("Missing value for --format") }
                format = args[i + 1].lowercased()
                guard format == "default" || format == "tart" else {
                    fatal("--format must be 'default' or 'tart'")
                }
                i += 2
            default:
                if folder == nil { folder = arg }
                else { fatal("Unexpected: \(arg)") }
                i += 1
            }
        }
        guard let folder else { fatal("watch requires a folder path") }
        let folderURL = URL(fileURLWithPath: folder)
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder) else {
            fatal("Folder does not exist: \(folder)")
        }
        FileHandle.standardError.write(Data("Watching \(folder)\n".utf8))
        var seen = Set<String>(
            (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        )
        while true {
            Thread.sleep(forTimeInterval: 1.0)
            guard let now = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            let nowSet = Set(now)
            let added = nowSet.subtracting(seen)
            seen = nowSet
            for name in added where isImage(name) {
                let imageURL = folderURL.appendingPathComponent(name)
                Thread.sleep(forTimeInterval: 0.4)
                guard let cgImage = loadCGImage(from: imageURL) else { continue }
                let cap = maxHeight > 0 ? maxHeight : nil
                let result = analyzeViaServerOrLocal(
                    imagePath: imageURL.path,
                    cgImage: cgImage,
                    maxHeight: cap
                )
                let payload: String
                switch format {
                case "tart":
                    payload = encodeTartJSON(
                        result: result,
                        sourcePath: imageURL.path,
                        imageWidth: cgImage.width,
                        imageHeight: cgImage.height,
                        pretty: false,
                        cgImage: cgImage
                    )
                default:
                    payload = encodeJSON(
                        result: result,
                        sourcePath: imageURL.path,
                        pretty: false
                    )
                }
                if let outputDir {
                    let base = (name as NSString).deletingPathExtension
                    let outURL = URL(fileURLWithPath: outputDir)
                        .appendingPathComponent("\(base).json")
                    try? payload.write(to: outURL, atomically: true, encoding: .utf8)
                    FileHandle.standardError.write(Data("→ \(outURL.path)\n".utf8))
                } else {
                    print(payload)
                }
            }
        }
    }

    // MARK: - serve

    private static func serve(_ args: [String]) {
        var socketPath = "/tmp/vcs.sock"
        var maxHeight = 720
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--socket":
                guard i + 1 < args.count else { fatal("Missing --socket value") }
                socketPath = args[i + 1]; i += 2
            case "--max-height":
                guard i + 1 < args.count, let h = Int(args[i + 1]) else {
                    fatal("Missing or invalid --max-height value")
                }
                maxHeight = h; i += 2
            default:
                fatal("Unexpected argument: \(args[i])")
            }
        }
        do {
            try Server.run(socketPath: socketPath, maxHeight: maxHeight)
        } catch {
            fatal("serve failed: \(error.localizedDescription)")
        }
    }

    // MARK: - vnc-screenshot / vnc-watch

    private struct VNCArgs {
        var host: String?
        var port: UInt16 = 5900
        var password: String?
        var outputPath: String?
        var format: String = "none"   // "none" | "default" | "tart"
        var jsonOutputPath: String?
        var maxHeight: Int = 720
        var prettyPrint = true
        var intervalMillis: Int = 1000
    }

    private static func parseVNCArgs(_ args: [String], usage: String) -> VNCArgs {
        var v = VNCArgs()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--host":
                guard i + 1 < args.count else { fatal("Missing value for --host") }
                v.host = args[i + 1]; i += 2
            case "--port":
                guard i + 1 < args.count, let p = UInt16(args[i + 1]) else {
                    fatal("Missing or invalid value for --port")
                }
                v.port = p; i += 2
            case "--password":
                guard i + 1 < args.count else { fatal("Missing value for --password") }
                v.password = args[i + 1]; i += 2
            case "-o", "--output":
                guard i + 1 < args.count else { fatal("Missing value for \(arg)") }
                v.outputPath = args[i + 1]; i += 2
            case "--format":
                guard i + 1 < args.count else { fatal("Missing value for --format") }
                v.format = args[i + 1].lowercased()
                guard v.format == "default" || v.format == "tart" else {
                    fatal("--format must be 'default' or 'tart'")
                }
                i += 2
            case "--json-output":
                guard i + 1 < args.count else { fatal("Missing value for --json-output") }
                v.jsonOutputPath = args[i + 1]; i += 2
            case "--max-height":
                guard i + 1 < args.count, let h = Int(args[i + 1]) else {
                    fatal("Missing or invalid value for --max-height")
                }
                v.maxHeight = h; i += 2
            case "--full-resolution":
                v.maxHeight = 0; i += 1
            case "--compact":
                v.prettyPrint = false; i += 1
            case "--interval-ms":
                guard i + 1 < args.count, let ms = Int(args[i + 1]) else {
                    fatal("Missing or invalid value for --interval-ms")
                }
                v.intervalMillis = ms; i += 2
            default:
                fatal("Unexpected argument: \(arg)\n\(usage)")
            }
        }
        guard v.host != nil else { fatal("--host is required\n\(usage)") }
        if v.password == nil {
            v.password = ProcessInfo.processInfo.environment["CGTOOL_VNC_PASSWORD"]
        }
        return v
    }

    /// One-shot VNC framebuffer pull. Connects, grabs a single frame, and
    /// either saves it as a PNG (-o), runs it through the same
    /// analyze/encode pipeline as `analyze <file>` (--format), or both.
    /// The connection's whole lifetime is this one process — "no
    /// disconnect until VCS is done running" holds trivially here; see
    /// vnc-watch for the form that keeps one connection alive across many
    /// pulls.
    private static func vncScreenshot(_ args: [String]) {
        let usage = "usage: vcs vnc-screenshot --host <h> [--port <p>] [--password <pw>] " +
            "[-o out.png] [--format default|tart] [--json-output out.json] [--compact] " +
            "[--max-height N | --full-resolution]"
        let v = parseVNCArgs(args, usage: usage)
        guard v.outputPath != nil || v.format != "none" else {
            fatal("vnc-screenshot: need at least one of -o or --format\n\(usage)")
        }

        let image = captureOneFrame(host: v.host!, port: v.port, password: v.password)
        emitFrame(image, host: v.host!, port: v.port, v: v)
    }

    /// Long-running form: one VNCFramebufferConnection is opened once and
    /// reused for every pull in the loop — the actual "keep the session
    /// alive" behavior, analogous to how `vcs serve` holds one
    /// VisionControlDetector across every request instead of
    /// re-initializing per call. Runs until killed (Ctrl-C / SIGTERM) or
    /// the VNC server drops the connection.
    private static func vncWatch(_ args: [String]) {
        let usage = "usage: vcs vnc-watch --host <h> [--port <p>] [--password <pw>] " +
            "-o outdir [--interval-ms 1000] [--format default|tart] [--max-height N]"
        let v = parseVNCArgs(args, usage: usage)
        guard let outputPath = v.outputPath else { fatal("vnc-watch requires -o <dir>\n\(usage)") }
        try? FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true)

        let conn: VNCFramebufferConnection
        do {
            conn = try VNCFramebufferConnection(host: v.host!, port: v.port, password: v.password)
        } catch {
            fatal("vnc-watch: \(error.localizedDescription)")
        }
        FileHandle.standardError.write(Data(
            "vcs vnc-watch: connected to \(v.host!):\(v.port), writing to \(outputPath)\n".utf8
        ))

        var frameIndex = 0
        while true {
            let image: CGImage
            do {
                image = try conn.captureFrame()
            } catch {
                fatal("vnc-watch: capture failed after \(frameIndex) frame(s): \(error.localizedDescription)")
            }
            var frameV = v
            let base = String(format: "frame-%06d", frameIndex)
            frameV.outputPath = "\(outputPath)/\(base).png"
            if v.format != "none" {
                frameV.jsonOutputPath = v.jsonOutputPath ?? "\(outputPath)/\(base).json"
            }
            emitFrame(image, host: v.host!, port: v.port, v: frameV)
            frameIndex += 1
            usleep(useconds_t(max(0, v.intervalMillis) * 1000))
        }
    }

    private static func captureOneFrame(host: String, port: UInt16, password: String?) -> CGImage {
        do {
            let conn = try VNCFramebufferConnection(host: host, port: port, password: password)
            return try conn.captureFrame()
        } catch {
            fatal("vnc-screenshot: \(error.localizedDescription)")
        }
    }

    private static func emitFrame(_ image: CGImage, host: String, port: UInt16, v: VNCArgs) {
        if let outputPath = v.outputPath {
            do {
                try VNCFramebufferIO.savePNG(image, to: outputPath)
            } catch {
                fatal("vnc-screenshot: failed to save PNG: \(error.localizedDescription)")
            }
        }
        guard v.format != "none" else { return }

        let sourceTag = "(vnc:\(host):\(port))"
        let cap = v.maxHeight > 0 ? v.maxHeight : nil
        let result = analyzeViaServerOrLocal(imagePath: sourceTag, cgImage: image, maxHeight: cap)
        let payload: String
        switch v.format {
        case "tart":
            payload = encodeTartJSON(
                result: result, sourcePath: sourceTag,
                imageWidth: image.width, imageHeight: image.height,
                pretty: v.prettyPrint, cgImage: image
            )
        default:
            payload = encodeJSON(result: result, sourcePath: sourceTag, pretty: v.prettyPrint)
        }
        write(payload, to: v.jsonOutputPath)
    }

    // MARK: - Encoders

    /// Default JSON shape â used by the GUI and one-off tooling.
    static func encodeJSON(
        result: AnalysisResult,
        sourcePath: String,
        pretty: Bool
    ) -> String {
        struct Out: Encodable {
            let source: String
            let summary: Summary
            let detections: [Det]
            struct Summary: Encodable {
                let title: String?
                let subtitle: String?
                let prompt: String?
                let options: [Opt]
                let buttons: [Btn]
                let textFields: [Tfd]
            }
            struct Opt: Encodable {
                let text: String
                let selected: Bool
            }
            struct Btn: Encodable {
                let text: String
                let enabled: Bool
                let role: String
            }
            struct Tfd: Encodable {
                let label: String
                let focused: Bool
            }
            struct Det: Encodable {
                let kind: String
                let label: String?
                let value: String
                let confidence: Float
                let box: Box
                let click: Pt?
                let style: String?
            }
            struct Box: Encodable {
                let x: Double
                let y: Double
                let w: Double
                let h: Double
            }
            struct Pt: Encodable {
                let x: Double
                let y: Double
            }
        }
        let out = Out(
            source: sourcePath,
            summary: Out.Summary(
                title: result.summary.title,
                subtitle: result.summary.subtitle,
                prompt: result.summary.prompt,
                options: result.summary.options.map {
                    Out.Opt(text: $0.text, selected: $0.selected)
                },
                buttons: result.summary.buttons.map {
                    Out.Btn(text: $0.text, enabled: $0.enabled, role: $0.role.rawValue)
                },
                textFields: result.summary.textFields.map {
                    Out.Tfd(label: $0.label, focused: $0.focused)
                }
            ),
            detections: result.detections.map { d in
                Out.Det(
                    kind: d.kind.rawValue,
                    label: d.label,
                    value: d.value,
                    confidence: d.confidence,
                    box: Out.Box(
                        x: Double(d.boundingBox.minX),
                        y: Double(d.boundingBox.minY),
                        w: Double(d.boundingBox.width),
                        h: Double(d.boundingBox.height)
                    ),
                    click: d.controlCenter.map {
                        Out.Pt(x: Double($0.x), y: Double($0.y))
                    },
                    style: d.style
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(out)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Compact convenience wrapper used by Server.swift.
    static func encodeAnalysisResultJSONCompact(
        result: AnalysisResult,
        sourcePath: String
    ) -> String {
        return encodeJSON(result: result, sourcePath: sourcePath, pretty: false)
    }

    /// Tart-shaped JSON consumed by packer-plugin-tart-uiautomate's `detect()`.
    static func encodeTartJSON(
        result: AnalysisResult,
        sourcePath: String,
        imageWidth: Int,
        imageHeight: Int,
        pretty: Bool,
        cgImage: CGImage? = nil
    ) -> String {
        struct Tart: Encodable {
            struct Screen: Encodable {
                let width: Int
                let height: Int
            }
            struct Rect: Encodable {
                let x: Int
                let y: Int
                let w: Int
                let h: Int
            }
            struct Point: Encodable {
                let x: Int
                let y: Int
            }
            struct Control: Encodable {
                let role: String
                let label: String
                let value: String
                let selected: Bool?
                let enabled: Bool?
                let style: String?
                let bbox: Rect
                let controlCenter: Point?
                let click: Point?
                let confidence: Double
            }
            struct OCR: Encodable {
                let text: String
                let bbox: Rect
                let confidence: Double
            }
            struct Panes: Encodable {
                let sidebar: Rect
                let content: Rect
            }
            let source: String
            let screen: Screen
            let scene: String?
            let controls: [Control]
            let ocr: [OCR]
            let panes: Panes?
        }
        func tartRect(from box: CGRect) -> Tart.Rect {
            let px = Int((box.minX * CGFloat(imageWidth)).rounded())
            let pw = Int((box.width * CGFloat(imageWidth)).rounded())
            let ph = Int((box.height * CGFloat(imageHeight)).rounded())
            let py = Int(((1.0 - box.minY - box.height) * CGFloat(imageHeight)).rounded())
            return Tart.Rect(x: px, y: py, w: pw, h: ph)
        }
        func tartPoint(from point: CGPoint?) -> Tart.Point? {
            guard let point else { return nil }
            let px = Int((point.x * CGFloat(imageWidth)).rounded())
            let py = Int(((1.0 - point.y) * CGFloat(imageHeight)).rounded())
            return Tart.Point(x: px, y: py)
        }
        var scene: String? = nil
        if let t = result.summary.title,
           t.hasPrefix("["),
           let end = t.firstIndex(of: "]") {
            scene = String(t[t.index(after: t.startIndex)..<end])
        }
        var controls: [Tart.Control] = []
        var ocr: [Tart.OCR] = []
        for d in result.detections {
            let bbox = tartRect(from: d.boundingBox)
            let role = mapKindToRole(d.kind)
            switch d.kind {
            case .text:
                ocr.append(Tart.OCR(
                    text: d.label ?? d.value,
                    bbox: bbox,
                    confidence: Double(d.confidence)
                ))
            default:
                var selected: Bool? = nil
                var enabled: Bool? = nil
                switch d.kind {
                case .button:
                    enabled = (d.value != "disabled")
                case .checkbox,
                     .radioButton,
                     .radioOption,
                     .toggleSwitch:
                    selected = (d.value == "selected")
                default:
                    break
                }
                let clickPoint = tartPoint(from: d.controlCenter)
                controls.append(Tart.Control(
                    role: role,
                    label: d.label ?? "",
                    value: d.value,
                    selected: selected,
                    enabled: enabled,
                    style: d.style,
                    bbox: bbox,
                    controlCenter: clickPoint,
                    click: clickPoint,
                    confidence: Double(d.confidence)
                ))
            }
        }
        var panes: Tart.Panes? = nil
        if let cgImage, let detected = PaneDetector.detect(cgImage: cgImage) {
            func rect(from r: CGRect) -> Tart.Rect {
                Tart.Rect(x: Int(r.minX), y: Int(r.minY), w: Int(r.width), h: Int(r.height))
            }
            panes = Tart.Panes(sidebar: rect(from: detected.sidebar), content: rect(from: detected.content))
        }
        let out = Tart(
            source: sourcePath,
            screen: Tart.Screen(width: imageWidth, height: imageHeight),
            scene: scene,
            controls: controls,
            ocr: ocr,
            panes: panes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(out)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func mapKindToRole(_ kind: Detection.Kind) -> String {
        switch kind {
        case .button:       return "button"
        case .checkbox:     return "checkbox"
        case .radioButton:  return "radio"
        case .radioOption:  return "option"
        case .menuItem:     return "menuitem"
        case .toggleSwitch: return "switch"
        case .textField:    return "textfield"
        case .text:         return "text"
        case .menuBarItem:  return "menubar"
        case .dockItem:     return "dock"
        case .unknown:      return "unknown"
        }
    }

    private static func encodeText(result: AnalysisResult, sourcePath: String) -> String {
        var lines: [String] = []
        lines.append("Source: \(sourcePath)")
        if let t = result.summary.title    { lines.append("Title: \(t)") }
        if let s = result.summary.subtitle { lines.append("Subtitle: \(s)") }
        if let p = result.summary.prompt   { lines.append("Prompt: \(p)") }
        if !result.summary.textFields.isEmpty {
            lines.append("Text Fields:")
            for f in result.summary.textFields {
                lines.append("  - \(f.label)\(f.focused ? " [focused]" : "")")
            }
        }
        if !result.summary.options.isEmpty {
            lines.append("Options:")
            for o in result.summary.options {
                lines.append("  - \(o.text)\(o.selected ? " [selected]" : "")")
            }
        }
        if !result.summary.buttons.isEmpty {
            lines.append("Buttons:")
            for b in result.summary.buttons {
                lines.append("  - \(b.text) [\(b.role.rawValue), \(b.enabled ? "enabled" : "disabled")]")
            }
        }
        lines.append("")
        lines.append("Detections (\(result.detections.count)):")
        for d in result.detections {
            var line = "  \(d.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
            line += " \(d.label ?? "")"
            if let s = d.style { line += " [\(s)]" }
            if let c = d.controlCenter {
                line += String(format: "  click=(%.3f, %.3f)", c.x, c.y)
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func loadCGImage(from url: URL) -> CGImage? {
        // Use CGImageSource directly to get the full pixel-resolution image.
        // Going through NSImage + cgImage(forProposedRect:) interprets DPI
        // metadata, which on Retina displays halves the pixel dimensions
        // (e.g. a 1024×768 capture at 144 DPI becomes 512×384).  That
        // causes encodeTartJSON to emit coordinates at half scale.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }

    private static func isImage(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".png") ||
               lower.hasSuffix(".jpg") ||
               lower.hasSuffix(".jpeg") ||
               lower.hasSuffix(".heic") ||
               lower.hasSuffix(".tiff") ||
               lower.hasSuffix(".bmp")
    }

    private static func write(_ payload: String, to path: String?) {
        if let path {
            try? payload.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            print(payload)
        }
    }

    private static func fatal(_ message: String) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }

    private static func printUsage() {
        let usage = """
        VisionControlScanner
        Usage:
          vcs analyze <image> [-o out.json] [--text] [--compact]
                              [--max-height N | --full-resolution]
                              [--format default|tart] [--include-chrome]
          vcs watch   <folder> [-o output-dir]
                               [--max-height N | --full-resolution]
                               [--format default|tart]
          vcs serve   [--socket /tmp/vcs.sock] [--max-height N]
          vcs --help

        analyze
          Analyze a single screenshot. Prints JSON to stdout unless -o is given.
          --text             Emit a human-readable summary instead of JSON.
          --compact          JSON on one line.
          --max-height N     Downscale to N pixels tall before analysis (default 720).
          --full-resolution  Skip downscaling.
          --format tart      Emit JSON shaped for packer-plugin-tart-uiautomate
                             (pixel-space coords, top-left origin, scene field).
          --include-chrome   Also detect the OS's own menu bar (Apple menu,
                             app menu titles, Spotlight, Control Center,
                             clock) and Dock icons, anywhere in the image —
                             not just inside a Setup Assistant card. Off by
                             default (adds an extra OCR pass; only useful once
                             past Setup Assistant, e.g. driving Terminal or
                             System Settings via the VM's own UI instead of
                             host-global hotkeys the VM can't receive).
                             Roles: "menubar" and "dock".

        watch
          Watch a folder for new image files and emit JSON for each.

        serve
          Long-lived scanner. Listens on a Unix socket; one JSON request per
          line. `analyze` automatically delegates to this when VCS_SOCKET (or
          /tmp/vcs.sock by default) exists. Set VCS_SOCKET="" to disable.
          --socket <path>    Unix socket path (default /tmp/vcs.sock)
          --max-height N     Default downscale height (default 720; 0 = full res)
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }
}

// MARK: - Server delegation client

private enum ServerClient {
    static func analyze(
        socketPath: String,
        imagePath: String,
        maxHeight: Int?,
        includeChrome: Bool = false
    ) -> AnalysisResult? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok: Bool = withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let p = socketPath.utf8CString
            guard p.count <= buf.count else { return false }
            _ = p.withUnsafeBytes { src in
                memcpy(buf.baseAddress!, src.baseAddress!, src.count)
            }
            return true
        }
        guard ok else { return nil }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, addrLen)
            }
        }
        guard connectResult == 0 else { return nil }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var req: [String: Any] = ["image": imagePath]
        if let maxHeight { req["max_height"] = maxHeight }
        if includeChrome { req["include_chrome"] = true }
        guard let body = try? JSONSerialization.data(withJSONObject: req) else {
            return nil
        }
        var line = body
        line.append(0x0A)
        let sent: Bool = line.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard sent else { return nil }
        var resp = Data()
        var scratch = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &scratch, scratch.count)
            if n <= 0 { break }
            resp.append(scratch, count: n)
            if resp.contains(0x0A) { break }
        }
        guard let nl = resp.firstIndex(of: 0x0A) else { return nil }
        let payload = resp.subdata(in: resp.startIndex..<nl)
        if let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           obj["error"] != nil {
            return nil
        }
        return ServerClient.decode(payload: payload)
    }

    private static func decode(payload: Data) -> AnalysisResult? {
        struct Wire: Decodable {
            let source: String?
            let summary: Summary
            let detections: [Det]
            struct Summary: Decodable {
                let title: String?
                let subtitle: String?
                let prompt: String?
                let options: [Opt]
                let buttons: [Btn]
                let textFields: [Tfd]
            }
            struct Opt: Decodable { let text: String; let selected: Bool }
            struct Btn: Decodable { let text: String; let enabled: Bool; let role: String }
            struct Tfd: Decodable { let label: String; let focused: Bool }
            struct Det: Decodable {
                let kind: String
                let label: String?
                let value: String
                let confidence: Float
                let box: Box
                let click: Pt?
                let style: String?
            }
            struct Box: Decodable { let x, y, w, h: Double }
            struct Pt:  Decodable { let x, y: Double }
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: payload) else {
            return nil
        }
        let detections: [Detection] = wire.detections.map { d in
            let kind = Detection.Kind(rawValue: d.kind) ?? .unknown
            let box = CGRect(x: d.box.x, y: d.box.y, width: d.box.w, height: d.box.h)
            let click = d.click.map { CGPoint(x: $0.x, y: $0.y) }
            return Detection(
                kind: kind,
                boundingBox: box,
                controlCenter: click,
                value: d.value,
                confidence: d.confidence,
                label: d.label,
                style: d.style
            )
        }
        let options = wire.summary.options.map {
            SetupOption(text: $0.text, selected: $0.selected)
        }
        let buttons = wire.summary.buttons.map { btn -> SetupButton in
            let role = SetupButton.Role(rawValue: btn.role) ?? .secondary
            return SetupButton(text: btn.text, enabled: btn.enabled, role: role)
        }
        let textFields = wire.summary.textFields.map {
            SetupTextField(label: $0.label, focused: $0.focused)
        }
        let summary = SetupScreenSummary(
            title: wire.summary.title,
            subtitle: wire.summary.subtitle,
            prompt: wire.summary.prompt,
            options: options,
            buttons: buttons,
            textFields: textFields
        )
        return AnalysisResult(detections: detections, summary: summary)
    }
}
