using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace Manimble;

/// A private working copy of a deck (a port of apps/macos/Sources/Manimble/Workspace.swift). Edits go to the copy;
/// Save writes them back to the original.
///
/// The copy mirrors the deck's surroundings so its relative paths keep working: folders become directory
/// junctions (no administrator rights or developer mode needed, unlike symbolic links), files are copied.
public sealed class Workspace
{
    public string Original { get; }
    public string Work { get; }          // the copied deck folder (what the engine opens)
    public string Root { get; }          // workspace root, deleted on discard
    public string ProjectName { get; }
    readonly Dictionary<string, byte[]?> baseline = new(StringComparer.OrdinalIgnoreCase);
    readonly HashSet<string> ownFiles = new(StringComparer.OrdinalIgnoreCase);
    readonly HashSet<string> mirrored = new(StringComparer.OrdinalIgnoreCase);   // copies of the original's surroundings

    /// Folders of the deck that hold what Manimble or Manim Slides make, never saved: output, caches.
    static readonly HashSet<string> Generated = new(StringComparer.OrdinalIgnoreCase) { "slides", "media", "__pycache__", ".manimble" };

    static string Hash(string s) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(s.ToLowerInvariant())))[..12].ToLowerInvariant();

    public static string CacheDir(string deck)
    {
        var d = Path.Combine(Paths.Base, "cache", Path.GetFileName(deck) + "-" + Hash(deck));
        Directory.CreateDirectory(d);
        return d;
    }

    public Workspace(string deck)
    {
        Original = Path.GetFullPath(deck).TrimEnd('\\', '/');
        var x = Path.GetDirectoryName(Original) ?? Original;          // the deck's parent
        var g = Path.GetDirectoryName(x);                              // and its parent
        var deckName = Path.GetFileName(Original);
        var xName = Path.GetFileName(x);
        if (string.IsNullOrEmpty(xName)) xName = "deck-parent";
        ProjectName = xName + "-" + deckName;
        // each open gets its own root: reopening a deck makes the new copy before the old one is discarded
        Root = Path.Combine(Paths.Base, "work", deckName + "-" + Hash(Original) + "-" + Guid.NewGuid().ToString("N")[..8]);
        var wx = Path.Combine(Root, xName);
        Work = Path.Combine(wx, deckName);
        Directory.CreateDirectory(Work);
        // siblings of the deck's parent and of the deck itself: folders become junctions
        if (g != null && !IsDriveRoot(x))
            foreach (var e in Directory.EnumerateFileSystemEntries(g))
            {
                var n = Path.GetFileName(e);
                if (n.Equals(xName, StringComparison.OrdinalIgnoreCase) || n.StartsWith('.')) continue;
                if (Directory.Exists(e)) Junction(Path.Combine(Root, n), e);
            }
        foreach (var e in Directory.EnumerateFileSystemEntries(x))
        {
            var n = Path.GetFileName(e);
            if (n.Equals(deckName, StringComparison.OrdinalIgnoreCase) || n.StartsWith('.')) continue;
            if (Directory.Exists(e)) Junction(Path.Combine(wx, n), e);
            else TryCopySmall(e, Path.Combine(wx, n));
        }
        foreach (var src in Directory.EnumerateFileSystemEntries(Original))
        {
            var n = Path.GetFileName(src);
            if (n.StartsWith('.') || n.Equals("__pycache__", StringComparison.OrdinalIgnoreCase)) continue;
            var dest = Path.Combine(Work, n);
            if (Directory.Exists(src))
            {
                if (n.Equals("slides", StringComparison.OrdinalIgnoreCase))
                    CopyDir(src, dest);                 // manim-slides output: building edited code never touches the original's
                else if (!Generated.Contains(n) && HoldsPython(src))
                    CopyDir(src, dest);                 // a package of the deck's code: saved, reverted and undone like its files
                else
                    Junction(dest, src);
            }
            else File.Copy(src, dest, true);
        }
        foreach (var rel in DeckFiles()) baseline[rel] = ReadOrNull(Path.Combine(Original, rel));
        // what a coding agent started in the terminal reads first; a deck's own wins
        foreach (var e in AgentInstructions.Files)
        {
            var p = Path.Combine(Work, e);
            if (File.Exists(p)) continue;
            try { File.WriteAllText(p, AgentInstructions.Text); ownFiles.Add(e); } catch { }
        }
    }

    static bool IsDriveRoot(string p) => Path.GetPathRoot(p)?.TrimEnd('\\') == p.TrimEnd('\\');

    /// Files next to the deck folder (a README, a .bib): copied when small, so links in the deck still find them.
    void TryCopySmall(string src, string dest)
    {
        try
        {
            if (new FileInfo(src).Length < 20_000_000) { File.Copy(src, dest, true); mirrored.Add(dest); }
        }
        catch { }
    }

    static void CopyDir(string src, string dest)
    {
        Directory.CreateDirectory(dest);
        foreach (var f in Directory.EnumerateFiles(src)) File.Copy(f, Path.Combine(dest, Path.GetFileName(f)), true);
        foreach (var d in Directory.EnumerateDirectories(src))
        {
            if (new DirectoryInfo(d).Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
            CopyDir(d, Path.Combine(dest, Path.GetFileName(d)));
        }
    }

    /// A directory junction at `link` pointing at `target`.
    static void Junction(string link, string target)
    {
        try
        {
            var psi = new ProcessStartInfo("cmd.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            psi.ArgumentList.Add("/c");
            psi.ArgumentList.Add("mklink");
            psi.ArgumentList.Add("/J");
            psi.ArgumentList.Add(link);
            psi.ArgumentList.Add(target);
            using var p = Process.Start(psi)!;
            p.WaitForExit(10_000);
        }
        catch (Exception e) { Log.Note($"junction {link}: {e.Message}"); }
    }

    static bool HoldsPython(string dir)
    {
        try
        {
            foreach (var f in Directory.EnumerateFiles(dir, "*.py")) return true;
            foreach (var d in Directory.EnumerateDirectories(dir))
            {
                var n = Path.GetFileName(d);
                if (Generated.Contains(n) || n.StartsWith('.')) continue;
                if (new DirectoryInfo(d).Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                if (HoldsPython(d)) return true;
            }
        }
        catch { }
        return false;
    }

    static byte[]? ReadOrNull(string p)
    {
        try { return File.Exists(p) ? File.ReadAllBytes(p) : null; } catch { return null; }
    }

    /// Every file Save writes back, by path in the deck folder: files in it and its real folders (not junctions to
    /// the original's other folders, nor generated output), but not the agent instructions Manimble wrote.
    List<string> DeckFiles()
    {
        var outp = new List<string>();
        void Walk(string dir, string rel)
        {
            foreach (var f in Directory.EnumerateFiles(dir))
            {
                var n = Path.GetFileName(f);
                if (n.StartsWith('.')) continue;
                var r = rel.Length == 0 ? n : rel + "\\" + n;
                if (ownFiles.Contains(r) || n.EndsWith(".manimble.tmp", StringComparison.OrdinalIgnoreCase)) continue;
                outp.Add(r);
            }
            foreach (var d in Directory.EnumerateDirectories(dir))
            {
                var n = Path.GetFileName(d);
                if (n.StartsWith('.') || Generated.Contains(n)) continue;
                if (new DirectoryInfo(d).Attributes.HasFlag(FileAttributes.ReparsePoint)) continue;
                Walk(d, rel.Length == 0 ? n : rel + "\\" + n);
            }
        }
        try { Walk(Work, ""); } catch { }
        outp.Sort(StringComparer.OrdinalIgnoreCase);
        return outp;
    }

    readonly Dictionary<string, (long size, DateTime modified, bool same)> compared = new(StringComparer.OrdinalIgnoreCase);

    bool Differs(string rel)
    {
        var p = Path.Combine(Work, rel);
        FileInfo fi;
        try { fi = new FileInfo(p); if (!fi.Exists) return true; } catch { return true; }
        if (compared.TryGetValue(rel, out var c) && c.size == fi.Length && c.modified == fi.LastWriteTimeUtc) return !c.same;
        bool same = false;
        if (baseline.TryGetValue(rel, out var b) && b != null && b.Length == fi.Length)
        {
            var now = ReadOrNull(p);
            same = now != null && now.AsSpan().SequenceEqual(b);
        }
        compared[rel] = (fi.Length, fi.LastWriteTimeUtc, same);
        return !same;
    }

    /// Files whose working copy differs from the baseline: changed, new, or deleted.
    public List<string> ChangedFiles
    {
        get
        {
            var present = DeckFiles();
            var set = new HashSet<string>(present, StringComparer.OrdinalIgnoreCase);
            var outp = present.Where(Differs).ToList();
            outp.AddRange(baseline.Keys.Where(k => !set.Contains(k)).OrderBy(k => k, StringComparer.OrdinalIgnoreCase));
            return outp;
        }
    }

    public bool IsModified => ChangedFiles.Count > 0;

    /// Files of the original that someone else changed since the copy was made.
    public List<string> ConflictFiles => ChangedFiles.Where(e =>
    {
        var cur = ReadOrNull(Path.Combine(Original, e));
        baseline.TryGetValue(e, out var b);
        if (cur == null || b == null) return cur != b;
        return !cur.AsSpan().SequenceEqual(b);
    }).ToList();

    public bool OriginalMissing => !Directory.Exists(Original);

    public void Save()
    {
        if (OriginalMissing)
            throw new IOException($"The deck folder is no longer at {Original}: it was moved, renamed or deleted since it was opened. " +
                                  "Your edits are still in the working copy. Use File > Save Project Copy… to save them in a new folder.");
        foreach (var e in ChangedFiles)
        {
            var src = Path.Combine(Work, e);
            var dest = Path.Combine(Original, e);
            if (File.Exists(src))
            {
                var data = File.ReadAllBytes(src);
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                var tmp = dest + ".manimble.tmp";
                File.WriteAllBytes(tmp, data);
                File.Move(tmp, dest, true);
                baseline[e] = data;
            }
            else
            {
                if (File.Exists(dest)) File.Delete(dest);
                baseline.Remove(e);
            }
            compared.Remove(e);
        }
    }

    /// Back to the last saved deck: changed and deleted files as they were, new ones gone.
    public void Revert()
    {
        foreach (var e in ChangedFiles)
        {
            var p = Path.Combine(Work, e);
            if (baseline.TryGetValue(e, out var d) && d != null)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(p)!);
                File.WriteAllBytes(p, d);
            }
            else
            {
                try { File.Delete(p); } catch { }
            }
            compared.Remove(e);
        }
    }

    /// The working copy saved as a new deck folder `dest` (Save Project Copy…).
    public void SaveCopy(string dest)
    {
        Directory.CreateDirectory(dest);
        foreach (var rel in DeckFiles())
        {
            var d = Path.Combine(dest, rel);
            Directory.CreateDirectory(Path.GetDirectoryName(d)!);
            File.Copy(Path.Combine(Work, rel), d, true);
        }
        // the folders the deck links to (assets, media) come along as real copies
        foreach (var dir in Directory.EnumerateDirectories(Work))
        {
            var n = Path.GetFileName(dir);
            if (Generated.Contains(n) || n.StartsWith('.')) continue;
            if (new DirectoryInfo(dir).Attributes.HasFlag(FileAttributes.ReparsePoint) && !Directory.Exists(Path.Combine(dest, n)))
                CopyDir(dir, Path.Combine(dest, n));
        }
    }

    /// Deletes the working copy. Junctions are removed as links: what they point at is never touched.
    public void Discard()
    {
        // render workers may still be leaving the folder (their working directory): try again for a few seconds
        for (int i = 0; i < 10; i++)
        {
            try { DeleteTree(Root); } catch (Exception e) { Log.Note("discard: " + e.Message); }
            if (!Directory.Exists(Root)) return;
            Thread.Sleep(300);
        }
    }

    static void DeleteTree(string dir)
    {
        var info = new DirectoryInfo(dir);
        if (!info.Exists) return;
        if (info.Attributes.HasFlag(FileAttributes.ReparsePoint)) { info.Delete(false); return; }
        foreach (var d in info.EnumerateDirectories()) DeleteTree(d.FullName);
        foreach (var f in info.EnumerateFiles())
        {
            try { f.Attributes = FileAttributes.Normal; f.Delete(); } catch { }
        }
        try { info.Delete(false); } catch { }
    }

    /// Working copies left behind by a crash: anything in work\ not in use by a running Manimble.
    public static void CleanStale(string? keep = null)
    {
        try
        {
            var work = Path.Combine(Paths.Base, "work");
            if (!Directory.Exists(work)) return;
            var others = Process.GetProcessesByName("Manimble").Length > 1;
            if (others) return;
            foreach (var d in Directory.EnumerateDirectories(work))
                if (keep == null || !d.Equals(keep, StringComparison.OrdinalIgnoreCase)) DeleteTree(d);
        }
        catch { }
    }
}
