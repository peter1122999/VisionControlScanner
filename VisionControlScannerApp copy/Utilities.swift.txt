import Foundation
import CoreGraphics
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

func loadCGImage(from url: URL) -> CGImage? {
    guard let image = NSImage(contentsOf: url) else { return nil }
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
        return .zero
    }
    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let origin = CGPoint(x: (container.width - fittedSize.width) / 2.0,
                         y: (container.height - fittedSize.height) / 2.0)
    return CGRect(origin: origin, size: fittedSize)
}

func viewRect(from normalizedRect: CGRect, imageRect: CGRect) -> CGRect {
    CGRect(
        x: imageRect.minX + normalizedRect.minX * imageRect.width,
        y: imageRect.minY + (1.0 - normalizedRect.minY - normalizedRect.height) * imageRect.height,
        width: normalizedRect.width * imageRect.width,
        height: normalizedRect.height * imageRect.height
    )
}

func cropCGImage(_ image: CGImage, to normalizedRect: CGRect) -> CGImage? {
    let pxRect = normalizedRectToPixelRect(normalizedRect, width: image.width, height: image.height)
        .integral
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !pxRect.isNull, pxRect.width > 2, pxRect.height > 2 else { return nil }
    return image.cropping(to: pxRect)
}

func normalizedRectToPixelRect(_ rect: CGRect, width: Int, height: Int) -> CGRect {
    CGRect(
        x: rect.minX * CGFloat(width),
        y: (1.0 - rect.minY - rect.height) * CGFloat(height),
        width: rect.width * CGFloat(width),
        height: rect.height * CGFloat(height)
    )
}

func pixelRectToNormalized(_ rect: CGRect, width: Int, height: Int) -> CGRect {
    CGRect(
        x: rect.minX / CGFloat(width),
        y: 1.0 - rect.maxY / CGFloat(height),
        width: rect.width / CGFloat(width),
        height: rect.height / CGFloat(height)
    )
}

func mapRect(_ rect: CGRect, fromCrop crop: CGRect) -> CGRect {
    CGRect(
        x: crop.minX + rect.minX * crop.width,
        y: crop.minY + rect.minY * crop.height,
        width: rect.width * crop.width,
        height: rect.height * crop.height
    )
}

func preprocessForOCR(_ cgImage: CGImage) -> CGImage? {
    let ciImage = CIImage(cgImage: cgImage)

    let color = CIFilter.colorControls()
    color.inputImage = ciImage
    color.saturation = 0.0
    color.contrast = 1.35
    color.brightness = 0.02

    let sharpen = CIFilter.sharpenLuminance()
    sharpen.inputImage = color.outputImage
    sharpen.sharpness = 0.42

    let exposure = CIFilter.exposureAdjust()
    exposure.inputImage = sharpen.outputImage
    exposure.ev = 0.12

    guard let output = exposure.outputImage else { return nil }
    let context = CIContext(options: nil)
    return context.createCGImage(output, from: output.extent)
}

func maskTextRegions(in image: CGImage, textRects: [CGRect], expand: CGFloat = 0.01) -> CGImage? {
    let width = image.width
    let height = image.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(NSColor.white.cgColor)

    for rect in textRects {
        let expanded = rect.expanded(by: expand).clampedToUnit()
        context.fill(normalizedRectToPixelRect(expanded, width: width, height: height))
    }

    return context.makeImage()
}

struct RGBAImage {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: [UInt8]

    init?(cgImage: CGImage) {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let ok: Bool = buffer.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard ok else { return nil }

        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.data = buffer
    }

    func rgba(x: Int, y: Int) -> (Double, Double, Double, Double) {
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        let offset = cy * bytesPerRow + cx * 4
        return (
            Double(data[offset]) / 255.0,
            Double(data[offset + 1]) / 255.0,
            Double(data[offset + 2]) / 255.0,
            Double(data[offset + 3]) / 255.0
        )
    }

    func brightness(x: Int, y: Int) -> Double {
        let (r, g, b, _) = rgba(x: x, y: y)
        return (r + g + b) / 3.0
    }

    func saturation(x: Int, y: Int) -> Double {
        let (r, g, b, _) = rgba(x: x, y: y)
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        return maxV <= 0.0001 ? 0 : (maxV - minV) / maxV
    }

    func hue(x: Int, y: Int) -> Double {
        let (r, g, b, _) = rgba(x: x, y: y)
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        if delta == 0 { return 0 }

        var h: Double
        if maxV == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            h = ((b - r) / delta) + 2
        } else {
            h = ((r - g) / delta) + 4
        }

        h /= 6
        if h < 0 { h += 1 }
        return h
    }
}

func connectedComponents(width: Int, height: Int, isOn: (Int, Int) -> Bool, minArea: Int = 1) -> [ConnectedComponent] {
    var visited = [UInt8](repeating: 0, count: width * height)
    func idx(_ x: Int, _ y: Int) -> Int { y * width + x }
    let neighbors = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    var output: [ConnectedComponent] = []

    for y in 0..<height {
        for x in 0..<width {
            let start = idx(x, y)
            if visited[start] == 1 || !isOn(x, y) { continue }
            visited[start] = 1
            var queue: [(Int, Int)] = [(x, y)]
            var head = 0
            var minX = x, minY = y, maxX = x, maxY = y
            var area = 0

            while head < queue.count {
                let (cx, cy) = queue[head]
                head += 1
                area += 1
                minX = min(minX, cx)
                minY = min(minY, cy)
                maxX = max(maxX, cx)
                maxY = max(maxY, cy)

                for (dx, dy) in neighbors {
                    let nx = cx + dx
                    let ny = cy + dy
                    if nx < 0 || ny < 0 || nx >= width || ny >= height { continue }
                    let n = idx(nx, ny)
                    if visited[n] == 1 || !isOn(nx, ny) { continue }
                    visited[n] = 1
                    queue.append((nx, ny))
                }
            }

            if area >= minArea {
                let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
                let fillRatio = Double(area) / max(1.0, Double(bounds.width * bounds.height))
                output.append(ConnectedComponent(bounds: bounds, area: area, fillRatio: fillRatio))
            }
        }
    }

    return output
}

extension CGRect {
    var area: CGFloat { max(0, width) * max(0, height) }

    func expanded(by delta: CGFloat) -> CGRect {
        insetBy(dx: -delta, dy: -delta)
    }

    func clampedToUnit() -> CGRect {
        let x = min(max(minX, 0), 1)
        let y = min(max(minY, 0), 1)
        let mx = min(max(maxX, 0), 1)
        let my = min(max(maxY, 0), 1)
        return CGRect(x: x, y: y, width: max(0, mx - x), height: max(0, my - y))
    }

    func iou(with other: CGRect) -> CGFloat {
        let intersectionRect = intersection(other)
        if intersectionRect.isNull || intersectionRect.isEmpty { return 0 }
        let union = area + other.area - intersectionRect.area
        return union > 0 ? intersectionRect.area / union : 0
    }
}

extension String {
    var collapsedSpaces: String {
        replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
