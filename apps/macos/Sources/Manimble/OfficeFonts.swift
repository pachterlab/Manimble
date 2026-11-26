import AppKit
import CoreText

/// Microsoft Office's fonts (Aptos, Office's default since 2023, Aptos Display, Calibri, Cambria, ...) for this
/// process, so they are in the font menus and drawn in their own faces there. Office doesn't install them
/// system-wide: it ships them inside each app (DFonts) and downloads "cloud fonts" (Aptos Display, Aptos Serif, ...)
/// into its group container, a folder per family. The engine registers the same files for drawing slides
/// (engine/manimble/officefonts.py); nothing is copied or installed.
enum OfficeFonts {
    static func files() -> [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let apps = try? fm.contentsOfDirectory(atPath: "/Applications") {
            for a in apps.sorted() where a.hasPrefix("Microsoft ") && a.hasSuffix(".app") {
                dirs.append(URL(fileURLWithPath: "/Applications/\(a)/Contents/Resources/DFonts"))
            }
        }
        let cloud = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/UBF8T346G9.Office/FontCache/4/CloudFonts")
        if let families = try? fm.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil) {
            dirs += families.sorted { $0.path < $1.path }
        }
        var seen = Set<String>(), out: [URL] = []
        for d in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
            let isCloud = d.deletingLastPathComponent().lastPathComponent == "CloudFonts"
            for n in names.sorted() where ["ttf", "otf", "ttc"].contains((n as NSString).pathExtension.lowercased()) {
                // every Office app ships the same fonts; a cloud font's file names are numbers, unique per family
                let key = (isCloud ? d.lastPathComponent + "/" + n : n).lowercased()
                if seen.insert(key).inserted { out.append(d.appendingPathComponent(n)) }
            }
        }
        return out
    }

    /// Register them for this process, synchronously, so menus built next list them (a file that fails, or is
    /// registered already, is skipped).
    static func register() {
        for u in files() {
            CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
        }
    }
}
