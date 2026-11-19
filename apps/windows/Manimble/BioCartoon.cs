using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Manimble;

/// One icon of the BioCartoon catalog, as `biocartoon search --json` lists it.
public sealed class BCIcon
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string Source { get; set; } = "";
    public string? SourceName { get; set; }
    public string? Credit { get; set; }
    public string? License { get; set; }
    public string? Category { get; set; }
    public string? Author { get; set; }
    public string? Description { get; set; }
    public string? ThumbUrl { get; set; }
    public string? Url { get; set; }
    public double? Width { get; set; }
    public double? Height { get; set; }
    public string? SvgKey { get; set; }
    public string? Variant { get; set; }
    public List<BCTaxon>? Taxa { get; set; }

    /// What a tile shows on hover: the title, its categories, the collection, licence, file type and size, the credit.
    public string Info
    {
        get
        {
            var lines = new List<string> { Title };
            if (!string.IsNullOrEmpty(Variant)) lines.Add("Variant: " + Variant);
            var taxa = (Taxa ?? new()).Select(t => string.IsNullOrEmpty(t.Subcategory) ? t.Category : $"{t.Category} › {t.Subcategory}").ToList();
            if (taxa.Count > 0) lines.Add("Category: " + string.Join(", ", taxa));
            var last = new List<string> { SourceName ?? Source };
            if (!string.IsNullOrEmpty(License)) last.Add(License);
            last.Add(SvgKey != null ? "SVG" : "PNG");
            if (Width is > 0 && Height is > 0) last.Add($"{Width:0} × {Height:0} px");
            lines.Add(string.Join("  ·  ", last));
            if (!string.IsNullOrEmpty(Credit)) lines.Add(Credit);
            return string.Join("\n", lines);
        }
    }
}

public sealed class BCTaxon
{
    public string Category { get; set; } = "";
    public string Subcategory { get; set; } = "";
}

