// Import the black-and-white BioCartoon logo from the biocartoon repository (brand/biocartoon-mono.svg):
// keeps a copy as assets/biocartoon-mono.svg and renders assets/biocartoon-mono.png, the toolbar's template image.
//   swift tools/import_biocartoon_logo.swift [path/to/biocartoon]   (default: $BIOCARTOON_REPO, else ~/code/biocartoon)
import AppKit

let env = ProcessInfo.processInfo.environment
let repo = CommandLine.arguments.dropFirst().first ?? env["BIOCARTOON_REPO"] ?? NSString(string: "~/code/biocartoon").expandingTildeInPath
let svg = URL(fileURLWithPath: repo).appendingPathComponent("brand/biocartoon-mono.svg")
let assets = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("assets")
guard let image = NSImage(contentsOf: svg) else { FileHandle.standardError.write("cannot read \(svg.path)\n".data(using: .utf8)!); exit(1) }

let side = 256
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
NSGraphicsContext.restoreGraphicsState()

try? FileManager.default.removeItem(at: assets.appendingPathComponent("biocartoon-mono.svg"))
try FileManager.default.copyItem(at: svg, to: assets.appendingPathComponent("biocartoon-mono.svg"))
try rep.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("biocartoon-mono.png"))
print("imported \(svg.path)")
