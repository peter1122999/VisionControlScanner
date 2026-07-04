import Foundation
import CoreGraphics

/// Splits a System-Settings-style window screenshot into a left sidebar
/// pane and a right content pane. Needed because the sidebar's row
/// background is now nearly indistinguishable in color from the content
/// pane (Sequoia+ redesign dropped the old solid-gray sidebar fill), so a
/// naive column-color scan finds nothing — only the *selected* sidebar row
/// still stands out (system-blue highlight). Instead this looks for a
/// sustained brightness/color shift between a narrow band just left of the
/// expected divider and a narrow band just right of it, sampled across many
/// rows so a single row's icon or selection highlight can't dominate the
/// score, and falls back to the expected divider itself when no sample in
/// the search window scores above noise (e.g. a content pane so uniformly
/// white it matches the sidebar almost exactly).
enum PaneDetector {
    struct RGBPixel {
        let r: UInt8
        let g: UInt8
        let b: UInt8
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
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var raw = [UInt8](repeating: 0, count: height * bytesPerRow)
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
            pixels.append(RGBPixel(r: raw[index], g: raw[index + 1], b: raw[index + 2]))
            index += 4
        }
        return RGBImage(width: width, height: height, pixels: pixels)
    }

    /// Sidebar and content pane rects, in the same top-down pixel space as
    /// `cgImage` (matches the coordinate convention used for `bbox` in the
    /// tart JSON output — origin top-left, y grows downward).
    struct Panes {
        let sidebar: CGRect
        let content: CGRect
    }

    /// macOS System Settings' sidebar is ~213pt wide against a ~750pt
    /// default window width — used only as the center of the search
    /// window and as a last-resort fallback, never as the final answer.
    private static let expectedSidebarFraction: Double = 0.284
    private static let searchHalfWidthFraction: Double = 0.12
    /// A real divider's band-average luminance gap; below this the scan
    /// found nothing meaningful (e.g. an all-white content pane row) and
    /// should not be trusted over the fallback.
    private static let minEdgeScore: Double = 6.0

    static func detect(cgImage: CGImage) -> Panes? {
        guard let rgb = makeRGBImage(from: cgImage) else { return nil }
        let width = rgb.width
        let height = rgb.height
        guard width > 40, height > 40 else { return nil }

        let expectedX = Int(Double(width) * expectedSidebarFraction)
        let searchHalf = max(10, Int(Double(width) * searchHalfWidthFraction))
        let loX = max(8, expectedX - searchHalf)
        let hiX = min(width - 8, expectedX + searchHalf)
        guard loX < hiX else {
            return fallbackPanes(width: width, height: height, splitX: expectedX)
        }

        // Skip the title bar / toolbar strip (icons, traffic lights) at the
        // very top and any status strip at the very bottom.
        let topMargin = Int(Double(height) * 0.08)
        let bottomMargin = Int(Double(height) * 0.03)
        let yStart = min(height - 1, topMargin)
        let yEnd = max(yStart + 1, height - bottomMargin)
        guard yEnd > yStart else {
            return fallbackPanes(width: width, height: height, splitX: expectedX)
        }
        // Sample every 3rd row — cheap and plenty dense for a band average.
        let rowStride = 3
        let bandHalf = 4 // pixels averaged on each side of the candidate column

        var bestX = expectedX
        var bestScore = -Double.infinity

        var x = loX
        while x <= hiX {
            var leftSum = 0.0, leftCount = 0.0
            var rightSum = 0.0, rightCount = 0.0
            var y = yStart
            while y < yEnd {
                for dx in 1...bandHalf {
                    if let lp = rgb.pixel(x: x - dx, y: y) {
                        leftSum += lp.luminance; leftCount += 1
                    }
                    if let rp = rgb.pixel(x: x + dx, y: y) {
                        rightSum += rp.luminance; rightCount += 1
                    }
                }
                y += rowStride
            }
            if leftCount > 0, rightCount > 0 {
                let score = abs((leftSum / leftCount) - (rightSum / rightCount))
                if score > bestScore {
                    bestScore = score
                    bestX = x
                }
            }
            x += 1
        }

        let splitX = bestScore >= minEdgeScore ? bestX : expectedX
        return fallbackPanes(width: width, height: height, splitX: splitX)
    }

    private static func fallbackPanes(width: Int, height: Int, splitX: Int) -> Panes {
        let clampedX = max(1, min(width - 1, splitX))
        let sidebar = CGRect(x: 0, y: 0, width: clampedX, height: height)
        let content = CGRect(x: clampedX, y: 0, width: width - clampedX, height: height)
        return Panes(sidebar: sidebar, content: content)
    }
}
