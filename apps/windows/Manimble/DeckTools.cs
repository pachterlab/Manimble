using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;

namespace Manimble;

public sealed class FindMatch
{
    public string Scene { get; set; } = "";
    public int Oid { get; set; }
    public int Stop { get; set; }
    public int Index { get; set; }
    public string Kind { get; set; } = "";
    public string Value { get; set; } = "";
    public string Match { get; set; } = "";
    public bool Editable { get; set; }
}

public sealed class FindResult
{
    public bool? Ok { get; set; }
    public List<FindMatch> Matches { get; set; } = new();
    public string? Error { get; set; }
    public int? Count { get; set; }
    public int? Skipped { get; set; }
    public string? Message { get; set; }
}

public sealed class BackgroundInfo
{
    public string? Mode { get; set; }
    public string? Color { get; set; }
    public string? Image { get; set; }
    public double? Transparency { get; set; }
    public string? Default { get; set; }
}

public sealed class PageNumberInfo
{
    public bool On { get; set; }
    public string Pos { get; set; } = "DR";
    public int Start { get; set; } = 1;
    public bool Skip { get; set; }
    public bool Total { get; set; }
    public int Size { get; set; } = 24;
    public bool? Sub { get; set; }
}

public sealed class ThemeInfo
{
    public bool? Ok { get; set; }
    public string? Theme { get; set; }
    public bool? Crosses { get; set; }
    public string? Error { get; set; }
    public string? Message { get; set; }
}

/// A deck theme: a complete common.py in the engine's manimble/themes folder.
public sealed record DeckTheme(string Id, string Name, string Background, string Text)
{
    public static List<DeckTheme> All()
    {
        var dir = Path.Combine(Paths.Engine, "manimble", "themes");
        var outp = new List<DeckTheme>();
        if (!Directory.Exists(dir)) return outp;
        static string? Constant(string name, string src) =>
            Regex.Match(src, $"^{name}\\s*=\\s*\"([^\"]*)\"", RegexOptions.Multiline) is { Success: true } m ? m.Groups[1].Value : null;
        foreach (var f in Directory.EnumerateFiles(dir, "*.py"))
        {
            var src = File.ReadAllText(f);
            if (Constant("THEME", src) is not { } name) continue;
            outp.Add(new DeckTheme(Path.GetFileNameWithoutExtension(f), name, Constant("BACKGROUND", src) ?? "#000000", Constant("TEXT_COLOR", src) ?? "#FFFFFF"));
        }
        // Midnight (the old black default) first, then by name, as on the Mac
        return outp.OrderBy(t => t.Id == "midnight" ? 0 : 1).ThenBy(t => t.Name).ToList();
    }
}

public partial class MainWindow
{
    // ================================================================ find and replace

    List<FindMatch> findMatches = new();
    int findIndex = -1;
    readonly DispatcherTimer findTimer = new() { Interval = TimeSpan.FromMilliseconds(300) };
    bool findHooked;

    JsonObject FindOptions() => new()
    {
        ["query"] = FindBox.Text, ["case"] = FindCase.IsChecked == true, ["word"] = FindWord.IsChecked == true,
        ["regex"] = FindRegex.IsChecked == true, ["notes"] = FindNotes.IsChecked == true,
    };

    void OpenFind(bool replace)
    {
        if (workspace == null) return;
        if (!findHooked) { findTimer.Tick += async (_, _) => { findTimer.Stop(); await RunFind(keepIndex: false); }; findHooked = true; }
        FindBar.Visibility = Visibility.Visible;
        ReplaceRow.Visibility = replace ? Visibility.Visible : Visibility.Collapsed;
        // the selected text is what to look for
        if (FindBox.Text.Length == 0 && SelectedObj is { IsText: true } o && !o.Value.Contains('\n')) FindBox.Text = o.Value;
        FindBox.Focus();
        FindBox.SelectAll();
    }

    void Find_Click(object sender, RoutedEventArgs e) => OpenFind(false);
    void FindReplace_Click(object sender, RoutedEventArgs e) => OpenFind(true);
    void FindClose_Click(object sender, RoutedEventArgs e) => CloseFind();

