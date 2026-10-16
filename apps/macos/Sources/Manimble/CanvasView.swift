import AppKit
import Metal
import MetalKit
import ImageIO

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U {
    float4 rect;     // x, y, w, h in frame pixels
    float4 color;    // rgba (solid) / opacity in .a (textured)
    float2 frame;    // frame size in pixels
    float2 pad;
};
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut vs(uint vid [[vertex_id]], constant U &u [[buffer(0)]]) {
    const float2 c[6] = { float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(1,1), float2(0,1) };
    float2 p = c[vid];
    float2 px = u.rect.xy + p * u.rect.zw;
    VOut o;
    o.pos = float4(px.x / u.frame.x * 2.0 - 1.0, 1.0 - px.y / u.frame.y * 2.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// Geometry from `geo` (x, y, w, h) while rect/color carry shader parameters.
struct U2 {
    float4 rect;
    float4 color;
    float2 frame;
    float2 pad;
    float4 geo;
};
vertex VOut vs_geo(uint vid [[vertex_id]], constant U2 &u [[buffer(0)]]) {
    const float2 c[6] = { float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(1,1), float2(0,1) };
    float2 p = c[vid];
    float2 px = u.geo.xy + p * u.geo.zw;
    VOut o;
    o.pos = float4(px.x / u.frame.x * 2.0 - 1.0, 1.0 - px.y / u.frame.y * 2.0, 0.0, 1.0);
    o.uv = p;
    return o;
}
fragment float4 fs_gradient2(VOut in [[stage_in]], constant U2 &u [[buffer(0)]]) {
    float3 top = u.color.rgb, bottom = u.rect.xyz;
    float t = clamp(in.uv.y, 0.0, 1.0);
    float2 c = in.uv - 0.5;
    float vignette = 1.0 - 0.38 * smoothstep(0.15, 0.85, length(c * float2(1.0, 1.15)));
    return float4(mix(top, bottom, t) * vignette, 1.0);
}
fragment float4 fs_disc2(VOut in [[stage_in]], constant U2 &u [[buffer(0)]]) {
    float2 p = (in.uv - 0.5) * 2.0;
    float r = length(p);
    float aa = 0.12;
    float inside = 1.0 - smoothstep(1.0 - aa, 1.0, r);
    float ring = smoothstep(1.0 - u.pad.x - aa, 1.0 - u.pad.x, r);
    float3 rgb = mix(u.color.rgb, u.rect.xyz, ring);
    return float4(rgb * inside, inside);
}
fragment float4 fs_shadow2(VOut in [[stage_in]], constant U2 &u [[buffer(0)]]) {
    float2 p = abs(in.uv - 0.5) * 2.0;
    float2 q = (p - (1.0 - u.pad)) / max(u.pad, float2(1e-3));
    float d = length(max(q, 0.0));
    float a = (1.0 - smoothstep(0.0, 1.0, d));
    return float4(0, 0, 0, a * a * u.color.a);
}

// A thick segment from rect.xy to rect.zw (frame px), thickness in pad.x.
vertex VOut vs_line(uint vid [[vertex_id]], constant U &u [[buffer(0)]]) {
    const float2 c[6] = { float2(0,0), float2(1,0), float2(0,1), float2(1,0), float2(1,1), float2(0,1) };
    float2 p = c[vid];
    float2 a = u.rect.xy, b = u.rect.zw;
    float2 d = normalize(b - a + float2(1e-4, 0));
    float2 n = float2(-d.y, d.x) * (u.pad.x * 0.5);
    float2 px = mix(a, b, p.x) + n * (p.y * 2.0 - 1.0);
    VOut o;
    o.pos = float4(px.x / u.frame.x * 2.0 - 1.0, 1.0 - px.y / u.frame.y * 2.0, 0.0, 1.0);
    o.uv = p;
    return o;
}

// Textures hold premultiplied RGBA.
fragment float4 fs_tex(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv) * u.color.a;
}

// Dark mode: lightness of near-neutral colours mirrored, hue kept (see DarkMode.swift; chroma thresholds in u.pad).
float3 darkmap(float3 c, float2 th) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float w = 1.0 - smoothstep(th.x, th.y, mx - mn);
    return clamp(c + w * (1.0 - mx - mn), 0.0, 1.0);
}
fragment float4 fs_tex_dark(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 p = t.sample(s, in.uv);
    if (p.a <= 0.0) return float4(0.0);
    return float4(darkmap(p.rgb / p.a, u.pad) * p.a, p.a) * u.color.a;
}

fragment float4 fs_tex_invert(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant U &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 p = t.sample(s, in.uv);
    return float4(p.a - p.rgb, p.a) * u.color.a;          // premultiplied 1 - c
}

fragment float4 fs_solid(VOut in [[stage_in]], constant U &u [[buffer(0)]]) {
    return float4(u.color.rgb * u.color.a, u.color.a);
}

