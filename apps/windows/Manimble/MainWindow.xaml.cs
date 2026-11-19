using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using ICSharpCode.AvalonEdit.Highlighting;
using Microsoft.Win32;

namespace Manimble;

/// One row of the slide navigator.
public sealed class SlideItem : INotifyPropertyChanged
{
    public string Name { get; init; } = "";
    public bool Unused { get; init; }
    int number; string? thumbPath; string badge = ""; bool hidden; bool current; bool error;
    public int Number { get => number; set { number = value; On(nameof(Number)); } }
    public BitmapSource? Thumb => Images.Load(thumbPath, 320);
    public double ThumbHeight => 112;
    public string Badge { get => badge; set { if (badge != value) { badge = value; On(nameof(Badge)); } } }
    public double Opacity => hidden || Unused ? 0.45 : 1;
    public Brush Ring => error ? (Brush)Application.Current.Resources["ErrorBrush"]
        : current ? (Brush)Application.Current.Resources["SelectionBrush"] : new SolidColorBrush(Color.FromArgb(0x40, 0x80, 0x80, 0x80));

    public void Update(SceneSummary s, int n, bool isCurrent)
    {
        Number = n;
        if (thumbPath != s.Thumb) { thumbPath = s.Thumb; On(nameof(Thumb)); }
        hidden = s.Hidden == true; On(nameof(Opacity));
        error = s.Status == "error"; current = isCurrent; On(nameof(Ring));
        Badge = s.Status switch
        {
            "rendering" => "rendering…",
            "queued" or "pending" or "stale" => s.Thumb == null ? "waiting" : "",
            "error" => "error",
            _ => s.Stops > 1 ? $"{s.Stops} builds" : "",
        };
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    void On(string p) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(p));
}

public partial class MainWindow : Window
{
    readonly Engine engine = new();
    readonly SlideCanvas canvas = new();
    readonly ObservableCollection<SlideItem> slides = new();
    readonly DispatcherTimer refreshTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    readonly DispatcherTimer nudgeTimer = new() { Interval = TimeSpan.FromMilliseconds(400) };
    readonly SemaphoreSlim editQueue = new(1, 1);

    Workspace? workspace;
    StateInfo? state;
    SceneData? scene;
    string? sceneName;
    int stopIndex;
    string? shownDir;               // render folder of the frames on screen
    string? sourceBase;             // the slide's source as last shown, what edit_source checks against
    bool suppressList, suppressSource;
    int busy;
    int loadSeq;
    bool closingConfirmed;
    Vector pendingNudge;
    int queuedEdits;

    public MainWindow()
    {
        InitializeComponent();
        CanvasHost.Content = canvas;
        SlideList.ItemsSource = slides;
        SourceEditor.SyntaxHighlighting = HighlightingManager.Instance.GetDefinition("Python");
        SourceEditor.Options.ConvertTabsToSpaces = true;
        SourceEditor.Options.IndentationSize = 4;
        canvas.MoveCommitted += OnMoveCommitted;
        canvas.TextCommitted += (oid, text) => Submit(() => RunEdit(new JsonObject { ["oid"] = oid, ["op"] = "text", ["value"] = text }));
        canvas.PlaceholderCommitted += OnPlaceholderCommitted;
        canvas.SelectionChanged += RebuildInspector;
        engine.EventReceived += OnEngineEvent;
        engine.Exited += code =>
        {
            Toast($"The Manimble engine stopped (exit code {code}). See View ▸ Show Engine Log.", error: true);
            Log.Note("engine exited " + code);
        };
        refreshTimer.Tick += async (_, _) => await ReloadState();
        nudgeTimer.Tick += (_, _) => FlushNudge();
        PreviewKeyDown += OnKey;
        Closing += OnClosing;
        var s = Settings.Current;
        if (s.WindowWidth is double w && s.WindowHeight is double h) { Width = w; Height = h; }
        if (s.WindowMaximized) WindowState = WindowState.Maximized;
        ShowSourceItem.IsChecked = s.ShowSource;
        ApplySourceVisibility();
        RefreshRecent();
        UpdateTitle();
    }

    // ================================================================ startup

    public async void Start(string? deck)
    {
        Workspace.CleanStale();
        Busy(+1, "Looking for Python with Manim…");
        var python = await Tools.FindPython();
        Busy(-1);
        if (python == null)
        {
            WelcomeText.Text = "Manimble needs a Python with Manim. Run apps\\windows\\install_manimble.ps1 from the Manimble " +
                               "repository to install one, or choose a Python that has manim with File ▸ Choose Python…";
            Toast("No Python with Manim found", error: true);
            return;
        }
        StartEngine(python);
        if (deck != null) await OpenDeck(deck);
    }

    void StartEngine(string python)
    {
        try
        {
            engine.Start(python);
            Toast("Engine started · " + python);
            if (!Tools.HasLatex()) Toast("No LaTeX found: slides with formulas (MathTex, Tex) will not render until one is installed (MiKTeX or TinyTeX)", error: true);
        }
        catch (Exception e)
        {
            Toast("Could not start the engine: " + e.Message, error: true);
        }
    }

    // ================================================================ status

    void Toast(string msg, bool error = false)
    {
        StatusText.Text = msg.Replace("\n", " ");
        StatusText.Foreground = error ? (Brush)Application.Current.Resources["ErrorBrush"] : SystemColors.ControlTextBrush;
        if (error) Log.Note("toast: " + msg);
    }

    void Busy(int delta, string? text = null)
    {
        busy = Math.Max(0, busy + delta);
        BusyBar.Visibility = busy > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (text != null) Toast(text);
    }

