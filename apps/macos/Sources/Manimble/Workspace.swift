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
    private var baseline: [String: Data] = [:]     // original contents when the copy was made, by path in the deck folder
    private(set) var ownFiles: Set<String> = []          // written here for coding agents; never saved to the original

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
            } else if isDir.boolValue && !Workspace.generated.contains(e) && Workspace.holdsPython(src) {
                // a package of the deck's code: a real copy, saved, reverted and undone like the deck's own files
                try fm.copyItem(at: src, to: work.appendingPathComponent(e))
            } else if isDir.boolValue {
                try? fm.createSymbolicLink(at: work.appendingPathComponent(e), withDestinationURL: src)
            } else {
                try fm.copyItem(at: src, to: work.appendingPathComponent(e))
            }
        }
        for rel in deckFiles() { baseline[rel] = try? Data(contentsOf: original.appendingPathComponent(rel)) }
        // what a coding agent started in the terminal reads first (Claude Code, Codex, Gemini CLI); a deck's own wins
        for e in AgentInstructions.files where !fm.fileExists(atPath: work.appendingPathComponent(e).path) {
            if (try? Data(AgentInstructions.text.utf8).write(to: work.appendingPathComponent(e))) != nil { ownFiles.insert(e) }
        }
    }

    /// Folders of the deck that hold what Manimble or Manim Slides make, never saved: output, caches.
    private static let generated: Set<String> = ["slides", "media", "__pycache__", ".manimble"]

    /// Whether a folder of the deck holds Python code (a package its slides import).
    private static func holdsPython(_ dir: URL) -> Bool {
        guard let it = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        for case let u as URL in it {
            if generated.contains(u.lastPathComponent) { it.skipDescendants(); continue }
            if u.pathExtension == "py" { return true }
        }
        return false
    }

    /// Every file Save writes back, by path in the deck folder: files in it and in its real folders (not the links
    /// to the original's other folders, nor generated output), but not the agent instructions Manimble wrote.
    private func deckFiles() -> [String] {
        let fm = FileManager.default
        guard let it = fm.enumerator(at: work, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        let base = work.standardizedFileURL.path + "/"
        var out: [String] = []
        for case let u as URL in it {
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count))
            let v = try? u.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if v?.isSymbolicLink == true { continue }
            if Workspace.generated.contains(u.lastPathComponent) { it.skipDescendants(); continue }
            if v?.isRegularFile == true, !ownFiles.contains(rel), !rel.hasSuffix(".manimble.tmp") { out.append(rel) }
        }
        return out.sorted()
    }

    /// Files whose working copy differs from the baseline: changed, new, or deleted.
    var changedFiles: [String] {
        let present = deckFiles()
        return present.filter(differs) + Set(baseline.keys).subtracting(present).sorted()
    }

    /// The outcome of the last comparison of each file with its baseline, and the size and time it had then: the
    /// window asks every two seconds, and a deck folder can hold large pictures and videos.
    private var compared: [String: (size: Int, modified: Date, same: Bool)] = [:]

    private func differs(_ rel: String) -> Bool {
        let u = work.appendingPathComponent(rel)
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path),
              let size = (a[.size] as? NSNumber)?.intValue, let modified = a[.modificationDate] as? Date else { return true }
        if let c = compared[rel], c.size == size, c.modified == modified { return !c.same }
        let same = baseline[rel].map { $0.count == size && (try? Data(contentsOf: u)) == $0 } ?? false
        compared[rel] = (size, modified, same)
        return !same
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
        let fm = FileManager.default
        for e in changedFiles {
            let src = work.appendingPathComponent(e), dest = original.appendingPathComponent(e)
            if fm.fileExists(atPath: src.path) {
                let data = try Data(contentsOf: src)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest, options: .atomic)
                baseline[e] = data; compared[e] = nil
            } else {                                     // deleted in the working copy
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                baseline[e] = nil; compared[e] = nil
            }
        }
    }

    /// Back to the last saved deck: changed and deleted files as they were, new ones gone.
    func revert() throws {
        let fm = FileManager.default
        for e in changedFiles {
            let u = work.appendingPathComponent(e)
            if let d = baseline[e] {
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try d.write(to: u, options: .atomic)
            } else {
                try? fm.removeItem(at: u)
            }
        }
    }

    func discard() { try? FileManager.default.removeItem(at: root) }
}
