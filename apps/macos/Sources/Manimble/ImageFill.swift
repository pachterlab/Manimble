import CoreGraphics
import Foundation

/// Fills a hole in a picture with a best guess of what is behind it: multi-scale PatchMatch with patch voting
/// (Wexler et al., "Space-Time Completion of Video"; Barnes et al., "PatchMatch"), the same idea as content-aware fill.
/// Every hole pixel is rebuilt from 7 × 7 patches copied from the rest of the picture, coarse to fine, so walls,
/// water, floors and outlines continue through the gap instead of being smeared.
enum ImageFill {
    private static let r = 3                     // patch radius (7 × 7 patches); larger ones bleed walls into floors
    private static let globalTries = 4           // random candidates from anywhere in the picture, per pixel and pass
    private static let occLambda: Float = 20     // cost of reusing a source patch again (keeps textures varied)

    /// One pyramid level: RGBA floats (0…255, straight alpha) and the hole (true = unknown).
    private struct Level {
        let w: Int, h: Int
        var px: [Float]
        var hole: [Bool]
    }

    /// `hole`: one byte per pixel of `image` (row 0 at the top), non-zero where the picture should be invented.
    static func inpaint(_ image: CGImage, hole: [UInt8]) -> CGImage? {
        let w = image.width, h = image.height
        guard hole.count == w * h, var rgba = rgbaBytes(image) else { return nil }
        guard hole.contains(where: { $0 != 0 }) else { return image }
        var finest = Level(w: w, h: h, px: rgba.map { Float($0) }, hole: hole.map { $0 != 0 })
        if !finest.hole.contains(false) { return nil }   // nothing to copy from

        // pyramid, finest first; stop once the picture is small enough that the hole is a few patches across
        var levels = [finest]
        while max(levels.last!.w, levels.last!.h) > 96, min(levels.last!.w, levels.last!.h) > 24 {
            let next = downsample(levels.last!)
            if !next.hole.contains(false) { break }
            levels.append(next)
        }
        levels[levels.count - 1].px = diffuse(levels[levels.count - 1])

        var nnf: [Int32] = []                   // per pixel: index of the source patch centre (-1 = none)
        for li in stride(from: levels.count - 1, through: 0, by: -1) {
            var L = levels[li]
            let valid = validCentres(L)
            guard !valid.isEmpty else { return nil }
            if li == levels.count - 1 {
                nnf = randomField(L, valid)
            } else {
                let C = levels[li + 1]
                nnf = upsampleField(nnf, from: C, to: L, valid: valid)
                L.px = upsample(C.px, cw: C.w, ch: C.h, into: L)
                vote(&L, nnf: nnf, sharp: false)
            }
            let rounds = li == levels.count - 1 ? 8 : 5
            var isValid = [Bool](repeating: false, count: L.w * L.h)
            for v in valid { isValid[Int(v)] = true }
            for round in 0..<rounds {
                patchMatch(L, nnf: &nnf, valid: valid, isValid: isValid, iterations: round == 0 ? 3 : 2)
                vote(&L, nnf: nnf, sharp: round >= rounds / 2)
            }
            levels[li] = L
        }
        finest = levels[0]
        for i in 0..<(w * h) where finest.hole[i] {
            for c in 0..<4 { rgba[i * 4 + c] = UInt8(max(0, min(255, finest.px[i * 4 + c].rounded()))) }
        }
        return makeImage(rgba, w: w, h: h)
    }

    // MARK: pixels

