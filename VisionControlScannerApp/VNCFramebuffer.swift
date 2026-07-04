//
//  VNCFramebuffer.swift
//  VisionControlScannerApp
//
//  Native RFB (VNC) framebuffer-pull client — lets `vcs` grab a screenshot
//  directly from a VNC server (e.g. `tart run --vnc-experimental`) without
//  going through a host-side window capture. Handshake logic (protocol
//  version negotiation, security types None/VNC-Authentication via DES,
//  ClientInit/ServerInit) is ported from cgtool's VNCInput.swift, which is
//  the already-verified-working implementation against Tart's VNC server —
//  see that file for the protocol-choice reasoning. This adds the pixel
//  side of the protocol cgtool's input-only client doesn't need:
//  SetPixelFormat, SetEncodings, FramebufferUpdateRequest/Update.
//
//  "Keep the session alive": a VNCFramebufferConnection, once constructed,
//  holds its TCP socket and completed handshake open across as many
//  captureFrame() calls as the caller makes — there is no reconnect
//  between pulls. It disconnects only when deinit'd (process exit) or the
//  server closes the connection. `vcs vnc-watch` uses one connection for
//  its whole run; `vcs serve` (see Server.swift) caches one connection per
//  host:port across all client requests for the life of the serve process.
//

import Foundation
import CommonCrypto
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum VNCFramebufferError: Error, LocalizedError {
    case resolveFailed(String)
    case connectFailed(String, Int32)
    case connectionClosed
    case timeout
    case protocolError(String)
    case passwordRequired
    case authenticationFailed(String)
    case unsupportedSecurity([UInt8])
    case unexpectedEncoding(Int32)
    case imageBuildFailed

    var errorDescription: String? {
        switch self {
        case .resolveFailed(let host): return "Could not resolve VNC host: \(host)"
        case .connectFailed(let hostPort, let e): return "Could not connect to VNC server \(hostPort): \(String(cString: strerror(e)))"
        case .connectionClosed: return "VNC server closed the connection."
        case .timeout: return "Timed out waiting for VNC server data."
        case .protocolError(let d): return "VNC protocol error: \(d)"
        case .passwordRequired: return "VNC server requires a password."
        case .authenticationFailed(let r): return "VNC authentication failed: \(r)"
        case .unsupportedSecurity(let t): return "VNC server offers no supported security type (offered: \(t))."
        case .unexpectedEncoding(let e): return "VNC server sent unrequested encoding \(e) (only Raw(0) was offered)."
        case .imageBuildFailed: return "Could not build an image from the received framebuffer."
        }
    }
}

final class VNCFramebufferConnection {
    private let fd: Int32
    private let hostPort: String
    private(set) var framebufferWidth: Int = 0
    private(set) var framebufferHeight: Int = 0

    // Fixed 32bpp BGRX pixel format we ask the server to send, so decoding
    // never has to branch on whatever format the server would otherwise
    // pick (its native depth can be 8/16/24/32bpp, big- or little-endian).
    private static let bytesPerPixel = 4

    init(host: String, port: UInt16, password: String?, timeoutSeconds: Int32 = 10) throws {
        hostPort = "\(host):\(port)"
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
            throw VNCFramebufferError.resolveFailed(host)
        }
        defer { freeaddrinfo(res) }

