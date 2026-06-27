//
//  ImageScaling.swift
//  VisionControlScannerApp
//
//  Created by Avery Varney on 6/26/26.
//


import Foundation
import CoreGraphics
import CoreImage

enum ImageScaling {

    /// Downscale `image` so its height does not exceed `maxHeight`, preserving
    /// aspect ratio. Returns the original image untouched if it's already at
    /// or below the target height. Uses Lanczos for sharp text downsampling.
    static func downscaleIfNeeded(_ image: CGImage, maxHeight: Int) -> CGImage {
        guard maxHeight > 0, image.height > maxHeight else { return image }

        let scale = CGFloat(maxHeight) / CGFloat(image.height)
        let newWidth = Int((CGFloat(image.width) * scale).rounded())
        let newHeight = maxHeight

        let ci = CIImage(cgImage: image)
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let output = filter.outputImage else { return image }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let targetRect = CGRect(x: 0, y: 0, width: newWidth, height: newHeight)
        guard let cg = context.createCGImage(output, from: targetRect) else { return image }
        return cg
    }
}