"""

private struct Uniforms {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
    var frame: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
}

private struct Uniforms2 {
    var rect: SIMD4<Float>
    var color: SIMD4<Float>
    var frame: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
    var geo: SIMD4<Float>
}

private let accentRGB = SIMD4<Float>(0.486, 0.361, 1.0, 1)

/// A temporary, instant edit shown while the real re-render is still running.
struct Override {
    var dx: Double = 0, dy: Double = 0        // px translation
    var scale: Double = 1                     // about the object's centre
    var replacement: (tex: MTLTexture, w: Double, h: Double)?   // new text/formula raster
}

enum Handle: Int { case nw, ne, sw, se }

/// Metal-drawn slide canvas: exact frame when idle; backdrop + object sprites while editing.
final class CanvasView: MTKView {
    private var queue: MTLCommandQueue!
    private var texPipe: MTLRenderPipelineState!
    private var darkPipe: MTLRenderPipelineState!
    private var invertPipe: MTLRenderPipelineState!
    private var solidPipe: MTLRenderPipelineState!
    private var linePipe: MTLRenderPipelineState!
    private var gradPipe: MTLRenderPipelineState!
    private var shadowPipe: MTLRenderPipelineState!
    private var discPipe: MTLRenderPipelineState!
    private var cache: [String: MTLTexture] = [:]
    private var cacheOrder: [String] = []
    private let loader: MTKTextureLoader

    // content
    var frameSize = CGSize(width: 1280, height: 720) { didSet { onGeometryChange?() } }
    var stop: StopInfo? { didSet { needsDisplay2(); onGeometryChange?() } }
    var sceneObjects: [String: ObjInfo] = [:]
    var selection: Int? { didSet { needsDisplay2(); onGeometryChange?() } }
    var hover: Int?
    var overrides: [Int: Override] = [:] { didSet { needsDisplay2(); onGeometryChange?() } }
    var showObjects = false { didSet { needsDisplay2() } }
    /// Dark mode / inverted colours (nothing is written): the slide is composited from backdrop + sprites, each colour-mapped.
    var colorView = ColorView.normal { didSet { needsDisplay2() } }
    var darkImages = true { didSet { needsDisplay2() } }
    /// Live endpoint edits of lines/arrows: oid -> (sx, sy, ex, ey) in frame px.
    var lineOverrides: [Int: [Double]] = [:] { didSet { needsDisplay2() } }
    /// A just-inserted element shown at once, before the real render arrives.
    var ghost: (tex: MTLTexture, cx: Double, cy: Double, w: Double, h: Double)? { didSet { needsDisplay2() } }
    var onEndpoints: ((Int, [Double]) -> Void)?
    private var dragEnd: Int?           // 0 = start, 1 = end
    /// Frame pixels per manim unit (grid spacing); set from the scene.
    var unitPx: Double = 90 { didSet { needsDisplay2(); onGeometryChange?() } }
    var showGrid = false { didSet { needsDisplay2() } }
    /// Snap a dragged object's edges and centre to other objects, the slide and the grid.
    var snapEnabled = true
    private var guides: [(vertical: Bool, pos: Double)] = [] { didSet { needsDisplay2() } }
    /// Guides the user added (frame px); draggable, removed by dragging off the slide, and snap targets.
    var userGuides: [(vertical: Bool, pos: Double)] = [] { didSet { needsDisplay2(); onGeometryChange?() } }
    var onGuidesChange: (() -> Void)?
    private var dragGuide: Int?
    /// Drawing mode: "line", "arrow", "darrow", "rectangle" or "ellipse"; drag on the slide to create one.
    var drawTool: String? { didSet { needsDisplay2(); onDrawToolChange?() } }
    var onDraw: ((String, Double, Double, Double, Double) -> Void)?
    var onDrawToolChange: (() -> Void)?
    private var drawStart: CGPoint?
    private var drawBand: (Double, Double, Double, Double)? { didSet { needsDisplay2() } }
    /// Pen tool (`drawTool == "pen"`): freehand strokes, each becoming a smooth VMobject in the source.
    var penColor = NSColor(hex: "#FF3B30") { didSet { needsDisplay2() } }
    var penWidth: Double = 6                        // manim stroke_width
    var onPen: (([CGPoint]) -> Void)?
    private var penPoints: [CGPoint] = [] { didSet { needsDisplay2() } }
    /// Strokes handed to the engine whose render has not arrived yet (drawn so they never flicker away).
    var pendingStrokes: [[CGPoint]] = [] { didSet { needsDisplay2() } }

    // callbacks
    var onSelect: ((Int?) -> Void)?
    var onMove: ((Int, Double, Double) -> Void)?
    var onResize: ((Int, Double) -> Void)?
    var onEdit: ((Int) -> Void)?
    var onNudge: ((Int, Double, Double) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onZoomChange: (() -> Void)?
    var onContextMenu: (() -> NSMenu?)?
    /// Anything the rulers show changed: slide placement, zoom, pan, selection or guides.
    var onGeometryChange: (() -> Void)?
    /// Pointer position over the canvas in frame px (nil when it leaves), for the rulers' cursor marks.
    var onCursorMove: ((CGPoint?) -> Void)?

    /// Points per frame pixel; nil = fit the slide to the window.
    var zoom: CGFloat? { didSet { if zoom == nil { pan = .zero }; needsDisplay2(); onZoomChange?(); onGeometryChange?() } }
    var pan = CGPoint.zero { didSet { needsDisplay2(); onGeometryChange?() } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onGeometryChange?()
    }

    // drag state
    private var dragStart: CGPoint?
    private var dragOID: Int?
    private var dragHandle: Handle?
    private var dragBox: Box?
    private var dragBase = (dx: 0.0, dy: 0.0)   // the object's previewed offset when this drag began (moves still rendering)
    /// The object being dragged right now, if any.
    var dragging: Int? { dragOID }

    /// A fresh render now shows part of this object's previewed offset: keep previewing only the rest.
    func settle(_ oid: Int, shownDx: Double, shownDy: Double) {
        guard var o = overrides[oid] else { return }
        o.dx -= shownDx; o.dy -= shownDy
        overrides[oid] = o
        if dragOID == oid { dragBase = (dragBase.dx - shownDx, dragBase.dy - shownDy) }
    }
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    init() {
        let dev = MTLCreateSystemDefaultDevice()!
        loader = MTKTextureLoader(device: dev)
        super.init(frame: .zero, device: dev)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.105, green: 0.108, blue: 0.12, alpha: 1)
        enableSetNeedsDisplay = true
        isPaused = true
        framebufferOnly = true
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        queue = dev.makeCommandQueue()
        buildPipelines(dev)
    }
    required init(coder: NSCoder) { fatalError() }

    private func needsDisplay2() { setNeedsDisplay(bounds) }

    private func buildPipelines(_ dev: MTLDevice) {
        let lib = try! dev.makeLibrary(source: shaderSource, options: nil)
        func make(_ frag: String, vertex: String = "vs") -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vertex)
            d.fragmentFunction = lib.makeFunction(name: frag)
            let a = d.colorAttachments[0]!
            a.pixelFormat = colorPixelFormat
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add; a.alphaBlendOperation = .add
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try! dev.makeRenderPipelineState(descriptor: d)
        }
        texPipe = make("fs_tex")
        darkPipe = make("fs_tex_dark")
        invertPipe = make("fs_tex_invert")
        solidPipe = make("fs_solid")
        linePipe = make("fs_solid", vertex: "vs_line")
        gradPipe = make("fs_gradient2", vertex: "vs_geo")
        shadowPipe = make("fs_shadow2", vertex: "vs_geo")
        discPipe = make("fs_disc2", vertex: "vs_geo")
    }

    // MARK: textures

    /// Decode a PNG/JPEG into a premultiplied RGBA8 Metal texture (cached).
    func texture(path: String) -> MTLTexture? {
        if let t = cache[path] { return t }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device!.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        cache[path] = t
        cacheOrder.append(path)
        if cacheOrder.count > 160 {            // bound memory: drop oldest
            for old in cacheOrder.prefix(40) { cache.removeValue(forKey: old) }
            cacheOrder.removeFirst(40)
        }
        return t
    }

    func dropTextures() { cache.removeAll(); cacheOrder.removeAll() }

    // MARK: geometry

    private var fitRect: CGRect {
        let m: CGFloat = 24
        let avail = bounds.insetBy(dx: m, dy: m)
        let ar = frameSize.width / frameSize.height
        var w = avail.width, h = w / ar
        if h > avail.height { h = avail.height; w = h * ar }
        return CGRect(x: avail.midX - w / 2, y: avail.midY - h / 2, width: w, height: h)
    }

    /// Scale that makes the slide fit the window (points per frame pixel).
    var fitScale: CGFloat { fitRect.width / frameSize.width }
    var effectiveScale: CGFloat { zoom ?? fitScale }

    /// Slide rectangle inside the view, in points.
    var slideRect: CGRect {
        guard let z = zoom else { return fitRect }
        let w = frameSize.width * z, h = frameSize.height * z
        return CGRect(x: bounds.midX - w / 2 + pan.x, y: bounds.midY - h / 2 + pan.y, width: w, height: h)
    }

    func zoomBy(_ factor: CGFloat) {
        zoom = min(8, max(0.1, effectiveScale * factor))
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoom != nil else { return }
        pan = CGPoint(x: pan.x + event.scrollingDeltaX, y: pan.y - event.scrollingDeltaY)
    }

    override func magnify(with event: NSEvent) { zoomBy(1 + event.magnification) }
    private var pxPerPoint: Double { Double(frameSize.width / slideRect.width) }

    private func framePoint(_ ev: NSEvent) -> CGPoint { framePoint(window: ev.locationInWindow) }

    /// Frame-pixel coordinates (y down) of a point given in window coordinates.
    func framePoint(window wp: CGPoint) -> CGPoint {
        let p = convert(wp, from: nil)
        let r = slideRect
        return CGPoint(x: (p.x - r.minX) * frameSize.width / r.width,
                       y: (r.maxY - p.y) * frameSize.height / r.height)     // flipped: y down
    }

    /// The selected object's box as shown right now (live drag included), in frame px.
    var selectedBox: Box? {
        guard let s = selection else { return nil }
        if let e = lineEnds(s) { return Box(x0: min(e[0], e[2]), y0: min(e[1], e[3]), x1: max(e[0], e[2]), y1: max(e[1], e[3])) }
        return currentBox(s)
    }

    // MARK: guides dragged in from the rulers

    /// Start dragging a brand-new guide (it begins off the slide, under the pointer on the ruler).
    func beginGuideDrag(vertical: Bool, pos: Double) {
        userGuides.append((vertical: vertical, pos: pos))
        dragGuide = userGuides.count - 1
    }
    /// Start dragging an existing guide by its ruler marker.
    func continueGuideDrag(index: Int) {
        guard userGuides.indices.contains(index) else { return }
        dragGuide = index; needsDisplay2()
    }
    func updateGuideDrag(pos: Double) {
        guard let i = dragGuide, userGuides.indices.contains(i) else { return }
        userGuides[i].pos = pos
    }
    /// Drop the dragged guide: gone if it ended off the slide, otherwise kept and saved.
    func endGuideDrag() {
        guard let i = dragGuide else { return }
        dragGuide = nil
        if userGuides.indices.contains(i) {
            let g = userGuides[i], limit = g.vertical ? Double(frameSize.width) : Double(frameSize.height)
            if g.pos < 0 || g.pos > limit { userGuides.remove(at: i) }          // dragged off the slide: gone
        }
        needsDisplay2()
        onGuidesChange?()
    }

    /// Current endpoints of a line object (live edit if any).
    func lineEnds(_ oid: Int) -> [Double]? {
        if let o = lineOverrides[oid] { return o }
        if let l = stop?.lines?[String(oid)], l.count >= 4 { return Array(l[0..<4]) }
        return nil
    }

    /// Box inflated so thin objects (lines) stay easy to hit and see.
    private func currentBox(_ oid: Int) -> Box? {
        guard var b = rawBox(oid) else { return nil }
        let minSide = 10 * pxPerPoint
        if b.w < minSide { b.x0 = b.cx - minSide / 2; b.x1 = b.x0 + minSide }
        if b.h < minSide { b.y0 = b.cy - minSide / 2; b.y1 = b.y0 + minSide }
        return b
    }

    private func rawBox(_ oid: Int) -> Box? {
        guard var b = stop?.box(of: oid) else { return nil }
        if let o = overrides[oid] {
            if let rep = o.replacement {
                let cx = b.cx + o.dx, cy = b.cy + o.dy
                return Box(x0: cx - rep.w * o.scale / 2, y0: cy - rep.h * o.scale / 2,
                           x1: cx + rep.w * o.scale / 2, y1: cy + rep.h * o.scale / 2)
            }
            let w = b.w * o.scale, h = b.h * o.scale
            b = Box(x0: b.cx + o.dx - w / 2, y0: b.cy + o.dy - h / 2, x1: b.cx + o.dx + w / 2, y1: b.cy + o.dy + h / 2)
        }
        return b
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable, let pass = currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        encodeFrame(enc, scale: window?.backingScaleFactor ?? 2)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    /// The whole view (backdrop, shadow, slide, selection) rendered offscreen; used by --selftest.
    func snapshotView() -> CGImage? {
        let scale: CGFloat = 2
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        guard let tex = device!.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        encodeFrame(enc, scale: scale)
        enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
        return ctx.makeImage()
    }

    private func encodeFrame(_ enc: MTLRenderCommandEncoder, scale: CGFloat) {
        let r = slideRect
        // 1. backdrop: soft gradient + the slide's drop shadow, in view-point coordinates
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(bounds.width * scale), height: Double(bounds.height * scale), znear: 0, zfar: 1))
        let view = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        func geo(_ pipe: MTLRenderPipelineState, _ u: Uniforms2) {
            var u = u
            enc.setRenderPipelineState(pipe)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms2>.size, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms2>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        geo(gradPipe, Uniforms2(rect: SIMD4(0.085, 0.088, 0.112, 0), color: SIMD4(0.205, 0.210, 0.255, 1), frame: view,
                                geo: SIMD4(0, 0, Float(bounds.width), Float(bounds.height))))
        let m: CGFloat = 46
        let sw = r.width + 2 * m, sh = r.height + 2 * m
        geo(shadowPipe, Uniforms2(rect: .zero, color: SIMD4(0, 0, 0, 0.62), frame: view,
                                  pad: SIMD2(Float(m / (sw / 2)), Float(m / (sh / 2))),
                                  geo: SIMD4(Float(r.minX - m), Float(bounds.height - r.maxY - m + 14), Float(sw), Float(sh))))
        // hairline around the slide so black slides still read as a card
        do {
            let t: CGFloat = 1.0
            let top = Float(bounds.height - r.maxY)
            for rect in [SIMD4<Float>(Float(r.minX - t), top - Float(t), Float(r.width + 2 * t), Float(t)),
                         SIMD4<Float>(Float(r.minX - t), top + Float(r.height), Float(r.width + 2 * t), Float(t)),
                         SIMD4<Float>(Float(r.minX - t), top, Float(t), Float(r.height)),
                         SIMD4<Float>(Float(r.maxX), top, Float(t), Float(r.height))] {
                var u = Uniforms(rect: rect, color: SIMD4(1, 1, 1, 0.16), frame: view)
                enc.setRenderPipelineState(solidPipe)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
        // 2. the slide itself
        enc.setViewport(MTLViewport(originX: Double(r.minX * scale), originY: Double((bounds.height - r.maxY) * scale),
                                    width: Double(r.width * scale), height: Double(r.height * scale), znear: 0, zfar: 1))
        encodeContent(enc)
    }

    /// Render the current content offscreen at the frame's native size (used by --selftest).
    func snapshot() -> CGImage? {
        let w = Int(frameSize.width), h = Int(frameSize.height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        guard let tex = device!.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        let enc = cb.makeRenderCommandEncoder(descriptor: pass)!
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: 0, zfar: 1))
        encodeContent(enc)
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { return nil }
        return ctx.makeImage()
    }

    private func encodeContent(_ enc: MTLRenderCommandEncoder) {
        let frame = SIMD2<Float>(Float(frameSize.width), Float(frameSize.height))

        let view = colorView, dark = view != .normal
        func drawTex(_ t: MTLTexture, _ x: Double, _ y: Double, _ w: Double, _ h: Double, alpha: Float = 1, map: Bool = true) {
            var u = Uniforms(rect: SIMD4(Float(x), Float(y), Float(w), Float(h)), color: SIMD4(1, 1, 1, alpha), frame: frame,
                             pad: SIMD2(DarkMode.lo, DarkMode.hi))
            enc.setRenderPipelineState(!dark || !map ? texPipe : view == .invert ? invertPipe : darkPipe)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
            enc.setFragmentTexture(t, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        func drawSolid(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: SIMD4<Float>) {
            var u = Uniforms(rect: SIMD4(Float(x), Float(y), Float(w), Float(h)), color: c, frame: frame)
            enc.setRenderPipelineState(solidPipe)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        if let stop = stop {
            // the exact frame has object edges blended into the background, so dark mode maps each layer on its own
            // (inverting is linear, but the same path keeps "leave images alone" working)
            if overrides.isEmpty && lineOverrides.isEmpty && !dark {
                if let t = texture(path: stop.png) { drawTex(t, 0, 0, Double(frameSize.width), Double(frameSize.height)) }
            } else {
                if let t = texture(path: stop.bg) { drawTex(t, 0, 0, Double(frameSize.width), Double(frameSize.height)) }
                for sp in stop.sprites {
                    if lineOverrides[sp.oid] != nil { continue }
                    let o = overrides[sp.oid]
                    let map = darkImages || sceneObjects[String(sp.oid)]?.kind != "image"
                    if let o = o, let rep = o.replacement, let b = stop.box(of: sp.oid) {
                        let cx = b.cx + o.dx, cy = b.cy + o.dy
                        drawTex(rep.tex, cx - rep.w * o.scale / 2, cy - rep.h * o.scale / 2, rep.w * o.scale, rep.h * o.scale)
                        continue
                    }
                    guard let t = texture(path: sp.file) else { continue }
                    if let o = o {
                        let b = stop.box(of: sp.oid) ?? Box(x0: sp.x, y0: sp.y, x1: sp.x + sp.w, y1: sp.y + sp.h)
                        let cx = b.cx, cy = b.cy
                        let nx = cx + o.dx + (sp.x - cx) * o.scale, ny = cy + o.dy + (sp.y - cy) * o.scale
                        drawTex(t, nx, ny, sp.w * o.scale, sp.h * o.scale, map: map)
                    } else {
                        drawTex(t, sp.x, sp.y, sp.w, sp.h, map: map)
                    }
                }
            }
            if let g = ghost { drawTex(g.tex, g.cx - g.w / 2, g.cy - g.h / 2, g.w, g.h) }
            for (oid, p) in lineOverrides {
                let stroke = max(2.0, stop.lines?[String(oid)]?[4] ?? 3)
                var c = NSColor(hex: sceneObjects[String(oid)]?.color ?? "#FFFFFF")
                if dark { c = DarkMode.map(c) }
                var u = Uniforms(rect: SIMD4(Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3])),
                                 color: SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1),
                                 frame: frame, pad: SIMD2(Float(stroke), 0))
                enc.setRenderPipelineState(linePipe)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            // overlays
            let th = max(1.0, 1.4 * pxPerPoint)
            func outline(_ b: Box, _ c: SIMD4<Float>, _ t: Double) {
                drawSolid(b.x0, b.y0, b.w, t, c); drawSolid(b.x0, b.y1 - t, b.w, t, c)
                drawSolid(b.x0, b.y0, t, b.h, c); drawSolid(b.x1 - t, b.y0, t, b.h, c)
            }
            func segment(_ p: [Double], _ c: SIMD4<Float>, _ stroke: Double) {
                var u = Uniforms(rect: SIMD4(Float(p[0]), Float(p[1]), Float(p[2]), Float(p[3])), color: c, frame: frame, pad: SIMD2(Float(stroke), 0))
                enc.setRenderPipelineState(linePipe)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
            let fw = Double(frameSize.width), fh = Double(frameSize.height)
            if showGrid, unitPx > 4 {
                let t = max(1.0, 0.8 * pxPerPoint)
                let axis = SIMD4<Float>(0.486, 0.361, 1, 0.55), minor = SIMD4<Float>(1, 1, 1, 0.13)
                var k = 0.0
                while fw / 2 + k * unitPx <= fw + 0.5 {
                    drawSolid(fw / 2 + k * unitPx - t / 2, 0, t, fh, k == 0 ? axis : minor)
                    if k > 0 { drawSolid(fw / 2 - k * unitPx - t / 2, 0, t, fh, minor) }
                    k += 1
                }
                k = 0
                while fh / 2 + k * unitPx <= fh + 0.5 {
                    drawSolid(0, fh / 2 + k * unitPx - t / 2, fw, t, k == 0 ? axis : minor)
                    if k > 0 { drawSolid(0, fh / 2 - k * unitPx - t / 2, fw, t, minor) }
                    k += 1
                }
            }
            for (i, g) in userGuides.enumerated() {
                let c = SIMD4<Float>(0.25, 0.85, 1.0, i == dragGuide ? 1.0 : 0.8)
                let t = i == dragGuide ? th * 1.5 : th
                if g.vertical { drawSolid(g.pos - t / 2, 0, t, fh, c) } else { drawSolid(0, g.pos - t / 2, fw, t, c) }
            }
            for g in guides {
                let c = SIMD4<Float>(1.0, 0.424, 0.047, 0.95)
                if g.vertical { drawSolid(g.pos - th / 2, 0, th, fh, c) } else { drawSolid(0, g.pos - th / 2, fw, th, c) }
            }
            if drawTool == "pen" || !pendingStrokes.isEmpty {
                var pc = penColor.usingColorSpace(.sRGB) ?? penColor
                if dark { pc = DarkMode.map(pc) }
                let c = SIMD4<Float>(Float(pc.redComponent), Float(pc.greenComponent), Float(pc.blueComponent), 1)
                let stroke = max(1.5, penWidth * 0.01 * unitPx)
                for pts in pendingStrokes + (penPoints.isEmpty ? [] : [penPoints]) {
                    for i in 1..<max(1, pts.count) {
                        segment([Double(pts[i - 1].x), Double(pts[i - 1].y), Double(pts[i].x), Double(pts[i].y)], c, stroke)
                    }
                    for p in pts {           // round the joints
                        var u = Uniforms2(rect: c, color: c, frame: frame, pad: SIMD2(0, 0),
                                          geo: SIMD4(Float(Double(p.x) - stroke / 2), Float(Double(p.y) - stroke / 2), Float(stroke), Float(stroke)))
                        enc.setRenderPipelineState(discPipe)
                        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms2>.size, index: 0)
                        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms2>.size, index: 0)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    }
                }
            }
            if let d = drawBand, let tool = drawTool, tool != "pen" {
                let c = SIMD4<Float>(0.486, 0.361, 1, 1)
                if ["line", "arrow", "darrow"].contains(tool) {
                    segment([d.0, d.1, d.2, d.3], c, max(2.0, 3 * pxPerPoint))
                } else {
                    outline(Box(x0: min(d.0, d.2), y0: min(d.1, d.3), x1: max(d.0, d.2), y1: max(d.1, d.3)), c, th * 1.4)
                }
            }
            if let g = ghost {
                outline(Box(x0: g.cx - g.w / 2, y0: g.cy - g.h / 2, x1: g.cx + g.w / 2, y1: g.cy + g.h / 2), SIMD4(0.486, 0.361, 1, 1), th * 1.6)
            }
            if showObjects {
                for v in stop.visible {
                    let oid = Int(v[0])
                    if oid == selection { continue }
                    if let b = currentBox(oid) { outline(b, SIMD4(0.486, 0.361, 1, oid == hover ? 0.95 : 0.35), oid == hover ? th * 1.4 : th * 0.7) }
                }
            } else if let h = hover, let b = currentBox(h) {
                outline(b, SIMD4(0.486, 0.361, 1, 0.95), th * 1.4)
            }
            if let s = selection, let b = currentBox(s) {
                outline(b, SIMD4(0.486, 0.361, 1, 1), th * 1.6)
                let hs = 6.5 * pxPerPoint
                let corners: [(Double, Double)]
                if let p = lineEnds(s) { corners = [(p[0], p[1]), (p[2], p[3])] }
                else { corners = [(b.x0, b.y0), (b.x1, b.y0), (b.x0, b.y1), (b.x1, b.y1)] }
                for (x, y) in corners {
                    var u = Uniforms2(rect: accentRGB, color: SIMD4(1, 1, 1, 1), frame: frame, pad: SIMD2(0.28, 0),
                                      geo: SIMD4(Float(x - hs), Float(y - hs), Float(2 * hs), Float(2 * hs)))
                    enc.setRenderPipelineState(discPipe)
                    enc.setVertexBytes(&u, length: MemoryLayout<Uniforms2>.size, index: 0)
                    enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms2>.size, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                }
            }
        }
    }

    // MARK: input

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseExited(with event: NSEvent) { onCursorMove?(nil) }

    private func hit(_ p: CGPoint) -> Int? {
        guard let stop = stop else { return nil }
        var best: (Int, Double)?
        for v in stop.visible {
            let oid = Int(v[0])
            guard let b = currentBox(oid), b.contains(Double(p.x), Double(p.y)) else { continue }
            if best == nil || b.area < best!.1 { best = (oid, b.area) }
        }
        return best?.0
    }

    private func handleAt(_ p: CGPoint, _ b: Box) -> Handle? {
        let tol = 9 * pxPerPoint
        let corners: [(Handle, Double, Double)] = [(.nw, b.x0, b.y0), (.ne, b.x1, b.y0), (.sw, b.x0, b.y1), (.se, b.x1, b.y1)]
        for (h, x, y) in corners where abs(Double(p.x) - x) <= tol && abs(Double(p.y) - y) <= tol { return h }
        return nil
    }

    /// Index of the user guide under a point, if any.
    private func guideAt(_ p: CGPoint) -> Int? {
        let tol = 5 * pxPerPoint
        for (i, g) in userGuides.enumerated() where abs((g.vertical ? Double(p.x) : Double(p.y)) - g.pos) <= tol { return i }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        onCursorMove?(framePoint(event))
        if drawTool != nil { NSCursor.crosshair.set(); return }
        if let i = guideAt(framePoint(event)) { (userGuides[i].vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set(); return }
        let h = hit(framePoint(event))
        if h != hover { hover = h; needsDisplay2() }
        if let s = selection, let e = lineEnds(s), (0..<2).contains(where: { hypot(Double(framePoint(event).x) - e[$0 * 2], Double(framePoint(event).y) - e[$0 * 2 + 1]) <= 10 * pxPerPoint }) { NSCursor.crosshair.set() }
        else if let s = selection, lineEnds(s) == nil, let b = currentBox(s), handleAt(framePoint(event), b) != nil { NSCursor.crosshair.set() }
        else if h != nil { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = framePoint(event)
        if drawTool == "pen" {
            penPoints = [p]
            return
        }
        if drawTool != nil {
            drawStart = p
            drawBand = (Double(p.x), Double(p.y), Double(p.x), Double(p.y))
            return
        }
        if event.clickCount == 2, let oid = hit(p) { onSelect?(oid); onEdit?(oid); return }
        if let i = guideAt(p) { dragGuide = i; needsDisplay2(); return }
        if let s = selection, let e = lineEnds(s) {
            let tol = 10 * pxPerPoint
            for i in 0..<2 where hypot(Double(p.x) - e[i * 2], Double(p.y) - e[i * 2 + 1]) <= tol {
                dragEnd = i; dragStart = p; dragOID = s; lineOverrides[s] = e
                return
            }
        }
        if let s = selection, lineEnds(s) == nil, let b = currentBox(s), let h = handleAt(p, b) {
            dragStart = p; dragOID = s; dragHandle = h; dragBox = b
            return
        }
        let oid = hit(p)
        if oid != selection { selection = oid; onSelect?(oid) }
        if let oid = oid {
            dragStart = p; dragOID = oid; dragHandle = nil; dragBox = currentBox(oid)
            dragBase = overrides[oid].map { ($0.dx, $0.dy) } ?? (0, 0)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        onCursorMove?(framePoint(event))
        if drawTool == "pen", let last = penPoints.last {
            let p = framePoint(event)
            if hypot(Double(p.x - last.x), Double(p.y - last.y)) >= 1.5 { penPoints.append(p) }
            return
        }
        if let s = drawStart, let tool = drawTool {
            let p = framePoint(event)
            var x = Double(p.x), y = Double(p.y)
            if event.modifierFlags.contains(.shift) {
                if ["line", "arrow", "darrow"].contains(tool) {        // snap the angle to 15° steps
                    let ang = atan2(y - Double(s.y), x - Double(s.x)), len = hypot(x - Double(s.x), y - Double(s.y))
                    let snapped = (ang / (.pi / 12)).rounded() * (.pi / 12)
                    x = Double(s.x) + len * cos(snapped); y = Double(s.y) + len * sin(snapped)
                } else {                                               // square / circle
                    let side = max(abs(x - Double(s.x)), abs(y - Double(s.y)))
                    x = Double(s.x) + (x >= Double(s.x) ? side : -side); y = Double(s.y) + (y >= Double(s.y) ? side : -side)
                }
            }
            drawBand = (Double(s.x), Double(s.y), x, y)
            return
        }
        if let i = dragGuide, userGuides.indices.contains(i) {
            let p = framePoint(event)
            userGuides[i].pos = userGuides[i].vertical ? Double(p.x) : Double(p.y)
            return
        }
        if let end = dragEnd, let oid = dragOID, var e = lineOverrides[oid] {
            let p = framePoint(event)
            var x = Double(p.x), y = Double(p.y)
            if event.modifierFlags.contains(.shift) {        // snap the angle to 15° steps
                let ox = e[end == 0 ? 2 : 0], oy = e[end == 0 ? 3 : 1]
                let ang = atan2(y - oy, x - ox), len = hypot(x - ox, y - oy)
                let snapped = (ang / (.pi / 12)).rounded() * (.pi / 12)
                x = ox + len * cos(snapped); y = oy + len * sin(snapped)
            }
            e[end * 2] = x; e[end * 2 + 1] = y
            lineOverrides[oid] = e
            return
        }
        guard let s = dragStart, let oid = dragOID, let b = dragBox else { return }
        let p = framePoint(event)
        var o = overrides[oid] ?? Override()
        if let h = dragHandle {
            _ = h
            let d0 = hypot(b.w / 2, b.h / 2)
            let d = hypot(Double(p.x) - b.cx, Double(p.y) - b.cy)
            o.scale = max(0.05, d / max(d0, 1))
        } else {
            var dx = Double(p.x - s.x), dy = Double(p.y - s.y)
            if event.modifierFlags.contains(.shift) { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            if abs(dx) + abs(dy) < 2 && overrides[oid] == nil { return }
            if snapEnabled && !event.modifierFlags.contains(.option) {
                (dx, dy, guides) = snapDelta(oid, b, dx, dy)
            } else if !guides.isEmpty { guides = [] }
            o.dx = dragBase.dx + dx; o.dy = dragBase.dy + dy
        }
        overrides[oid] = o
    }

    /// Pull a dragged box onto nearby alignment targets: edges and centres of the other objects, the slide's
    /// edges and centre, and the grid when shown. Returns the adjusted translation and the guides to draw.
    private func snapDelta(_ oid: Int, _ b: Box, _ dx: Double, _ dy: Double) -> (Double, Double, [(vertical: Bool, pos: Double)]) {
        guard let stop = stop else { return (dx, dy, []) }
        let fw = Double(frameSize.width), fh = Double(frameSize.height)
        var xs: [Double] = [0, fw / 2, fw], ys: [Double] = [0, fh / 2, fh]
        for v in stop.visible where Int(v[0]) != oid {
            guard let ob = rawBox(Int(v[0])) else { continue }
            xs += [ob.x0, ob.cx, ob.x1]; ys += [ob.y0, ob.cy, ob.y1]
        }
        for g in userGuides { if g.vertical { xs.append(g.pos) } else { ys.append(g.pos) } }
        if showGrid, unitPx > 4 {
            var k = 1.0
            while fw / 2 + k * unitPx <= fw + 0.5 { xs += [fw / 2 + k * unitPx, fw / 2 - k * unitPx]; k += 1 }
            k = 1
            while fh / 2 + k * unitPx <= fh + 0.5 { ys += [fh / 2 + k * unitPx, fh / 2 - k * unitPx]; k += 1 }
        }
        let tol = 6 * pxPerPoint
        let moved = Box(x0: b.x0 + dx, y0: b.y0 + dy, x1: b.x1 + dx, y1: b.y1 + dy)
        func best(_ cands: [Double], _ targets: [Double]) -> (Double, Double)? {
            var r: (Double, Double)?
            for c in cands { for t in targets { let d = t - c; if abs(d) <= tol && (r == nil || abs(d) < abs(r!.0)) { r = (d, t) } } }
            return r
        }
        var ndx = dx, ndy = dy
        var g: [(vertical: Bool, pos: Double)] = []
        if let bx = best([moved.x0, moved.cx, moved.x1], xs) { ndx += bx.0; g.append((true, bx.1)) }
        if let by = best([moved.y0, moved.cy, moved.y1], ys) { ndy += by.0; g.append((false, by.1)) }
        return (ndx, ndy, g)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragOID = nil; dragHandle = nil; dragBox = nil; dragEnd = nil; guides = [] }
        if dragGuide != nil { endGuideDrag(); return }
        if drawTool == "pen" {
            let pts = CanvasView.simplify(penPoints, tolerance: 1.2)
            penPoints = []
            var length = 0.0
            for i in 1..<max(1, pts.count) { length += hypot(Double(pts[i].x - pts[i - 1].x), Double(pts[i].y - pts[i - 1].y)) }
            if pts.count >= 2, length >= 4 * pxPerPoint {
                pendingStrokes.append(pts)
                onPen?(pts)
            }
            return                               // the pen stays active for the next stroke (esc ends it)
        }
        if drawStart != nil, let tool = drawTool, let d = drawBand {
            drawStart = nil; drawBand = nil
            if hypot(d.2 - d.0, d.3 - d.1) >= 6 * pxPerPoint { onDraw?(tool, d.0, d.1, d.2, d.3) }
            drawTool = nil
            return
        }
        if dragEnd != nil, let oid = dragOID, let e = lineOverrides[oid] {
            let o = stop?.lines?[String(oid)] ?? e
            if hypot(e[0] - o[0], e[1] - o[1]) + hypot(e[2] - o[2], e[3] - o[3]) > 1 { onEndpoints?(oid, e) } else { lineOverrides[oid] = nil }
            return
        }
        guard let oid = dragOID, var o = overrides[oid] else { return }
        let idle = o.dx == 0 && o.dy == 0 && o.replacement == nil      // nothing else of this object is still previewed
        if dragHandle != nil {
            if abs(o.scale - 1) > 0.002 { onResize?(oid, o.scale) } else if idle { overrides[oid] = nil }
        } else {
            let dx = o.dx - dragBase.dx, dy = o.dy - dragBase.dy      // this drag alone; earlier moves are already on their way
            if abs(dx) + abs(dy) >= 1 { onMove?(oid, dx, dy) }
            else if dragBase.dx == 0 && dragBase.dy == 0 && o.scale == 1 && o.replacement == nil { overrides[oid] = nil }
            else { o.dx = dragBase.dx; o.dy = dragBase.dy; overrides[oid] = o }
        }
    }

    /// Ramer-Douglas-Peucker: the fewest points that keep the stroke within `tolerance` frame pixels.
    static func simplify(_ pts: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        let a = pts[0], b = pts[pts.count - 1]
        var worst = 0.0, at = 0
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y), len = hypot(dx, dy)
        for i in 1..<(pts.count - 1) {
            let p = pts[i]
            let d = len < 1e-9 ? hypot(Double(p.x - a.x), Double(p.y - a.y))
                : abs(dy * Double(p.x - a.x) - dx * Double(p.y - a.y)) / len
            if d > worst { worst = d; at = i }
        }
        if worst <= tolerance { return [a, b] }
        let left = simplify(Array(pts[0...at]), tolerance: tolerance), right = simplify(Array(pts[at...]), tolerance: tolerance)
        return left.dropLast() + right
    }

    override func keyDown(with event: NSEvent) {
        let n: Double = event.modifierFlags.contains(.shift) ? 10 : 1
        if event.keyCode == 53, drawTool != nil { drawTool = nil; drawStart = nil; drawBand = nil; penPoints = []; return }
        guard let s = selection else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 123: onNudge?(s, -n, 0)
        case 124: onNudge?(s, n, 0)
        case 126: onNudge?(s, 0, -n)
        case 125: onNudge?(s, 0, n)
        case 36: onEdit?(s)
        case 51, 117: onDelete?(s)
        case 53: selection = nil; onSelect?(nil)
        default: super.keyDown(with: event)
        }
    }
}