        var sock: Int32 = -1
        var lastErrno: Int32 = ECONNREFUSED
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let ai = info {
            sock = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if sock >= 0 {
                if connect(sock, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { break }
                lastErrno = errno
                close(sock)
                sock = -1
            }
            info = ai.pointee.ai_next
        }
        guard sock >= 0 else { throw VNCFramebufferError.connectFailed(hostPort, lastErrno) }
        fd = sock

        var tv = timeval(tv_sec: Int(timeoutSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        do {
            try handshake(password: password)
            try setPixelFormatAndEncodings()
        } catch {
            disconnect()
            throw error
        }
    }

    deinit { disconnect() }

    func disconnect() {
        if fd >= 0 { close(fd) }
    }

    // MARK: Low-level I/O

    private func readExact(_ n: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress!.advanced(by: got), n - got)
            }
            if r == 0 { throw VNCFramebufferError.connectionClosed }
            if r < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { throw VNCFramebufferError.timeout }
                throw VNCFramebufferError.protocolError("read failed: \(String(cString: strerror(errno)))")
            }
            got += r
        }
        return buf
    }

    private func writeAll(_ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let w = bytes.withUnsafeBytes { ptr -> Int in
                write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if w <= 0 { throw VNCFramebufferError.protocolError("write failed: \(String(cString: strerror(errno)))") }
            sent += w
        }
    }

    private func readU8() throws -> UInt8 { try readExact(1)[0] }
    private func readU16() throws -> UInt16 {
        let b = try readExact(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }
    private func readU32() throws -> UInt32 {
        let b = try readExact(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }
    private func readS32() throws -> Int32 { Int32(bitPattern: try readU32()) }
    private func readReasonString() -> String {
        guard let len = try? readU32(), len < 4096, let bytes = try? readExact(Int(len)) else {
            return "(no reason given)"
        }
        return String(bytes: bytes, encoding: .utf8) ?? "(unreadable reason)"
    }

    // MARK: Handshake — identical wire behavior to cgtool's VNCInput.swift

    private func handshake(password: String?) throws {
        let versionBytes = try readExact(12)
        guard let version = String(bytes: versionBytes, encoding: .ascii), version.hasPrefix("RFB ") else {
            throw VNCFramebufferError.protocolError("bad ProtocolVersion banner")
        }
        let minor = Int(version.dropFirst(8).prefix(3)) ?? 3
        let major = Int(version.dropFirst(4).prefix(3)) ?? 3
        let useV38 = major > 3 || (major == 3 && minor >= 7)
        try writeAll(Array((useV38 ? "RFB 003.008\n" : "RFB 003.003\n").utf8))

        var securityType: UInt8
        if useV38 {
            let count = try readU8()
            if count == 0 { throw VNCFramebufferError.protocolError("server rejected connection: \(readReasonString())") }
            let offered = try readExact(Int(count))
            if offered.contains(1) && (password ?? "").isEmpty {
                securityType = 1
            } else if offered.contains(2) {
                securityType = 2
            } else if offered.contains(1) {
                securityType = 1
            } else {
                throw VNCFramebufferError.unsupportedSecurity(offered)
            }
            try writeAll([securityType])
        } else {
            let type = try readU32()
            if type == 0 { throw VNCFramebufferError.protocolError("server rejected connection: \(readReasonString())") }
            guard type == 1 || type == 2 else { throw VNCFramebufferError.unsupportedSecurity([UInt8(clamping: type)]) }
            securityType = UInt8(type)
        }

        if securityType == 2 {
            guard let password, !password.isEmpty else { throw VNCFramebufferError.passwordRequired }
            let challenge = try readExact(16)
            let response = Self.desChallengeResponse(challenge: challenge, password: password)
            try writeAll(response)
        }

        if useV38 || securityType == 2 {
            let result = try readU32()
            if result != 0 {
                let reason = useV38 ? readReasonString() : "wrong password?"
                throw VNCFramebufferError.authenticationFailed(reason)
            }
        }

        // ClientInit (shared = 1) / ServerInit
        try writeAll([1])
        framebufferWidth = Int(try readU16())
        framebufferHeight = Int(try readU16())
        _ = try readExact(16)  // server's native PIXEL_FORMAT — we override it below
        let nameLen = try readU32()
        if nameLen > 0 && nameLen < 4096 { _ = try readExact(Int(nameLen)) }
    }

    static func desChallengeResponse(challenge: [UInt8], password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        for (i, byte) in password.utf8.prefix(8).enumerated() {
            var b = byte, reversed: UInt8 = 0
            for _ in 0..<8 {
                reversed = (reversed << 1) | (b & 1)
                b >>= 1
            }
            key[i] = reversed
        }
        var out = [UInt8](repeating: 0, count: challenge.count + kCCBlockSizeDES)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                              key, key.count, nil, challenge, challenge.count, &out, out.count, &moved)
        guard status == kCCSuccess, moved >= 16 else { return [UInt8](repeating: 0, count: 16) }
        return Array(out.prefix(16))
    }

    // MARK: Pixel setup

    /// Requests 32bpp BGRX (depth 24, little-endian). Raw is the only
    /// pixel encoding this client decodes; DesktopSize/ExtendedDesktopSize/
    /// Cursor/LastRect are pseudo-encodings carrying capability
    /// declarations rather than a competing pixel format, and are
    /// declared (with correct skip-parsing below) because Tart's
    /// `--vnc-experimental` server crashed the whole VM on connect when a
    /// client declared Raw-only with none of these — logged as `FIXME IF:
    /// "It is unclear if we can support clients that don't support this
    /// pseudo encoding." line 233` right before the VM died (reproduced
    /// against a disposable `tart run` instance, not just guessed at).
    private func setPixelFormatAndEncodings() throws {
        var msg: [UInt8] = [0, 0, 0, 0]  // SetPixelFormat, 3 bytes padding
        msg.append(contentsOf: [
            32,           // bits-per-pixel
            24,           // depth
            0,            // big-endian-flag = false
            1,            // true-color-flag = true
            0, 255,       // red-max
            0, 255,       // green-max
            0, 255,       // blue-max
            16,           // red-shift
            8,            // green-shift
            0,            // blue-shift
            0, 0, 0,      // padding
        ])
        try writeAll(msg)

        let encodings: [Int32] = [0, -223, -308, -239, -224]  // Raw, DesktopSize, ExtendedDesktopSize, Cursor, LastRect
        var enc: [UInt8] = [2, 0]  // SetEncodings, 1 byte padding
        enc.append(UInt8(encodings.count >> 8 & 0xFF)); enc.append(UInt8(encodings.count & 0xFF))
        for e in encodings {
            enc.append(UInt8(truncatingIfNeeded: e >> 24))
            enc.append(UInt8(truncatingIfNeeded: e >> 16))
            enc.append(UInt8(truncatingIfNeeded: e >> 8))
            enc.append(UInt8(truncatingIfNeeded: e))
        }
        try writeAll(enc)
    }

    // MARK: Framebuffer pull

    /// Requests and reads one full (non-incremental) framebuffer update,
    /// returning a CGImage. Safe to call repeatedly on the same
    /// connection — this is the "session stays alive" entry point.
    func captureFrame() throws -> CGImage {
        var req: [UInt8] = [3, 0]  // FramebufferUpdateRequest, incremental=0
        req.append(contentsOf: [0, 0])  // x
        req.append(contentsOf: [0, 0])  // y
        req.append(UInt8(framebufferWidth >> 8 & 0xFF)); req.append(UInt8(framebufferWidth & 0xFF))
        req.append(UInt8(framebufferHeight >> 8 & 0xFF)); req.append(UInt8(framebufferHeight & 0xFF))
        try writeAll(req)

        var pixels = [UInt8](repeating: 0, count: framebufferWidth * framebufferHeight * Self.bytesPerPixel)
        let stride = framebufferWidth * Self.bytesPerPixel

        // A server may split one update into multiple FramebufferUpdate
        // messages if it coalesces partial redraws; keep reading until the
        // full frame area has been covered at least once.
        var covered = 0
        let totalArea = framebufferWidth * framebufferHeight
        while covered < totalArea {
            let msgType = try readU8()
            guard msgType == 0 else {
                throw VNCFramebufferError.protocolError("expected FramebufferUpdate(0), got message type \(msgType)")
            }
            _ = try readU8()  // padding
            let numRects = try readU16()
            // A server that supports the LastRect pseudo-encoding may send
            // 0xFFFF as a sentinel meaning "keep reading rectangles until
            // you see a LastRect marker" instead of a literal count — we
            // declared support for it (see setPixelFormatAndEncodings),
            // so it's a real possibility, not just a spec footnote.
            let useLastRectSentinel = numRects == 0xFFFF
            var rectsRead: UInt16 = 0
            var sawLastRect = false
            while (useLastRectSentinel && !sawLastRect) || (!useLastRectSentinel && rectsRead < numRects) {
                let rx = Int(try readU16())
                let ry = Int(try readU16())
                let rw = Int(try readU16())
                let rh = Int(try readU16())
                let encoding = try readS32()

                switch encoding {
                case 0:  // Raw
                    let rowBytes = rw * Self.bytesPerPixel
                    for row in 0..<rh {
                        let rowData = try readExact(rowBytes)
                        let destY = ry + row
                        guard destY >= 0, destY < framebufferHeight else { continue }
                        let destOffset = destY * stride + rx * Self.bytesPerPixel
                        let copyLen = min(rowBytes, stride - rx * Self.bytesPerPixel)
                        guard copyLen > 0 else { continue }
                        rowData.withUnsafeBufferPointer { src in
                            pixels.withUnsafeMutableBufferPointer { dst in
                                dst.baseAddress!.advanced(by: destOffset).update(from: src.baseAddress!, count: copyLen)
                            }
                        }
                    }
                    covered += rw * rh
                case -223:  // DesktopSize: capability marker, no payload at all.
                    break
                case -308:  // ExtendedDesktopSize: 1-byte screen count + 3
                            // padding, then 16 bytes per screen. Must be
                            // read and discarded to keep the stream in
                            // sync even though we don't use the contents.
                    let screenCount = Int(try readU8())
                    _ = try readExact(3)
                    if screenCount > 0 {
                        _ = try readExact(screenCount * 16)
                    }
                case -239:  // Cursor: width*height pixels (current pixel
                            // format) + a 1-bpp bitmask, ceil(width/8) bytes
                            // per row.
                    if rw > 0, rh > 0 {
                        _ = try readExact(rw * rh * Self.bytesPerPixel)
                        _ = try readExact(((rw + 7) / 8) * rh)
                    }
                case -224:  // LastRect: no payload; ends a 0xFFFF-sentinel batch.
                    sawLastRect = true
                default:
                    throw VNCFramebufferError.unexpectedEncoding(encoding)
                }
                rectsRead += 1
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            throw VNCFramebufferError.imageBuildFailed
        }
        // Matches the SetPixelFormat above: 32bpp, byte order [B,G,R,X]
        // per pixel (little-endian word with red at bit16, i.e. skip the
        // first/highest byte for alpha).
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(
            width: framebufferWidth,
            height: framebufferHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw VNCFramebufferError.imageBuildFailed
        }
        return image
    }
}

enum VNCFramebufferIO {
    static func savePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw VNCFramebufferError.imageBuildFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw VNCFramebufferError.imageBuildFailed
        }
    }
}
