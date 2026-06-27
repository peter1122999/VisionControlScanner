//
//  CLI.swift
//  VisionControlScannerApp
//
//  Created by Avery Varney on 6/26/26.
//


import Foundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

enum CLI {

    /// Returns true if CLI mode handled the invocation (caller should NOT
    /// start the SwiftUI app). Returns false if no CLI args were given.
    @discardableResult
    static func runIfNeeded() -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1 else { return false }
        

        // Strip leading binary path; also ignore Xcode's launcher args.
        let userArgs = Array(args.dropFirst()).filter {
            !$0.hasPrefix("-NSDocumentRevisionsDebugMode") &&
            !$0.hasPrefix("YES")
        }

        guard let command = userArgs.first else { return false }

        switch command {
        case "serve":
            serve(Array(userArgs.dropFirst()))
        case "analyze":
            analyze(Array(userArgs.dropFirst()))
        case "watch":
            watch(Array(userArgs.dropFirst()))
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

    // MARK: - Commands

    private static func analyze(_ args: [String]) {
        var inputPath: String?
        var outputPath: String?
        var jsonMode = true
        var prettyPrint = true

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
            default:
                if inputPath == nil {
                    inputPath = arg
                } else {
                    fatal("Unexpected argument: \(arg)")
                }
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

        let detector = VisionControlDetector()
        let result: AnalysisResult
        do {
            result = try detector.analyze(cgImage: cgImage)
        } catch {
            fatal("Analysis failed: \(error.localizedDescription)")
        }

        let payload: String
        if jsonMode {
            payload = encodeJSON(result: result, sourcePath: inputPath, pretty: prettyPrint)
        } else {
            payload = encodeText(result: result, sourcePath: inputPath)
        }

        write(payload, to: outputPath)
    }

    private static func watch(_ args: [String]) {
        var folder: String?
        var outputDir: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-o", "--output":
                guard i + 1 < args.count else { fatal("Missing value for \(arg)") }
                outputDir = args[i + 1]; i += 2
            default:
                if folder == nil { folder = arg } else { fatal("Unexpected: \(arg)") }
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

        // Lightweight polling implementation (no DispatchSource events to
        // keep this dependency-free). Fine for screenshot ingestion.
        var seen = Set<String>(try! fm.contentsOfDirectory(atPath: folder))

        while true {
            Thread.sleep(forTimeInterval: 1.0)
            guard let now = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            let nowSet = Set(now)
            let added = nowSet.subtracting(seen)
            seen = nowSet

            for name in added where isImage(name) {
                let imageURL = folderURL.appendingPathComponent(name)
                // Wait briefly for the file to finish writing.
                Thread.sleep(forTimeInterval: 0.4)

                guard let cgImage = loadCGImage(from: imageURL) else { continue }
                let detector = VisionControlDetector()
                guard let result = try? detector.analyze(cgImage: cgImage) else { continue }

                let payload = encodeJSON(
                    result: result,
                    sourcePath: imageURL.path,
                    pretty: false
                )

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

    // MARK: - Encoding

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
                    }
                )
            }
        )

        let encoder = JSONEncoder()
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        let data = (try? encoder.encode(out)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    static func encodeAnalysisResultJSONCompact(
        result: AnalysisResult,
        sourcePath: String
    ) -> String {
        return encodeJSON(result: result, sourcePath: sourcePath, pretty: false)
    }
    
    private static func encodeText(result: AnalysisResult, sourcePath: String) -> String {
        var lines: [String] = []
        lines.append("Source: \(sourcePath)")
        if let t = result.summary.title { lines.append("Title: \(t)") }
        if let s = result.summary.subtitle { lines.append("Subtitle: \(s)") }
        if let p = result.summary.prompt { lines.append("Prompt: \(p)") }

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
            if let c = d.controlCenter {
                line += String(format: "  click=(%.3f, %.3f)", c.x, c.y)
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func loadCGImage(from url: URL) -> CGImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
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
          VisionControlScanner analyze <image> [-o out.json] [--text] [--compact]
          VisionControlScanner watch   <folder> [-o output-dir]
          VisionControlScanner --help

        analyze
          Analyze a single screenshot. Prints JSON to stdout unless -o is given.
          --text     Emit a human-readable summary instead of JSON.
          --compact  JSON on one line.

        watch
          Watch a folder for new image files and emit JSON for each.
          With -o, writes <basename>.json into the output directory.
          Without -o, prints each result to stdout.
        """
        FileHandle.standardError.write(Data((usage + "\n").utf8))
    }
}
