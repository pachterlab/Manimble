using System.IO;
using System.IO.Compression;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Manimble;

/// The manifest at the top of a portable project (manimble-project.json), the same file the Mac app writes, so a
/// .manimble package moves between the two. Paths in it use forward slashes.
public sealed class PortableManifest
{
    [JsonPropertyName("format")] public string Format { get; set; } = "manimble-project";
    [JsonPropertyName("version")] public int Version { get; set; } = 1;
    [JsonPropertyName("projectName")] public string ProjectName { get; set; } = "";
    [JsonPropertyName("deckPath")] public string DeckPath { get; set; } = "";
    [JsonPropertyName("dependencies")] public List<string> Dependencies { get; set; } = new();
    [JsonPropertyName("createdAt")] public string CreatedAt { get; set; } = "";
}

public sealed class PortableProjectException(string message) : Exception(message);

/// Portable projects (a port of apps/macos/Sources/Manimble/PortableProject.swift): a project folder holding the
/// deck, the files its slides read (from the engine's dependency_report) and a manifest; or that folder zipped as a
/// .manimble package. Opening a package unpacks it into an ordinary project folder; the package is never written.
public static class PortableProject
{
    public const string ManifestName = "manimble-project.json";
    static readonly StringComparison Ci = StringComparison.OrdinalIgnoreCase;

    public static void CreateFolder(Workspace ws, IEnumerable<string> dependencies, string destination)
    {
        if (Directory.Exists(destination) || File.Exists(destination))
            throw new PortableProjectException($"A folder already exists at {destination}. Choose another location or remove it first.");
        var parent = Path.GetDirectoryName(destination)!;
        Directory.CreateDirectory(parent);
        var stage = Path.Combine(parent, $".{Path.GetFileName(destination)}.{Guid.NewGuid():N}.tmp");
        try
        {
            Build(ws, dependencies, stage);
            Directory.Move(stage, destination);
        }
        catch
        {
            TryDelete(stage);
            throw;
        }
    }

    public static void CreateArchive(Workspace ws, IEnumerable<string> dependencies, string destination)
    {
        var stageRoot = Path.Combine(Paths.Base, "export", "portable-" + Guid.NewGuid().ToString("N"));
        var project = Path.Combine(stageRoot, ws.ProjectName);
        var partial = destination + ".partial";
        try
        {
            Build(ws, dependencies, project);
            if (File.Exists(partial)) File.Delete(partial);
            // the project folder itself is the archive's one top-level entry, as `ditto --keepParent` makes it
            using (var zip = ZipFile.Open(partial, ZipArchiveMode.Create))
            {
                foreach (var f in Directory.EnumerateFiles(project, "*", SearchOption.AllDirectories))
                {
                    var rel = ws.ProjectName + "/" + Path.GetRelativePath(project, f).Replace('\\', '/');
                    zip.CreateEntryFromFile(f, rel, CompressionLevel.Optimal);
                }
            }
            if (File.Exists(destination)) File.Delete(destination);
            File.Move(partial, destination);
        }
        finally
        {
            TryDelete(stageRoot);
            try { if (File.Exists(partial)) File.Delete(partial); } catch { }
        }
    }

