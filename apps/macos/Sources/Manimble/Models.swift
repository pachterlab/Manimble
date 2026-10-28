import Foundation

struct SceneSummary: Decodable {
    var name: String
    var file: String
    var line: Int
    var status: String
    var thumb: String?
    var stops: Int?
    var error: String?
    var hidden: Bool?                // in the show's order but left out of slideshows and exports
}

struct StateInfo: Decodable {
    var deck: String
    var path: String
    var scenes: [SceneSummary]
    var unusedScenes: [SceneSummary]
    var canUndo: Bool
    var canRedo: Bool
    var undoLabel: String
    var hasPresent: Bool
}

struct SpriteInfo: Decodable {
    var oid: Int
    var file: String
    var x: Double, y: Double, w: Double, h: Double
    var z: Int
}

struct StopInfo: Decodable {
    var png: String
    var bg: String
    var visible: [[Double]]          // [oid, x0, y0, x1, y1] in frame pixels
    var sprites: [SpriteInfo]
    var lines: [String: [Double]]?   // oid -> [sx, sy, ex, ey, strokePx]
    var xforms: [String: [Double]]?  // oid -> [a, b, c, d, tx, ty]: an attached line's sprite mapped to follow an optimistic move
    var cells: [String: [[Double]]]? // table oid -> [row, col, cell x0, y0, x1, y1, entry ink x0, y0, x1, y1] per data cell
    var glyphs: [String: [[Double]]]? // text oid -> [x0, y0, x1, y1] of each non-space character of its value
}

struct SharedInfo: Decodable {
    var name: String
    var uses: Int
    var rel: String
}

struct FormatInfo: Decodable {
    var underline: Bool?
    var strike: Bool?
    var highlight: String?           // "#RRGGBB", "on" (a named colour) or nil
    var align: String?               // left | center | right
    var columns: Int?
    var lineSpacing: Double?         // manim line_spacing (0.3 = default)
    var valign: String?              // top | mid: where text sits in its frame
    var link: String?                // hyperlink opened when the text is clicked in a show
}

struct ObjInfo: Decodable {
    var kind: String                 // text | tex | image | line | shape | table
    var value: String
    var fontSize: Double?
    var color: String?
    var font: String?
    var weight: String?
    var slant: String?
    var siblings: Int
    var loc: String
    var textOk: Bool?
    var textLoc: String?
    var textNote: String?
    var shared: SharedInfo?
    var image: String?
    var imagePath: String?           // absolute path of the picture file (images)
    var shape: String?
    var rotation: Double?            // degrees, from the object's own rotate() calls
    var dims: [Double]?              // manim width/height in frame pixels
    var format: FormatInfo?
    /// A text frame (x0, y0, x1, y1 in frame px): the box keeps this size whatever is typed, the text sits in it
    /// by its alignment. Text typed into a layout placeholder gets one.
    var frame: [Double]?
    /// The group the object belongs to (a `Group(...)  # manimble group` line): its members select together.
    var group: Int?
    /// A line redrawn from the objects its ends are attached to (`always_redraw`): those objects' oids.
    var follows: [Int]?
    var frameBox: Box? { frame.flatMap { $0.count == 4 ? Box(x0: $0[0], y0: $0[1], x1: $0[2], y1: $0[3]) : nil } }
}

struct ChangedLines: Decodable {
    var file: String?
    var ranges: [[Int]]?
}

struct SourceInfo: Decodable {
    var file: String
    var start: Int
    var end: Int
    var text: String
    var changed: ChangedLines?
}

struct SceneData: Decodable {
    var name: String
    var status: String
    var size: [Double]?
    var frame: [Double]?
    var stops: [StopInfo]?
    var objects: [String: ObjInfo]?
    var source: SourceInfo?
    var error: String?
    var notes: String?               // speaker notes (self.next_slide(notes=...) at the top of construct)
    var buildNotes: [String]?        // each build's own notes (Presenter View shows them under the slide's)
    var altText: String?             // what the slide shows, for people who cannot see it (`alt_text = "..."` on its class)
    var placeholders: [Placeholder]? // empty layout boxes ("Click to add title"), drawn by the editor only
    var font: String?                // the deck's FONT constant
    var textColor: String?           // the deck theme's TEXT_COLOR (manimble/themes), new text's colour
    var theme: String?               // the deck's THEME name
    var optimistic: Bool?            // a move/resize shown before its verifying render: the exact frames are stale
}

/// An empty text box of a new slide's layout (a `# manimble placeholder` comment): nothing renders until it is typed into.
struct Placeholder: Decodable {
    var line: Int                    // its line in the slide's file
    var role: String                 // "title", "subtitle" or "body"
    var prompt: String
    var size: Int                    // font_size of the text typed into it
    var box: [Double]                // x0, y0, x1, y1 in frame px

