import Foundation
import CoreGraphics
import ImageIO
import CoreImage

struct SetupCardDetection: Codable {
    let found: Bool
    let x: Int
    let y: Int
    let w: Int
    let h: Int
    let confidence: Double
}

extension CLI {
    static func findCardRunIfNeeded(_ args: [String] = CommandLine.arguments) -> Bool {
        guard args.count >= 2, args[1] == "find-card" else { return false }

        guard args.count >= 3 else {
            emitFindCardJSON(SetupCardDetection(found: false, x: 0, y: 0, w: 0, h: 0, confidence: 0.0))
            fputs("usage: vcs find-card <screenshot.png>\n", stderr)
            return true
        }

        let path = args[2]
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            emitFindCardJSON(SetupCardDetection(found: false, x: 0, y: 0, w: 0, h: 0, confidence: 0.0))
            fputs("find-card: could not load image: \(path)\n", stderr)
            return true
        }

        emitFindCardJSON(findSetupCardRegion(cgImage: image))
        return true
    }

    private static func emitFindCardJSON(_ result: SetupCardDetection) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
            print(json)
        } else {
            print("{\"found\":false,\"x\":0,\"y\":0,\"w\":0,\"h\":0,\"confidence\":0.0}")
        }
    }

    private static func findSetupCardRegion(cgImage: CGImage) -> SetupCardDetection {
        guard let rgb = makeRGBImage(from: cgImage) else {
            return SetupCardDetection(found: false, x: 0, y: 0, w: 0, h: 0, confidence: 0.0)
        }
        guard let rect = findSetupCard(in: rgb) else {
            return SetupCardDetection(found: false, x: 0, y: 0, w: 0, h: 0, confidence: 0.0)
        }
        let r = rect.integral
        return SetupCardDetection(
            found: true,
            x: max(0, Int(r.minX.rounded())),
            y: max(0, Int(r.minY.rounded())),
            w: max(0, Int(r.width.rounded())),
            h: max(0, Int(r.height.rounded())),
            confidence: 0.95
        )
    }

    private struct RGBPixel {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
        var luminance: Double {
            0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
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

    private static func makeRGBImage(from image: CGImage) -> RGBImage? {
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
            pixels.append(RGBPixel(r: raw[index], g: raw[index + 1], b: raw[index + 2], a: raw[index + 3]))
            index += 4
        }
        return RGBImage(width: width, height: height, pixels: pixels)
    }

    private static func findSetupCard(in rgb: RGBImage) -> CGRect? {
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
                if !visited[seed], let p = rgb.pixel(x: sx, y: sy), isCard(p) {
                    var stack: [(Int, Int)] = [(sx, sy)]
                    visited[seed] = true
                    var minX = sx, maxX = sx, minY = sy, maxY = sy
                    var count = 0

                    while let current = stack.popLast() {
                        let cx = current.0
                        let cy = current.1
                        count += 1
                        minX = min(minX, cx); maxX = max(maxX, cx)
                        minY = min(minY, cy); maxY = max(maxY, cy)

                        for n in [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)] {
                            let nx = n.0
                            let ny = n.1
                            guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                            let ni = idx(nx, ny)
                            if visited[ni] { continue }
                            visited[ni] = true
                            guard let np = rgb.pixel(x: nx, y: ny), isCard(np) else { continue }
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
                       aspect >= 0.5,
                       aspect <= 2.8,
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
}
