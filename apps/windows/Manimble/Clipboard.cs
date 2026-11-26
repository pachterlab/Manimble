using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Manimble;

/// The engine's answer to `copy` (copy_objects).
public sealed class CopyResult
{
    public sealed class Picture { public string Png { get; set; } = ""; public double[] Box { get; set; } = Array.Empty<double>(); }
    public sealed class Item
    {
        public string Kind { get; set; } = "";
        public string? Code { get; set; }
        public string? Why { get; set; }
        public double[] At { get; set; } = Array.Empty<double>();
        public double[] Box { get; set; } = Array.Empty<double>();
        public List<Picture> Pictures { get; set; } = new();
        public string? Text { get; set; }
    }
    public bool? Ok { get; set; }
    public string? Error { get; set; }
    public List<Item>? Items { get; set; }
}

/// What Manimble puts on the clipboard for copied objects (the Mac app's CopiedObjects): the code that makes them
/// again, and their pictures (PNG, base64) for where the code cannot go.
public sealed class CopiedObjects
{
    public const string Format = "Manimble.Objects";
    public sealed class Picture { public string Png { get; set; } = ""; public double[] Box { get; set; } = Array.Empty<double>(); }
    public sealed class Item
    {
        public string Kind { get; set; } = "";
        public string? Code { get; set; }
        public string? Why { get; set; }
        public double[] At { get; set; } = Array.Empty<double>();
        public double[] Box { get; set; } = Array.Empty<double>();
        public List<Picture> Pictures { get; set; } = new();
        public string? Text { get; set; }
    }
    public string Deck { get; set; } = "";
    public string Scene { get; set; } = "";
    public List<Item> Items { get; set; } = new();
}

/// What Copy puts on the clipboard when a slide, or one of its builds, is selected in the navigator (the Mac app's
/// CopiedSlide); Paste makes a duplicate of it (a slide after the selected slide, a build right after the one it copies).
public sealed class CopiedSlide
{
    public const string Format = "Manimble.Slide";
    public string Deck { get; set; } = "";
    public string Scene { get; set; } = "";
    public int? Build { get; set; }                // null: the whole slide
}

public partial class MainWindow
{
    static readonly Dictionary<string, int> pastes = new();

    /// A build listed under a slide in the navigator was clicked since the last click on a slide row.
    bool buildFocused;

    /// Focus is in the slide navigator (also while the Edit menu is open: the menu keeps the window's logical focus).
    bool NavigatorFocused =>
        sceneName != null && (SlideList.IsKeyboardFocusWithin
                              || (FocusManager.GetFocusedElement(this) is Visual v && v.IsDescendantOf(SlideList)));

    /// Ctrl+C in the navigator: the selected slide, or the build clicked under it, onto the clipboard.
    void CopySlide()
    {
        if (workspace == null || sceneName == null) return;
        int? build = buildFocused && scene?.Stops is { Count: > 1 } ? stopIndex : null;
        var c = new CopiedSlide { Deck = workspace.Original, Scene = sceneName, Build = build };
        var data = new DataObject();
        data.SetData(CopiedSlide.Format, JsonSerializer.Serialize(c));
        try { Clipboard.SetDataObject(data, true); }
        catch (Exception ex) { Toast("Could not use the clipboard: " + ex.Message, error: true); return; }
        Toast(build is int b ? $"Copied build {b + 1} of {sceneName} · Ctrl+V pastes a duplicate" : $"Copied slide {sceneName} · Ctrl+V pastes a duplicate");
    }

    /// Paste a copied slide (a duplicate after the selected slide) or build (a duplicate right after it).
    void PasteSlide(CopiedSlide c, Workspace ws)
    {
        if (!string.Equals(Path.GetFullPath(c.Deck).TrimEnd('\\', '/'), Path.GetFullPath(ws.Original).TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase))
        {
            Toast("Slides paste only into the deck they were copied from", error: true); return;
        }
        if (!slides.Any(s => s.Name == c.Scene)) { Toast($"The copied slide {c.Scene} is no longer in this deck", error: true); return; }
        if (c.Build is int b) DuplicateBuild(c.Scene, b);
        else SlideOp(new JsonObject { ["op"] = "duplicate", ["scene"] = c.Scene, ["after"] = sceneName });
    }