/// The `biocartoon` command line, installed with the engine's requirements: searches, downloads and the catalog.
public static class BioCartoonCli
{
    public const string MinimumVersion = "0.4.3";

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower, PropertyNameCaseInsensitive = true,
        NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowReadingFromString,
    };

    /// An explicit choice (MANIMBLE_BIOCARTOON), then the engine's Python environment, then PATH.
    public static string? Find(string? python)
    {
        var c = new List<string>();
        if (Environment.GetEnvironmentVariable("MANIMBLE_BIOCARTOON") is { Length: > 0 } e) c.Add(e);
        if (python != null && Path.GetDirectoryName(python) is string dir)
        {
            c.Add(Path.Combine(dir, "biocartoon.exe"));
            c.Add(Path.Combine(dir, "Scripts", "biocartoon.exe"));       // a base interpreter rather than a venv's
        }
        c.Add(Path.Combine(Paths.Base, "python", "Scripts", "biocartoon.exe"));
        foreach (var p in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            if (p.Length > 0) c.Add(Path.Combine(p.Trim('"'), "biocartoon.exe"));
        return c.FirstOrDefault(File.Exists);
    }

    /// Runs the program to completion and returns its stdout (its stderr becomes the error on failure).
    public static async Task<string> Run(string exe, IEnumerable<string> args, int timeoutSeconds = 120)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["PYTHONIOENCODING"] = "utf-8";
        psi.Environment["PYTHONUTF8"] = "1";
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("could not start " + exe);
        var outTask = p.StandardOutput.ReadToEndAsync();
        var errTask = p.StandardError.ReadToEndAsync();
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(timeoutSeconds));
        try { await p.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException) { try { p.Kill(true); } catch { } throw new TimeoutException("biocartoon took too long"); }
        var output = await outTask;
        var err = (await errTask).Trim();
        if (p.ExitCode != 0)
        {
            var last = err.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0 && !l.StartsWith("downloading"));
            throw new InvalidOperationException(last ?? $"biocartoon exited with status {p.ExitCode}");
        }
        return output;
    }

    public static async Task<string> Version(string exe)
    {
        using var doc = JsonDocument.Parse(await Run(exe, new[] { "--version", "--json" }));
        return doc.RootElement.TryGetProperty("version", out var v) ? v.GetString() ?? "" : "";
    }

    public static bool Supported(string version)
    {
        static int[] Parts(string s) => s.Split('.').Select(x => int.TryParse(new string(x.TakeWhile(char.IsDigit).ToArray()), out var n) ? n : 0).ToArray();
        var a = Parts(version); var b = Parts(MinimumVersion);
        for (int i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            int x = i < a.Length ? a[i] : 0, y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return true;
    }

    sealed class Hits { public List<BCIcon>? Icons { get; set; } }

    /// One page of `biocartoon search` (the first search downloads the catalog, so it may take a while).
    public static async Task<List<BCIcon>> Search(string exe, string query, string? category, string? source, string sort, int offset, int limit)
    {
        var args = new List<string> { "search" };
        if (query.Length > 0) args.Add(query);
        args.AddRange(new[] { "--icons", "--no-sql", "--json", "--limit", limit.ToString(), "--offset", offset.ToString(), "--sort", sort });
        if (category != null) args.AddRange(new[] { "--category", category });
        if (source != null) args.AddRange(new[] { "--source", source });
        return JsonSerializer.Deserialize<Hits>(await Run(exe, args, 300), Json)?.Icons ?? new();
    }

    public sealed class Category { public string Slug { get; set; } = ""; public string Name { get; set; } = ""; public int? Icons { get; set; } }
    public sealed class Collection { public string Source { get; set; } = ""; public string Name { get; set; } = ""; public int? Icons { get; set; } }

    public static async Task<List<Category>> Categories(string exe) =>
        JsonSerializer.Deserialize<List<Category>>(await Run(exe, new[] { "--categories", "--json" }), Json) ?? new();

    public static async Task<List<Collection>> Collections(string exe) =>
        JsonSerializer.Deserialize<List<Collection>>(await Run(exe, new[] { "--sources", "--json" }), Json) ?? new();

    /// The icon's PNG at `dest`, its longest side at most `maxSide` px.
    public static Task Fetch(string exe, string id, string dest, int maxSide = 1600) =>
        Run(exe, new[] { "fetch", id, "--out", dest, "--max-side", maxSide.ToString(), "--json" }, 180);

    /// The icon's SVG as published (fails when it has none).
    public static Task FetchSvg(string exe, string id, string dest) =>
        Run(exe, new[] { "fetch", id, "--svg", "--out", dest, "--json" }, 180);

    /// Crops a PNG's fully transparent margins in place and returns its size afterwards.
    public static Size TrimTransparentMargins(string path)
    {
        BitmapSource src;
        using (var fs = File.OpenRead(path))
        {
            var dec = BitmapDecoder.Create(fs, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
            src = new FormatConvertedBitmap(dec.Frames[0], PixelFormats.Bgra32, null, 0);
            src.Freeze();
        }
        int w = src.PixelWidth, h = src.PixelHeight, stride = w * 4;
        var px = new byte[stride * h];
        src.CopyPixels(px, stride, 0);
        int x0 = w, y0 = h, x1 = -1, y1 = -1;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
                if (px[y * stride + x * 4 + 3] > 0) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
        if (x1 < 0 || (x0 == 0 && y0 == 0 && x1 == w - 1 && y1 == h - 1)) return new Size(w, h);
        var crop = new CroppedBitmap(src, new Int32Rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1));
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(crop));
        var tmp = path + ".trim";
        using (var fs = File.Create(tmp)) enc.Save(fs);
        File.Move(tmp, path, overwrite: true);
        return new Size(x1 - x0 + 1, y1 - y0 + 1);
    }
}

/// The icon search panel, shown in the inspector's place (Insert > BioCartoon Icons…): search words, a category and
/// a collection, result tiles that insert their icon when clicked or dragged onto the slide.
public sealed class BioCartoonPanel : Border
{
    public const string DragFormat = "Manimble.BioCartoonIcon";
    public event Action<BCIcon>? IconChosen;
    public event Action? Closed;
    public event Action? InstallRequested;

