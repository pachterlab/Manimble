import Foundation
import CryptoKit

/// A private working copy of a deck. Edits go to the copy; Save writes them back to the original.
///
/// The copy mirrors the deck's surroundings with symlinks (assets, media, data …) so the
/// deck's relative paths keep working, while the deck folder itself holds real copies of its files.
final class Workspace {
    let original: URL
    let work: URL            // the copied deck folder (what the engine opens)
    let root: URL            // workspace root, deleted on discard
    let projectName: String
    let deckRelativePath: String
    private var baseline: [String: Data] = [:]     // original contents when the copy was made

    static var base: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Manimble")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func cacheDir(for deck: URL) -> String {
        let h = SHA256.hash(data: Data(deck.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let u = base.appendingPathComponent("cache").appendingPathComponent(deck.lastPathComponent + "-" + h)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.path
    }

    init(deck: String) throws {
        let fm = FileManager.default
        original = URL(fileURLWithPath: deck).standardizedFileURL.resolvingSymlinksInPath()
        let x = original.deletingLastPathComponent()
        let g = x.deletingLastPathComponent()
        projectName = x.lastPathComponent + "-" + original.lastPathComponent
        let h = SHA256.hash(data: Data(original.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        // Give each open its own root. Reopening the same deck creates the new
        // workspace before the controller discards the old one; a deterministic
        // path lets that cleanup accidentally delete the new workspace.
        root = Workspace.base.appendingPathComponent("work").appendingPathComponent(original.lastPathComponent + "-" + h + "-" + UUID().uuidString)
        try? fm.removeItem(at: root)
        let wx = root.appendingPathComponent(x.lastPathComponent)
        work = wx.appendingPathComponent(original.lastPathComponent)
        deckRelativePath = x.lastPathComponent + "/" + original.lastPathComponent
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        // siblings of the deck's parent and of the deck itself become symlinks
        for e in try fm.contentsOfDirectory(atPath: g.path) where e != x.lastPathComponent && !e.hasPrefix(".") {
            try? fm.createSymbolicLink(at: root.appendingPathComponent(e), withDestinationURL: g.appendingPathComponent(e))
        }
        for e in try fm.contentsOfDirectory(atPath: x.path) where e != original.lastPathComponent && !e.hasPrefix(".") {
            try? fm.createSymbolicLink(at: wx.appendingPathComponent(e), withDestinationURL: x.appendingPathComponent(e))
        }
        for e in try fm.contentsOfDirectory(atPath: original.path) where !e.hasPrefix(".") && e != "__pycache__" {
            let src = original.appendingPathComponent(e)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: src.path, isDirectory: &isDir)
            if isDir.boolValue && e == "slides" {
                // manim-slides output: copy it, so building from edited code never touches the original's builds
                try? fm.copyItem(at: src, to: work.appendingPathComponent(e))
            } else if isDir.boolValue {
                try? fm.createSymbolicLink(at: work.appendingPathComponent(e), withDestinationURL: src)
            } else {
                try fm.copyItem(at: src, to: work.appendingPathComponent(e))
                baseline[e] = try? Data(contentsOf: src)
            }
        }
    }

    private func regularFiles(_ dir: URL) -> [String] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { e in
            if e.hasPrefix(".") { return false }
            var isDir: ObjCBool = false
            let u = dir.appendingPathComponent(e)
            if (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return false }
            return fm.fileExists(atPath: u.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    /// Files whose working copy differs from the baseline.
    var changedFiles: [String] {
        regularFiles(work).filter { e in (try? Data(contentsOf: work.appendingPathComponent(e))) != baseline[e] }
    }

    var isModified: Bool { !changedFiles.isEmpty }

    /// Files of the original that someone else changed since the copy was made.
    var conflictFiles: [String] {
        changedFiles.filter { e in
            let cur = try? Data(contentsOf: original.appendingPathComponent(e))
            return cur != baseline[e]
        }
    }

    func save() throws {
        for e in changedFiles {
            let data = try Data(contentsOf: work.appendingPathComponent(e))
            try data.write(to: original.appendingPathComponent(e), options: .atomic)
            baseline[e] = data
        }
    }

    func revert() throws {
        for e in changedFiles {
            if let d = baseline[e] { try d.write(to: work.appendingPathComponent(e), options: .atomic) }
        }
    }

    func discard() { try? FileManager.default.removeItem(at: root) }
}
