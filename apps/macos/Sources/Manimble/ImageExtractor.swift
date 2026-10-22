import AppKit
import Vision

/// Splits a picture into its foreground elements (people, objects …) with the system's subject-lifting model
/// (`VNGenerateForegroundInstanceMaskRequest`, macOS 14+): every subject in the picture, or the one inside a box.
/// Elements are masks over the picture; each becomes a transparent PNG crop plus where it sits in the picture,
/// so it can be placed on the slide exactly where it was.
enum ImageExtractor {
    struct Part {
        let image: CGImage          // RGBA crop with the rest of the picture transparent
        let box: CGRect             // pixels of the source picture, origin top-left
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

    static func load(path: String) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw Failure.unreadable
        }
        return cg
    }

    // MARK: masks (one byte per pixel of the picture, row 0 at the top, 255 = part of the element)

    /// One mask per separate foreground element the subject-lifting model finds in the whole picture.
    static func subjects(in cg: CGImage) throws -> [[UInt8]] {
        guard #available(macOS 14.0, *) else { throw Failure.unsupported }
        return try instanceMasks(cg).map { $0.mask }
    }

    /// The element inside `box` (picture pixels, origin top-left): the model looks at a crop around the box,
    /// so a smaller thing (a hat, a framed picture) becomes the subject, and the result is clipped to the box.
    /// Falls back to the whole box when the model finds nothing there.
    static func subject(in cg: CGImage, box: CGRect) throws -> [UInt8] {
        guard #available(macOS 14.0, *) else { throw Failure.unsupported }
        let w = cg.width, h = cg.height
        let b = box.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard b.width >= 2, b.height >= 2 else { return [UInt8](repeating: 0, count: w * h) }
        let pad = max(b.width, b.height) * 0.12
        let crop = b.insetBy(dx: -pad, dy: -pad).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let piece = cg.cropping(to: crop) else { return rectangle(w: w, h: h, box: b) }
        let cw = piece.width, chh = piece.height
        // the box in crop pixels
        let bx0 = Int(b.minX - crop.minX), by0 = Int(b.minY - crop.minY)
        let bx1 = min(cw, bx0 + Int(b.width)), by1 = min(chh, by0 + Int(b.height))
        var chosen: [[UInt8]] = []
        var fallback: ([UInt8], Int)? = nil
        for inst in try instanceMasks(piece) {
            var inside = 0, total = 0
            for y in 0..<chh {
                for x in 0..<cw where inst.mask[y * cw + x] > 127 {
                    total += 1
                    if x >= bx0 && x < bx1 && y >= by0 && y < by1 { inside += 1 }
                }
            }
            guard total > 0 else { continue }
            if Double(inside) >= 0.5 * Double(total) { chosen.append(inst.mask) }
            else if inside > (fallback?.1 ?? 0) { fallback = (inst.mask, inside) }
        }
        let boxArea = (bx1 - bx0) * (by1 - by0)
        if chosen.isEmpty, let f = fallback, Double(f.1) > 0.1 * Double(boxArea) { chosen = [f.0] }
        guard !chosen.isEmpty else { return rectangle(w: w, h: h, box: b) }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in by0..<by1 {
            for x in bx0..<bx1 {
                var v: UInt8 = 0
                for m in chosen { v = max(v, m[y * cw + x]) }
                out[(y + Int(crop.minY)) * w + x + Int(crop.minX)] = v
            }
        }
        return out
    }

    static func rectangle(w: Int, h: Int, box: CGRect) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        let b = box.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !b.isNull, b.width > 0, b.height > 0 else { return out }
        for y in Int(b.minY)..<Int(b.maxY) { for x in Int(b.minX)..<Int(b.maxX) { out[y * w + x] = 255 } }
        return out
    }

    @available(macOS 14.0, *)
    private static func instanceMasks(_ cg: CGImage) throws -> [(mask: [UInt8], count: Int)] {
        let w = cg.width, h = cg.height
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let obs = request.results?.first else { return [] }
        var out: [(mask: [UInt8], count: Int)] = []
        for i in obs.allInstances {
            let buf = try obs.generateScaledMaskForImage(forInstances: IndexSet(integer: i), from: handler)
            let m = bytes(of: buf, w: w, h: h)
            let n = m.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
            if n > 0 { out.append((m, n)) }
        }
        return out
    }

    /// A Vision mask as one byte per pixel (it is already scaled to the picture).
    private static func bytes(of mask: CVPixelBuffer, w: Int, h: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        var out = [UInt8](repeating: 0, count: w * h)
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return out }
        let mw = min(w, CVPixelBufferGetWidth(mask)), mh = min(h, CVPixelBufferGetHeight(mask))
        let stride = CVPixelBufferGetBytesPerRow(mask)
        let floats = CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float
        for y in 0..<mh {
            let row = base + y * stride
            for x in 0..<mw {
                out[y * w + x] = floats ? UInt8(max(0, min(255, row.load(fromByteOffset: x * 4, as: Float.self) * 255)))
                                        : row.load(fromByteOffset: x, as: UInt8.self)
            }
        }
        return out
    }

    /// Tight box (plus a little padding) around the pixels of a mask, origin top-left.
    static func bounds(of mask: [UInt8], w: Int, h: Int) -> CGRect? {
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            var rowHit = false
            for x in 0..<w where mask[y * w + x] > 127 {
                rowHit = true
                if x < minX { minX = x }
                if x > maxX { maxX = x }
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

    /// The element as a transparent crop of the picture.
    static func cutOut(_ cg: CGImage, mask: [UInt8]) -> Part? {
        let w = cg.width, h = cg.height
        guard mask.count == w * h, let box = bounds(of: mask, w: w, h: h), let rgba = ImageFill.rgbaBytes(cg) else { return nil }
        let bx = Int(box.minX), by = Int(box.minY), bw = Int(box.width), bh = Int(box.height)
        var out = [UInt8](repeating: 0, count: bw * bh * 4)
        for y in 0..<bh {
            for x in 0..<bw {
                let s = (y + by) * w + x + bx, t = (y * bw + x) * 4
                for c in 0..<3 { out[t + c] = rgba[s * 4 + c] }
                out[t + 3] = UInt8(Int(rgba[s * 4 + 3]) * Int(mask[s]) / 255)
            }
        }
        guard let img = ImageFill.makeImage(out, w: bw, h: bh) else { return nil }
        return Part(image: img, box: box)
    }

    /// What the background fill has to invent: every element, grown by a few pixels so their outlines
    /// and soft edges go too.
    static func hole(for masks: [[UInt8]], w: Int, h: Int) -> [UInt8] {
        var hole = [UInt8](repeating: 0, count: w * h)
        for m in masks { for i in 0..<(w * h) where m[i] > 40 { hole[i] = 255 } }
        let grow = max(2, min(w, h) / 160)
        // separable square dilation
        var tmp = hole
        for y in 0..<h {
            var last = -1_000_000
            for x in 0..<w { if hole[y * w + x] != 0 { last = x }; if x - last <= grow { tmp[y * w + x] = 255 } }
            last = 1_000_000
            for x in stride(from: w - 1, through: 0, by: -1) { if hole[y * w + x] != 0 { last = x }; if last - x <= grow { tmp[y * w + x] = 255 } }
        }
        var out = tmp
        for x in 0..<w {
            var last = -1_000_000
            for y in 0..<h { if tmp[y * w + x] != 0 { last = y }; if y - last <= grow { out[y * w + x] = 255 } }
            last = 1_000_000
            for y in stride(from: h - 1, through: 0, by: -1) { if tmp[y * w + x] != 0 { last = y }; if last - y <= grow { out[y * w + x] = 255 } }
        }
        return out
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
