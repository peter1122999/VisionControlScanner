//
//  Server.swift
//  VisionControlScannerApp
//
//  Created by Avery Varney on 6/26/26.
//


import Foundation
import Darwin
import AppKit
import CoreGraphics

/// Long-lived scanner process. Listens on a Unix domain socket. One
/// JSON request per line, one JSON response per line. Holds a single
/// VisionControlDetector across all requests so the Vision framework's
/// per-process warmup happens once.
enum Server {

    private static let detector = VisionControlDetector()

    static func run(socketPath: String, maxHeight: Int) throws -> Never {
        // Clean up any stale socket from a previous run.
        unlink(socketPath)

        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        try withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let p = socketPath.utf8CString
            guard p.count <= buf.count else {
                throw NSError(domain: "vcs.serve", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "socket path too long"
                ])
            }
            _ = p.withUnsafeBytes { src in
                memcpy(buf.baseAddress!, src.baseAddress!, src.count)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFD, sa, addrLen)
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }

        // Loosen permissions so the packer plugin (different uid in CI?)
        // can connect. Tighten if you care.
        chmod(socketPath, 0o666)

        guard listen(listenFD, 64) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }

        FileHandle.standardError.write(Data(
            "vcs serving on \(socketPath) (max-height=\(maxHeight))\n".utf8
        ))

        // Cleanup on SIGTERM / SIGINT.
        installSignalHandlers(socketPath: socketPath, listenFD: listenFD)

        let acceptQueue = DispatchQueue(label: "vcs.accept")
        let workerQueue = DispatchQueue(
            label: "vcs.worker",
            attributes: .concurrent
        )

        acceptQueue.async {
            while true {
                let client = accept(listenFD, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    FileHandle.standardError.write(Data(
                        "accept failed: \(String(cString: strerror(errno)))\n".utf8
                    ))
                    continue
                }
                workerQueue.async {
                    handleClient(fd: client, defaultMaxHeight: maxHeight)
                    close(client)
                }
            }
        }

        dispatchMain()
    }

    // MARK: - Per-connection handler

    private static func handleClient(fd: Int32, defaultMaxHeight: Int) {
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var buffer = Data()

        while true {
            let chunk: Data
            do {
                chunk = try input.read(upToCount: 4096) ?? Data()
            } catch {
                return
            }
            if chunk.isEmpty { return }
            buffer.append(chunk)

            // Process every complete line in buffer.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)

                let response = process(
                    line: line,
                    defaultMaxHeight: defaultMaxHeight
                )
                writeLine(fd: fd, data: response)
            }
        }
    }

    private static func process(line: Data, defaultMaxHeight: Int) -> Data {
        struct Request: Decodable {
            let image: String?
            let max_height: Int?
            let ping: Bool?
        }

        guard let req = try? JSONDecoder().decode(Request.self, from: line) else {
            return errorJSON("malformed json")
        }

        if req.ping == true {
            return jsonLine(["ok": true, "pid": Int(getpid())])
        }

        guard let imagePath = req.image else {
            return errorJSON("missing 'image' field")
        }

        let url = URL(fileURLWithPath: imagePath)
        guard let nsImage = NSImage(contentsOf: url) else {
            return errorJSON("could not load image at \(imagePath)")
        }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return errorJSON("could not produce CGImage")
        }

        let cap = req.max_height ?? defaultMaxHeight
        let result: AnalysisResult
        do {
            result = try detector.analyze(cgImage: cg, maxHeight: cap > 0 ? cap : nil)
        } catch {
            return errorJSON("analyze failed: \(error.localizedDescription)")
        }

        // Reuse the exact same encoder shape as `vcs analyze`.
        let payload = CLI.encodeAnalysisResultJSONCompact(result: result, sourcePath: imagePath)
        return Data(payload.utf8)
    }

    // MARK: - Helpers

    private static func writeLine(fd: Int32, data: Data) {
        var line = data
        line.append(0x0A)
        line.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    private static func errorJSON(_ msg: String) -> Data {
        jsonLine(["error": msg])
    }

    private static func jsonLine(_ obj: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return data
    }

    private static func installSignalHandlers(socketPath: String, listenFD: Int32) {
        let cleanup: @convention(c) (Int32) -> Void = { _ in
            // SIGINT handler — cleanup will happen via atexit too.
            _exit(0)
        }
        signal(SIGINT, cleanup)
        signal(SIGTERM, cleanup)
        atexit_b {
            unlink(socketPath)
        }
    }
}