import AppKit
import CoreImage
import Vision

/// Splits a picture into its foreground elements (people, objects …) with the system's subject-lifting model
/// (`VNGenerateForegroundInstanceMaskRequest`, macOS 14+). Each element comes back as a transparent PNG crop plus
/// where it sits in the picture, so it can be placed on the slide exactly where it was.
enum ImageExtractor {
    struct Part {
        let image: CGImage          // RGBA crop with the rest of the picture transparent
        let box: CGRect             // pixels of the source picture, origin top-left
    }
    struct Output {
        let size: CGSize            // source picture in pixels
        let parts: [Part]           // left to right
    }

    enum Failure: LocalizedError {
        case unsupported, unreadable
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Extracting elements needs macOS 14 or later."
            case .unreadable: return "The picture could not be read."
            }
        }
    }

    static func extract(path: String) throws -> Output {
        guard #available(macOS 14.0, *) else { throw Failure.unsupported }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.unreadable
        }
        let w = cg.width, h = cg.height
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let obs = request.results?.first else { return Output(size: CGSize(width: w, height: h), parts: []) }
        let source = CIImage(cgImage: cg)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CIContext(options: [.workingColorSpace: srgb, .outputColorSpace: srgb])
        var parts: [Part] = []
        for i in obs.allInstances {
            let mask = try obs.generateScaledMaskForImage(forInstances: IndexSet(integer: i), from: handler)
            guard let box = bounds(of: mask) else { continue }
            let maskImage = CIImage(cvPixelBuffer: mask)
            guard let blend = CIFilter(name: "CIBlendWithMask") else { continue }
            blend.setValue(source, forKey: kCIInputImageKey)
            blend.setValue(CIImage(color: .clear).cropped(to: source.extent), forKey: kCIInputBackgroundImageKey)
            blend.setValue(maskImage, forKey: kCIInputMaskImageKey)
            guard let out = blend.outputImage else { continue }
            // Core Image counts y from the bottom
            let rect = CGRect(x: box.minX, y: CGFloat(h) - box.maxY, width: box.width, height: box.height)
            guard let crop = ctx.createCGImage(out, from: rect, format: .RGBA8, colorSpace: srgb) else { continue }
            parts.append(Part(image: crop, box: box))
        }
        parts.sort { $0.box.minX < $1.box.minX }
        return Output(size: CGSize(width: w, height: h), parts: parts)
    }

    /// Tight box (plus a little padding) around the opaque pixels of a mask, in mask pixels, origin top-left.
    private static func bounds(of mask: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        let stride = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let floats = CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = base + y * stride
            var rowHit = false
            for x in 0..<w {
                let on = floats ? row.load(fromByteOffset: x * 4, as: Float.self) > 0.5
                               : row.load(fromByteOffset: x, as: UInt8.self) > 127
                if on {
                    rowHit = true
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
            }
            if rowHit {
                if y < minY { minY = y }
                maxY = y
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 2
        let x0 = max(0, minX - pad), y0 = max(0, minY - pad)
        let x1 = min(w, maxX + 1 + pad), y1 = min(h, maxY + 1 + pad)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Modal chooser: a checkbox and thumbnail per element. Returns the indexes to insert.
    @MainActor static func choose(parts: [Part], source: String) -> [Int] {
        let a = NSAlert()
        a.messageText = "Extract elements from \(source)"
        a.informativeText = "\(parts.count) separate element\(parts.count == 1 ? "" : "s") found. Each ticked one becomes its own image on the slide, placed where it is in the picture, so it can be moved and animated on its own. The original picture stays."
        let rowH: CGFloat = 86, width: CGFloat = 380
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: rowH * CGFloat(parts.count)))
        var boxes: [NSButton] = []
        for (i, p) in parts.enumerated() {
            let iv = NSImageView(frame: NSRect(x: 8, y: CGFloat(i) * rowH + 5, width: 120, height: rowH - 10))
            iv.image = NSImage(cgImage: p.image, size: NSSize(width: p.image.width, height: p.image.height))
            iv.imageScaling = .scaleProportionallyDown
            iv.wantsLayer = true
            iv.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.25).cgColor
            iv.layer?.cornerRadius = 5
            let cb = NSButton(checkboxWithTitle: "Element \(i + 1)   \(Int(p.box.width)) × \(Int(p.box.height)) px", target: nil, action: nil)
            cb.state = .on
            cb.frame = NSRect(x: 140, y: CGFloat(i) * rowH + rowH / 2 - 10, width: width - 150, height: 20)
            doc.addSubview(iv); doc.addSubview(cb)
            boxes.append(cb)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(rowH * CGFloat(parts.count), 4 * rowH)))
        scroll.documentView = doc
        scroll.hasVerticalScroller = parts.count > 4
        scroll.borderType = .bezelBorder
        a.accessoryView = scroll
        a.addButton(withTitle: "Insert Elements"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return [] }
        return boxes.enumerated().filter { $0.element.state == .on }.map { $0.offset }
    }
}