    static void Build(Workspace ws, IEnumerable<string> dependencies, string project)
    {
        var deckDestination = Path.Combine(project, ws.DeckRelativePath.Replace('/', '\\'));
        Directory.CreateDirectory(deckDestination);
        CopyDeck(ws.Work, deckDestination, ws.OwnFiles);

        // assets are a conventional part of a Manim Slides project: copied even when no slide read every file
        var assetSource = Path.Combine(Path.GetDirectoryName(ws.Work)!, "assets");
        if (Directory.Exists(assetSource))
            CopyNode(assetSource, Path.Combine(Path.GetDirectoryName(deckDestination)!, "assets"));

        // Files the slides read sit in the working copy, or (through its junctions, or a path the deck code resolved)
        // in the original project around the deck. The portable layout mirrors that same parent, so both keep
        // their relative paths.
        var roots = new List<string> { ws.Root };
        var sourceProjectRoot = Path.GetDirectoryName(Path.GetDirectoryName(ws.Original));
        if (sourceProjectRoot != null) roots.Add(sourceProjectRoot);
        roots = roots.Select(r => Path.GetFullPath(r).TrimEnd('\\') + "\\").Distinct(StringComparer.OrdinalIgnoreCase).ToList();

        var outside = new List<string>();
        var unavailable = new List<string>();
        var included = new List<string>();
        foreach (var raw in dependencies.Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(d => d, StringComparer.OrdinalIgnoreCase))
        {
            string path;
            try { path = Path.GetFullPath(raw); } catch { outside.Add(raw); continue; }
            var root = roots.FirstOrDefault(r => path.StartsWith(r, Ci));
            if (root == null) { outside.Add(raw); continue; }
            var relative = path[root.Length..];
            var info = new FileInfo(path);
            // an online-only cloud file (OneDrive, Dropbox) reads as missing or empty until it is downloaded
            if (!info.Exists || info.Length == 0 || info.Attributes.HasFlag((FileAttributes)0x00400000 /* RECALL_ON_DATA_ACCESS */))
            {
                unavailable.Add(raw);
                continue;
            }
            included.Add(relative.Replace('\\', '/'));
            var target = Path.Combine(project, relative);
            if (File.Exists(target)) continue;
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            File.Copy(path, target);
        }
        if (outside.Count > 0)
            throw new PortableProjectException(
                "These files are outside the project folder, so the project would not be portable:\n\n" + string.Join("\n", outside) +
                "\n\nManimble checked these project roots:\n" + string.Join("\n", roots.Select(r => r.TrimEnd('\\'))) +
                "\n\nMove them into the project folder and update the deck paths, then package it again.");
        if (unavailable.Count > 0)
            throw new PortableProjectException(
                "Manimble could not read these dependencies. They may be online-only OneDrive or Dropbox files:\n\n" +
                string.Join("\n", unavailable) + "\n\nDownload them locally (Always keep on this device), then try again.");

        var manifest = new PortableManifest
        {
            ProjectName = ws.ProjectName,
            DeckPath = ws.DeckRelativePath,
            Dependencies = included.Order(StringComparer.Ordinal).ToList(),
            CreatedAt = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
        };
        File.WriteAllText(Path.Combine(project, ManifestName),
            JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true }));
    }

    static readonly HashSet<string> Excluded = new(StringComparer.OrdinalIgnoreCase) { "snap", "__pycache__", ".manimble" };

    /// The deck's files and folders. Existing Manim Slides builds and their media come along, so a recipient can
    /// present the deck before rendering it again.
    static void CopyDeck(string source, string destination, IReadOnlySet<string> own)
    {
        foreach (var child in Directory.EnumerateFileSystemEntries(source).Order(StringComparer.OrdinalIgnoreCase))
        {
            var name = Path.GetFileName(child);
            if (name.StartsWith('.') || Excluded.Contains(name) || own.Contains(name)) continue;
            CopyNode(child, Path.Combine(destination, name));
        }
    }

    /// Copies a file or folder; junctions and links are followed, so the copy holds real files.
    static void CopyNode(string source, string destination, int depth = 0)
    {
        if (depth >= 64) throw new PortableProjectException("The project contains a directory link loop.");
        if (Directory.Exists(source))
        {
            Directory.CreateDirectory(destination);
            foreach (var child in Directory.EnumerateFileSystemEntries(source).Order(StringComparer.OrdinalIgnoreCase))
            {
                var name = Path.GetFileName(child);
                if (name.StartsWith('.') || name.Equals("__pycache__", Ci)) continue;
                CopyNode(child, Path.Combine(destination, name), depth + 1);
            }
        }
        else if (File.Exists(source))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(source, destination, true);
        }
        else throw new PortableProjectException("A project asset link is broken: " + source);
    }

    /// The deck of a portable project folder, or null when `project` has no manifest.
    public static string? DeckIn(string project)
    {
        var manifestPath = Path.Combine(project, ManifestName);
        if (!File.Exists(manifestPath)) return null;
        PortableManifest? m;
        try { m = JsonSerializer.Deserialize<PortableManifest>(File.ReadAllText(manifestPath)); }
        catch { m = null; }
        if (m == null || m.Format != "manimble-project" || m.Version != 1 || m.DeckPath.Length == 0 ||
            m.DeckPath.StartsWith('/') || m.DeckPath.Contains('\\') || m.DeckPath.Contains(':') || m.DeckPath.Split('/').Contains(".."))
            throw new PortableProjectException("This Manimble project has an unsupported or invalid manifest.");
        var root = Path.GetFullPath(project).TrimEnd('\\') + "\\";
        var deck = Path.GetFullPath(Path.Combine(project, m.DeckPath.Replace('/', '\\')));
        if (!deck.StartsWith(root, Ci) || !Directory.Exists(deck))
            throw new PortableProjectException("The deck folder listed in this project is missing.");
        return deck;
    }

    /// Unpacks `archive` into the new project folder `target` and returns its deck. The folder is an ordinary
    /// project: what Save writes, Revert goes back to and Open Recent opens again.
    public static string UnpackArchive(string archive, string target)
    {
        if (Directory.Exists(target) || File.Exists(target))
            throw new PortableProjectException($"A file or folder already exists at {target}. Choose another name.");
        var stage = Path.Combine(Paths.Base, "projects", Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(stage);
            var stageRoot = Path.GetFullPath(stage).TrimEnd('\\') + "\\";
            using (var zip = ZipFile.OpenRead(archive))
            {
                if (zip.Entries.Count == 0) throw new PortableProjectException("This .manimble file is empty.");
                foreach (var e in zip.Entries)
                {
                    var name = e.FullName;
                    // the Mac's resource-fork sidecars mean nothing here
                    if (name.StartsWith("__MACOSX/", Ci)) continue;
                    if (name.StartsWith('/') || name.Contains('\\') || name.Contains(':') || name.Split('/').Contains(".."))
                        throw new PortableProjectException("This .manimble file has unsafe or invalid archive paths and was not opened.");
                    var dest = Path.GetFullPath(Path.Combine(stage, name.Replace('/', '\\')));
                    if (!dest.StartsWith(stageRoot, Ci))
                        throw new PortableProjectException("This .manimble file has unsafe or invalid archive paths and was not opened.");
                    if (name.EndsWith('/')) { Directory.CreateDirectory(dest); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                    e.ExtractToFile(dest, overwrite: false);
                }
            }
            // the project folder is the one holding the manifest (usually the archive's top-level folder)
            var manifest = Directory.EnumerateFiles(stage, ManifestName, SearchOption.AllDirectories)
                .OrderBy(p => p.Length).FirstOrDefault()
                ?? throw new PortableProjectException("This archive does not contain a valid Manimble project.");
            var project = Path.GetDirectoryName(manifest)!;
            if (DeckIn(project) == null) throw new PortableProjectException("This archive does not contain a valid Manimble project.");
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(target))!);
            MoveDirectory(project, target);
            return DeckIn(target)!;
        }
        catch (InvalidDataException)
        {
            throw new PortableProjectException("This .manimble file is not a valid archive.");
        }
        finally
        {
            TryDelete(stage);
        }
    }

    /// Directory.Move only works on one volume; the staging folder may be on another drive than the target.
    static void MoveDirectory(string source, string target)
    {
        if (string.Equals(Path.GetPathRoot(Path.GetFullPath(source)), Path.GetPathRoot(Path.GetFullPath(target)), Ci))
        {
            Directory.Move(source, target);
            return;
        }
        CopyNode(source, target);
    }

    static void TryDelete(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, true); } catch (Exception e) { Log.Note("portable cleanup: " + e.Message); }
    }
}