    /// Edit > Duplicate (Ctrl+D, as in PowerPoint): a copy of the selected objects pasted a little below and right of
    /// them, without touching the clipboard.
    void DuplicateSelection() => CopySelection(duplicate: true);

    /// Edit > Copy (Ctrl+C) on the slide: the selected objects as Manimble objects, plus a picture and their text for
    /// other programs; `then` runs once they are on the clipboard (Cut deletes them). `duplicate`: pasted straight back
    /// onto the slide instead of going to the clipboard.
    void CopySelection(Action? then = null, bool duplicate = false)
    {
        var oids = canvas.Selected.ToList();
        var name = sceneName;
        if (workspace == null || name == null || oids.Count == 0) return;
        var ws = workspace;
        Submit(async () =>
        {
            var req = new JsonObject { ["scene"] = name, ["stop"] = stopIndex, ["oids"] = new JsonArray(oids.Select(i => (JsonNode)i).ToArray()) };
            if (Seen is { } seen) req["seen"] = seen;
            var r = await engine.TryCall<CopyResult>("copy", req);
            if (r?.Items is not { Count: > 0 } items) { Toast(r?.Error ?? "Could not copy: these elements are not on this build", error: true); return; }
            var copied = new CopiedObjects
            {
                Deck = ws.Original, Scene = name,
                Items = items.Select(it => new CopiedObjects.Item
                {
                    Kind = it.Kind, Code = it.Code, Why = it.Why, At = it.At, Box = it.Box, Text = it.Text,
                    Pictures = it.Pictures.Where(p => File.Exists(p.Png))
                                          .Select(p => new CopiedObjects.Picture { Png = Convert.ToBase64String(File.ReadAllBytes(p.Png)), Box = p.Box }).ToList(),
                }).ToList(),
            };
            if (duplicate) { PasteObjects(copied, ws); return; }
            var data = new DataObject();
            data.SetData(CopiedObjects.Format, JsonSerializer.Serialize(copied));
            var texts = copied.Items.Select(i => i.Text).Where(t => !string.IsNullOrEmpty(t)).ToList();
            if (texts.Count > 0) data.SetText(string.Join("\n", texts));
            if (copied.Items.FirstOrDefault()?.Pictures.FirstOrDefault() is { } pic)
            {
                try
                {
                    var bi = new BitmapImage();
                    bi.BeginInit(); bi.StreamSource = new MemoryStream(Convert.FromBase64String(pic.Png)); bi.CacheOption = BitmapCacheOption.OnLoad; bi.EndInit();
                    data.SetImage(bi);
                }
                catch { }
            }
            try { Clipboard.SetDataObject(data, true); }
            catch (Exception ex) { Toast("Could not use the clipboard: " + ex.Message, error: true); return; }
            var why = copied.Items.FirstOrDefault(i => i.Code == null)?.Why;
            Toast(why != null ? "Copied; part of it pastes as a picture: " + why : $"Copied {oids.Count} object{(oids.Count == 1 ? "" : "s")}");
            then?.Invoke();
        });
    }

    void CutSelection() => CopySelection(DeleteSelection);

    double UnitPx => canvas.FrameSize.Width / 14.222222222222221;

    /// Each paste a little below and right of the one before, as PowerPoint pastes them, so they don't cover each other.
    double NextPasteOffset(bool sameSlide)
    {
        if (!sameSlide) return 0;
        var key = sceneName ?? "";
        var k = (pastes.GetValueOrDefault(key) + 1) % 6;
        pastes[key] = k;
        return Math.Max(1, k) * 0.04 * canvas.FrameSize.Width;
    }