    readonly TextBox search = new() { Margin = new Thickness(0, 0, 0, 6), ToolTip = "Search words (cell, mitochondria, pipette…)" };
    readonly ComboBox category = new() { Margin = new Thickness(0, 0, 4, 0), MinWidth = 120 };
    readonly ComboBox collection = new() { MinWidth = 110 };
    readonly TextBlock status = new() { FontSize = 12, Opacity = 0.7, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 4) };
    readonly WrapPanel tiles = new();
    readonly Button more = new() { Content = "Show more", Margin = new Thickness(0, 6, 0, 6), HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed };
    readonly StackPanel installBox = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 8, 0, 0) };
    readonly DispatcherTimer debounce = new() { Interval = TimeSpan.FromMilliseconds(350) };
    const int PageSize = 60;
    string? exe;
    int generation, offset;
    bool filtersLoaded, suppress;

    public string? Exe => exe;

    public BioCartoonPanel()
    {
        SetResourceReference(BackgroundProperty, SystemColors.WindowBrushKey);
        Padding = new Thickness(10, 6, 10, 6);
        var close = new Button { Content = "✕", Padding = new Thickness(6, 0, 6, 0), ToolTip = "Back to the inspector", HorizontalAlignment = HorizontalAlignment.Right };
        close.Click += (_, _) => Closed?.Invoke();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        DockPanel.SetDock(close, Dock.Right);
        head.Children.Add(close);
        head.Children.Add(new TextBlock { Text = "BIOCARTOON ICONS", FontSize = 11, FontWeight = FontWeights.SemiBold, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center });

        var filters = new DockPanel();
        var clear = new Button { Content = "Clear filters", FontSize = 11, Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(4, 0, 0, 0) };
        clear.Click += (_, _) => { suppress = true; category.SelectedIndex = 0; collection.SelectedIndex = 0; suppress = false; Restart(); };
        DockPanel.SetDock(clear, Dock.Right);
        filters.Children.Add(clear);
        var two = new Grid();
        two.ColumnDefinitions.Add(new ColumnDefinition()); two.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(collection, 1);
        two.Children.Add(category); two.Children.Add(collection);
        filters.Children.Add(two);

        installBox.Children.Add(new TextBlock
        {
            Text = "BioCartoon's command line is not installed in Manimble's Python environment. Install Dependencies sets it up, with the rest of what the engine needs.",
            TextWrapping = TextWrapping.Wrap, FontSize = 12, Margin = new Thickness(0, 0, 0, 6),
        });
        var install = new Button { Content = "Install Dependencies…", HorizontalAlignment = HorizontalAlignment.Left };
        install.Click += (_, _) => InstallRequested?.Invoke();
        installBox.Children.Add(install);

        var body = new StackPanel();
        body.Children.Add(tiles);
        body.Children.Add(more);
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Content = body };

        var top = new StackPanel();
        top.Children.Add(head);
        top.Children.Add(search);
        top.Children.Add(filters);
        top.Children.Add(status);
        top.Children.Add(installBox);
        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);
        root.Children.Add(scroll);
        Child = root;

        search.TextChanged += (_, _) => { debounce.Stop(); debounce.Start(); };
        search.KeyDown += (_, e) => { if (e.Key == Key.Enter) { debounce.Stop(); Restart(); } };
        debounce.Tick += (_, _) => { debounce.Stop(); Restart(); };
        category.SelectionChanged += (_, _) => { if (!suppress) Restart(); };
        collection.SelectionChanged += (_, _) => { if (!suppress) Restart(); };
        more.Click += (_, _) => _ = Load(append: true);
    }

    /// Opened (again): finds the command line, loads the filters once and shows the first page.
    public async Task Activate(string? python)
    {
        search.Focus();
        exe = BioCartoonCli.Find(python);
        if (exe == null) { ShowInstall(null); return; }
        try
        {
            var v = await BioCartoonCli.Version(exe);
            if (!BioCartoonCli.Supported(v)) { ShowInstall($"biocartoon {v} is installed; Manimble needs {BioCartoonCli.MinimumVersion} or newer."); return; }
        }
        catch (Exception e) { ShowInstall("biocartoon does not run: " + e.Message); return; }
        installBox.Visibility = Visibility.Collapsed;
        if (!filtersLoaded) await LoadFilters();
        if (tiles.Children.Count == 0) Restart();
    }

    void ShowInstall(string? why)
    {
        installBox.Visibility = Visibility.Visible;
        status.Text = why ?? "";
        tiles.Children.Clear();
        more.Visibility = Visibility.Collapsed;
    }

    async Task LoadFilters()
    {
        if (exe == null) return;
        suppress = true;
        category.Items.Clear(); collection.Items.Clear();
        category.Items.Add(new ComboBoxItem { Content = "All categories", Tag = null });
        collection.Items.Add(new ComboBoxItem { Content = "All collections", Tag = null });
        category.SelectedIndex = 0; collection.SelectedIndex = 0;
        try
        {
            foreach (var c in await BioCartoonCli.Categories(exe))
            {
                var sub = c.Slug.Contains('.');
                category.Items.Add(new ComboBoxItem { Content = (sub ? "    " : "") + c.Name + (c.Icons is int n ? $"  ({n})" : ""), Tag = c.Slug, FontWeight = sub ? FontWeights.Normal : FontWeights.SemiBold });
            }
            foreach (var s in await BioCartoonCli.Collections(exe))
                collection.Items.Add(new ComboBoxItem { Content = s.Name + (s.Icons is int n ? $"  ({n})" : ""), Tag = s.Source });
            filtersLoaded = true;
        }
        catch (Exception e) { status.Text = "Could not load the filters: " + e.Message; }
        finally { suppress = false; }
    }

    void Restart() { offset = 0; _ = Load(append: false); }

    async Task Load(bool append)
    {
        if (exe == null) return;
        var gen = ++generation;
        var q = search.Text.Trim();
        var cat = (category.SelectedItem as ComboBoxItem)?.Tag as string;
        var src = (collection.SelectedItem as ComboBoxItem)?.Tag as string;
        status.Text = append ? "Loading more…" : "Searching…";
        List<BCIcon> icons;
        try { icons = await BioCartoonCli.Search(exe, q, cat, src, q.Length > 0 ? "relevance" : "popular", offset, PageSize); }
        catch (Exception e) { if (gen == generation) status.Text = "Search failed: " + e.Message; return; }
        if (gen != generation) return;            // a newer search was started meanwhile
        if (!append) tiles.Children.Clear();
        foreach (var icon in icons) tiles.Children.Add(Tile(icon));
        offset += icons.Count;
        more.Visibility = icons.Count == PageSize ? Visibility.Visible : Visibility.Collapsed;
        status.Text = tiles.Children.Count == 0
            ? "No icons found. Try other words or clear the filters."
            : $"{tiles.Children.Count}{(icons.Count == PageSize ? "+" : "")} icons · click one to insert it, or drag it onto the slide";
    }

    FrameworkElement Tile(BCIcon icon)
    {
        var img = new Image { Width = 72, Height = 72, Stretch = Stretch.Uniform };
        var url = icon.ThumbUrl ?? icon.Url;
        if (url != null && Uri.TryCreate(url, UriKind.Absolute, out var u))
        {
            try
            {
                var bi = new BitmapImage();
                bi.BeginInit();
                bi.UriSource = u;
                bi.DecodePixelWidth = 144;
                bi.CacheOption = BitmapCacheOption.OnLoad;
                bi.EndInit();
                img.Source = bi;
            }
            catch { }
        }
        var b = new Button
        {
            Content = img, Width = 84, Height = 84, Margin = new Thickness(0, 0, 4, 4), Padding = new Thickness(4),
            ToolTip = new ToolTip { Content = new TextBlock { Text = icon.Info, TextWrapping = TextWrapping.Wrap, MaxWidth = 320 } },
            Background = new SolidColorBrush(Color.FromArgb(0x10, 0x80, 0x80, 0x80)),
        };
        ToolTipService.SetInitialShowDelay(b, 250);
        b.Click += (_, _) => IconChosen?.Invoke(icon);
        Point? down = null;
        b.PreviewMouseLeftButtonDown += (_, e) => down = e.GetPosition(b);
        b.PreviewMouseMove += (_, e) =>
        {
            if (down is not Point d || e.LeftButton != MouseButtonState.Pressed) return;
            var v = e.GetPosition(b) - d;
            if (Math.Abs(v.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(v.Y) < SystemParameters.MinimumVerticalDragDistance) return;
            down = null;
            DragDrop.DoDragDrop(b, new DataObject(DragFormat, JsonSerializer.Serialize(icon)), DragDropEffects.Copy);
        };
        b.PreviewMouseLeftButtonUp += (_, _) => down = null;
        var menu = new ContextMenu();
        var copyName = new MenuItem { Header = "Copy Name" };
        copyName.Click += (_, _) => System.Windows.Clipboard.SetText(icon.Title);
        var copyCredit = new MenuItem { Header = "Copy Credit", IsEnabled = !string.IsNullOrEmpty(icon.Credit) };
        copyCredit.Click += (_, _) => System.Windows.Clipboard.SetText(icon.Credit ?? icon.Title);
        var insert = new MenuItem { Header = "Insert" };
        insert.Click += (_, _) => IconChosen?.Invoke(icon);
        menu.Items.Add(insert); menu.Items.Add(new Separator()); menu.Items.Add(copyName); menu.Items.Add(copyCredit);
        b.ContextMenu = menu;
        return b;
    }

    public static BCIcon? FromDrag(IDataObject data) =>
        data.GetDataPresent(DragFormat) && data.GetData(DragFormat) is string json ? JsonSerializer.Deserialize<BCIcon>(json) : null;
}