    static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        // un-premultiply so transparent areas don't darken what is copied from them
        for i in stride(from: 0, to: data.count, by: 4) {
            let a = Int(data[i + 3])
            if a > 0 && a < 255 {
                for c in 0..<3 { data[i + c] = UInt8(min(255, Int(data[i + c]) * 255 / a)) }
            }
        }
        return data
    }

    static func makeImage(_ straight: [UInt8], w: Int, h: Int) -> CGImage? {
        var data = straight
        for i in stride(from: 0, to: data.count, by: 4) {
            let a = Int(data[i + 3])
            if a < 255 { for c in 0..<3 { data[i + c] = UInt8(Int(data[i + c]) * a / 255) } }
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return data.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    // MARK: pyramid

    private static func downsample(_ L: Level) -> Level {
        let w = (L.w + 1) / 2, h = (L.h + 1) / 2
        var px = [Float](repeating: 0, count: w * h * 4)
        var hole = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
                var n: Float = 0, anyHole = false
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let sx = min(L.w - 1, 2 * x + dx), sy = min(L.h - 1, 2 * y + dy), s = sy * L.w + sx
                        if L.hole[s] { anyHole = true; continue }
                        acc.0 += L.px[s * 4]; acc.1 += L.px[s * 4 + 1]; acc.2 += L.px[s * 4 + 2]; acc.3 += L.px[s * 4 + 3]
                        n += 1
                    }
                }
                let i = y * w + x
                hole[i] = anyHole
                if n > 0 { px[i * 4] = acc.0 / n; px[i * 4 + 1] = acc.1 / n; px[i * 4 + 2] = acc.2 / n; px[i * 4 + 3] = acc.3 / n }
            }
        }
        return Level(w: w, h: h, px: px, hole: hole)
    }

    /// Bilinear upsample of a coarser level's colours, used only inside the finer level's hole.
    private static func upsample(_ cpx: [Float], cw: Int, ch: Int, into L: Level) -> [Float] {
        var px = L.px
        for y in 0..<L.h {
            let fy = max(0, min(Float(ch - 1), (Float(y) + 0.5) / 2 - 0.5))
            let y0 = Int(fy), y1 = min(ch - 1, y0 + 1), ty = fy - Float(y0)
            for x in 0..<L.w where L.hole[y * L.w + x] {
                let fx = max(0, min(Float(cw - 1), (Float(x) + 0.5) / 2 - 0.5))
                let x0 = Int(fx), x1 = min(cw - 1, x0 + 1), tx = fx - Float(x0)
                let i = (y * L.w + x) * 4
                for c in 0..<4 {
                    let a = cpx[(y0 * cw + x0) * 4 + c] * (1 - tx) + cpx[(y0 * cw + x1) * 4 + c] * tx
                    let b = cpx[(y1 * cw + x0) * 4 + c] * (1 - tx) + cpx[(y1 * cw + x1) * 4 + c] * tx
                    px[i + c] = a * (1 - ty) + b * ty
                }
            }
        }
        return px
    }

    /// Starting guess at the coarsest level: peel the hole from its edge inwards, averaging known neighbours.
    private static func diffuse(_ L: Level) -> [Float] {
        var px = L.px, known = L.hole.map { !$0 }
        var left = known.filter { !$0 }.count
        while left > 0 {
            var newly: [Int] = []
            for y in 0..<L.h {
                for x in 0..<L.w where !known[y * L.w + x] {
                    var acc: [Float] = [0, 0, 0, 0], n: Float = 0
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < L.w, ny < L.h, known[ny * L.w + nx] else { continue }
                        for c in 0..<4 { acc[c] += px[(ny * L.w + nx) * 4 + c] }
                        n += 1
                    }
                    if n > 0 {
                        for c in 0..<4 { px[(y * L.w + x) * 4 + c] = acc[c] / n }
                        newly.append(y * L.w + x)
                    }
                }
            }
            if newly.isEmpty { break }
            for i in newly { known[i] = true }
            left -= newly.count
        }
        return px
    }

    // MARK: PatchMatch

    /// Patch centres whose whole patch lies inside the picture and outside the hole.
    private static func validCentres(_ L: Level) -> [Int32] {
        // integral image of the hole, to test each patch in O(1)
        let W = L.w + 1
        var sum = [Int32](repeating: 0, count: W * (L.h + 1))
        for y in 0..<L.h {
            var row: Int32 = 0
            for x in 0..<L.w {
                row += L.hole[y * L.w + x] ? 1 : 0
                sum[(y + 1) * W + x + 1] = sum[y * W + x + 1] + row
            }
        }
        var out: [Int32] = []
        guard L.w > 2 * r, L.h > 2 * r else { return out }
        for y in r..<(L.h - r) {
            for x in r..<(L.w - r) {
                let x0 = x - r, y0 = y - r, x1 = x + r + 1, y1 = y + r + 1
                if sum[y1 * W + x1] - sum[y0 * W + x1] - sum[y1 * W + x0] + sum[y0 * W + x0] == 0 {
                    out.append(Int32(y * L.w + x))
                }
            }
        }
        return out
    }

    /// Pixels whose patch overlaps the hole: the patches the fill is made of.
    private static func targets(_ L: Level) -> [Int] {
        var mark = [Bool](repeating: false, count: L.w * L.h)
        for y in 0..<L.h {
            for x in 0..<L.w where L.hole[y * L.w + x] {
                for yy in max(0, y - r)...min(L.h - 1, y + r) {
                    for xx in max(0, x - r)...min(L.w - 1, x + r) { mark[yy * L.w + xx] = true }
                }
            }
        }
        return mark.indices.filter { mark[$0] }
    }

    private static func randomField(_ L: Level, _ valid: [Int32]) -> [Int32] {
        var nnf = [Int32](repeating: -1, count: L.w * L.h)
        var rng = SplitMix(seed: 1)
        for p in targets(L) { nnf[p] = valid[Int(rng.next() % UInt64(valid.count))] }
        return nnf
    }

    private static func upsampleField(_ coarse: [Int32], from C: Level, to L: Level, valid: [Int32]) -> [Int32] {
        var nnf = [Int32](repeating: -1, count: L.w * L.h)
        var rng = SplitMix(seed: 2)
        var isValid = [Bool](repeating: false, count: L.w * L.h)
        for v in valid { isValid[Int(v)] = true }
        for p in targets(L) {
            let x = p % L.w, y = p / L.w
            let c = coarse[min(C.h - 1, y / 2) * C.w + min(C.w - 1, x / 2)]
            if c >= 0 {
                let qx = min(L.w - 1, Int(c) % C.w * 2 + x % 2), qy = min(L.h - 1, Int(c) / C.w * 2 + y % 2)
                let q = qy * L.w + qx
                if isValid[q] { nnf[p] = Int32(q); continue }
            }
            nnf[p] = valid[Int(rng.next() % UInt64(valid.count))]
        }
        return nnf
    }

    /// Sum of squared colour differences between the patch at p (current guess, clipped to the picture)
    /// and the source patch at q, divided by the pixels compared. Gives up early past `limit`.
    @inline(__always)
    private static func distance(_ px: UnsafePointer<Float>, _ w: Int, _ h: Int, _ p: Int, _ q: Int, _ limit: Float) -> Float {
        let px0 = p % w, py0 = p / w, qx0 = q % w, qy0 = q / w
        var d: Float = 0, n: Float = 0
        let x0 = max(-r, -px0), x1 = min(r, w - 1 - px0), y0 = max(-r, -py0), y1 = min(r, h - 1 - py0)
        let cap = limit * Float((x1 - x0 + 1) * (y1 - y0 + 1))
        for dy in y0...y1 {
            var a = ((py0 + dy) * w + px0 + x0) * 4, b = ((qy0 + dy) * w + qx0 + x0) * 4
            for _ in x0...x1 {
                let e0 = px[a] - px[b], e1 = px[a + 1] - px[b + 1], e2 = px[a + 2] - px[b + 2], e3 = px[a + 3] - px[b + 3]
                d += e0 * e0 + e1 * e1 + e2 * e2 + e3 * e3
                a += 4; b += 4
            }
            n += Float(x1 - x0 + 1)
            if d > cap { return .greatestFiniteMagnitude }
        }
        return d / max(n, 1)
    }

    private static func patchMatch(_ L: Level, nnf: inout [Int32], valid: [Int32], isValid: [Bool], iterations: Int) {
        let w = L.w, h = L.h
        let ts = targets(L)
        var rng = SplitMix(seed: UInt64(w * 31 + h))
        L.px.withUnsafeBufferPointer { pb in
            let px = pb.baseAddress!
            var dist = [Float](repeating: .greatestFiniteMagnitude, count: w * h)
            // how often each source patch is used: reusing one smooth patch everywhere makes flat fills
            var occ = [Float](repeating: 0, count: w * h)
            for p in ts where nnf[p] >= 0 { occ[Int(nnf[p])] += 1 }
            let lambda = occLambda
            for p in ts { dist[p] = distance(px, w, h, p, Int(nnf[p]), .greatestFiniteMagnitude) + lambda * occ[Int(nnf[p])] }
            for it in 0..<iterations {
                let forward = it % 2 == 0
                let step = forward ? 1 : -1
                var k = forward ? 0 : ts.count - 1
                while k >= 0 && k < ts.count {
                    let p = ts[k]; k += step
                    let x = p % w, y = p / w
                    let was = Int(nnf[p])
                    var best = was, bestD = dist[p]
                    @inline(__always) func tryq(_ q: Int) {
                        guard q >= 0, q < w * h, q != best, isValid[q] else { return }
                        let pen = lambda * (occ[q] + 1)
                        guard pen < bestD else { return }
                        let d = distance(px, w, h, p, q, bestD - pen) + pen
                        if d < bestD { bestD = d; best = q }
                    }
                    // propagation: the neighbour's match, shifted by one
                    let nx = x - step, ny = y - step
                    if nx >= 0 && nx < w, nnf[y * w + nx] >= 0 {
                        let q = Int(nnf[y * w + nx]); let qx = q % w + step
                        if qx >= 0 && qx < w { tryq(q + step) }
                    }
                    if ny >= 0 && ny < h, nnf[ny * w + x] >= 0 {
                        let q = Int(nnf[ny * w + x]); let qy = q / w + step
                        if qy >= 0 && qy < h { tryq(q + step * w) }
                    }
                    // random search around the current match, shrinking
                    var radius = max(w, h)
                    let bx = best % w, by = best / w
                    while radius >= 1 {
                        let rx = bx + Int(rng.next() % UInt64(2 * radius + 1)) - radius
                        let ry = by + Int(rng.next() % UInt64(2 * radius + 1)) - radius
                        if rx >= 0 && rx < w && ry >= 0 && ry < h { tryq(ry * w + rx) }
                        radius /= 2
                    }
                    // and a few anywhere: matches from elsewhere in the picture
                    for _ in 0..<globalTries { tryq(Int(valid[Int(rng.next() % UInt64(valid.count))])) }
                    if best != was { occ[was] -= 1; occ[best] += 1 }
                    nnf[p] = Int32(best); dist[p] = bestD
                }
            }
        }
    }

    /// Rebuild each hole pixel from the matched patches that cover it. `sharp` takes the best-matching
    /// patch's pixel instead of the weighted mean, which keeps thin outlines and edges crisp.
    private static func vote(_ L: inout Level, nnf: [Int32], sharp: Bool) {
        let w = L.w, h = L.h
        var acc = [Float](repeating: 0, count: w * h * 4)
        var wsum = [Float](repeating: 0, count: w * h)
        var bestW = [Float](repeating: -1, count: w * h)
        var dists: [Float] = []
        let ts = targets(L)
        L.px.withUnsafeBufferPointer { pb in
            for p in ts { dists.append(distance(pb.baseAddress!, w, h, p, Int(nnf[p]), .greatestFiniteMagnitude)) }
        }
        let sorted = dists.sorted()
        let sigma2 = max(1, sorted.isEmpty ? 1 : sorted[sorted.count * 3 / 4])
        var pick = L.px
        for (k, p) in ts.enumerated() {
            let q = Int(nnf[p]); guard q >= 0 else { continue }
            let wt = exp(-dists[k] / (2 * sigma2))
            let px0 = p % w, py0 = p / w, qx0 = q % w, qy0 = q / w
            for dy in -r...r {
                let ty = py0 + dy; guard ty >= 0, ty < h else { continue }
                for dx in -r...r {
                    let tx = px0 + dx; guard tx >= 0, tx < w else { continue }
                    let t = ty * w + tx; guard L.hole[t] else { continue }
                    let s = ((qy0 + dy) * w + qx0 + dx) * 4
                    for c in 0..<4 { acc[t * 4 + c] += wt * L.px[s + c] }
                    wsum[t] += wt
                    if sharp && wt > bestW[t] {
                        bestW[t] = wt
                        for c in 0..<4 { pick[t * 4 + c] = L.px[s + c] }
                    }
                }
            }
        }
        for t in 0..<(w * h) where L.hole[t] && wsum[t] > 0 {
            for c in 0..<4 { L.px[t * 4 + c] = sharp ? pick[t * 4 + c] : acc[t * 4 + c] / wsum[t] }
        }
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}