    /// Edit > Paste (Ctrl+V): objects copied in Manimble, or a picture or text from another program.
    async void PasteOnSlide()
    {
        if (workspace == null || sceneName == null) return;
        var ws = workspace;
        IDataObject? data;
        try { data = Clipboard.GetDataObject(); } catch { data = null; }
        if (data == null) return;
        if (data.GetDataPresent(CopiedSlide.Format) && data.GetData(CopiedSlide.Format) is string sj
            && JsonSerializer.Deserialize<CopiedSlide>(sj) is { } slide)
        {
            PasteSlide(slide, ws);
            return;
        }
        if (data.GetDataPresent(CopiedObjects.Format) && data.GetData(CopiedObjects.Format) is string json
            && JsonSerializer.Deserialize<CopiedObjects>(json) is { } copied)
        {
            PasteObjects(copied, ws);
            return;
        }
        var (cx, cy) = (canvas.FrameSize.Width / 2, canvas.FrameSize.Height / 2);
        var d = NextPasteOffset(true) - 0.04 * canvas.FrameSize.Width;
        if (data.GetDataPresent(DataFormats.Bitmap) || data.GetDataPresent("PNG"))
        {
            var file = SavePastedPicture(data, ws.Work);
            if (file == null) { Toast("Could not read the picture on the clipboard", error: true); return; }
            var half = 2 * UnitPx;
            Insert("image", new JsonObject { ["file"] = file, ["sx"] = cx + d - half, ["sy"] = cy + d, ["ex"] = cx + d + half, ["ey"] = cy + d });
            return;
        }
        if (DroppedFiles(data).FirstOrDefault() is { } img)
        {
            if (await PictureFile(img, ws.Work) is not { } name || sceneName == null) return;
            var half = 2 * UnitPx;
            Insert("image", new JsonObject { ["file"] = name, ["sx"] = cx + d - half, ["sy"] = cy + d, ["ex"] = cx + d + half, ["ey"] = cy + d });
            return;
        }
        if (data.GetDataPresent(DataFormats.UnicodeText) && data.GetData(DataFormats.UnicodeText) is string text && text.Trim().Length > 0)
        {
            Insert("text", new JsonObject { ["value"] = text.TrimEnd('\r', '\n'), ["sx"] = cx + d - 1, ["sy"] = cy + d, ["ex"] = cx + d + 1, ["ey"] = cy + d });
            return;
        }
        Toast("Nothing on the clipboard can go on a slide: copy a picture or some text", error: true);
    }

