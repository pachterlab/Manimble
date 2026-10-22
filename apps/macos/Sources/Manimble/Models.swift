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
    var cells: [String: [[Double]]]? // table oid -> [row, col, cell x0, y0, x1, y1, entry ink x0, y0, x1, y1] per data cell
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
}

struct EditResult: Decodable {
    var ok: Bool?
    var message: String?
    var error: String?
    var siblings: Int?
    var changed: ChangedLines?
    var pageNumber: Bool?            // the edit changed a slide-number line
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
    var error: String?
    var notes: String?
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
}
