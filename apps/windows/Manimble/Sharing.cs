using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;

namespace Manimble;

public sealed class PagesResult
{
    public List<string>? Pages { get; set; }
    public string? Error { get; set; }
}

/// New Deck, export (PowerPoint, PDF, movie, Beamer, Python) and import (PowerPoint, Beamer), as File > Export To and
/// File > Import on the Mac. The engine does the work; this is the dialogs and the progress events.
public partial class MainWindow
{
    /// The name exports suggest: the deck folder's, or its project's when the folder is just "deck" or "slides".
    string DeckBaseName
    {
        get
        {
            if (workspace == null) return "presentation";
            var name = Path.GetFileName(workspace.Original);
            if (name.Equals("deck", StringComparison.OrdinalIgnoreCase) || name.Equals("slides", StringComparison.OrdinalIgnoreCase))
                name = Path.GetFileName(Path.GetDirectoryName(workspace.Original)) ?? name;
            return string.IsNullOrEmpty(name) ? "presentation" : name;
        }
    }

    // ================================================================ new deck

    async void NewDeck_Click(object sender, RoutedEventArgs e)
    {
        var themes = DeckTheme.All();
        var w = new Window
        {
            Title = "New Deck", Owner = this, Width = 520, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        var name = new TextBox { Text = "Untitled Deck" };
        var where = new TextBox { Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Manimble Decks") };
        var browse = new Button { Content = "Browse…", Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(6, 0, 0, 0) };
        browse.Click += (_, _) =>
        {
            var dlg = new OpenFolderDialog { Title = "Where should the new deck be created?" };
            if (dlg.ShowDialog(w) == true) where.Text = dlg.FolderName;
        };
        var theme = new ComboBox { ItemsSource = themes.Select(t => t.Name).ToList(), SelectedIndex = 0 };
        var ok = new Button { Content = "Create Deck", IsDefault = true, MinWidth = 100, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(6, 0, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90, Padding = new Thickness(10, 4, 10, 4) };
        ok.Click += (_, _) => w.DialogResult = true;
        Grid Row(string label, UIElement c, UIElement? extra = null)
        {
            var g = new Grid { Margin = new Thickness(0, 0, 0, 8) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var l = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
            g.Children.Add(l);
            Grid.SetColumn((UIElement)c, 1); g.Children.Add(c);
            if (extra != null) { Grid.SetColumn(extra, 2); g.Children.Add(extra); }
            return g;
        }
        w.Content = new StackPanel
        {
            Margin = new Thickness(18),
            Children =
            {
                new TextBlock { Text = "A folder with this name is made, holding the deck and an assets folder.", Opacity = 0.8, Margin = new Thickness(0, 0, 0, 12), TextWrapping = TextWrapping.Wrap },
                Row("Name", name), Row("In", where, browse), Row("Theme", theme),
                new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0), Children = { cancel, ok } },
            },
        };
        w.Loaded += (_, _) => { name.Focus(); name.SelectAll(); };
        if (w.ShowDialog() != true) return;
        var title = name.Text.Trim();
        if (title.Length == 0 || title.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0) { Toast("Choose a name that can be a folder name", error: true); return; }
        var dest = Path.Combine(where.Text.Trim(), title);
        var deck = Path.Combine(dest, "deck");
        if (Directory.Exists(deck)) { Toast($"{dest} already holds a deck: open it with File > Open Deck", error: true); return; }
        try
        {
            Directory.CreateDirectory(deck);
            Directory.CreateDirectory(Path.Combine(dest, "assets"));
            var t = themes.Count > 0 ? themes[Math.Max(0, theme.SelectedIndex)] : null;
            foreach (var (file, text) in NewDeckFiles(title, t)) File.WriteAllText(Path.Combine(deck, file), text);
        }
        catch (Exception ex) { Toast("Could not create the deck: " + ex.Message, error: true); return; }
        await OpenDeck(deck);
    }

    /// A title slide laid out like Slide > New Slide > Title Slide, on the theme's common.py and manim.cfg (the same
    /// files as the Mac app's newDeckFiles).
    static IEnumerable<(string, string)> NewDeckFiles(string title, DeckTheme? theme)
    {
        var quoted = "\"" + title.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        string common = theme != null ? File.ReadAllText(Path.Combine(Paths.Engine, "manimble", "themes", theme.Id + ".py")) : """"
            """Shared base class for the deck."""

            from pathlib import Path

            from manim import *
            from manim_slides import Slide

            ASSETS = Path(__file__).resolve().parent.parent / "assets"


            class Deck(Slide):
                skip_reversing = True

            """";
        var (s0, s1) = theme == null ? ("", ", color=GREY_B") : (", font=FONT, color=TEXT_COLOR", ", font=FONT, color=MUTED_COLOR");
        yield return ("common.py", common);
        yield return ("slides.py",
            "\"\"\"Slides of the deck.\"\"\"\n\nfrom common import *\n\n\nclass Title(Deck):\n    def construct(self):\n" +
            $"        title = Text({quoted}, font_size=64{s0}).move_to((0, 0.7, 0))  # manimble\n" +
            "        self.add(title)  # manimble\n" +
            $"        subtitle = Text(\"Subtitle\", font_size=32{s1}).move_to((0, -0.8, 0))  # manimble\n" +
            "        self.add(subtitle)  # manimble\n");
        yield return ("order.txt", "Title\n");
        yield return ("manim.cfg", $"[CLI]\nbackground_color = {theme?.Background ?? "#000000"}\npixel_width = 1280\npixel_height = 720\nframe_rate = 30\n");
    }

    // ================================================================ export

    /// A Save dialog for an export; null when cancelled.
    string? SaveTo(string title, string ext, string filter, string? name = null)
    {
        var dlg = new SaveFileDialog { Title = title, FileName = (name ?? DeckBaseName) + "." + ext, Filter = filter, AddExtension = true, DefaultExt = ext };
        return dlg.ShowDialog(this) == true ? dlg.FileName : null;
    }

    /// The options of a slide export: every build as its own slide, and editable text or pictures only.
    (bool builds, bool editable)? ExportOptions(string what, bool withEditable, string editableLabel)
    {
        var w = new Window
        {
            Title = what, Owner = this, Width = 440, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        var builds = new CheckBox { Content = "Every build as its own " + (what.Contains("PDF") ? "page" : "slide"), IsChecked = true };
        var mode = new ComboBox { ItemsSource = new[] { editableLabel, "Pictures only (exact look)" }, SelectedIndex = 0, Margin = new Thickness(0, 10, 0, 0) };
        var ok = new Button { Content = "Export", IsDefault = true, MinWidth = 90, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(6, 0, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90, Padding = new Thickness(10, 4, 10, 4) };
        ok.Click += (_, _) => w.DialogResult = true;
        var panel = new StackPanel { Margin = new Thickness(18), Children = { builds } };
        if (withEditable) panel.Children.Add(mode);
        panel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0), Children = { cancel, ok } });
        w.Content = panel;
        return w.ShowDialog() == true ? (builds.IsChecked == true, mode.SelectedIndex == 0) : null;
    }

    void ExportPowerPoint_Click(object sender, RoutedEventArgs e) => RunExport("pptx");
    void ExportBeamer_Click(object sender, RoutedEventArgs e) => RunExport("beamer");

    async void RunExport(string kind)
    {
        if (workspace == null) return;
        var ext = kind == "pptx" ? "pptx" : "tex";
        var what = kind == "pptx" ? "Export to PowerPoint" : "Export to Beamer";
        var path = SaveTo(what, ext, kind == "pptx" ? "PowerPoint|*.pptx" : "LaTeX Beamer|*.tex");
        if (path == null) return;
        var opts = ExportOptions(what, true, kind == "beamer" ? "Editable text and LaTeX formulas (recommended)" : "Editable text boxes (recommended)");
        if (opts is not { } o) return;
        await FinishEdits();
        Busy(+1, "Exporting…");
        exporting = true;
        EditResult? r = null; string? failure = null;
        try { r = await engine.Call<EditResult>("export", new JsonObject { ["kind"] = kind, ["path"] = path, ["builds"] = o.builds, ["editable"] = o.editable }); }
        catch (Exception ex) { failure = ex.Message; }
        if (r?.Ok != true) { exporting = false; Busy(-1); Toast(failure ?? r?.Error ?? "Could not start the export", error: true); }
    }

    bool exporting, exportingMovie;

    void OnExportEvent(JsonElement ev, bool movie)
    {
        var phase = ev.TryGetProperty("phase", out var ph) ? ph.GetString() : null;
        string Str(string k) => ev.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        int Int(string k) => ev.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;
        switch (phase)
        {
            case "building": Toast($"Building {Str("scene")} ({Math.Min(Int("done") + 1, Math.Max(1, Int("total")))} of {Int("total")})…"); break;
            case "encoding": Toast($"Encoding the movie ({Int("done")} of {Int("total")})…"); break;
            case "done":
            case "error":
            case "cancelled":
                if (movie ? exportingMovie : exporting) Busy(-1);
                if (movie) exportingMovie = false; else exporting = false;
                if (phase == "done")
                {
                    var path = Str("path");
                    var pdfError = Str("pdfError");
                    Toast("Saved " + Path.GetFileName(path) + (pdfError.Length > 0 ? " (LaTeX could not typeset the PDF; the .tex is there)" : ""));
                    if (File.Exists(path)) Tools.Reveal(path);
                }
                else if (phase == "error") Toast("The export failed: " + LastLine(Str("error")), error: true);
                else Toast("Cancelled");
                break;
        }
    }

    async void ExportPdf_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null || engine.Python == null) return;
        var path = SaveTo("Export to PDF", "pdf", "PDF|*.pdf");
        if (path == null) return;
        var opts = ExportOptions("Export to PDF", false, "");
        if (opts is not { } o) return;
        await FinishEdits();
        Busy(+1, "Rendering every slide for the PDF…");
        try
        {
            var r = await engine.Call<PagesResult>("pages", new JsonObject { ["builds"] = o.builds });
            if (r?.Pages is not { Count: > 0 } pages) { Toast(r?.Error ?? "Could not render the slides for the PDF", error: true); return; }
            // the pages into one PDF with Pillow, which the engine's Python has
            var list = Path.Combine(Path.GetTempPath(), "manimble-pdf-pages.json");
            File.WriteAllText(list, JsonSerializer.Serialize(new { pages, path }));
            var psi = new ProcessStartInfo(engine.Python) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add("import json,sys; from PIL import Image; a=json.load(open(sys.argv[1],encoding='utf-8')); " +
                                 "ims=[Image.open(p).convert('RGB') for p in a['pages']]; ims[0].save(a['path'], save_all=True, append_images=ims[1:], resolution=144)");
            psi.ArgumentList.Add(list);
            using var p = Process.Start(psi)!;
            var err = await p.StandardError.ReadToEndAsync();
            await p.WaitForExitAsync();
            if (p.ExitCode != 0) { Toast("Could not write the PDF: " + LastLine(err), error: true); return; }
            Toast("Saved " + Path.GetFileName(path) + $" ({pages.Count} pages)");
            Tools.Reveal(path);
        }
        catch (Exception ex) { Toast("Could not export the PDF: " + ex.Message, error: true); }
        finally { Busy(-1); }
    }