public partial class MainWindow
{
    BioCartoonPanel? biocartoon;

    void BioCartoon_Click(object sender, RoutedEventArgs e) => _ = ShowBioCartoon();

    async Task ShowBioCartoon()
    {
        if (biocartoon == null)
        {
            biocartoon = new BioCartoonPanel();
            biocartoon.IconChosen += icon => InsertBioCartoon(icon, null);
            biocartoon.Closed += HideBioCartoon;
            biocartoon.InstallRequested += () => InstallDependencies_Click(this, new RoutedEventArgs());
            BioCartoonHost.Child = biocartoon;
        }
        if (SourcePane.Visibility != Visibility.Visible) { ShowSourceItem.IsChecked = true; ToggleSource_Click(this, new RoutedEventArgs()); }
        BioCartoonHost.Visibility = Visibility.Visible;
        await biocartoon.Activate(engine.Python);
    }

    void HideBioCartoon() => BioCartoonHost.Visibility = Visibility.Collapsed;

    /// Downloads the icon into the deck folder and inserts it as a picture centred on `at` (frame px; null: the
    /// slide's centre), its longer side 3 manim units: an SVG when it is published as one and the engine can draw it
    /// like the PNG, else the PNG with its transparent margins cropped.
    async void InsertBioCartoon(BCIcon icon, Point? at)
    {
        if (workspace is not { } ws || sceneName == null) { Toast("Open a deck and pick a slide first", error: true); return; }
        var exe = biocartoon?.Exe ?? BioCartoonCli.Find(engine.Python);
        if (exe == null) { Toast("BioCartoon's command line is not installed (File ▸ Install Dependencies…)", error: true); return; }
        var words = new string(icon.Title.ToLowerInvariant().Select(ch => char.IsLetterOrDigit(ch) ? ch : ' ').ToArray())
            .Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(6);
        var stem = string.Join("_", words);
        if (stem.Length == 0) stem = "biocartoon";
        var name = stem;
        for (int n = 1; File.Exists(Path.Combine(ws.Work, name + ".png")) || File.Exists(Path.Combine(ws.Work, name + ".svg")); n++) name = $"{stem}_{n}";
        var png = Path.Combine(ws.Work, name + ".png");
        var svg = Path.Combine(ws.Work, name + ".svg");
        var fs = canvas.FrameSize;
        var c = at ?? new Point(fs.Width / 2, fs.Height / 2);
        Busy(+1, $"Downloading {icon.Title}…");
        string dest; Size size;
        try
        {
            await BioCartoonCli.Fetch(exe, icon.Id, png);
            if (icon.SvgKey != null && await VectorCopy(exe, icon, png, svg) is Size v)
            {
                try { File.Delete(png); } catch { }
                dest = svg; size = v;
            }
            else
            {
                dest = png;
                size = await Task.Run(() => BioCartoonCli.TrimTransparentMargins(png));
            }
        }
        catch (Exception ex) { Busy(-1); Toast($"Could not download {icon.Title}: {ex.Message}", error: true); return; }
        Busy(-1);
        var half = 1.5 * canvas.UnitPx * Math.Min(1, size.Width / Math.Max(size.Height, 1));
        Insert("image", new JsonObject
        {
            ["file"] = Path.GetFileName(dest), ["path"] = dest,
            ["sx"] = c.X - half, ["sy"] = c.Y, ["ex"] = c.X + half, ["ey"] = c.Y,
        });
        if (!string.IsNullOrEmpty(icon.Credit)) Log.Note($"BioCartoon {icon.Id} inserted as {Path.GetFileName(dest)}: {icon.Credit}");
    }

