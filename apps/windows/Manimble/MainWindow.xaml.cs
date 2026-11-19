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
    public string Badge { get => badge; set { if (badge != value) { badge = value; On(nameof(Badge)); On(nameof(BadgeVisibility)); } } }
    public Visibility BadgeVisibility => badge.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
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
        canvas.CellCommitted += CommitCell;
        canvas.HasCornerAction = oid => PlotOf(oid) != null;
        canvas.CornerAction += RerunPlot;
        canvas.ObjectDoubleClicked += EditPlot;
        canvas.CanDrop = d => d.GetDataPresent(BioCartoonPanel.DragFormat);
        canvas.DataDropped += (d, p) => { if (BioCartoonPanel.FromDrag(d) is { } icon) BioCartoonDropped(icon, p); };
        canvas.TextCommitted += (oid, text) => Submit(() => RunEdit(new JsonObject { ["oid"] = oid, ["op"] = "text", ["value"] = text }));
        canvas.PlaceholderCommitted += OnPlaceholderCommitted;
        canvas.SelectionChanged += RebuildInspector;
        canvas.GuidesChanged += SaveGuides;
        canvas.ShowRulers = RulerItem.IsChecked = Settings.Current.ShowRulers;
        canvas.ResizeCommitted += (oid, ratio) => Submit(() => RunEdit(new JsonObject { ["oid"] = oid, ["op"] = "resize", ["ratio"] = ratio }));
        canvas.WrapCommitted += (oid, width, side) => Submit(() => RunEdit(new JsonObject { ["oid"] = oid, ["op"] = "wrap", ["width"] = width, ["side"] = side }));
        canvas.EndpointsCommitted += (oid, e) => Submit(() => RunEdit(new JsonObject
            { ["oid"] = oid, ["op"] = "endpoints", ["sx"] = e[0], ["sy"] = e[1], ["ex"] = e[2], ["ey"] = e[3] }));
        canvas.DrawCommitted += (tool, a, b) => Insert(tool, new JsonObject { ["sx"] = a.X, ["sy"] = a.Y, ["ex"] = b.X, ["ey"] = b.Y });
        canvas.PenCommitted += pts => Insert("pen", new JsonObject
        {
            ["points"] = new JsonArray(pts.Select(p => (JsonNode)new JsonArray(Math.Round(p.X, 1), Math.Round(p.Y, 1))).ToArray()),
            ["color"] = penColor, ["width"] = 6,
        });
        canvas.DrawToolChanged += () => DrawButtonText.Text = canvas.DrawTool switch
        {
            null => "Draw ▾", "pen" => "Pen (Esc ends)", "darrow" => "Drawing: double arrow", var t => "Drawing: " + t,
        };
        BuildPenColorMenu();
        BuildThemeMenu();
        SyncPlayMenu();
        canvas.ContextMenuOpening += CanvasContextMenu;
        canvas.ContextMenu = new ContextMenu();          // an empty menu, so ContextMenuOpening fires
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
        pendingDeck = deck;
        await StartWithSetup(firstLaunch: true);
    }

    string? pendingDeck;
    SetupWindow? setup;

    /// Finds Python and LaTeX; when one is missing, the setup window offers to install it (the Mac app's start()).
    async Task StartWithSetup(bool firstLaunch)
    {
        Busy(+1, firstLaunch ? "Looking for Python with Manim…" : "Checking for Python and LaTeX…");
        var status = await SetupWindow.Check();
        Busy(-1);
        if (status.Python != null && !engine.IsRunning) await LaunchEngine(status.Python);
        if (status.Python == null)
        {
            WelcomeText.Text = "Manimble needs a Python with Manim. The setup window installs one, or choose a Python " +
                               "that has manim with File ▸ Choose Python…";
            Toast("No Python with Manim found", error: true);
        }
        // only LaTeX missing: the app works meanwhile, and "Not Now" stops the question at later launches
        if (!firstLaunch || status.Python == null || (!status.Latex && !Settings.Current.SkipLatexSetup))
            ShowSetup(status);
    }

    async Task LaunchEngine(string python)
    {
        StartEngine(python);
        if (pendingDeck is { } d) { pendingDeck = null; await OpenDeck(d); }
    }

    void ShowSetup(SetupWindow.Status status)
    {
        if (setup != null) { setup.Activate(); return; }
        var s = new SetupWindow(status, IsVisible ? this : null);
        s.OnDone = async (installedPython, installedTex) =>
        {
            setup = null;
            if (installedPython && !engine.IsRunning)
            {
                if (await Tools.FindPython() is { } py) await LaunchEngine(py);
                else Toast("Python was installed but does not import manim; see " + Paths.LogFile, error: true);
            }
            else if (installedTex && engine.IsRunning)
            {
                // the engine's PATH is set when it starts: restart it so it finds the new LaTeX
                if (workspace is { IsModified: true })
                {
                    Toast("LaTeX is installed. Save the deck and restart Manimble for formulas to render.");
                    return;
                }
                var deck = workspace?.Original;
                workspace?.Discard(); workspace = null;
                var py = engine.Python;
                engine.Stop();
                if (py != null) { pendingDeck = deck; await LaunchEngine(py); }
            }
        };
        s.OnChoosePython = () => ChoosePython_Click(this, new RoutedEventArgs());
        setup = s;
        s.Show();
    }

    async void InstallDependencies_Click(object sender, RoutedEventArgs e) => await StartWithSetup(firstLaunch: false);

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
        try
        {
            if (File.Exists(path) && path.EndsWith(".manimble", StringComparison.OrdinalIgnoreCase))
            {
                // a package: unpacked into a project folder, which is what gets edited and saved
                if (UnpackTarget(path) is not { } target) return;
                Busy(+1, "Unpacking " + Path.GetFileName(path) + "…");
                try { path = await Task.Run(() => PortableProject.UnpackArchive(path, target)); }
                finally { Busy(-1); }
            }
            else if (File.Exists(path))
                path = Path.GetDirectoryName(path)!;      // a file of a deck (a slide's .py): its deck
            if (Directory.Exists(path) && PortableProject.DeckIn(path) is { } inner) path = inner;
        }
        catch (Exception e)
        {
            MessageBox.Show(this, e.Message, "Could not open the project", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
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
        LoadGuides();
        slides.Clear();
        suppressSource = true; SourceEditor.Text = ""; suppressSource = false;
        sourceBase = null; SourceLoc.Text = ""; SourceError.Visibility = Visibility.Collapsed;
        NotesBox.Text = "";
        AltTextBox.Text = "";
        canvas.SetScene(null, 0);
        WelcomePanel.Visibility = Visibility.Collapsed;
        canvas.ShowMessage("Rendering…");
        Settings.Current.AddRecent(ws.Original);
        terminal?.Start(ws.Work, ws.Original, engine.Python);         // a shell in the new deck's working copy
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

    async void OpenPackage_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog { Title = "Open a Manimble package", Filter = "Manimble package (*.manimble)|*.manimble" };
        if (dlg.ShowDialog(this) == true) await OpenDeck(dlg.FileName);
    }

    /// Where a .manimble package is unpacked: a project folder the user names, beside the package by default.
    /// MANIMBLE_TEST_UNPACK names it without asking.
    string? UnpackTarget(string package)
    {
        if (Environment.GetEnvironmentVariable("MANIMBLE_TEST_UNPACK") is { Length: > 0 } t) return t;
        var stem = Path.GetFileNameWithoutExtension(package);
        var dir = Path.GetDirectoryName(package)!;
        var name = stem;
        for (int n = 2; Directory.Exists(Path.Combine(dir, name)) || File.Exists(Path.Combine(dir, name)); n++) name = $"{stem} {n}";
        var dlg = new SaveFileDialog
        {
            Title = $"Unpack {Path.GetFileName(package)} into a project folder (you edit and save the folder; the package stays as it is)",
            InitialDirectory = dir, FileName = name, Filter = "Project folder|*.*", AddExtension = false, OverwritePrompt = false,
        };
        if (dlg.ShowDialog(this) != true) return null;
        return dlg.FileName;
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

    /// Save Project Copy…: a portable project folder (deck, the files its slides read, manifest), named after the project.
    async void SaveCopy_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null) return;
        var dlg = new OpenFolderDialog { Title = "Choose where Manimble should create the project folder" };
        if (dlg.ShowDialog(this) != true) return;
        var name = workspace.ProjectName;
        var dest = Path.Combine(dlg.FolderName, name);
        for (int n = 2; Directory.Exists(dest) || File.Exists(dest); n++) dest = Path.Combine(dlg.FolderName, $"{name} ({n})");
        await SavePortable(dest, archive: false);
    }

    /// Package for Sharing…: the same, zipped as one .manimble file.
    async void PackageProject_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null) return;
        var dlg = new SaveFileDialog
        {
            Title = "Package the project for sharing: one .manimble file with the deck and the files its slides use",
            FileName = workspace.ProjectName, DefaultExt = ".manimble", Filter = "Manimble package (*.manimble)|*.manimble",
        };
        if (dlg.ShowDialog(this) != true) return;
        var dest = dlg.FileName;
        if (!dest.EndsWith(".manimble", StringComparison.OrdinalIgnoreCase)) dest += ".manimble";
        await SavePortable(dest, archive: true);
    }

    async Task SavePortable(string destination, bool archive)
    {
        var ws = workspace;
        if (ws == null) return;
        await FinishEdits();             // the copy holds the last edits, as Save does
        Busy(+1, "Checking slide dependencies (every slide renders once)…");
        try
        {
            var report = await engine.Call<DependencyReport>("dependency_report");
            if (report.ScannedScenes != report.TotalScenes)
            {
                MessageBox.Show(this, $"Manimble checked {report.ScannedScenes} of {report.TotalScenes} slides. Please try again.",
                                "Dependency scan incomplete", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            if (report.Failures.Count > 0)
            {
                var details = string.Join("\n", report.Failures.Take(5).Select(f => $"{f.Scene}: {LastLine(f.Error)}"));
                if (MessageBox.Show(this, $"Manimble found dependencies in {report.ScannedScenes} slides, but the package may be incomplete.\n\n" +
                                          $"{details}\n\nContinue with the project copy?", "Some slides did not render during the dependency check",
                                    MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
            }
            Toast(archive ? "Packaging…" : "Copying the project…");
            if (archive) await Task.Run(() => PortableProject.CreateArchive(ws, report.Dependencies, destination));
            else await Task.Run(() => PortableProject.CreateFolder(ws, report.Dependencies, destination));
            Toast(archive ? "Packaged " + destination : "Saved the project folder " + destination);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Could not save the portable project", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally { Busy(-1); }
    }

    static string LastLine(string s) => s.Split('\n').Where(l => l.Trim().Length > 0).LastOrDefault()?.Trim() ?? s;

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
        terminal?.Stop();
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
        if (!AltTextBox.IsKeyboardFocusWithin) AltTextBox.Text = sc.AltText ?? "";
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
            lastBuildMove = null;
            if (r.OneBuild == true && req["oid"] is JsonNode bo)
            {
                lastBuildMove = (name, bo.GetValue<int>(), req["stop"]?.GetValue<int>() ?? 0);
                msg += " · in this build only; Ctrl+Shift+A applies it to every build";
            }
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
                await RunEdit(new JsonObject { ["oid"] = ids[0], ["op"] = "move", ["dx"] = dx, ["dy"] = dy, ["build"] = true });
            else
                await AsOneUndoStep("Move", async () =>
                {
                    foreach (var oid in ids)
                        await RunEdit(new JsonObject { ["oid"] = oid, ["op"] = "move", ["dx"] = dx, ["dy"] = dy, ["build"] = true, ["optimistic"] = false }, reload: false);
                    if (sceneName != null) await LoadScene(sceneName, keepStop: true);
                });
        });
    }

    (string scene, int oid, int stop)? lastBuildMove;

    /// Right after a move in one build, that move in every build instead (Ctrl+Shift+A, as on the Mac).
    void SpreadLastMove()
    {
        if (lastBuildMove is not { } m || m.scene != sceneName) { Toast("Move an object in one build first"); return; }
        lastBuildMove = null;
        Submit(() => RunEdit(new JsonObject { ["oid"] = m.oid, ["op"] = "spread", ["scene"] = m.scene, ["stop"] = m.stop }));
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
    void Cut_Click(object sender, RoutedEventArgs e) => CutSelection();
    void Copy_Click(object sender, RoutedEventArgs e) => CopySelection();
    void Paste_Click(object sender, RoutedEventArgs e) => PasteOnSlide();
    void SpreadMove_Click(object sender, RoutedEventArgs e) => SpreadLastMove();
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

    /// The Alt Text tab: `alt_text = "..."` on the slide's class, a description for people who cannot see it.
    void AltTextBox_LostFocus(object sender, KeyboardFocusChangedEventArgs e)
    {
        if (scene == null || sceneName == null || AltTextBox.Text.Trim() == (scene.AltText ?? "").Trim()) return;
        var name = sceneName; var text = AltTextBox.Text.Trim();
        scene.AltText = text;
        Submit(async () =>
        {
            var r = await engine.TryCall<EditResult>("alt_text", new JsonObject { ["op"] = "set", ["scene"] = name, ["text"] = text });
            if (r?.Ok == true) Toast(text.Length > 0 ? "Saved the alt text" : "Removed the alt text");
            else Toast(r?.Error ?? "Could not save the alt text", error: true);
            await ReloadState();
        });
    }

    // ================================================================ hyperlinks

    /// Format ▸ Hyperlink… (Ctrl+K) and the right-click menu: the URL a text opens when clicked in a show.
    void Hyperlink_Click(object sender, RoutedEventArgs e)
    {
        if (Single is not int s || SelectedObj is not { } o || (o.Kind != "text" && o.Kind != "tex"))
        {
            Toast("Select a text or formula to link");
            return;
        }
        var current = o.Format?.Link;
        if (Dialogs.Hyperlink(this, current) is not { } url || url == (current ?? "")) return;
        Submit(() => RunEdit(new JsonObject { ["oid"] = s, ["op"] = "link", ["url"] = url }));
    }

    // ================================================================ inspector

    bool suppressInspector;
    bool fontsLoaded;

    int? Single => canvas.Selected.Count == 1 ? canvas.Selected[0] : null;
    ObjInfo? SelectedObj => Single is int s ? scene?.Obj(s) : null;

    void RebuildInspector()
    {
        var sel = canvas.Selected;
        suppressInspector = true;
        try
        {
            if (scene == null || sel.Count == 0)
            {
                SelTitle.Text = "Nothing selected";
                SelDetail.Text = "Click an object on the slide. Drag to move it, drag a corner to resize it, double-click text to retype it, Delete removes it.";
                SelFields.Visibility = Visibility.Collapsed;
                ArrangeBar.Visibility = Visibility.Collapsed;
                HideTableEditor();
                return;
            }
            ArrangeBar.Visibility = Visibility.Visible;
            if (sel.Count > 1)
            {
                SelTitle.Text = $"{sel.Count} objects";
                SelDetail.Text = "Drag or use the arrow keys to move them together; Ctrl+G groups them.";
                SelFields.Visibility = Visibility.Visible;
                TextFormat.Visibility = Visibility.Collapsed;
                GeometryFields.Visibility = Visibility.Collapsed;
                HideTableEditor();
                ColorBox.Text = "";
                ColorSwatchFill.Background = Brushes.Transparent;
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
            if (o.Shared is { } sh) details.Add($"shared {sh.Name}, used {sh.Uses}×");
            if (o.Group is int g) details.Add($"in group {g}");
            if (o.TextOk == false && o.TextNote != null) details.Add(o.TextNote);
            if (o.Siblings > 1) details.Add($"{o.Siblings} similar objects come from this line");
            SelDetail.Text = string.Join(" · ", details);
            SelFields.Visibility = Visibility.Visible;
            GeometryFields.Visibility = Visibility.Visible;
            TextFormat.Visibility = o.IsText ? Visibility.Visible : Visibility.Collapsed;
            if (o.Kind == "table") ShowTableEditor(sel[0], o); else HideTableEditor();
            if (o.IsText)
            {
                if (!fontsLoaded)
                {
                    FontCombo.ItemsSource = Fonts.SystemFontFamilies.Select(f => f.Source).OrderBy(n => n).ToList();
                    fontsLoaded = true;
                }
                FontCombo.IsEnabled = o.Kind == "text";
                FontCombo.Text = o.Font ?? scene.Font ?? "";
                SizeBox.Text = o.FontSize is double fs ? fs.ToString("0.#") : "";
                BoldButton.IsChecked = string.Equals(o.Weight, "BOLD", StringComparison.OrdinalIgnoreCase);
                ItalicButton.IsChecked = string.Equals(o.Slant, "ITALIC", StringComparison.OrdinalIgnoreCase);
                BoldButton.IsEnabled = ItalicButton.IsEnabled = o.Kind == "text";
                UnderlineButton.IsChecked = o.Format?.Underline == true;
                StrikeButton.IsChecked = o.Format?.Strike == true;
                var align = o.Format?.Align ?? "left";
                AlignLeftButton.IsChecked = align == "left";
                AlignCenterButton.IsChecked = align == "center";
                AlignRightButton.IsChecked = align == "right";
                AlignLeftButton.IsEnabled = AlignCenterButton.IsEnabled = AlignRightButton.IsEnabled = o.Kind == "text";
            }
            ColorBox.Text = o.Color ?? "";
            ColorSwatchFill.Background = o.Color != null && TryColor(o.Color) is Color c ? new SolidColorBrush(c) : Brushes.Transparent;
            if (canvas.Stop?.Box(sel[0]) is Rect b)
            {
                XBox.Text = (b.X + b.Width / 2).ToString("0");
                YBox.Text = (b.Y + b.Height / 2).ToString("0");
                var (w, h) = Dims(sel[0], o);
                WBox.Text = w.ToString("0");
                HBox.Text = h.ToString("0");
            }
            RotBox.Text = (o.Rotation ?? 0).ToString("0.#");
            HighlightSourceLine(o.Loc);         // the source pane shows where the object was made
        }
        finally { suppressInspector = false; }
    }

    (double w, double h) Dims(int oid, ObjInfo o)
    {
        if (o.Dims is { Length: 2 } d) return (d[0], d[1]);
        var b = canvas.Stop?.Box(oid) ?? new Rect();
        return (b.Width, b.Height);
    }

    static Color? TryColor(string hex)
    {
        try { return (Color)ColorConverter.ConvertFromString(hex); } catch { return null; }
    }

    static string Short(string s) { s = s.Replace('\n', ' '); return s.Length > 60 ? s[..60] + "…" : s; }

    /// The same edit on every selected object, as one undo step.
    void EditSelection(string label, Func<int, JsonObject> make)
    {
        var ids = canvas.Selected.ToList();
        if (ids.Count == 0) return;
        if (ids.Count == 1) { Submit(() => RunEdit(make(ids[0]))); return; }
        Submit(() => AsOneUndoStep(label, async () =>
        {
            foreach (var oid in ids) await RunEdit(make(oid), reload: oid == ids[^1]);
        }));
    }

    void ApplyColor(string hex)
    {
        hex = hex.Trim();
        if (!hex.StartsWith('#')) hex = "#" + hex;
        if (hex.Length != 7 || TryColor(hex) == null) { Toast("A colour is #RRGGBB", error: true); return; }
        hex = hex.ToUpperInvariant();
        EditSelection("Color", oid => new JsonObject { ["oid"] = oid, ["op"] = "color", ["value"] = hex });
    }

    void ColorBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || canvas.Selected.Count == 0) return;
        ApplyColor(ColorBox.Text);
        canvas.Focus();
        e.Handled = true;
    }

    static readonly (string name, string hex)[] Palette =
    {
        ("White", "#FFFFFF"), ("Light grey", "#BBBBBB"), ("Grey", "#888888"), ("Black", "#000000"), ("Red", "#FC6255"),
        ("Orange", "#FF862F"), ("Yellow", "#FFFF00"), ("Green", "#83C167"), ("Teal", "#5CD0B3"), ("Blue", "#58C4DD"),
        ("Purple", "#9A72AC"), ("Pink", "#D147BD"),
    };

    void ColorSwatch_Click(object sender, RoutedEventArgs e)
    {
        if (canvas.Selected.Count == 0) return;
        var items = Palette.Select(p => (p.name, (string?)p.hex, (RoutedEventHandler)((_, _) => ApplyColor(p.hex)))).ToList();
        items.Add(("-", null, (_, _) => { }));
        items.Add(("Other (type #RRGGBB)…", null, (_, _) => { ColorBox.Focus(); ColorBox.SelectAll(); }));
        DropDown(ColorSwatch, items.ToArray());
    }

    void CommitStyle(string? font = null, string? weight = null, string? slant = null)
    {
        if (Single is not int s || SelectedObj is not { Kind: "text" }) return;
        var req = new JsonObject { ["oid"] = s, ["op"] = "style", ["shared"] = true };
        if (font != null) req["font"] = font;
        if (weight != null) req["weight"] = weight;
        if (slant != null) req["slant"] = slant;
        Submit(() => RunEdit(req));
    }

    void FontCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (suppressInspector || FontCombo.SelectedItem is not string f || f == SelectedObj?.Font) return;
        CommitStyle(font: f);
    }

    void FontCombo_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        var f = FontCombo.Text.Trim();
        if (f.Length > 0 && f != SelectedObj?.Font) CommitStyle(font: f);
        canvas.Focus();
        e.Handled = true;
    }

    void CommitFontSize(double v)
    {
        if (Single is not int s || SelectedObj is not { IsText: true } || v < 4 || v > 400) return;
        SizeBox.Text = v.ToString("0.#");
        Submit(() => RunEdit(new JsonObject { ["oid"] = s, ["op"] = "font", ["value"] = Math.Round(v, 1) }));
    }

    void SizeBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        if (double.TryParse(SizeBox.Text, out var v)) CommitFontSize(v);
        canvas.Focus();
        e.Handled = true;
    }

    void Bigger_Click(object sender, RoutedEventArgs e) { if (SelectedObj?.FontSize is double fs) CommitFontSize(Math.Round(fs * 1.15)); }
    void Smaller_Click(object sender, RoutedEventArgs e) { if (SelectedObj?.FontSize is double fs) CommitFontSize(Math.Max(4, Math.Round(fs / 1.15))); }

    void Bold_Click(object sender, RoutedEventArgs e) => ToggleBold();
    void Italic_Click(object sender, RoutedEventArgs e) => ToggleItalic();
    void ToggleBold()
    {
        if (SelectedObj is not { Kind: "text" } o) return;
        CommitStyle(weight: string.Equals(o.Weight, "BOLD", StringComparison.OrdinalIgnoreCase) ? "NORMAL" : "BOLD");
    }
    void ToggleItalic()
    {
        if (SelectedObj is not { Kind: "text" } o) return;
        CommitStyle(slant: string.Equals(o.Slant, "ITALIC", StringComparison.OrdinalIgnoreCase) ? "NORMAL" : "ITALIC");
    }

    void Decorate(string kind)
    {
        if (Single is not int s || SelectedObj is not { IsText: true } o) return;
        var on = kind == "underline" ? o.Format?.Underline != true : o.Format?.Strike != true;
        Submit(() => RunEdit(new JsonObject { ["oid"] = s, ["op"] = "decorate", ["kind"] = kind, ["on"] = on }));
    }
    void Underline_Click(object sender, RoutedEventArgs e) => Decorate("underline");
    void Strike_Click(object sender, RoutedEventArgs e) => Decorate("strike");

    void Highlight_Click(object sender, RoutedEventArgs e)
    {
        if (Single is not int s || SelectedObj is not { IsText: true }) return;
        void Set(string? hex)
        {
            var req = new JsonObject { ["oid"] = s, ["op"] = "highlight", ["opacity"] = 0.6 };
            if (hex != null) req["color"] = hex;
            Submit(() => RunEdit(req));
        }
        DropDown(HighlightButton, ("Yellow", "#FFD400", (_, _) => Set("#FFD400")), ("Green", "#34C759", (_, _) => Set("#34C759")),
            ("Blue", "#4D7CFF", (_, _) => Set("#4D7CFF")), ("Pink", "#FF5FA2", (_, _) => Set("#FF5FA2")),
            ("Orange", "#FF9A2E", (_, _) => Set("#FF9A2E")), ("-", null, (_, _) => { }), ("No highlight", null, (_, _) => Set(null)));
    }

    void Align_Click(object sender, RoutedEventArgs e)
    {
        if (Single is not int s || SelectedObj is not { Kind: "text" } || (sender as FrameworkElement)?.Tag is not string v) return;
        Submit(() => RunEdit(new JsonObject { ["oid"] = s, ["op"] = "align", ["value"] = v }));
    }

    void Spacing_Click(object sender, RoutedEventArgs e)
    {
        if (Single is not int s || SelectedObj is not { Kind: "text" }) return;
        // Manim's line_spacing is relative to the font size with 0.3 as single; 1.0 is single here, as in PowerPoint
        void Set(double v) => Submit(() => RunEdit(new JsonObject { ["oid"] = s, ["op"] = "spacing", ["value"] = Math.Max(-0.6, v - 0.7) }));
        DropDown((Button)sender, ("1.0 (single)", null, (_, _) => Set(1.0)), ("1.15", null, (_, _) => Set(1.15)), ("1.5", null, (_, _) => Set(1.5)),
            ("2.0 (double)", null, (_, _) => Set(2.0)), ("2.5", null, (_, _) => Set(2.5)), ("3.0", null, (_, _) => Set(3.0)));
    }

    void ClearFormat_Click(object sender, RoutedEventArgs e)
    {
        if (Single is not int s || SelectedObj is not { IsText: true }) return;
        Submit(() => RunEdit(new JsonObject { ["oid"] = s, ["op"] = "clear_format" }));
    }

    void Geometry_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter || Single is not int s || SelectedObj is not { } o || sender is not TextBox box) return;
        e.Handled = true;
        if (!double.TryParse(box.Text, out var v)) { Toast("Type a number", error: true); return; }
        var b = canvas.Stop?.Box(s);
        switch (box.Tag as string)
        {
            case "x" when b is Rect r: OnMoveCommitted(new List<int> { s }, v - (r.X + r.Width / 2), 0); canvas.Nudge(0, 0); break;
            case "y" when b is Rect r: OnMoveCommitted(new List<int> { s }, 0, v - (r.Y + r.Height / 2)); break;
            case "rot": Submit(() => RunEdit(new JsonObject { ["oid"] = s, ["op"] = "rotate", ["degrees"] = v })); break;
            case "w" or "h" when v > 0:
            {
                var (w, h) = Dims(s, o);
                var stretch = AspectLock.IsChecked != true && o.Kind is "image" or "shape";
                if (!stretch)
                {
                    var ratio = (string)box.Tag == "w" ? v / Math.Max(1, w) : v / Math.Max(1, h);
                    Submit(() => RunEdit(new JsonObject { ["oid"] = s, ["op"] = "resize", ["ratio"] = ratio }));
                }
                else
                {
                    var req = new JsonObject { ["oid"] = s, ["op"] = "size" };
                    req[(string)box.Tag == "w" ? "width" : "height"] = v;
                    Submit(() => RunEdit(req));
                }
                break;
            }
        }
        canvas.Focus();
    }

    // ================================================================ arrange

    void ArrangeSelection(string how)
    {
        var ids = canvas.Selected.ToList();
        if (ids.Count == 0) return;
        Submit(() => RunEdit(new JsonObject { ["oid"] = ids[0], ["oids"] = new JsonArray(ids.Select(i => (JsonNode)i).ToArray()), ["op"] = "order", ["value"] = how }));
    }

    void Arrange_Click(object sender, RoutedEventArgs e) { if ((sender as FrameworkElement)?.Tag is string how) ArrangeSelection(how); }

    void GroupSelection()
    {
        var ids = canvas.Selected.ToList();
        if (ids.Count < 2) { Toast("Select two or more objects to group them"); return; }
        Submit(() => RunEdit(new JsonObject { ["oid"] = ids[0], ["oids"] = new JsonArray(ids.Select(i => (JsonNode)i).ToArray()), ["op"] = "group" }));
    }

    void UngroupSelection()
    {
        var ids = canvas.Selected.ToList();
        if (ids.Count == 0) return;
        Submit(() => RunEdit(new JsonObject { ["oid"] = ids[0], ["oids"] = new JsonArray(ids.Select(i => (JsonNode)i).ToArray()), ["op"] = "ungroup" }));
    }

    void Group_Click(object sender, RoutedEventArgs e) => GroupSelection();
    void Ungroup_Click(object sender, RoutedEventArgs e) => UngroupSelection();

    /// The canvas's right-click menu, for what is selected.
    void CanvasContextMenu(object sender, ContextMenuEventArgs e)
    {
        var m = new ContextMenu();
        void Add(string header, Action a, bool enabled = true, string? gesture = null)
        {
            var mi = new MenuItem { Header = header, IsEnabled = enabled, InputGestureText = gesture ?? "" };
            mi.Click += (_, _) => a();
            m.Items.Add(mi);
        }
        var sel = canvas.Selected.ToList();
        var o = SelectedObj;
        if (sel.Count == 0)
        {
            Add("Insert Text", () => Insert("text", typeAfter: true), gesture: "Ctrl+Shift+T");
            Add("Insert Formula…", () => InsertFormula_Click(this, new RoutedEventArgs()), gesture: "Ctrl+Shift+E");
            Add("Insert Image…", () => InsertImage_Click(this, new RoutedEventArgs()), gesture: "Ctrl+Shift+I");
            m.Items.Add(new Separator());
            Add("Select All", canvas.SelectAll, gesture: "Ctrl+A");
            Add("New Build", () => NewBuild_Click(this, new RoutedEventArgs()), gesture: "Ctrl+Shift+B");
        }
        else
        {
            if (o is { } obj && (obj.IsText || obj.Kind == "table")) Add(obj.Kind == "tex" ? "Edit LaTeX" : obj.Kind == "table" ? "Edit Cell" : "Edit Text", () => canvas.BeginTextEdit(sel[0]), gesture: "Enter");
            if (o is { Kind: "text" or "tex" } lo)
                Add(lo.Format?.Link == null ? "Add Hyperlink…" : "Edit Hyperlink…", () => Hyperlink_Click(this, new RoutedEventArgs()), gesture: "Ctrl+K");
            Add("Delete", DeleteSelection, gesture: "Del");
            if (sel.Count == 1 && PlotOf(sel[0]) != null)
            {
                m.Items.Add(new Separator());
                var plot = sel[0];
                Add("Edit Plot…", () => EditPlot(plot), gesture: "Enter");
                Add("Run Plot Again", () => RerunPlot(plot));
            }
            m.Items.Add(new Separator());
            Add("Bring to Front", () => ArrangeSelection("front"), gesture: "Ctrl+Shift+]");
            Add("Bring Forward", () => ArrangeSelection("forward"), gesture: "Ctrl+]");
            Add("Send Backward", () => ArrangeSelection("backward"), gesture: "Ctrl+[");
            Add("Send to Back", () => ArrangeSelection("back"), gesture: "Ctrl+Shift+[");
            m.Items.Add(new Separator());
            Add("Group", GroupSelection, sel.Count > 1, "Ctrl+G");
            Add("Ungroup", UngroupSelection, sel.Any(i => scene?.Obj(i)?.Group != null), "Ctrl+Shift+G");
        }
        m.PlacementTarget = canvas;
        m.IsOpen = true;
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

    // ================================================================ inserting

    static readonly (string name, string hex)[] PenSwatches =
    {
        ("Red", "#FF3B30"), ("Orange", "#FF9A2E"), ("Yellow", "#FFD400"), ("Green", "#34C759"), ("Blue", "#4D7CFF"),
        ("Purple", "#7C5CFF"), ("White", "#FFFFFF"), ("Black", "#000000"),
    };
    string penColor = "#FF3B30";

    void BuildPenColorMenu()
    {
        PenColorMenu.Items.Clear();
        foreach (var (name, hex) in PenSwatches)
        {
            var swatch = new System.Windows.Shapes.Rectangle
            {
                Width = 12, Height = 12, Fill = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)),
                Stroke = Brushes.Gray, StrokeThickness = 0.5,
            };
            var mi = new MenuItem { Header = name, Tag = hex, Icon = swatch, IsCheckable = true, IsChecked = hex == penColor };
            mi.Click += (_, _) =>
            {
                penColor = hex;
                canvas.PenColor = (Color)ColorConverter.ConvertFromString(hex);
                foreach (var o in PenColorMenu.Items.OfType<MenuItem>()) o.IsChecked = (string)o.Tag == hex;
            };
            PenColorMenu.Items.Add(mi);
        }
        canvas.PenColor = (Color)ColorConverter.ConvertFromString(penColor);
    }

    /// Inserts an element: a preview shows at once, the source is patched and the slide re-rendered in the background,
    /// and the new element is selected (a new text box opens for typing).
    void Insert(string kind, JsonObject? extra = null, bool typeAfter = false)
    {
        var name = sceneName;
        if (name == null || workspace == null) { Toast("Open a deck and pick a slide first", error: true); return; }
        var req = extra ?? new JsonObject();
        req["kind"] = kind;
        req["scene"] = name;
        Task? preview = kind == "pen" ? null : ShowGhost((JsonObject)req.DeepClone());
        Submit(async () =>
        {
            req["stop"] = stopIndex;
            if (Seen is { } seen) req["seen"] = seen;
            Busy(+1, "Inserting…");
            EditResult? r = null; string? failure = null;
            try { r = await engine.Call<EditResult>("insert", req); }
            catch (Exception e) { failure = e.Message; }
            Busy(-1);
            if (preview != null) await preview;       // a preview landing after the insert would stay for good
            if (r?.Ok != true)
            {
                canvas.ClearGhost();
                if (kind == "pen") canvas.DropPendingStroke();
                Toast(failure ?? r?.Error ?? "The insert did not work", error: true);
                return;
            }
            Toast("Saved · " + (r.Message ?? "inserted"));
            await LoadScene(name, keepStop: true);
            canvas.ClearGhost();
            if (kind == "pen") canvas.DropPendingStroke();
            if (kind != "pen" && sceneName == name && scene?.Objects != null && r.Line is int line)
            {
                var hit = scene.Objects.FirstOrDefault(kv => LocMatches(kv.Value.Loc, r.File, line));
                if (hit.Key != null && int.TryParse(hit.Key, out var oid))
                {
                    canvas.Select(new[] { oid });
                    if (typeAfter) canvas.BeginTextEdit(oid);
                }
            }
            await ReloadState();
        });
    }

    static bool LocMatches(string loc, string? file, int line)
    {
        var i = loc.LastIndexOf(':');
        if (i < 0 || !int.TryParse(loc[(i + 1)..], out var l) || l != line) return false;
        return file == null || string.Equals(Path.GetFileName(loc[..i]), Path.GetFileName(file), StringComparison.OrdinalIgnoreCase);
    }

    async Task ShowGhost(JsonObject req)
    {
        try
        {
            var sp = await engine.Call<SpriteResult>("insert_sprite", req);
            if (sp?.Path == null || sp.W is not double w || sp.H is not double h || sceneName != (string?)req["scene"]) return;
            if (Images.Load(sp.Path) is { } img) canvas.SetGhost(img, sp.Cx ?? 0, sp.Cy ?? 0, w, h);
        }
        catch { }
    }

    void InsertText_Click(object sender, RoutedEventArgs e) => Insert("text", typeAfter: true);

    void InsertFormula_Click(object sender, RoutedEventArgs e)
    {
        if (sceneName == null) return;
        var tex = Dialogs.Formula(this, engine);
        if (tex != null) Insert("formula", new JsonObject { ["tex"] = tex });
    }

    void InsertShape_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is string kind) Insert(kind);
    }

    void DrawTool_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not string tool || sceneName == null) return;
        canvas.DrawTool = tool;
        canvas.Focus();
        Toast(tool == "pen" ? "Draw on the slide with the pen; Esc puts it down" : "Drag on the slide to draw; Shift keeps lines straight");
    }

    void InsertTable_Click(object sender, RoutedEventArgs e)
    {
        var style = (sender as FrameworkElement)?.Tag as string ?? "word";
        if (sceneName == null) return;
        if (Dialogs.Table(this, style) is { } t)
            Insert("table", new JsonObject { ["rows"] = t.rows, ["cols"] = t.cols, ["style"] = style });
    }

    void InsertImage_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null || sceneName == null) return;
        var dlg = new OpenFileDialog { Title = "Choose an image to insert", Filter = "Images|*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.tif;*.tiff;*.webp|All files|*.*" };
        if (dlg.ShowDialog(this) != true) return;
        // a copy in the deck folder, under a name not taken yet
        var baseName = Path.GetFileNameWithoutExtension(dlg.FileName);
        var ext = Path.GetExtension(dlg.FileName);
        var fileName = baseName + ext;
        for (int n = 1; File.Exists(Path.Combine(workspace.Work, fileName)); n++) fileName = $"{baseName}_{n}{ext}";
        try { File.Copy(dlg.FileName, Path.Combine(workspace.Work, fileName)); }
        catch (Exception ex) { Toast("Could not copy the image: " + ex.Message, error: true); return; }
        Insert("image", new JsonObject { ["file"] = fileName });
    }

    /// A toolbar button's drop-down: a copy of the menu items it stands for.
    void DropDown(Button b, params (string header, string? tag, RoutedEventHandler handler)[] items)
    {
        var m = new ContextMenu { PlacementTarget = b, Placement = PlacementMode.Bottom };
        foreach (var (header, tag, handler) in items)
        {
            if (header == "-") { m.Items.Add(new Separator()); continue; }
            var mi = new MenuItem { Header = header, Tag = tag };
            mi.Click += handler;
            m.Items.Add(mi);
        }
        m.IsOpen = true;
    }

    void ShapeButton_Click(object sender, RoutedEventArgs e) => DropDown(ShapeButton,
        ("Rectangle", "rectangle", InsertShape_Click), ("Rounded Rectangle", "rounded", InsertShape_Click), ("Circle", "circle", InsertShape_Click),
        ("Ellipse", "ellipse", InsertShape_Click), ("Triangle", "triangle", InsertShape_Click), ("-", null, InsertShape_Click),
        ("Line", "line", InsertShape_Click), ("Arrow", "arrow", InsertShape_Click), ("Double Arrow", "darrow", InsertShape_Click));

    void DrawButton_Click(object sender, RoutedEventArgs e)
    {
        if (canvas.DrawTool != null) { canvas.DrawTool = null; return; }        // a second click puts the tool down
        DropDown(DrawButton, ("Line", "line", DrawTool_Click), ("Arrow", "arrow", DrawTool_Click), ("Double Arrow", "darrow", DrawTool_Click),
            ("Rectangle", "rectangle", DrawTool_Click), ("Ellipse", "ellipse", DrawTool_Click), ("-", null, DrawTool_Click),
            ("Pen (freehand)", "pen", DrawTool_Click));
    }

    void InsertTableButton_Click(object sender, RoutedEventArgs e) => DropDown((Button)sender,
        ("Word Table…", "word", InsertTable_Click), ("Math Table…", "math", InsertTable_Click));

    void NewSlideButton_Click(object sender, RoutedEventArgs e) => DropDown(NewSlideButton,
        ("Title Slide", "title", NewSlideLayout_Click), ("Title and Content", "title_content", NewSlideLayout_Click),
        ("Two Content", "two_content", NewSlideLayout_Click), ("Title Only", "title_only", NewSlideLayout_Click), ("Blank", "blank", NewSlideLayout_Click));

    void NewSlideLayout_Click(object sender, RoutedEventArgs e)
    {
        if (sceneName != null && (sender as FrameworkElement)?.Tag is string layout) SlideOp(new JsonObject { ["op"] = "new", ["layout"] = layout });
    }

    // ================================================================ builds

    void NewBuild_Click(object sender, RoutedEventArgs e) => BuildOp("new_build", "could not add a build");

    void DeleteBuild_Click(object sender, RoutedEventArgs e)
    {
        if (scene?.Stops is not { Count: > 1 }) { Toast("This slide has only one build"); return; }
        BuildOp("delete_build", "could not delete the build");
    }

    void BuildOp(string cmd, string failure)
    {
        var name = sceneName;
        if (name == null || scene?.Stops == null) return;
        var stop = stopIndex;
        Submit(async () =>
        {
            Busy(+1, "Rendering…");
            var r = await engine.TryCall<EditResult>(cmd, new JsonObject { ["scene"] = name, ["stop"] = stop });
            Busy(-1);
            if (r?.Ok != true) { Toast(r?.Error ?? failure, error: true); return; }
            Toast("Saved · " + (r.Message ?? cmd.Replace('_', ' ')));
            if (r.Stop is int s) stopIndex = s;
            await LoadScene(name, keepStop: true);
            await ReloadState();
        });
    }

    // ================================================================ terminal

    TerminalPanel? terminal;

    void EnsureTerminal()
    {
        if (terminal != null) return;
        terminal = new TerminalPanel();
        TerminalHost.Content = terminal;
        if (workspace != null) terminal.Start(workspace.Work, workspace.Original, engine.Python);
    }

    void DrawerTabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (e.Source != DrawerTabs) return;
        if (DrawerTabs.SelectedItem == TerminalTab)
        {
            EnsureTerminal();
            if (DrawerRow.Height.Value < 240) DrawerRow.Height = new GridLength(280);
            Dispatcher.BeginInvoke(() => terminal?.FocusTerminal(), DispatcherPriority.Background);
        }
    }

    void ShowTerminal_Click(object sender, RoutedEventArgs e)
    {
        if (DrawerTabs.SelectedItem == TerminalTab && terminal?.IsKeyboardFocusWithin == true) { DrawerTabs.SelectedItem = NotesTab; canvas.Focus(); return; }
        DrawerTabs.SelectedItem = TerminalTab;
        terminal?.FocusTerminal();
    }

    void NewTerminal_Click(object sender, RoutedEventArgs e)
    {
        DrawerTabs.SelectedItem = TerminalTab;
        EnsureTerminal();
        if (workspace != null) terminal!.Start(workspace.Work, workspace.Original, engine.Python);
        else Toast("Open a deck first: the terminal runs in its working copy", error: true);
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
        if (Settings.Current.ShowAnimations) { await StartPresent(start); return; }
        var show = new SlideshowWindow(engine, start, from == sceneName ? stopIndex : 0) { Owner = this };
        show.Show();
    }

    // ---------------------------------------------------------------- the animated show

    AnimatedShowWindow? animatedShow;
    PresenterWindow? presenter;
    bool presentPending;
    bool presentWithPresenter;
    int presentFrom;
    Dictionary<string, List<string>> presenterStills = new();

    /// Presenter View: the show on the other display, notes, next build and timer on this one (Alt+F5).
    async void PresenterView_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null || presentPending || animatedShow != null) return;
        await FinishEdits();
        presentWithPresenter = true;
        await StartPresent(sceneName ?? state?.Scenes.FirstOrDefault()?.Name ?? "");
        if (!presentPending) presentWithPresenter = false;
    }

    async Task LoadPresenterStills()
    {
        try
        {
            var d = await engine.Call<DeckPages>("deck_pages", new JsonObject { ["ahead"] = 0 });
            presenterStills = d?.Slides.ToDictionary(s => s.Scene, s => s.Pages) ?? new();
        }
        catch { presenterStills = new(); }
    }

    string? PresenterStill(string scene, int build) =>
        presenterStills.TryGetValue(scene, out var pages) && pages.Count > 0 ? pages[Math.Min(build, pages.Count - 1)] : null;

    /// Builds the out-of-date slides with manim, then plays their clips (the `present` "ready" event). The show
    /// opens once the first few slides from here are built; the rest build behind it ("update" events).
    async Task StartPresent(string start)
    {
        if (animatedShow != null || presentPending) return;
        presentFrom = Math.Max(0, state?.Scenes.FindIndex(s => s.Name == start) ?? 0);
        presentPending = true;
        Busy(+1, "Preparing the presentation…");
        EditResult? r = null; string? failure = null;
        try { r = await engine.Call<EditResult>("present", new JsonObject { ["height"] = Settings.Current.AnimationHeight, ["current"] = start, ["ahead"] = 3 }); }
        catch (Exception e) { failure = e.Message; }
        if (r?.Ok != true)
        {
            presentPending = false;
            Busy(-1);
            Toast(failure ?? r?.Error ?? "Could not start the presentation", error: true);
        }
    }

    async void OpenShow(PresentDeck deck, int startScene)
    {
        if (deck.Slides.Count == 0) { Toast("Nothing to show: every slide is hidden or failed to build", error: true); return; }
        var withPresenter = presentWithPresenter;
        presentWithPresenter = false;
        Screen? audience = null;
        if (withPresenter)
        {
            var mine = Screen.Of(this);
            audience = Screen.All().FirstOrDefault(s => s.Handle != mine);
            await LoadPresenterStills();
        }
        var show = new AnimatedShowWindow(deck, startScene, audience, this);
        show.Exited += () => { animatedShow = null; presenter = null; Activate(); };
        animatedShow = show;
        show.Show();
        if (withPresenter)
        {
            if (audience == null) { show.Topmost = false; Toast("One display: the show is full screen behind Presenter View. With a second display it goes there."); }
            var p = new PresenterWindow(show, PresenterStill);
            presenter = p;
            p.Show();
            p.Activate();
        }
        else show.Activate();
    }

    void OnPresentEvent(JsonElement ev)
    {
        var phase = ev.TryGetProperty("phase", out var ph) ? ph.GetString() : null;
        switch (phase)
        {
            case "building":
                var done = ev.TryGetProperty("done", out var d) ? d.GetInt32() : 0;
                var total = ev.TryGetProperty("total", out var t) ? t.GetInt32() : 0;
                var sc = ev.TryGetProperty("scene", out var s) ? s.GetString() : "";
                Toast($"Building the animations: {sc} ({Math.Min(done + 1, Math.Max(total, 1))} of {total})…");
                break;
            case "ready":
            {
                var deck = ev.Deserialize<PresentDeck>(Engine.Json) ?? new PresentDeck();
                if (presentPending) { presentPending = false; Busy(-1); Toast("Presenting · Esc ends the show"); OpenShow(deck, presentFrom); }
                else animatedShow?.Update(deck);
                break;
            }
            case "update":
                if (ev.Deserialize<PresentDeck>(Engine.Json) is { } upd) animatedShow?.Update(upd);
                break;
            case "error":
                if (presentPending) { presentPending = false; Busy(-1); }
                Toast("The presentation could not be built: " + (ev.TryGetProperty("error", out var er) ? LastLine(er.GetString() ?? "") : ""), error: true);
                break;
            case "cancelled":
                if (presentPending) { presentPending = false; Busy(-1); }
                Toast("Cancelled");
                break;
        }
    }

    bool previewPending;

    async void PreviewAnimations_Click(object sender, RoutedEventArgs e)
    {
        if (sceneName == null || previewPending || animatedShow != null) return;
        await FinishEdits();
        previewPending = true;
        Busy(+1, $"Preparing {sceneName}'s animations…");
        EditResult? r = null; string? failure = null;
        try { r = await engine.Call<EditResult>("animation_preview", new JsonObject { ["scene"] = sceneName, ["height"] = Settings.Current.AnimationHeight }); }
        catch (Exception ex) { failure = ex.Message; }
        if (r?.Ok != true) { previewPending = false; Busy(-1); Toast(failure ?? r?.Error ?? "Could not play this slide", error: true); }
    }

    void OnPreviewEvent(JsonElement ev)
    {
        var phase = ev.TryGetProperty("phase", out var ph) ? ph.GetString() : null;
        if (phase == "building") { Toast("Building the slide's animations…"); return; }
        if (!previewPending) return;
        previewPending = false;
        Busy(-1);
        if (phase == "error") { Toast("Could not build the animations: " + (ev.TryGetProperty("error", out var er) ? LastLine(er.GetString() ?? "") : ""), error: true); return; }
        if (phase != "ready" || !ev.TryGetProperty("clips", out var clips)) return;
        var scene = ev.TryGetProperty("scene", out var s) ? s.GetString() ?? "" : "";
        var list = clips.EnumerateArray().ToList();
        var deck = new PresentDeck
        {
            Slides = list.Select((c, i) => new PresentSlide
            {
                Scene = scene, Number = 0, Index = i, Count = list.Count,
                Kind = c.TryGetProperty("kind", out var k) ? k.GetString() ?? "video" : "video",
                File = c.TryGetProperty("path", out var p) ? p.GetString() : null,
                Rate = c.TryGetProperty("playbackRate", out var pr) && pr.ValueKind == JsonValueKind.Number ? pr.GetDouble() : 1,
                RevRate = 1,
            }).ToList(),
        };
        OpenShow(deck, 0);
    }

    void ShowAnimations_Click(object sender, RoutedEventArgs e)
    {
        Settings.Current.ShowAnimations = ShowAnimationsItem.IsChecked;
        Settings.Current.Save();
    }

    void Resolution_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as MenuItem)?.Tag is string t && int.TryParse(t, out var h)) { Settings.Current.AnimationHeight = h; Settings.Current.Save(); }
        SyncPlayMenu();
    }

    void SyncPlayMenu()
    {
        ShowAnimationsItem.IsChecked = Settings.Current.ShowAnimations;
        foreach (var mi in ResolutionMenu.Items.OfType<MenuItem>()) mi.IsChecked = (string)mi.Tag == Settings.Current.AnimationHeight.ToString();
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
            case "present":
                OnPresentEvent(ev);
                break;
            case "export":
                OnExportEvent(ev, movie: false);
                break;
            case "export_movie":
                OnExportEvent(ev, movie: true);
                break;
            case "import":
                OnImportEvent(ev);
                break;
            case "animation_preview":
                OnPreviewEvent(ev);
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
        if (ctrl && !shift && key == Key.N) { NewDeck_Click(sender, e); e.Handled = true; return; }
        if (key == Key.F5 && ctrl && shift) { PreviewAnimations_Click(sender, e); e.Handled = true; return; }
        if (key == Key.F5 && Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) { PresenterView_Click(sender, e); e.Handled = true; return; }
        if (key == Key.F5) { if (shift) PlayCurrent_Click(sender, e); else PlayBeginning_Click(sender, e); e.Handled = true; return; }
        if (ctrl && key == Key.Oem3) { ShowTerminal_Click(sender, e); e.Handled = true; return; }
        if (ctrl && key == Key.F) { OpenFind(false); e.Handled = true; return; }
        if (ctrl && key == Key.H) { OpenFind(true); e.Handled = true; return; }
        if (key == Key.F3) { _ = StepFind(shift ? -1 : +1); e.Handled = true; return; }
        if (ctrl && key is Key.OemPlus or Key.Add) { canvas.ZoomBy(1.25); e.Handled = true; return; }
        if (ctrl && key is Key.OemMinus or Key.Subtract) { canvas.ZoomBy(0.8); e.Handled = true; return; }
        if (ctrl && key is Key.D0 or Key.NumPad0) { canvas.Zoom = null; e.Handled = true; return; }
        if (ctrl && shift && key == Key.R) { SetRulers(!RulerItem.IsChecked); e.Handled = true; return; }
        if (ctrl && key == Key.OemQuotes) { GridItem.IsChecked = !GridItem.IsChecked; canvas.ShowGrid = GridItem.IsChecked; e.Handled = true; return; }
        // typing in a text field: its own keys
        if (Keyboard.FocusedElement is TextBox || SourceEditor.IsKeyboardFocusWithin || canvas.IsEditingText) return;
        if (ctrl && key == Key.Z) { _ = UndoRedo(shift ? "redo" : "undo"); e.Handled = true; return; }
        if (ctrl && key == Key.Y) { _ = UndoRedo("redo"); e.Handled = true; return; }
        if (ctrl && shift && key == Key.N) { NewSlide_Click(sender, e); e.Handled = true; return; }
        if (ctrl && shift && key == Key.T) { InsertText_Click(sender, e); e.Handled = true; return; }
        if (ctrl && shift && key == Key.E) { InsertFormula_Click(sender, e); e.Handled = true; return; }
        if (ctrl && shift && key == Key.I) { InsertImage_Click(sender, e); e.Handled = true; return; }
        if (ctrl && shift && key == Key.P) { canvas.DrawTool = canvas.DrawTool == "pen" ? null : "pen"; e.Handled = true; return; }
        if (ctrl && shift && key == Key.B) { NewBuild_Click(sender, e); e.Handled = true; return; }
        if (ctrl && shift && key == Key.A) { SpreadLastMove(); e.Handled = true; return; }
        if (ctrl && !shift && key == Key.C) { CopySelection(); e.Handled = true; return; }
        if (ctrl && !shift && key == Key.X) { CutSelection(); e.Handled = true; return; }
        if (ctrl && !shift && key == Key.V) { PasteOnSlide(); e.Handled = true; return; }
        if (ctrl && !shift && key == Key.B) { ToggleBold(); e.Handled = true; return; }
        if (ctrl && key == Key.I && !shift) { ToggleItalic(); e.Handled = true; return; }
        if (ctrl && key == Key.U) { Decorate("underline"); e.Handled = true; return; }
        if (ctrl && key == Key.K) { Hyperlink_Click(sender, e); e.Handled = true; return; }
        if (ctrl && !shift && key == Key.G) { GroupSelection(); e.Handled = true; return; }
        if (ctrl && shift && key == Key.G) { UngroupSelection(); e.Handled = true; return; }
        if (ctrl && key == Key.OemCloseBrackets) { ArrangeSelection(shift ? "front" : "forward"); e.Handled = true; return; }
        if (ctrl && key == Key.OemOpenBrackets) { ArrangeSelection(shift ? "back" : "backward"); e.Handled = true; return; }
        if (ctrl && shift && key == Key.OemPeriod) { Bigger_Click(sender, e); e.Handled = true; return; }
        if (ctrl && shift && key == Key.OemComma) { Smaller_Click(sender, e); e.Handled = true; return; }
        if (key == Key.Escape && canvas.DrawTool != null) { canvas.DrawTool = null; e.Handled = true; return; }
        if (key == Key.Escape && FindBar.Visibility == Visibility.Visible && canvas.Selected.Count == 0) { CloseFind(); e.Handled = true; return; }
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
            case Key.Enter when canvas.Selected.Count == 1:
                if (PlotOf(canvas.Selected[0]) != null) EditPlot(canvas.Selected[0]); else canvas.BeginTextEdit(canvas.Selected[0]);
                e.Handled = true; break;
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