    void UpdateTitle()
    {
        if (workspace == null) { Title = "Manimble"; ModifiedText.Text = ""; return; }
        bool modified = false;
        try { modified = workspace.IsModified; } catch { }
        Title = $"{(modified ? "• " : "")}{Path.GetFileName(workspace.Original)} — Manimble";
        ModifiedText.Text = modified ? "Edited · Ctrl+S saves to the original" : "Saved";
        UndoItem.Header = state?.CanUndo == true && state.UndoLabel.Length > 0 ? $"_Undo {state.UndoLabel}" : "_Undo";
        UndoItem.IsEnabled = state?.CanUndo == true;
        RedoItem.IsEnabled = state?.CanRedo == true;
    }

    // ================================================================ opening and saving decks

    async Task OpenDeck(string path)
    {
        if (!engine.IsRunning) { Toast("The engine is not running", error: true); return; }
        path = Path.GetFullPath(path);
        if (!Directory.Exists(path)) { Toast("No deck folder at " + path, error: true); return; }
        if (!Directory.EnumerateFiles(path, "*.py").Any())
        {
            // a project folder whose deck lives in deck\ (as examples\hello does)
            var inner = Path.Combine(path, "deck");
            if (Directory.Exists(inner) && Directory.EnumerateFiles(inner, "*.py").Any()) path = inner;
            else { Toast("That folder has no Python slides (.py files)", error: true); return; }
        }
        if (!await ConfirmDiscard()) return;
        Workspace ws;
        try { ws = new Workspace(path); }
        catch (Exception e) { Toast("Could not copy the deck: " + e.Message, error: true); return; }
        var old = workspace;
        Busy(+1, "Opening " + path + "…");
        try
        {
            await engine.Raw("open", new JsonObject { ["deck"] = ws.Work, ["cache"] = Workspace.CacheDir(ws.Original) });
        }
        catch (Exception e)
        {
            Busy(-1);
            ws.Discard();
            Toast("Could not open the deck: " + e.Message, error: true);
            return;
        }
        Busy(-1);
        old?.Discard();
        workspace = ws;
        state = null; scene = null; sceneName = null; shownDir = null;
        slides.Clear();
        WelcomePanel.Visibility = Visibility.Collapsed;
        canvas.ShowMessage("Rendering…");
        Settings.Current.AddRecent(ws.Original);
        RefreshRecent();
        Toast("Opened " + ws.Original);
        await ReloadState();
        if (slides.Count > 0) await SelectScene(slides[0].Name);
        refreshTimer.Start();
        UpdateTitle();
    }

    /// Unsaved edits: Save, Don't Save or Cancel. True to go on.
    async Task<bool> ConfirmDiscard()
    {
        if (workspace == null) return true;
        await FinishEdits();
        if (!workspace.IsModified) return true;
        var r = MessageBox.Show(this, $"Save the changes to {Path.GetFileName(workspace.Original)} before closing it?",
                                "Manimble", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (r == MessageBoxResult.Cancel) return false;
        if (r == MessageBoxResult.Yes) return SaveToOriginal();
        return true;
    }

    bool SaveToOriginal()
    {
        if (workspace == null) return false;
        if (!workspace.IsModified) { Toast("Nothing to save"); return true; }
        if (!workspace.OriginalMissing && workspace.ConflictFiles is { Count: > 0 } conflicts)
        {
            var r = MessageBox.Show(this, $"{string.Join(", ", conflicts)} was modified outside Manimble since this copy was made. Overwrite it with your edits?",
                                    "Manimble", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
            if (r != MessageBoxResult.OK) return false;
        }
        try { workspace.Save(); Toast("Saved to " + workspace.Original); UpdateTitle(); return true; }
        catch (Exception e) { MessageBox.Show(this, e.Message, "Could not save", MessageBoxButton.OK, MessageBoxImage.Error); return false; }
    }

    /// Every edit asked for is in the deck's files and verified, so Save and Close act on what the user saw.
    async Task FinishEdits()
    {
        if (workspace == null) return;
        FlushNudge();
        canvas.CommitEdit();
        while (queuedEdits > 0) await Task.Delay(50);
        try { await engine.Raw("settle"); } catch { }
    }

    void RefreshRecent()
    {
        RecentMenu.Items.Clear();
        foreach (var d in Settings.Current.RecentDecks.Where(Directory.Exists))
        {
            var mi = new MenuItem { Header = d.Replace("_", "__"), Tag = d };
            mi.Click += Recent_Click;
            RecentMenu.Items.Add(mi);
        }
        RecentMenu.IsEnabled = RecentMenu.Items.Count > 0;
        WelcomeRecent.ItemsSource = Settings.Current.RecentDecks.Where(Directory.Exists).Take(6).ToList();
    }

    async void Recent_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is string d) await OpenDeck(d);
    }