    static readonly string[] PictureExts = { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff", ".pdf", ".svg" };
    static readonly System.Net.Http.HttpClient http = new();

    static string[] DroppedFiles(IDataObject d) =>
        d.GetDataPresent(DataFormats.FileDrop) && d.GetData(DataFormats.FileDrop) is string[] files
            ? files.Where(f => PictureExts.Contains(Path.GetExtension(f).ToLowerInvariant())).ToArray()
            : Array.Empty<string>();

    /// The web pictures (img tags with http sources) a page fragment dragged from a browser shows.
    static string[] DroppedImageLinks(IDataObject d)
    {
        if (!d.GetDataPresent(DataFormats.Html) || d.GetData(DataFormats.Html) is not string html) return Array.Empty<string>();
        return System.Text.RegularExpressions.Regex.Matches(html, @"<img\b[^>]*?\bsrc\s*=\s*[""']([^""']+)[""']",
                System.Text.RegularExpressions.RegexOptions.IgnoreCase)
            .Select(m => m.Groups[1].Value.Replace("&amp;", "&"))
            .Where(u => u.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || u.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            .ToArray();
    }

    /// Whether a drag over the slide carries pictures: image files, a browser's image, or a picture itself.
    bool CanDropPictures(IDataObject d) =>
        workspace != null && sceneName != null
        && (DroppedFiles(d).Length > 0 || DroppedImageLinks(d).Length > 0 || d.GetDataPresent("PNG") || d.GetDataPresent(DataFormats.Bitmap));

    /// Pictures dragged onto the slide, each centred where it was dropped, the next ones a little below and right of it.
    async void PicturesDropped(IDataObject d, Point at)
    {
        if (workspace is not { } ws || sceneName == null) return;
        var names = new List<string>();
        foreach (var f in DroppedFiles(d))
            if (await PictureFile(f, ws.Work) is { } name) names.Add(name);
        if (names.Count == 0 && DroppedImageLinks(d) is { Length: > 0 } links)
        {
            Busy(+1, "Downloading the picture…");
            foreach (var u in links)
            {
                try
                {
                    var bytes = await http.GetByteArrayAsync(u);
                    var src = BitmapFrame.Create(new MemoryStream(bytes), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                    var name = UniqueName(ws.Work, "dropped.png");
                    using var fs = File.Create(Path.Combine(ws.Work, name));
                    var enc = new PngBitmapEncoder();
                    enc.Frames.Add(BitmapFrame.Create(src));
                    enc.Save(fs);
                    names.Add(name);
                }
                catch { Toast("Could not get the dropped picture from " + (Uri.TryCreate(u, UriKind.Absolute, out var uri) ? uri.Host : "the web"), error: true); }
            }
            Busy(-1);
        }
        if (names.Count == 0 && SavePastedPicture(d, ws.Work, fromClipboard: false) is { } pic) names.Add(pic);
        if (names.Count == 0 || sceneName == null) return;
        var half = 2 * UnitPx;
        for (int k = 0; k < names.Count; k++)
        {
            var off = k * 0.04 * canvas.FrameSize.Width;
            var (cx, cy) = (at.X + off, at.Y + off);
            Insert("image", new JsonObject { ["file"] = names[k], ["sx"] = cx - half, ["sy"] = cy, ["ex"] = cx + half, ["ey"] = cy });
        }
    }

    /// A picture file copied into the deck folder as manim reads it: PNG, JPEG, GIF, BMP and WebP as they are, a TIFF
    /// as a PNG, a PDF's first page drawn as a PNG, an SVG as a vector copy (the engine's svg_icon). Its name, or null.
    async Task<string?> PictureFile(string f, string dir)
    {
        var ext = Path.GetExtension(f).ToLowerInvariant();
        var stem = Path.GetFileNameWithoutExtension(f);
        try
        {
            switch (ext)
            {
                case ".tif" or ".tiff":
                {
                    var name = UniqueName(dir, stem + ".png");
                    var src = BitmapFrame.Create(new Uri(Path.GetFullPath(f)), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                    using var fs = File.Create(Path.Combine(dir, name));
                    var enc = new PngBitmapEncoder();
                    enc.Frames.Add(BitmapFrame.Create(src));
                    enc.Save(fs);
                    return name;
                }
                case ".pdf":
                {
                    var name = UniqueName(dir, stem + ".png");
                    var file = await global::Windows.Storage.StorageFile.GetFileFromPathAsync(Path.GetFullPath(f));
                    var doc = await global::Windows.Data.Pdf.PdfDocument.LoadFromFileAsync(file);
                    if (doc.PageCount == 0) throw new InvalidDataException("the PDF has no pages");
                    using var page = doc.GetPage(0);
                    var k = 2400 / Math.Max(1, Math.Max(page.Size.Width, page.Size.Height));
                    using var mem = new global::Windows.Storage.Streams.InMemoryRandomAccessStream();
                    await page.RenderToStreamAsync(mem, new global::Windows.Data.Pdf.PdfPageRenderOptions
                    {
                        DestinationWidth = (uint)Math.Max(1, Math.Round(page.Size.Width * k)),
                        DestinationHeight = (uint)Math.Max(1, Math.Round(page.Size.Height * k)),
                    });                                  // PNG is the default encoding
                    using var fs = File.Create(Path.Combine(dir, name));
                    await mem.AsStreamForRead().CopyToAsync(fs);
                    return name;
                }
                case ".svg":
                {
                    var name = UniqueName(dir, stem + ".svg");
                    Busy(+1, $"Preparing {Path.GetFileName(f)}…");
                    try
                    {
                        // no PNG to compare with: taken when nothing in it is out of manim's reach
                        var r = await engine.TryCall<SvgPrepared>("svg_icon", new JsonObject { ["svg"] = Path.GetFullPath(f), ["out"] = Path.Combine(dir, name) });
                        if (r is { Ok: true }) return name;
                        Toast($"Manim cannot draw {Path.GetFileName(f)}: {r?.Why ?? "the engine did not answer"}", error: true);
                        return null;
                    }
                    finally { Busy(-1); }
                }
                default:
                {
                    var name = UniqueName(dir, Path.GetFileName(f));
                    File.Copy(f, Path.Combine(dir, name));
                    return name;
                }
            }
        }
        catch (Exception ex) { Toast($"Could not read {Path.GetFileName(f)}: {ex.Message}", error: true); return null; }
    }

    static string UniqueName(string dir, string fileName)
    {
        var b = Path.GetFileNameWithoutExtension(fileName);
        var ext = Path.GetExtension(fileName);
        var name = fileName;
        for (int n = 1; File.Exists(Path.Combine(dir, name)); n++) name = $"{b}_{n}{ext}";
        return name;
    }

    static string? SavePastedPicture(IDataObject data, string dir, bool fromClipboard = true)
    {
        try
        {
            BitmapSource? src = null;
            if (data.GetData("PNG") is MemoryStream ms) src = BitmapFrame.Create(ms, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            src ??= fromClipboard ? Clipboard.GetImage() : data.GetData(DataFormats.Bitmap) as BitmapSource;
            if (src == null) return null;
            var name = UniqueName(dir, "pasted.png");
            using var fs = File.Create(Path.Combine(dir, name));
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(src));
            enc.Save(fs);
            return name;
        }
        catch { return null; }
    }

    /// Objects copied from a slide: their code (in the same deck) where they were on their slide, or a little below
    /// and right of them on their own slide; their pictures where the code cannot go.
    void PasteObjects(CopiedObjects c, Workspace ws)
    {
        var sameDeck = string.Equals(Path.GetFullPath(c.Deck), Path.GetFullPath(ws.Original), StringComparison.OrdinalIgnoreCase);
        var d = NextPasteOffset(c.Scene == sceneName);
        double[] Shifted(double[] b) => b.Length == 4 ? new[] { b[0] + d, b[1] + d, b[2] + d, b[3] + d } : b;
        var unit = UnitPx;
        Submit(() => AsOneUndoStep("Paste", async () =>
        {
            foreach (var item in c.Items)
            {
                async Task Pictures()
                {
                    foreach (var p in item.Pictures)
                    {
                        var name = UniqueName(ws.Work, "pasted.png");
                        File.WriteAllBytes(Path.Combine(ws.Work, name), Convert.FromBase64String(p.Png));
                        var b = Shifted(p.Box);
                        var cy = (b[1] + b[3]) / 2;
                        await InsertNow("image", new JsonObject { ["file"] = name, ["sx"] = b[0], ["sy"] = cy, ["ex"] = b[2], ["ey"] = cy });
                    }
                }
                if (!sameDeck || item.Code == null || item.At.Length != 2) { await Pictures(); continue; }
                var x = item.At[0] + d / unit; var y = item.At[1] - d / unit;
                var ok = await InsertNow("code", new JsonObject
                {
                    ["code"] = item.Code + FormattableString.Invariant($".move_to(({x:0.###}, {y:0.###}, 0))"),
                    ["box"] = new JsonArray(Shifted(item.Box).Select(v => (JsonNode)v).ToArray()),
                }, quiet: true);
                if (!ok) await Pictures();         // code that does not run on this slide goes in as its picture
            }
            if (sceneName != null) await LoadScene(sceneName, keepStop: true);
        }));
    }

    /// An insert run inside an edit already queued (a paste of several objects): no preview, no extra queueing.
    async Task<bool> InsertNow(string kind, JsonObject req, bool quiet = false)
    {
        var name = sceneName;
        if (name == null) return false;
        req["kind"] = kind; req["scene"] = name; req["stop"] = stopIndex;
        if (Seen is { } seen) req["seen"] = seen;
        Busy(+1, "Pasting…");
        EditResult? r = null; string? failure = null;
        try { r = await engine.Call<EditResult>("insert", req); } catch (Exception ex) { failure = ex.Message; }
        Busy(-1);
        if (r?.Ok == true) { Toast("Pasted"); return true; }
        if (!quiet) Toast(failure ?? r?.Error ?? "Could not paste", error: true);
        return false;
    }
}