    var rect: Box { Box(x0: box[0], y0: box[1], x1: box[2], y1: box[3]) }
}

struct EditResult: Decodable {
    var ok: Bool?
    var message: String?
    var error: String?
    var siblings: Int?
    var changed: ChangedLines?
    var pageNumber: Bool?            // the edit changed a slide-number line
    var oneBuild: Bool?              // a move that applies to the current build only
}

struct SourceEditResult: Decodable {
    var ok: Bool
    var message: String?
    var error: String?
    var changed: ChangedLines?
}

struct SpriteResult: Decodable {
    var file: String?
    var path: String?
    var w: Double?
    var h: Double?
    var cx: Double?
    var cy: Double?
    var error: String?
}

struct UndoMark: Decodable { var mark: Int }

struct UndoResult: Decodable {
    var ok: Bool?
    var label: String?
    var error: String?
}

/// Axis-aligned box in frame pixels.
struct Box {
    var x0: Double, y0: Double, x1: Double, y1: Double
    var w: Double { x1 - x0 }
    var h: Double { y1 - y0 }
    var cx: Double { (x0 + x1) / 2 }
    var cy: Double { (y0 + y1) / 2 }
    var area: Double { w * h }
    func contains(_ x: Double, _ y: Double) -> Bool { x >= x0 && x <= x1 && y >= y0 && y <= y1 }
}

extension StopInfo {
    func box(of oid: Int) -> Box? {
        for v in visible where Int(v[0]) == oid { return Box(x0: v[1], y0: v[2], x1: v[3], y1: v[4]) }
        return nil
    }
    /// The ink of non-space characters `from..<to` of a text object, one box per line it spans; nil when the render
    /// has no character boxes for it.
    func glyphBoxes(_ oid: Int, _ from: Int, _ to: Int) -> [Box]? {
        guard let g = glyphs?[String(oid)], from >= 0, to <= g.count, from < to else { return nil }
        var out: [Box] = []
        for v in g[from..<to] where v.count == 4 {
            let b = Box(x0: v[0], y0: v[1], x1: v[2], y1: v[3])
            // a character on the line of the box before it (its middle within that box's height) joins that box
            if var last = out.last, b.x0 >= last.x0 - 1, b.cy > last.y0, b.cy < last.y1 {
                last.x1 = max(last.x1, b.x1); last.y0 = min(last.y0, b.y0); last.y1 = max(last.y1, b.y1)
                out[out.count - 1] = last
            } else { out.append(b) }
        }
        return out.isEmpty ? nil : out
    }
    /// The data cell of a table under a frame-pixel point: (row, col, cell area, entry ink).
    func tableCell(_ oid: Int, at p: CGPoint) -> (row: Int, col: Int, cell: Box, ink: Box)? {
        tableCells(oid).first { $0.cell.contains(Double(p.x), Double(p.y)) }
    }
    func tableCells(_ oid: Int) -> [(row: Int, col: Int, cell: Box, ink: Box)] {
        (cells?[String(oid)] ?? []).filter { $0.count >= 10 }.map {
            (Int($0[0]), Int($0[1]), Box(x0: $0[2], y0: $0[3], x1: $0[4], y1: $0[5]), Box(x0: $0[6], y0: $0[7], x1: $0[8], y1: $0[9]))
        }
    }
}

struct InsertResult: Decodable {
    var ok: Bool?
    var message: String?
    var error: String?
    var line: Int?
    var file: String?
}

struct PagesResult: Decodable {
    var pages: [String]?
    var error: String?
}

struct DependencyFailure: Decodable {
    var scene: String
    var error: String
}

struct DependencyReportResult: Decodable {
    var dependencies: [String]
    var scannedScenes: Int
    var totalScenes: Int
    var failures: [DependencyFailure]
}

struct DeckSlide: Decodable {
    var scene: String
    var pages: [String]
    var pending: Bool?          // still rendering in the background: `pages` is empty, `builds` its expected count
    var builds: Int?
    var error: String?
    var notes: String?
    var buildNotes: [String]?
    var links: [[PresentDeck.LinkRegion]]?   // each build's clickable regions
}

struct PageNumberInfo: Decodable {
    var on: Bool
    var pos: String                  // DR | DOWN | DL
    var start: Int
    var skip: Bool
    var total: Bool
    var size: Int
    var sub: Bool?                   // also count a slide's builds: "29 / 47 · 1/3"
}

struct NotesResult: Decodable {
    var ok: Bool?
    var text: String?
    var message: String?
    var error: String?
    var changed: ChangedLines?
}

struct DeckPages: Decodable {
    var slides: [DeckSlide]
}

struct SlideResult: Decodable {
    var ok: Bool?
    var message: String?
    var error: String?
    var select: String?
    var stop: Int?                   // delete_build: the build to show afterwards
    var changed: ChangedLines?
}