    async void ExportMovie_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null || state == null) return;
        var w = new Window
        {
            Title = "Export Movie", Owner = this, Width = 460, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        var which = new ComboBox { ItemsSource = new[] { "The whole show", $"Only the current slide ({sceneName})" }, SelectedIndex = 0 };
        var heights = new[] { 720, 1080, 1440, 2160 };
        var res = new ComboBox { ItemsSource = new[] { "720p", "1080p", "1440p", "2160p (4K)" }, SelectedIndex = Math.Max(0, Array.IndexOf(heights, Settings.Current.AnimationHeight)) };
        var hold = new TextBox { Text = "2", Width = 60 };
        var rates = new[] { 24, 30, 60 };
        var fps = new ComboBox { ItemsSource = rates.Select(r => r + " fps").ToList(), SelectedIndex = 1 };
        var ok = new Button { Content = "Export…", IsDefault = true, MinWidth = 90, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(6, 0, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90, Padding = new Thickness(10, 4, 10, 4) };
        ok.Click += (_, _) => w.DialogResult = true;
        StackPanel Row(string label, UIElement c) => new()
        {
            Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8),
            Children = { new TextBlock { Text = label, Width = 150, VerticalAlignment = VerticalAlignment.Center }, c },
        };
        w.Content = new StackPanel
        {
            Margin = new Thickness(18),
            Children =
            {
                new TextBlock { Text = "Every build plays, then holds its last frame. The movie has no sound.", Opacity = 0.8, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12) },
                Row("Slides", which), Row("Resolution", res), Row("Hold each build (s)", hold), Row("Frame rate", fps),
                new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0), Children = { cancel, ok } },
            },
        };
        if (w.ShowDialog() != true) return;
        var only = which.SelectedIndex == 1 ? sceneName : null;
        var path = SaveTo("Export Movie", "mp4", "MP4 movie|*.mp4", only != null ? DeckBaseName + "_" + only : null);
        if (path == null) return;
        await FinishEdits();
        var req = new JsonObject
        {
            ["path"] = path, ["height"] = heights[Math.Max(0, res.SelectedIndex)],
            ["hold"] = double.TryParse(hold.Text, out var hs) ? Math.Max(0, hs) : 2, ["fps"] = rates[Math.Max(0, fps.SelectedIndex)],
        };
        if (only != null) req["scenes"] = new JsonArray(only);
        Busy(+1, "Exporting the movie…");
        exportingMovie = true;
        EditResult? r = null; string? failure = null;
        try { r = await engine.Call<EditResult>("export_movie", req); } catch (Exception ex) { failure = ex.Message; }
        if (r?.Ok != true) { exportingMovie = false; Busy(-1); Toast(failure ?? r?.Error ?? "Could not start the movie export", error: true); }
    }

    async void ExportPython_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null) return;
        var path = SaveTo("Export as one Python file", "py", "Python|*.py");
        if (path == null) return;
        var hidden = MessageBox.Show(this, "Include the hidden slides too?", "Export Python", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
        await FinishEdits();
        var r = await engine.TryCall<EditResult>("export_python", new JsonObject { ["path"] = path, ["hidden"] = hidden });
        if (r?.Ok == true) { Toast("Saved " + Path.GetFileName(path)); Tools.Reveal(path); }
        else Toast(r?.Error ?? "Could not export the Python file", error: true);
    }

    // ================================================================ import

    void ImportPowerPoint_Click(object sender, RoutedEventArgs e) => RunImport("PowerPoint", "PowerPoint|*.pptx");
    void ImportBeamer_Click(object sender, RoutedEventArgs e) => RunImport("Beamer", "LaTeX Beamer|*.tex");

    string? importDest;

    async void RunImport(string label, string filter)
    {
        if (!engine.IsRunning) return;
        var open = new OpenFileDialog { Title = $"Choose a {label} presentation to import", Filter = filter };
        if (open.ShowDialog(this) != true) return;
        var src = open.FileName;
        var save = new SaveFileDialog
        {
            Title = "Where should the new deck be created? A folder with this name is made.",
            FileName = Path.GetFileNameWithoutExtension(src), Filter = "Folder|*.",
        };
        if (save.ShowDialog(this) != true) return;
        var dest = Path.Combine(Path.GetDirectoryName(save.FileName)!, Path.GetFileNameWithoutExtension(save.FileName));
        if (Directory.Exists(dest) && Directory.EnumerateFileSystemEntries(dest).Any()) { Toast(dest + " already exists and is not empty", error: true); return; }
        if (label == "Beamer") await OfferLatexPackages(src);
        importDest = dest;
        Busy(+1, "Importing…");
        EditResult? r = null; string? failure = null;
        try { r = await engine.Call<EditResult>("import", new JsonObject { ["src"] = src, ["dest"] = dest }); } catch (Exception ex) { failure = ex.Message; }
        if (r?.Ok != true) { importDest = null; Busy(-1); Toast(failure ?? r?.Error ?? "Could not start the import", error: true); }
    }

    /// Beamer: the LaTeX packages the file uses that this TeX lacks, offered for installing (never on its own).
    async Task OfferLatexPackages(string src)
    {
        try
        {
            var m = await engine.Call<JsonElement>("latex_missing", new JsonObject { ["src"] = src });
            if (!m.TryGetProperty("missing", out var miss) || miss.GetArrayLength() == 0) return;
            var files = miss.EnumerateArray().Select(x => x.GetString() ?? "").ToList();
            if (MessageBox.Show(this, $"This presentation uses LaTeX packages that are not installed: {string.Join(", ", files)}.\n\nInstall them now?",
                                "Import Beamer", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
            Busy(+1, "Installing LaTeX packages…");
            try { await engine.Raw("latex_install", new JsonObject { ["files"] = new JsonArray(files.Select(f => (JsonNode)f).ToArray()) }); }
            finally { Busy(-1); }
        }
        catch { }
    }

    async void OnImportEvent(JsonElement ev)
    {
        var phase = ev.TryGetProperty("phase", out var ph) ? ph.GetString() : null;
        switch (phase)
        {
            case "building":
                var done = ev.TryGetProperty("done", out var d) && d.ValueKind == JsonValueKind.Number ? d.GetInt32() : 0;
                var total = ev.TryGetProperty("total", out var t) && t.ValueKind == JsonValueKind.Number ? t.GetInt32() : 0;
                Toast($"Importing slide {Math.Min(done + 1, Math.Max(1, total))} of {total}…");
                break;
            case "done":
            {
                if (importDest != null) Busy(-1);
                importDest = null;
                var deck = ev.TryGetProperty("deck", out var dk) ? dk.GetString() : null;
                var warnings = ev.TryGetProperty("warnings", out var wn) && wn.ValueKind == JsonValueKind.Array ? wn.GetArrayLength() : 0;
                Toast("Imported" + (warnings > 0 ? $" with {warnings} warning(s): see the engine log" : ""));
                if (deck != null) await OpenDeck(deck);
                break;
            }
            case "error":
                if (importDest != null) Busy(-1);
                importDest = null;
                Toast("The import failed: " + (ev.TryGetProperty("error", out var er) ? LastLine(er.GetString() ?? "") : ""), error: true);
                break;
        }
    }
}