    void CloseFind()
    {
        FindBar.Visibility = Visibility.Collapsed;
        canvas.Focus();
    }

    void FindBox_TextChanged(object sender, TextChangedEventArgs e) { findTimer.Stop(); findTimer.Start(); }
    void FindOption_Click(object sender, RoutedEventArgs e) { findTimer.Stop(); findTimer.Start(); }

    void FindBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { _ = StepFind(Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? -1 : +1); e.Handled = true; }
        else if (e.Key == Key.Escape) { CloseFind(); e.Handled = true; }
    }

    void ReplaceBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { ReplaceOne_Click(sender, e); e.Handled = true; }
        else if (e.Key == Key.Escape) { CloseFind(); e.Handled = true; }
    }

    async Task RunFind(bool keepIndex)
    {
        if (FindBox.Text.Length == 0) { findMatches = new(); findIndex = -1; FindCount.Text = ""; return; }
        FindResult? r;
        try { r = await engine.Call<FindResult>("find", FindOptions()); }
        catch (Exception ex) { FindCount.Text = "error"; Toast(ex.Message, error: true); return; }
        if (r?.Error != null) { FindCount.Text = "error"; Toast(r.Error, error: true); return; }
        findMatches = r?.Matches ?? new();
        if (!keepIndex)
        {
            // the first match at or after the slide on screen
            var order = slides.Select(s => s.Name).ToList();
            var here = order.IndexOf(sceneName ?? "");
            findIndex = findMatches.FindIndex(m => order.IndexOf(m.Scene) >= here);
            if (findIndex < 0 && findMatches.Count > 0) findIndex = 0;
        }
        else findIndex = Math.Min(findIndex, findMatches.Count - 1);
        UpdateFindCount();
        if (findIndex >= 0) await ShowMatch(findMatches[findIndex]);
    }

    void UpdateFindCount() =>
        FindCount.Text = findMatches.Count == 0 ? (FindBox.Text.Length > 0 ? "no match" : "") : $"{findIndex + 1} of {findMatches.Count}";

    async Task StepFind(int d)
    {
        if (FindBar.Visibility != Visibility.Visible) { OpenFind(false); return; }
        if (findMatches.Count == 0) { await RunFind(keepIndex: false); return; }
        findIndex = (findIndex + d + findMatches.Count) % findMatches.Count;
        UpdateFindCount();
        await ShowMatch(findMatches[findIndex]);
    }

    void FindNext_Click(object sender, RoutedEventArgs e) => _ = StepFind(+1);
    void FindPrev_Click(object sender, RoutedEventArgs e) => _ = StepFind(-1);

    async Task ShowMatch(FindMatch m)
    {
        if (m.Scene != sceneName) await SelectScene(m.Scene);
        if (m.Scene != sceneName) return;
        if (m.Stop != stopIndex) ShowStop(m.Stop);
        if (m.Kind is "notes" or "buildNotes")
        {
            canvas.Select(Array.Empty<int>());
            Toast(m.Kind == "notes" ? "Found in the slide's speaker notes" : $"Found in the notes of build {m.Stop + 1}");
            return;
        }
        canvas.Select(new[] { m.Oid });
        if (!m.Editable) Toast("This text is made by code: change it in the source pane");
    }

    void ReplaceOne_Click(object sender, RoutedEventArgs e)
    {
        if (findIndex < 0 || findIndex >= findMatches.Count) return;
        var m = findMatches[findIndex];
        if (!m.Editable && m.Kind is not ("notes" or "buildNotes")) { Toast("This text is made by code and can't be replaced here", error: true); return; }
        var req = FindOptions();
        req["replacement"] = ReplaceBox.Text;
        req["scene"] = m.Scene; req["oid"] = m.Oid; req["index"] = m.Index; req["stop"] = m.Stop; req["kind"] = m.Kind;
        Submit(async () =>
        {
            Busy(+1, "Replacing…");
            EditResult? r = null; string? failure = null;
            try { r = await engine.Call<EditResult>("replace", req); } catch (Exception ex) { failure = ex.Message; }
            Busy(-1);
            if (r?.Ok == true) Toast("Replaced"); else Toast(failure ?? r?.Error ?? "Could not replace", error: true);
            if (sceneName != null) await LoadScene(sceneName, keepStop: true);
            await ReloadState();
            await RunFind(keepIndex: true);
        });
    }

    void ReplaceAll_Click(object sender, RoutedEventArgs e)
    {
        if (FindBox.Text.Length == 0) return;
        var req = FindOptions();
        req["replacement"] = ReplaceBox.Text;
        req["all"] = true;
        Submit(async () =>
        {
            Busy(+1, "Replacing…");
            FindResult? r = null; string? failure = null;
            try { r = await engine.Call<FindResult>("replace", req); } catch (Exception ex) { failure = ex.Message; }
            Busy(-1);
            if (r?.Ok == true)
                Toast($"Replaced {r.Count ?? 0}" + (r.Skipped is > 0 ? $" · {r.Skipped} made by code left alone" : ""));
            else Toast(failure ?? r?.Error ?? "Could not replace", error: true);
            if (sceneName != null) await LoadScene(sceneName, keepStop: true);
            await ReloadState();
            await RunFind(keepIndex: false);
        });
    }

    // ================================================================ zoom, grid, snapping

    void ZoomIn_Click(object sender, RoutedEventArgs e) => canvas.ZoomBy(1.25);
    void ZoomOut_Click(object sender, RoutedEventArgs e) => canvas.ZoomBy(0.8);
    void ZoomFit_Click(object sender, RoutedEventArgs e) => canvas.Zoom = null;
    void ZoomActual_Click(object sender, RoutedEventArgs e) => canvas.Zoom = 1;
    void Grid_Click(object sender, RoutedEventArgs e) => canvas.ShowGrid = GridItem.IsChecked;
    void Snap_Click(object sender, RoutedEventArgs e) => canvas.SnapEnabled = SnapItem.IsChecked;

    // ================================================================ rulers and guides

    void Ruler_Click(object sender, RoutedEventArgs e) => SetRulers(RulerItem.IsChecked);

    void SetRulers(bool on)
    {
        RulerItem.IsChecked = on;
        canvas.ShowRulers = on;
        Settings.Current.ShowRulers = on;
        Settings.Current.Save();
    }

    void AddVerticalGuide_Click(object sender, RoutedEventArgs e) => AddGuide(vertical: true);
    void AddHorizontalGuide_Click(object sender, RoutedEventArgs e) => AddGuide(vertical: false);

    void AddGuide(bool vertical)
    {
        if (sceneName == null || !canvas.HasSlide) return;
        canvas.AddGuide(vertical);
        Toast("Guide added at the centre: drag it into place, or off the slide to remove it");
    }

    void ClearGuides_Click(object sender, RoutedEventArgs e) => canvas.ClearGuides();

    string? GuidesKey => workspace?.Original.ToLowerInvariant();

    void SaveGuides()
    {
        if (GuidesKey is not string key) return;
        if (canvas.UserGuides.Count == 0) Settings.Current.Guides.Remove(key);
        else Settings.Current.Guides[key] = canvas.UserGuides.Select(g => new[] { g.vertical ? 1.0 : 0.0, g.pos }).ToList();
        Settings.Current.Save();
    }

    void LoadGuides()
    {
        var saved = GuidesKey is string key && Settings.Current.Guides.TryGetValue(key, out var l) ? l : new List<double[]>();
        canvas.SetGuides(saved.Where(g => g.Length == 2).Select(g => (g[0] > 0.5, g[1])));
    }

    // ================================================================ themes

    void BuildThemeMenu()
    {
        ThemeMenu.Items.Clear();
        foreach (var t in DeckTheme.All())
        {
            var swatch = new Border
            {
                Width = 26, Height = 16, CornerRadius = new CornerRadius(3), BorderBrush = Brushes.Gray, BorderThickness = new Thickness(0.5),
                Background = new SolidColorBrush(TryColor(t.Background) ?? Colors.Black),
                Child = new TextBlock
                {
                    Text = "Aa", FontSize = 9, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center, Foreground = new SolidColorBrush(TryColor(t.Text) ?? Colors.White),
                },
            };
            var mi = new MenuItem { Header = t.Name, Icon = swatch, Tag = t.Id };
            mi.Click += (_, _) => ApplyTheme(t);
            ThemeMenu.Items.Add(mi);
        }
        ThemeMenu.IsEnabled = ThemeMenu.Items.Count > 0;
    }

    void ApplyTheme(DeckTheme t)
    {
        if (workspace == null) return;
        var current = sceneName ?? "";
        Submit(async () =>
        {
            var info = await engine.TryCall<ThemeInfo>("theme", new JsonObject { ["op"] = "get", ["theme"] = t.Id, ["current"] = current });
            bool flip = false;
            if (info?.Crosses == true)
            {
                var r = MessageBox.Show(this,
                    $"{t.Name} has a {(TryColor(t.Background) is Color c && (c.R + c.G + c.B) > 384 ? "light" : "dark")} background. " +
                    "Flip the colours of what is already on the slides too, so dark text stays readable?\n\n" +
                    "Yes: flip the colours too.  No: only switch the theme.",
                    "Apply Theme", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
                if (r == MessageBoxResult.Cancel) return;
                flip = r == MessageBoxResult.Yes;
            }
            Busy(+1, $"Applying {t.Name}…");
            EditResult? res = null; string? failure = null;
            try { res = await engine.Call<EditResult>("theme", new JsonObject { ["theme"] = t.Id, ["current"] = current, ["flip"] = flip }); }
            catch (Exception ex) { failure = ex.Message; }
            Busy(-1);
            if (res?.Ok == true) Toast($"Applied the {t.Name} theme"); else Toast(failure ?? res?.Error ?? "Could not apply the theme", error: true);
            await ReloadState();
            if (sceneName != null) await LoadScene(sceneName, keepStop: true);
        });
    }

    // ================================================================ dark mode

    void DarkMode_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null || (sender as FrameworkElement)?.Tag is not string mode) return;
        var text = mode == "dark"
            ? "Turn the whole deck dark: light backgrounds become dark and colours are adjusted to stay readable. This is one undo step."
            : "Invert the colours of the whole deck (black becomes white and so on). This is one undo step.";
        if (MessageBox.Show(this, text, mode == "dark" ? "Apply Dark Mode" : "Apply Inverted Colors",
                            MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        var current = sceneName ?? "";
        Submit(async () =>
        {
            Busy(+1, mode == "dark" ? "Applying dark mode…" : "Inverting colours…");
            EditResult? r = null; string? failure = null;
            try { r = await engine.Call<EditResult>("darkmode", new JsonObject { ["mode"] = mode, ["current"] = current }); }
            catch (Exception ex) { failure = ex.Message; }
            Busy(-1);
            if (r?.Ok == true) Toast("Saved · " + (r.Message ?? "colours changed")); else Toast(failure ?? r?.Error ?? "That did not work", error: true);
            await ReloadState();
            if (sceneName != null) await LoadScene(sceneName, keepStop: true);
        });
    }

    // ================================================================ background

    async void Background_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null || sceneName == null) return;
        var name = sceneName;
        BackgroundInfo? info;
        try { info = await engine.Call<BackgroundInfo>("background", new JsonObject { ["op"] = "get", ["scene"] = name }); }
        catch (Exception ex) { Toast("Could not read the background: " + ex.Message, error: true); return; }
        info ??= new BackgroundInfo();

        var w = new Window
        {
            Title = "Background", Owner = this, Width = 440, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        var colorMode = new RadioButton { Content = "Colour", IsChecked = info.Mode != "image", GroupName = "bg", Margin = new Thickness(0, 0, 0, 4) };
        var colorBox = new TextBox { Text = info.Color ?? info.Default ?? "#000000", Width = 110, Margin = new Thickness(24, 0, 8, 8) };
        var imageMode = new RadioButton { Content = "Picture", IsChecked = info.Mode == "image", GroupName = "bg", Margin = new Thickness(0, 4, 0, 4) };
        string? imageFile = info.Image;
        var imageLabel = new TextBlock { Text = info.Image ?? "(none chosen)", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0), Opacity = 0.8 };
        var choose = new Button { Content = "Choose…", Padding = new Thickness(10, 2, 10, 2) };
        choose.Click += (_, _) =>
        {
            var dlg = new OpenFileDialog { Filter = "Images|*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.webp" };
            if (dlg.ShowDialog(w) != true) return;
            var fileName = Path.GetFileName(dlg.FileName);
            var dest = Path.Combine(workspace.Work, fileName);
            try { if (!File.Exists(dest)) File.Copy(dlg.FileName, dest); } catch (Exception ex) { MessageBox.Show(w, ex.Message); return; }
            imageFile = fileName; imageLabel.Text = fileName; imageMode.IsChecked = true;
        };
        var transparency = new Slider { Minimum = 0, Maximum = 1, Value = info.Transparency ?? 0, Width = 200, TickFrequency = 0.1, IsSnapToTickEnabled = false };
        var allSlides = new CheckBox { Content = "Apply to every slide", Margin = new Thickness(0, 12, 0, 0) };
        string? action = null;
        Button B(string text, string act, bool def = false)
        {
            var b = new Button { Content = text, MinWidth = 80, Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4), IsDefault = def };
            b.Click += (_, _) => { action = act; w.DialogResult = act != "cancel"; };
            return b;
        }
        var cancel = B("Cancel", "cancel"); cancel.IsCancel = true;
        w.Content = new StackPanel
        {
            Margin = new Thickness(18),
            Children =
            {
                colorMode,
                new StackPanel { Orientation = Orientation.Horizontal, Children = { colorBox, new TextBlock { Text = "#RRGGBB", Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center } } },
                imageMode,
                new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(24, 0, 0, 8), Children = { choose, imageLabel } },
                new StackPanel { Orientation = Orientation.Horizontal, Children = { new TextBlock { Text = "Transparency", Width = 90, VerticalAlignment = VerticalAlignment.Center }, transparency } },
                allSlides,
                new DockPanel
                {
                    Margin = new Thickness(0, 16, 0, 0), LastChildFill = false,
                    Children = { B("Reset to Default", "reset"), new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right } },
                },
                new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0), Children = { cancel, B("Apply", "set", true) } },
            },
        };
        if (w.ShowDialog() != true || action == null) return;
        var req = new JsonObject { ["scene"] = name, ["all"] = allSlides.IsChecked == true };
        if (action == "reset") req["op"] = "reset";
        else
        {
            req["op"] = "set";
            req["transparency"] = Math.Round(transparency.Value, 2);
            if (imageMode.IsChecked == true)
            {
                if (imageFile == null) { Toast("Choose a picture first", error: true); return; }
                req["mode"] = "image"; req["file"] = imageFile;
            }
            else
            {
                var hex = colorBox.Text.Trim();
                if (!hex.StartsWith('#')) hex = "#" + hex;
                if (hex.Length != 7 || TryColor(hex) == null) { Toast("A colour is #RRGGBB", error: true); return; }
                req["mode"] = "color"; req["color"] = hex.ToUpperInvariant();
            }
        }
        Submit(async () =>
        {
            Busy(+1, "Rendering…");
            EditResult? r = null; string? failure = null;
            try { r = await engine.Call<EditResult>("background", req); } catch (Exception ex) { failure = ex.Message; }
            Busy(-1);
            if (r?.Ok == true) Toast("Saved · " + (r.Message ?? "background")); else Toast(failure ?? r?.Error ?? "Could not change the background", error: true);
            await ReloadState();
            if (sceneName != null) await LoadScene(sceneName, keepStop: true);
        });
    }

    // ================================================================ slide numbers

    async void SlideNumbers_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null || sceneName == null) return;
        var name = sceneName;
        PageNumberInfo? info;
        try { info = await engine.Call<PageNumberInfo>("page_numbers", new JsonObject { ["op"] = "get" }); }
        catch (Exception ex) { Toast("Could not read the slide numbers: " + ex.Message, error: true); return; }
        info ??= new PageNumberInfo();
        if (!info.On) { info.Skip = true; info.Total = true; info.Size = 24; info.Start = 1; }

        var w = new Window
        {
            Title = "Slide Numbers", Owner = this, Width = 420, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        var pos = new ComboBox { Width = 160, ItemsSource = new[] { "Bottom right", "Bottom center", "Bottom left" } };
        var codes = new[] { "DR", "DOWN", "DL" };
        pos.SelectedIndex = Math.Max(0, Array.IndexOf(codes, info.Pos.ToUpperInvariant()));
        var start = new TextBox { Text = info.Start.ToString(), Width = 60 };
        var size = new TextBox { Text = info.Size.ToString(), Width = 60 };
        var skip = new CheckBox { Content = "No number on the first slide", IsChecked = info.Skip, Margin = new Thickness(0, 8, 0, 0) };
        var total = new CheckBox { Content = "Show the total (3 / 10)", IsChecked = info.Total, Margin = new Thickness(0, 4, 0, 0) };
        var sub = new CheckBox { Content = "Count builds too (3 / 10 · 1/3)", IsChecked = info.Sub == true, Margin = new Thickness(0, 4, 0, 0) };
        string? action = null;
        Button B(string text, string act, bool def = false)
        {
            var b = new Button { Content = text, MinWidth = 80, Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4), IsDefault = def };
            b.Click += (_, _) => { action = act; w.DialogResult = act != "cancel"; };
            return b;
        }
        var cancel = B("Cancel", "cancel"); cancel.IsCancel = true;
        StackPanel Row(string label, UIElement c) => new()
        {
            Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6),
            Children = { new TextBlock { Text = label, Width = 90, VerticalAlignment = VerticalAlignment.Center }, c },
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        if (info.On) buttons.Children.Add(B("Remove", "remove"));
        buttons.Children.Add(cancel);
        buttons.Children.Add(B(info.On ? "Update" : "Add", "set", true));
        w.Content = new StackPanel
        {
            Margin = new Thickness(18),
            Children =
            {
                new TextBlock { Text = "Every slide of the show gets a number. The numbers follow along when slides are added, deleted or reordered.",
                                TextWrapping = TextWrapping.Wrap, Opacity = 0.8, Margin = new Thickness(0, 0, 0, 12) },
                Row("Position", pos), Row("Start at", start), Row("Font size", size), skip, total, sub, buttons,
            },
        };
        if (w.ShowDialog() != true || action == null) return;
        JsonObject req = action == "remove"
            ? new JsonObject { ["op"] = "remove" }
            : new JsonObject
            {
                ["op"] = "set", ["scene"] = name, ["pos"] = codes[Math.Max(0, pos.SelectedIndex)],
                ["start"] = int.TryParse(start.Text, out var s0) ? s0 : 1, ["size"] = int.TryParse(size.Text, out var z) ? Math.Max(6, z) : 24,
                ["skip"] = skip.IsChecked == true, ["total"] = total.IsChecked == true, ["sub"] = sub.IsChecked == true,
            };
        Submit(async () =>
        {
            Busy(+1, "Rendering…");
            EditResult? r = null; string? failure = null;
            try { r = await engine.Call<EditResult>("page_numbers", req); } catch (Exception ex) { failure = ex.Message; }
            Busy(-1);
            if (r?.Ok == true) Toast("Saved · " + (r.Message ?? "slide numbers")); else Toast(failure ?? r?.Error ?? "Could not change the slide numbers", error: true);
            await ReloadState();
            if (sceneName != null) await LoadScene(sceneName, keepStop: true);
        });
    }
}