    async void OpenDeck_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFolderDialog { Title = "Open a deck folder (the folder with the slides' .py files)" };
        if (dlg.ShowDialog(this) == true) await OpenDeck(dlg.FolderName);
    }

    async void OpenExample_Click(object sender, RoutedEventArgs e)
    {
        var candidates = new List<string>();
        if (Paths.CheckoutRoot is { } root) candidates.Add(Path.Combine(root, "examples", "hello", "deck"));
        candidates.Add(Path.Combine(AppContext.BaseDirectory, "examples", "hello", "deck"));
        var src = candidates.FirstOrDefault(Directory.Exists);
        if (src == null) { Toast("The example deck is not installed", error: true); return; }
        // a copy in Documents, so the example can be edited and saved
        var dest = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Manimble Examples", "hello", "deck");
        if (!Directory.Exists(dest))
        {
            Directory.CreateDirectory(dest);
            foreach (var f in Directory.EnumerateFiles(src)) File.Copy(f, Path.Combine(dest, Path.GetFileName(f)));
        }
        await OpenDeck(dest);
    }

    void Save_Click(object sender, RoutedEventArgs e) => _ = SaveAsync();
    async Task SaveAsync() { await FinishEdits(); SaveToOriginal(); }

    async void SaveCopy_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null) return;
        var dlg = new OpenFolderDialog { Title = "Choose where to put the copy of the deck" };
        if (dlg.ShowDialog(this) != true) return;
        await FinishEdits();
        var dest = Path.Combine(dlg.FolderName, Path.GetFileName(workspace.Original) + " copy");
        try { workspace.SaveCopy(dest); Toast("Saved a copy in " + dest); }
        catch (Exception ex) { Toast("Could not save the copy: " + ex.Message, error: true); }
    }

    async void Revert_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null) return;
        await FinishEdits();
        if (!workspace.IsModified) { Toast("No changes to revert"); return; }
        if (MessageBox.Show(this, "Throw away every change since the deck was last saved?", "Revert to Original",
                            MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        try { workspace.Revert(); } catch (Exception ex) { Toast("Could not revert: " + ex.Message, error: true); return; }
        try { await engine.Raw("clear_history"); } catch { }
        Toast("Reverted to the original");
        await ReloadState();
        if (sceneName != null) await LoadScene(sceneName, keepStop: true);
    }

    void RevealDeck_Click(object sender, RoutedEventArgs e) { if (workspace != null) Tools.Reveal(workspace.Original); }
    void RevealWork_Click(object sender, RoutedEventArgs e) { if (workspace != null) Tools.Reveal(workspace.Work); }

    async void ChoosePython_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog { Title = "Choose a Python that has Manim", Filter = "python.exe|python.exe|Programs|*.exe" };
        if (dlg.ShowDialog(this) != true) return;
        Busy(+1, "Checking that this Python can import manim…");
        var ok = await Tools.CanImportManim(dlg.FileName);
        Busy(-1);
        if (!ok) { Toast(dlg.FileName + " cannot import manim and Pillow", error: true); return; }
        Settings.Current.Python = dlg.FileName;
        Settings.Current.Save();
        var deck = workspace?.Original;
        if (workspace != null && !await ConfirmDiscard()) return;
        workspace?.Discard(); workspace = null;
        engine.Stop();
        StartEngine(dlg.FileName);
        if (deck != null) await OpenDeck(deck);
    }

    void Exit_Click(object sender, RoutedEventArgs e) => Close();

    async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (closingConfirmed) return;
        e.Cancel = true;
        if (!await ConfirmDiscard()) return;
        var s = Settings.Current;
        s.WindowMaximized = WindowState == WindowState.Maximized;
        if (WindowState == WindowState.Normal) { s.WindowWidth = Width; s.WindowHeight = Height; }
        s.Save();
        refreshTimer.Stop();
        Hide();                                   // the engine and the working copy go away behind the scenes
        var ws = workspace;
        await Task.Run(() => { engine.Stop(); ws?.Discard(); });
        closingConfirmed = true;
        Close();
    }

    // ================================================================ state and the navigator

    async Task ReloadState()
    {
        if (workspace == null || !engine.IsRunning) return;
        StateInfo? st;
        try { st = await engine.Call<StateInfo>("state", new JsonObject { ["current"] = sceneName ?? "" }); }
        catch { return; }
        if (st == null) return;
        state = st;
        var rows = st.Scenes.ToList();
        if (slides.Select(s => s.Name).SequenceEqual(rows.Select(r => r.Name)))
        {
            for (int i = 0; i < rows.Count; i++) slides[i].Update(rows[i], i + 1, rows[i].Name == sceneName);
        }
        else
        {
            suppressList = true;
            slides.Clear();
            for (int i = 0; i < rows.Count; i++)
            {
                var item = new SlideItem { Name = rows[i].Name };
                item.Update(rows[i], i + 1, rows[i].Name == sceneName);
                slides.Add(item);
            }
            SlideList.SelectedItem = slides.FirstOrDefault(s => s.Name == sceneName);
            suppressList = false;
        }
        UpdateTitle();
        // the slide on screen is gone (an agent renamed it): show the one now in its place
        if (sceneName != null && busy == 0 && queuedEdits == 0 && !rows.Any(r => r.Name == sceneName))
        {
            if (rows.Count > 0) await SelectScene(rows[0].Name);
            else { sceneName = null; scene = null; canvas.ShowMessage("This deck has no slides"); }
            return;
        }
        // the slide on screen was re-rendered from outside (an edit in another editor): show it
        if (sceneName != null && busy == 0 && queuedEdits == 0 && rows.FirstOrDefault(r => r.Name == sceneName) is { Status: "ready", Thumb: { } t }
            && shownDir != null && !string.Equals(Path.GetDirectoryName(t), shownDir, StringComparison.OrdinalIgnoreCase)
            && !canvas.IsEditingText)
            await LoadScene(sceneName, keepStop: true, keepOverrides: true);
    }

    async Task SelectScene(string name)
    {
        if (name != sceneName && SourceDirty)
        {
            Toast("Apply or undo the source edits before changing slides (Ctrl+Enter applies)", error: true);
            suppressList = true; SlideList.SelectedItem = slides.FirstOrDefault(s => s.Name == sceneName); suppressList = false;
            return;
        }
        CommitNotes();
        canvas.CommitEdit();
        sceneName = name;
        stopIndex = 0;
        suppressList = true;
        SlideList.SelectedItem = slides.FirstOrDefault(s => s.Name == name);
        if (SlideList.SelectedItem != null) SlideList.ScrollIntoView(SlideList.SelectedItem);
        suppressList = false;
        foreach (var (s, i) in slides.Select((s, i) => (s, i)))
            if (state != null && i < state.Scenes.Count) s.Update(state.Scenes[i], i + 1, s.Name == name);
        await LoadScene(name, keepStop: false);
    }

    async Task LoadScene(string name, bool keepStop, bool keepOverrides = false)
    {
        var seq = ++loadSeq;
        Busy(+1);
        SceneData? sc;
        try { sc = await engine.Call<SceneData>("scene", new JsonObject { ["name"] = name }); }
        catch (Exception e) { Busy(-1); if (name == sceneName) Toast("Could not load the slide: " + e.Message, error: true); return; }
        Busy(-1);
        if (sc == null || name != sceneName || seq != loadSeq) return;
        if (sc.Status == "cancelled") { Toast("cancelled"); return; }
        if (sc.Status != "ready" || sc.Stops is not { Count: > 0 })
        {
            scene = sc;
            if (canvas.Scene?.Name != name || canvas.Scene?.Stops == null) canvas.SetScene(sc, 0);
            Toast("Slide failed to render: " + LastLine(sc.Error ?? "unknown error"), error: true);
            ShowSource(sc, sc.Error);
            RebuildBuilds();
            return;
        }
        await FollowRenumbering(name, sc);
        scene = sc;
        var dir = Path.GetDirectoryName(sc.Stops[0].Png);
        shownDir = dir;
        stopIndex = keepStop ? Math.Min(stopIndex, sc.Stops.Count - 1) : 0;
        canvas.SetScene(sc, stopIndex, keepOverrides);
        if (!NotesBox.IsKeyboardFocusWithin) NotesBox.Text = sc.Notes ?? "";
        ShowSource(sc, null);
        RebuildBuilds();
        RebuildInspector();
    }

    /// A render that numbers objects differently (one added or removed above the others): the selection follows
    /// its objects, so the next edit changes what the user picked.
    async Task FollowRenumbering(string name, SceneData sc)
    {
        if (canvas.Scene?.Name != name || shownDir == null || canvas.Selected.Count == 0) return;
        var from = Path.GetFileName(shownDir);
        var to = Path.GetFileName(Path.GetDirectoryName(sc.Stops![0].Png));
        if (from == to) return;
        var ids = new JsonArray(canvas.Selected.Select(i => (JsonNode)i).ToArray());
        var map = await engine.TryCall<OidMap>("resolve_oids", new JsonObject { ["scene"] = name, ["from"] = from, ["to"] = to, ["oids"] = ids });
        if (map == null) return;
        var now = canvas.Selected.Select(i => map.Map.TryGetValue(i.ToString(), out var m) ? (m != null && int.TryParse(m, out var k) ? k : (int?)null) : i)
                                 .Where(i => i != null).Select(i => i!.Value).ToList();
        canvas.Selected.Clear();
        canvas.Selected.AddRange(now);
    }

    static string LastLine(string s) => s.Split('\n').Where(l => l.Trim().Length > 0).LastOrDefault()?.Trim() ?? s;

    void RebuildBuilds()
    {
        BuildStrip.Items.Clear();
        var n = scene?.Stops?.Count ?? 0;
        BuildsBar.Visibility = n > 1 ? Visibility.Visible : Visibility.Collapsed;
        for (int i = 0; i < n; i++)
        {
            int k = i;
            var b = new ToggleButton
            {
                Content = (i + 1).ToString(), MinWidth = 30, Margin = new Thickness(2, 0, 2, 0), Padding = new Thickness(6, 1, 6, 1),
                IsChecked = i == stopIndex, ToolTip = $"Build {i + 1} of {n} (Page Up / Page Down)",
            };
            b.Click += (_, _) => ShowStop(k);
            BuildStrip.Items.Add(b);
        }
    }

    void ShowStop(int i)
    {
        if (scene?.Stops == null) return;
        stopIndex = Math.Clamp(i, 0, scene.Stops.Count - 1);
        canvas.SetStop(stopIndex);
        foreach (var (b, k) in BuildStrip.Items.OfType<ToggleButton>().Select((b, k) => (b, k))) b.IsChecked = k == stopIndex;
    }

    async void SlideList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (suppressList || SlideList.SelectedItem is not SlideItem s || s.Name == sceneName) return;
        await SelectScene(s.Name);
    }

    void SlideList_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Delete) { DeleteSlide_Click(sender, e); e.Handled = true; }
    }

    // drag a slide in the navigator to reorder the show
    Point? listDown;
    void SlideList_PreviewDown(object sender, MouseButtonEventArgs e) => listDown = e.GetPosition(SlideList);
    void SlideList_PreviewMove(object sender, MouseEventArgs e)
    {
        if (listDown is not Point d || e.LeftButton != MouseButtonState.Pressed) return;
        if ((e.GetPosition(SlideList) - d).Length < 8) return;
        listDown = null;
        if (ItemAt(d) is SlideItem item) DragDrop.DoDragDrop(SlideList, item.Name, DragDropEffects.Move);
    }

    SlideItem? ItemAt(Point p)
    {
        var el = SlideList.InputHitTest(p) as DependencyObject;
        while (el != null && el is not ListBoxItem) el = VisualTreeHelper.GetParent(el);
        return (el as ListBoxItem)?.DataContext as SlideItem;
    }

    void SlideList_Drop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(typeof(string)) is not string name) return;
        var target = ItemAt(e.GetPosition(SlideList));
        var from = slides.ToList().FindIndex(s => s.Name == name);
        var index = target == null ? slides.Count - 1 : slides.IndexOf(target);
        if (from < 0 || index == from) return;
        SlideOp(new JsonObject { ["op"] = "reorder", ["scene"] = name, ["index"] = index });
    }

    // ================================================================ edits

    /// Runs edit operations strictly one after another.
    void Submit(Func<Task> work)
    {
        queuedEdits++;
        _ = Task.Run(async () =>
        {
            await editQueue.WaitAsync();
            try { await Dispatcher.InvokeAsync(work).Task.Unwrap(); }
            catch (Exception e) { Log.Note("edit: " + e); }
            finally
            {
                editQueue.Release();
                await Dispatcher.InvokeAsync(() => queuedEdits--);
            }
        });
    }

    string? Seen => shownDir != null ? Path.GetFileName(shownDir) : null;

    async Task<EditResult?> RunEdit(JsonObject req, bool reload = true)
    {
        var name = sceneName;
        if (name == null) return null;
        req["scene"] ??= name;
        req["stop"] ??= stopIndex;
        if (Seen is { } seen && req["seen"] == null) req["seen"] = seen;
        Busy(+1, "Rendering…");
        EditResult? r = null; string? failure = null;
        try { r = await engine.Call<EditResult>("edit", req); }
        catch (Exception e) { failure = e.Message; }
        Busy(-1);
        if (r?.Ok == true)
        {
            var msg = r.Message == "no change" ? "No change" : "Saved · " + r.Message;
            if (r.Siblings is int n) msg += $" ({n} similar objects share this line; all changed)";
            Toast(msg);
        }
        else Toast(failure ?? r?.Error ?? "edit failed", error: true);
        if (reload && req["scene"]?.GetValue<string>() == sceneName)
        {
            await LoadScene(name, keepStop: true, keepOverrides: true);
            if (req["oid"] is JsonNode o) canvas.ClearOverride(o.GetValue<int>());
        }
        await ReloadState();
        return r;
    }

    /// Several edits as one undo step (a move of a multi-object selection).
    async Task AsOneUndoStep(string label, Func<Task> body)
    {
        int? mark = null;
        try { mark = (await engine.Call<EditResult>("undo_mark"))?.Mark; } catch { }
        await body();
        if (mark is int m)
        {
            try { await engine.Raw("undo_merge", new JsonObject { ["mark"] = m, ["label"] = label }); } catch { }
            await ReloadState();
        }
    }

    void OnMoveCommitted(List<int> oids, double dx, double dy)
    {
        var ids = oids.ToList();
        Submit(async () =>
        {
            if (ids.Count == 1)
                await RunEdit(new JsonObject { ["oid"] = ids[0], ["op"] = "move", ["dx"] = dx, ["dy"] = dy });
            else
                await AsOneUndoStep("Move", async () =>
                {
                    foreach (var oid in ids)
                        await RunEdit(new JsonObject { ["oid"] = oid, ["op"] = "move", ["dx"] = dx, ["dy"] = dy, ["optimistic"] = false }, reload: false);
                    if (sceneName != null) await LoadScene(sceneName, keepStop: true);
                });
        });
    }

    void Nudge(double dx, double dy)
    {
        if (canvas.Selected.Count == 0) return;
        canvas.Nudge(dx, dy);
        pendingNudge += new Vector(dx, dy);
        nudgeTimer.Stop();
        nudgeTimer.Start();
    }

    void FlushNudge()
    {
        nudgeTimer.Stop();
        if (pendingNudge.Length < 0.01 || canvas.Selected.Count == 0) { pendingNudge = new Vector(); return; }
        var v = pendingNudge;
        pendingNudge = new Vector();
        OnMoveCommitted(canvas.Selected.ToList(), v.X, v.Y);
    }

    void DeleteSelection()
    {
        var ids = canvas.Selected.ToList();
        if (ids.Count == 0) return;
        canvas.Select(Array.Empty<int>());
        Submit(async () =>
        {
            if (ids.Count == 1) await RunEdit(new JsonObject { ["oid"] = ids[0], ["op"] = "delete" });
            else await AsOneUndoStep("Delete", async () =>
            {
                // highest first: deleting one object can renumber the ones after it
                foreach (var oid in ids.OrderByDescending(i => i))
                    await RunEdit(new JsonObject { ["oid"] = oid, ["op"] = "delete" }, reload: false);
                if (sceneName != null) await LoadScene(sceneName, keepStop: true);
            });
        });
    }

    void OnPlaceholderCommitted(Placeholder ph, string text)
    {
        var name = sceneName;
        if (name == null) return;
        Submit(async () =>
        {
            Busy(+1, "Rendering…");
            var r = await engine.TryCall<EditResult>("placeholder", new JsonObject { ["scene"] = name, ["line"] = ph.Line, ["text"] = text });
            Busy(-1);
            if (r?.Ok == true) Toast("Saved · " + r.Message); else Toast(r?.Error ?? "could not add the text", error: true);
            await LoadScene(name, keepStop: true);
            await ReloadState();
        });
    }

    async void Undo_Click(object sender, RoutedEventArgs e) => await UndoRedo("undo");
    async void Redo_Click(object sender, RoutedEventArgs e) => await UndoRedo("redo");

    async Task UndoRedo(string cmd)
    {
        if (workspace == null) return;
        await FinishEdits();
        var r = await engine.TryCall<EditResult>(cmd);
        if (r?.Ok == true) Toast((cmd == "undo" ? "Undid " : "Redid ") + (r.Label ?? ""));
        else { Toast(r?.Error ?? "Nothing to " + cmd, error: r?.Error != null); return; }
        await ReloadState();
        if (sceneName != null && state?.Scenes.Any(s => s.Name == sceneName) == true) await LoadScene(sceneName, keepStop: true);
        else if (slides.Count > 0) await SelectScene(slides[0].Name);
    }

    void Delete_Click(object sender, RoutedEventArgs e) => DeleteSelection();
    void SelectAll_Click(object sender, RoutedEventArgs e) => canvas.SelectAll();
    void EditText_Click(object sender, RoutedEventArgs e) { if (canvas.Selected.Count == 1) canvas.BeginTextEdit(canvas.Selected[0]); }

    // ================================================================ slide operations

    void SlideOp(JsonObject req)
    {
        Submit(async () =>
        {
            req["scene"] ??= sceneName;
            Busy(+1, "Working…");
            var r = await engine.TryCall<EditResult>("slide", req);
            Busy(-1);
            if (r?.Ok != true) { Toast(r?.Error ?? "That did not work", error: true); return; }
            Toast(r.Message ?? "Done");
            await ReloadState();
            var next = r.Select ?? sceneName;
            if (next != null && slides.Any(s => s.Name == next)) await SelectScene(next);
            else if (sceneName != null) await LoadScene(sceneName, keepStop: true);
        });
    }

    void NewSlide_Click(object sender, RoutedEventArgs e) { if (sceneName != null) SlideOp(new JsonObject { ["op"] = "new", ["layout"] = "title_content" }); }
    void DuplicateSlide_Click(object sender, RoutedEventArgs e) { if (sceneName != null) SlideOp(new JsonObject { ["op"] = "duplicate" }); }
    void MoveSlideUp_Click(object sender, RoutedEventArgs e) { if (sceneName != null) SlideOp(new JsonObject { ["op"] = "up" }); }
    void MoveSlideDown_Click(object sender, RoutedEventArgs e) { if (sceneName != null) SlideOp(new JsonObject { ["op"] = "down" }); }

    void DeleteSlide_Click(object sender, RoutedEventArgs e)
    {
        if (sceneName == null) return;
        if (MessageBox.Show(this, $"Delete the slide {sceneName}? Undo brings it back.", "Delete Slide",
                            MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        SlideOp(new JsonObject { ["op"] = "delete" });
    }

    void HideSlide_Click(object sender, RoutedEventArgs e)
    {
        if (sceneName == null) return;
        var hidden = state?.Scenes.FirstOrDefault(s => s.Name == sceneName)?.Hidden == true;
        SlideOp(new JsonObject { ["op"] = hidden ? "unhide" : "hide" });
    }

    async void PrevSlide_Click(object sender, RoutedEventArgs e) => await StepSlide(-1);
    async void NextSlide_Click(object sender, RoutedEventArgs e) => await StepSlide(+1);
    void PrevBuild_Click(object sender, RoutedEventArgs e) => StepBuild(-1);
    void NextBuild_Click(object sender, RoutedEventArgs e) => StepBuild(+1);

    async Task StepSlide(int d)
    {
        var i = slides.ToList().FindIndex(s => s.Name == sceneName);
        var j = Math.Clamp(i + d, 0, slides.Count - 1);
        if (j != i && j >= 0) await SelectScene(slides[j].Name);
    }

    void StepBuild(int d)
    {
        if (scene?.Stops == null) return;
        var n = stopIndex + d;
        if (n >= 0 && n < scene.Stops.Count) ShowStop(n);
    }

    // ================================================================ notes

    void NotesBox_LostFocus(object sender, KeyboardFocusChangedEventArgs e) => CommitNotes();

    void CommitNotes()
    {
        if (scene == null || sceneName == null || NotesBox.Text == (scene.Notes ?? "")) return;
        var name = sceneName; var text = NotesBox.Text;
        scene.Notes = text;
        Submit(async () =>
        {
            var r = await engine.TryCall<EditResult>("notes", new JsonObject { ["op"] = "set", ["scene"] = name, ["text"] = text });
            if (r?.Ok == true) Toast("Saved the speaker notes"); else Toast(r?.Error ?? "Could not save the notes", error: true);
            await ReloadState();
        });
    }

    // ================================================================ inspector

    void RebuildInspector()
    {
        var sel = canvas.Selected;
        if (scene == null || sel.Count == 0)
        {
            SelTitle.Text = "Nothing selected";
            SelDetail.Text = "Click an object on the slide. Drag to move it, double-click text to retype it, Delete removes it.";
            SelFields.Visibility = Visibility.Collapsed;
            return;
        }
        if (sel.Count > 1)
        {
            SelTitle.Text = $"{sel.Count} objects";
            SelDetail.Text = "Drag or use the arrow keys to move them together.";
            SelFields.Visibility = Visibility.Collapsed;
            return;
        }
        var o = scene.Obj(sel[0]);
        if (o == null) { SelTitle.Text = "Object"; SelDetail.Text = ""; SelFields.Visibility = Visibility.Collapsed; return; }
        var kind = o.Kind switch
        {
            "text" => "Text", "tex" => "Formula", "image" => "Picture", "line" => "Line", "table" => "Table",
            "shape" => o.Shape ?? "Shape", _ => o.Kind,
        };
        SelTitle.Text = o.IsText ? $"{kind}: {Short(o.Value)}" : kind;
        var details = new List<string> { "made at " + o.Loc };
        if (o.FontSize is double fs) details.Add($"font size {fs:0.#}");
        if (o.Shared is { } sh) details.Add($"shared {sh.Name}, used {sh.Uses}×");
        if (o.TextOk == false && o.TextNote != null) details.Add(o.TextNote);
        if (o.Siblings > 1) details.Add($"{o.Siblings} similar objects come from this line");
        SelDetail.Text = string.Join(" · ", details);
        SelFields.Visibility = Visibility.Visible;
        ColorBox.Text = o.Color ?? "";
        FontBox.Text = o.Font ?? "";
        FontBox.IsEnabled = o.Kind == "text";
        // the source pane shows where the object was made
        HighlightSourceLine(o.Loc);
    }

    static string Short(string s) { s = s.Replace('\n', ' '); return s.Length > 60 ? s[..60] + "…" : s; }

    void ColorBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || canvas.Selected.Count == 0) return;
        var v = ColorBox.Text.Trim();
        if (!v.StartsWith('#')) v = "#" + v;
        if (v.Length != 7) { Toast("A colour is #RRGGBB", error: true); return; }
        var ids = canvas.Selected.ToList();
        Submit(() => AsOneUndoStep("Color", async () =>
        {
            foreach (var oid in ids) await RunEdit(new JsonObject { ["oid"] = oid, ["op"] = "color", ["value"] = v.ToUpperInvariant() }, reload: oid == ids[^1]);
        }));
        canvas.Focus();
        e.Handled = true;
    }

    void FontBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || canvas.Selected.Count != 1) return;
        var v = FontBox.Text.Trim();
        Submit(async () => { await RunEdit(new JsonObject { ["oid"] = canvas.Selected[0], ["op"] = "font", ["value"] = v }); });
        canvas.Focus();
        e.Handled = true;
    }

    // ================================================================ source pane

    bool SourceDirty => sourceBase != null && SourceEditor.Text != sourceBase;

    void ShowSource(SceneData sc, string? error)
    {
        SourceError.Text = error ?? "";
        SourceError.Visibility = string.IsNullOrEmpty(error) ? Visibility.Collapsed : Visibility.Visible;
        if (sc.Source == null || SourceDirty) return;      // keep the user's draft
        suppressSource = true;
        if (SourceEditor.Text != sc.Source.Text) SourceEditor.Text = sc.Source.Text;
        suppressSource = false;
        sourceBase = sc.Source.Text;
        SourceLoc.Text = $"{sc.Source.File}:{sc.Source.Start}–{sc.Source.End}";
        ApplySourceButton.IsEnabled = false;
    }

    void HighlightSourceLine(string loc)
    {
        if (scene?.Source == null || SourceDirty) return;
        var parts = loc.Split(':');
        if (parts.Length < 2 || !int.TryParse(parts[^1], out var line)) return;
        if (!string.Equals(Path.GetFileName(parts[0]), Path.GetFileName(scene.Source.File), StringComparison.OrdinalIgnoreCase)) return;
        var rel = line - scene.Source.Start + 1;
        if (rel < 1 || rel > SourceEditor.Document.LineCount) return;
        var l = SourceEditor.Document.GetLineByNumber(rel);
        SourceEditor.ScrollToLine(rel);
        SourceEditor.Select(l.Offset, l.Length);
    }

    void SourceEditor_TextChanged(object? sender, EventArgs e)
    {
        if (suppressSource) return;
        ApplySourceButton.IsEnabled = SourceDirty;
    }

    void SourceEditor_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { ApplySource(); e.Handled = true; }
        else if (e.Key == Key.Escape && SourceDirty)
        {
            suppressSource = true; SourceEditor.Text = sourceBase ?? ""; suppressSource = false;
            ApplySourceButton.IsEnabled = false;
            e.Handled = true;
        }
    }

    void ApplySource_Click(object sender, RoutedEventArgs e) => ApplySource();

    void ApplySource()
    {
        if (scene?.Source == null || sceneName == null || !SourceDirty) return;
        var name = sceneName; var file = scene.Source.File; var expected = sourceBase!; var text = SourceEditor.Text;
        Submit(async () =>
        {
            Busy(+1, "Rendering…");
            EditResult? r = null; string? failure = null;
            try { r = await engine.Call<EditResult>("edit_source", new JsonObject { ["scene"] = name, ["file"] = file, ["expected"] = expected, ["text"] = text }); }
            catch (Exception ex) { failure = ex.Message; }
            Busy(-1);
            if (r?.Ok == true)
            {
                sourceBase = null;                       // take the source of the new render
                Toast("Saved · " + (r.Message ?? "source applied"));
            }
            else
            {
                Toast(failure ?? r?.Error ?? "The code could not be applied", error: true);
                SourceError.Text = failure ?? r?.Error ?? "";
                SourceError.Visibility = Visibility.Visible;
                if (r?.Error != null && r.Ok == false && r.Changed != null) sourceBase = null;   // kept, but did not render
            }
            if (sourceBase == null) { await LoadScene(name, keepStop: true); }
            await ReloadState();
        });
    }

    void ToggleSource_Click(object sender, RoutedEventArgs e)
    {
        Settings.Current.ShowSource = ShowSourceItem.IsChecked;
        Settings.Current.Save();
        ApplySourceVisibility();
    }

    void ApplySourceVisibility()
    {
        var show = ShowSourceItem.IsChecked;
        SourcePane.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        SourceSplitter.Visibility = SourcePane.Visibility;
        SourceColumn.Width = show ? new GridLength(420) : new GridLength(0);
    }

    // ================================================================ playing

    async void PlayBeginning_Click(object sender, RoutedEventArgs e) => await Play(null);
    async void PlayCurrent_Click(object sender, RoutedEventArgs e) => await Play(sceneName);

    async Task Play(string? from)
    {
        if (workspace == null) return;
        await FinishEdits();
        var start = from ?? state?.Scenes.FirstOrDefault(s => s.Hidden != true)?.Name;
        if (start == null) return;
        var show = new SlideshowWindow(engine, start, from == sceneName ? stopIndex : 0) { Owner = this };
        show.Show();
    }

    // ================================================================ engine events

    readonly DispatcherTimer stateSoon = new() { Interval = TimeSpan.FromMilliseconds(250) };
    bool stateSoonHooked;

    void ReloadStateSoon()
    {
        if (!stateSoonHooked) { stateSoon.Tick += async (_, _) => { stateSoon.Stop(); await ReloadState(); }; stateSoonHooked = true; }
        stateSoon.Stop();
        stateSoon.Start();
    }

    async void OnEngineEvent(JsonElement ev)
    {
        var kind = ev.GetProperty("event").GetString();
        string? name = ev.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString() : null;
        switch (kind)
        {
            case "rendered":
                ReloadStateSoon();
                if (name != null && name == sceneName && queuedEdits == 0 && !canvas.IsEditingText)
                    await LoadScene(name, keepStop: true, keepOverrides: true);
                break;
            case "edit_failed":
                Toast("The edit was undone: " + (ev.TryGetProperty("error", out var er) ? er.GetString() : ""), error: true);
                if (name != null && name == sceneName)
                {
                    canvas.Overrides.Clear();
                    await LoadScene(name, keepStop: true);
                }
                ReloadStateSoon();
                break;
            case "render_progress":
                if (name != null && name == sceneName && busy > 0 && StatusText.Text.StartsWith("Rendering")) Toast($"Rendering {name}…");
                break;
        }
        SlideshowWindow.Forward(ev);
    }

    // ================================================================ keyboard

    void OnKey(object sender, KeyEventArgs e)
    {
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        // shortcuts that work everywhere
        if (ctrl && key == Key.S) { Save_Click(sender, e); e.Handled = true; return; }
        if (ctrl && key == Key.O) { OpenDeck_Click(sender, e); e.Handled = true; return; }
        if (key == Key.F5) { if (shift) PlayCurrent_Click(sender, e); else PlayBeginning_Click(sender, e); e.Handled = true; return; }
        // typing in a text field: its own keys
        if (Keyboard.FocusedElement is TextBox || SourceEditor.IsKeyboardFocusWithin || canvas.IsEditingText) return;
        if (ctrl && key == Key.Z) { _ = UndoRedo(shift ? "redo" : "undo"); e.Handled = true; return; }
        if (ctrl && key == Key.Y) { _ = UndoRedo("redo"); e.Handled = true; return; }
        if (ctrl && shift && key == Key.N) { NewSlide_Click(sender, e); e.Handled = true; return; }
        if (ctrl && key == Key.D) { DuplicateSlide_Click(sender, e); e.Handled = true; return; }
        if (ctrl && key == Key.A) { canvas.SelectAll(); e.Handled = true; return; }
        if (ctrl && shift && key == Key.Up) { MoveSlideUp_Click(sender, e); e.Handled = true; return; }
        if (ctrl && shift && key == Key.Down) { MoveSlideDown_Click(sender, e); e.Handled = true; return; }
        if (ctrl && key == Key.Up) { _ = StepSlide(-1); e.Handled = true; return; }
        if (ctrl && key == Key.Down) { _ = StepSlide(+1); e.Handled = true; return; }
        if (key == Key.PageUp) { StepBuild(-1); e.Handled = true; return; }
        if (key == Key.PageDown) { StepBuild(+1); e.Handled = true; return; }
        if (SlideList.IsKeyboardFocusWithin) return;       // the navigator's arrows move between slides
        double step = shift ? 10 : 1;
        switch (key)
        {
            case Key.Delete or Key.Back: DeleteSelection(); e.Handled = true; break;
            case Key.Left: Nudge(-step, 0); e.Handled = canvas.Selected.Count > 0; break;
            case Key.Right: Nudge(step, 0); e.Handled = canvas.Selected.Count > 0; break;
            case Key.Up: Nudge(0, -step); e.Handled = canvas.Selected.Count > 0; break;
            case Key.Down: Nudge(0, step); e.Handled = canvas.Selected.Count > 0; break;
            case Key.Enter when canvas.Selected.Count == 1: canvas.BeginTextEdit(canvas.Selected[0]); e.Handled = true; break;
            case Key.Escape: canvas.Select(Array.Empty<int>()); e.Handled = true; break;
        }
    }

    // ================================================================ help

    void ShowLog_Click(object sender, RoutedEventArgs e) => Tools.Reveal(Paths.LogFile);
    void Docs_Click(object sender, RoutedEventArgs e) => Tools.OpenUrl("https://pachterlab.github.io/Manimble/");

    void About_Click(object sender, RoutedEventArgs e) =>
        MessageBox.Show(this, $"Manimble {typeof(MainWindow).Assembly.GetName().Version?.ToString(3)} for Windows\n\n" +
                              $"Engine: {Paths.Engine}\nPython: {engine.Python ?? "none"}\n\nhttps://github.com/pachterlab/Manimble",
                        "About Manimble", MessageBoxButton.OK, MessageBoxImage.Information);
}