    sealed class SvgPrepared { public bool Ok { get; set; } public double? Width { get; set; } public double? Height { get; set; } public string? Why { get; set; } }

    /// The icon's SVG made ready for manim (the engine's svg_icon), when manim draws it like the catalog's PNG.
    async Task<Size?> VectorCopy(string exe, BCIcon icon, string png, string dest)
    {
        var raw = Path.Combine(Path.GetTempPath(), $"biocartoon-{Guid.NewGuid():N}.svg");
        try
        {
            await BioCartoonCli.FetchSvg(exe, icon.Id, raw);
            var r = await engine.TryCall<SvgPrepared>("svg_icon", new JsonObject { ["svg"] = raw, ["png"] = png, ["out"] = dest });
            if (r is { Ok: true, Width: > 0, Height: > 0 }) return new Size(r.Width.Value, r.Height.Value);
            Log.Note($"BioCartoon {icon.Id} stays a PNG: {r?.Why ?? "?"}");
            return null;
        }
        catch (Exception e) { Log.Note($"BioCartoon {icon.Id} SVG: {e.Message}"); return null; }
        finally { try { File.Delete(raw); } catch { } }
    }

    /// An icon dragged from the panel onto the slide.
    void BioCartoonDropped(BCIcon icon, Point at) => InsertBioCartoon(icon, at);
}
