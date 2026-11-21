using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
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

public partial class MainWindow
{
    static readonly Dictionary<string, int> pastes = new();

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
    void PasteOnSlide()
    {
        if (workspace == null || sceneName == null) return;
        var ws = workspace;
        IDataObject? data;
        try { data = Clipboard.GetDataObject(); } catch { data = null; }
        if (data == null) return;
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
        if (data.GetDataPresent(DataFormats.FileDrop) && data.GetData(DataFormats.FileDrop) is string[] files
            && files.FirstOrDefault(f => new[] { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp" }.Contains(Path.GetExtension(f).ToLowerInvariant())) is { } img)
        {
            var name = UniqueName(ws.Work, Path.GetFileName(img));
            File.Copy(img, Path.Combine(ws.Work, name));
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

    static string UniqueName(string dir, string fileName)
    {
        var b = Path.GetFileNameWithoutExtension(fileName);
        var ext = Path.GetExtension(fileName);
        var name = fileName;
        for (int n = 1; File.Exists(Path.Combine(dir, name)); n++) name = $"{b}_{n}{ext}";
        return name;
    }

    static string? SavePastedPicture(IDataObject data, string dir)
    {
        try
        {
            BitmapSource? src = null;
            if (data.GetData("PNG") is MemoryStream ms) src = BitmapFrame.Create(ms, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            src ??= Clipboard.GetImage();
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
