using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Manimble;

/// One feedback note (the Mac's Feedback.swift): red text pinned to a point of a slide, typed in Presenter View's
/// Feedback Mode (or in the editor). The audience never sees it: notes live in `feedback.json` beside the deck, not
/// in the Python, so nothing renders and no slide goes stale.
public sealed class FeedbackNote
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Scene { get; set; } = "";
    public int Build { get; set; }                    // the build it was typed on (shown on every build of the slide)
    public double X { get; set; }                     // top-left corner, as fractions of the slide (y from the top)
    public double Y { get; set; }
    public double W { get; set; } = DefaultWidth;     // wrap width, as a fraction of the slide's width
    public string Text { get; set; } = "";
    public DateTime Created { get; set; } = DateTime.UtcNow;

    public const double DefaultWidth = 0.32;
}

/// The deck's feedback notes, in `feedback.json` of the working copy (Save carries them to the original like any
/// other edit; closing without saving drops them). The file is the Mac app's.
public sealed class FeedbackStore
{
    readonly string path;
    readonly bool keepEmptyFile;
    List<FeedbackNote> notes = new();
    public event Action? Changed;

    sealed class FileData { public int Version { get; set; } = 1; public List<FeedbackNote> Notes { get; set; } = new(); }

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, WriteIndented = true,
        Converters = { new Iso8601() },
    };

    /// Dates as the Mac writes them (ISO 8601 in UTC, whole seconds).
    sealed class Iso8601 : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o) =>
            DateTime.TryParse(r.GetString(), null, System.Globalization.DateTimeStyles.AdjustToUniversal | System.Globalization.DateTimeStyles.AssumeUniversal, out var d) ? d : DateTime.UtcNow;
        public override void Write(Utf8JsonWriter w, DateTime v, JsonSerializerOptions o) => w.WriteStringValue(v.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"));
    }

    public FeedbackStore(string path, bool originalHasFile)
    {
        this.path = path;
        keepEmptyFile = originalHasFile;
        try { if (File.Exists(path)) notes = JsonSerializer.Deserialize<FileData>(File.ReadAllText(path), Json)?.Notes ?? new(); }
        catch (Exception e) { Log.Note("feedback.json unreadable: " + e.Message); }
    }

    void Save()
    {
        try
        {
            if (notes.Count == 0 && !keepEmptyFile) { if (File.Exists(path)) File.Delete(path); }
            else File.WriteAllText(path, JsonSerializer.Serialize(new FileData { Notes = notes }, Json));
        }
        catch (Exception e) { Log.Note("feedback.json not saved: " + e.Message); }
        Changed?.Invoke();
    }

    public IReadOnlyList<FeedbackNote> All => notes;
    public bool IsEmpty => notes.Count == 0;
    public List<FeedbackNote> NotesFor(string scene) => notes.Where(n => n.Scene == scene).ToList();
    public FeedbackNote? Note(string id) => notes.FirstOrDefault(n => n.Id == id);
    public bool Has(string scene) => notes.Any(n => n.Scene == scene);

    public FeedbackNote Add(string scene, int build, double x, double y)
    {
        var n = new FeedbackNote { Scene = scene, Build = build, X = Math.Clamp(x, 0, 0.98), Y = Math.Clamp(y, 0, 0.98) };
        notes.Add(n);
        Save();
        return n;
    }

    public void SetText(string id, string text)
    {
        if (Note(id) is not { } n || n.Text == text) return;
        n.Text = text;
        Save();
    }

    public void Move(string id, double x, double y)
    {
        if (Note(id) is not { } n) return;
        n.X = Math.Clamp(x, 0, 0.98); n.Y = Math.Clamp(y, 0, 0.98);
        Save();
    }

    public void Remove(string id) { if (notes.RemoveAll(n => n.Id == id) > 0) Save(); }
    public void RemoveAll() { if (notes.Count == 0) return; notes.Clear(); Save(); }
}

/// The notes of one slide laid over its picture: in the editor (over the canvas, in frame pixels) and in Presenter
/// View (over the current slide). The host says where the slide is (`SlideRect`) and calls Relayout when it moves.
/// Clicks pass through to what is beneath, unless they land on a note, or `Placing` is on (Feedback Mode): then a
/// click on the slide adds a note there and starts typing into it.
public sealed class FeedbackLayer : Canvas
{
    public static readonly Brush Red = Frozen(Color.FromRgb(0xff, 0x2d, 0x2d));
    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    FeedbackStore? store;
    public FeedbackStore? Store { get => store; set { if (store != null) store.Changed -= Rebuild; store = value; if (store != null) store.Changed += Rebuild; Rebuild(); } }
    string? scene;
    public string? Scene { get => scene; set { if (scene == value) return; EndEditing(); scene = value; Rebuild(); } }
    /// The build on screen: what a new note remembers.
    public int Build { get; set; }
    public Func<Rect> SlideRect = () => Rect.Empty;
    /// Fixed sizes in this layer's units per screen pixel (the editor's canvas is zoomed; Presenter View is not).
    public Func<double> PixelSize = () => 1;
    /// A note was added here.
    public event Action? Added;
    bool placing;
    public bool Placing
    {
        get => placing;
        set { placing = value; Background = value ? Brushes.Transparent : null; Cursor = value ? Cursors.Cross : null; }
    }

    readonly Dictionary<string, Border> boxes = new();
    string? dragging;
    Point dragFrom;
    Point dragNoteFrom;

    public FeedbackLayer()
    {
        ClipToBounds = true;
        MouseLeftButtonDown += (_, e) =>
        {
            if (!placing || store == null || scene == null || e.OriginalSource != this) return;
            var r = SlideRect();
            var p = e.GetPosition(this);
            if (r.Width <= 0 || !r.Contains(p)) return;
            var n = store.Add(scene, Build, (p.X - r.X) / r.Width, (p.Y - r.Y) / r.Height);
            Added?.Invoke();
            Dispatcher.BeginInvoke(() => Focus(n.Id), System.Windows.Threading.DispatcherPriority.Loaded);
            e.Handled = true;
        };
        SizeChanged += (_, _) => Relayout();
    }

    /// Font size for the text: about 3.3% of the slide's height (24 px on a 720 px slide).
    static double FontSize(Rect r) => Math.Max(8, Math.Round(r.Height * 0.033));

    /// Boxes for the scene's notes (new notes get one, gone notes lose theirs), laid out.
    public void Rebuild()
    {
        var keep = scene != null && store != null ? store.NotesFor(scene).Select(n => n.Id).ToHashSet() : new HashSet<string>();
        foreach (var id in boxes.Keys.Where(k => !keep.Contains(k)).ToList()) { Children.Remove(boxes[id]); boxes.Remove(id); }
        if (scene != null && store != null)
            foreach (var n in store.NotesFor(scene))
                if (!boxes.ContainsKey(n.Id)) { var b = MakeBox(n); boxes[n.Id] = b; Children.Add(b); }
        Relayout();
    }

    Border MakeBox(FeedbackNote n)
    {
        var text = new TextBox
        {
            Text = n.Text, Foreground = Red, Background = Brushes.Transparent, BorderThickness = new Thickness(0), CaretBrush = Red,
            TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, FontWeight = FontWeights.SemiBold, Padding = new Thickness(0),
            ToolTip = "Feedback · Esc or Ctrl+Enter ends typing · Backspace on an empty note removes it",
        };
        text.Template = PlainTemplate;
        var id = n.Id;
        text.LostFocus += (_, _) => store?.SetText(id, text.Text);
        text.AddHandler(PreviewKeyDownEvent, new KeyEventHandler((_, e) =>
        {
            if (e.Key == Key.Escape || (e.Key == Key.Enter && Keyboard.Modifiers.HasFlag(ModifierKeys.Control))) { store?.SetText(id, text.Text); EndEditing(); e.Handled = true; }
            else if (e.Key is Key.Back or Key.Delete && text.Text.Length == 0) { store?.Remove(id); e.Handled = true; }
        }), true);
        var close = new Button
        {
            Content = "✕", Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Red, Foreground = Brushes.White,
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, ToolTip = "Delete this note", Focusable = false,
        };
        close.Click += (_, e) => { store?.Remove(id); e.Handled = true; };
        var grid = new Grid();
        grid.Children.Add(text);
        grid.Children.Add(close);
        var box = new Border { BorderBrush = Red, Background = new SolidColorBrush(Color.FromArgb(0x01, 0, 0, 0)), Child = grid, Tag = text, Cursor = Cursors.SizeAll };
        text.Cursor = Cursors.IBeam;
        // a press on the frame (outside the text) drags the note
        box.MouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource is not Border || store?.Note(id) is not { } note) return;
            dragging = id; dragFrom = e.GetPosition(this); dragNoteFrom = new Point(note.X, note.Y);
            box.CaptureMouse();
            e.Handled = true;
        };
        box.MouseMove += (_, e) =>
        {
            if (dragging != id || e.LeftButton != MouseButtonState.Pressed) return;
            var r = SlideRect();
            var d = e.GetPosition(this) - dragFrom;
            SetLeft(box, r.X + r.Width * Math.Clamp(dragNoteFrom.X + d.X / r.Width, 0, 0.98));
            SetTop(box, r.Y + r.Height * Math.Clamp(dragNoteFrom.Y + d.Y / r.Height, 0, 0.98));
        };
        box.MouseLeftButtonUp += (_, e) =>
        {
            if (dragging != id) return;
            dragging = null;
            box.ReleaseMouseCapture();
            var r = SlideRect();
            var d = e.GetPosition(this) - dragFrom;
            if (d.Length > 1) store?.Move(id, dragNoteFrom.X + d.X / r.Width, dragNoteFrom.Y + d.Y / r.Height);
            e.Handled = true;
        };
        return box;
    }

    static readonly ControlTemplate PlainTemplate = (ControlTemplate)System.Windows.Markup.XamlReader.Parse(
        "<ControlTemplate TargetType='TextBox' xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>" +
        "<ScrollViewer x:Name='PART_ContentHost' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' " +
        "VerticalScrollBarVisibility='Hidden' HorizontalScrollBarVisibility='Hidden'/></ControlTemplate>");

    /// Puts the boxes where their notes say, sized to the slide.
    public void Relayout()
    {
        var r = SlideRect();
        if (store == null || r.Width <= 0) { foreach (var b in boxes.Values) b.Visibility = Visibility.Collapsed; return; }
        double px = PixelSize(), font = FontSize(r);
        foreach (var (id, b) in boxes)
        {
            if (store.Note(id) is not { } n) continue;
            b.Visibility = Visibility.Visible;
            b.Width = Math.Max(40 * px, r.Width * n.W);
            b.BorderThickness = new Thickness(Math.Max(1, 1.5 * px));
            b.Padding = new Thickness(5 * px, 3 * px, 5 * px, 3 * px);
            if (b.Tag is TextBox t) { t.FontSize = font; t.MinHeight = font * 1.3; }
            if (b.Child is Grid g && g.Children[1] is Button c) { c.Width = c.Height = 16 * px; c.FontSize = 10 * px; c.Margin = new Thickness(0, -3 * px - 8 * px, -5 * px - 8 * px, 0); }
            SetLeft(b, r.X + r.Width * n.X);
            SetTop(b, r.Y + r.Height * n.Y);
        }
    }

    /// Starts typing into a note (also after a jump to its slide from the feedback list).
    public void Focus(string id)
    {
        if (!boxes.TryGetValue(id, out var b) || b.Tag is not TextBox t) return;
        t.Focus();
        t.CaretIndex = t.Text.Length;
    }

    /// Whether one of this layer's notes is being typed into.
    public bool IsEditing => boxes.Values.Any(b => b.Tag is TextBox t && t.IsKeyboardFocusWithin);

    /// Ends typing (the text is saved as it loses focus) and hands the keys back.
    public void EndEditing()
    {
        if (!IsEditing) return;
        foreach (var b in boxes.Values) if (b.Tag is TextBox t && t.IsKeyboardFocusWithin) store?.SetText(boxes.First(kv => kv.Value == b).Key, t.Text);
        Keyboard.ClearFocus();
        if (Window.GetWindow(this) is { } w) w.Focus();
    }
}

/// The feedback list (View > Feedback…), in the inspector's place: every note grouped by slide, with Previous and
/// Next to walk through them, a delete button on each, Delete All, and Add Note to place one on the editor's slide.
public sealed class FeedbackPane : Border
{
    readonly FeedbackStore store;
    readonly Func<string, string> slideLabel;
    readonly Func<string, int> slideOrder;
    readonly StackPanel list = new();
    readonly TextBlock counter = new() { FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    public readonly System.Windows.Controls.Primitives.ToggleButton AddNote = new()
    {
        Content = "Add Note on Slide", Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(0, 0, 0, 6), HorizontalAlignment = HorizontalAlignment.Left,
        ToolTip = "Click on the slide to type a red note there (Presenter View's Feedback Mode, F, does the same during a show)",
    };
    string? current;
    public event Action? Closed;
    public event Action<FeedbackNote>? Go;

    public FeedbackPane(FeedbackStore store, Func<string, string> slideLabel, Func<string, int> slideOrder)
    {
        this.store = store;
        this.slideLabel = slideLabel;
        this.slideOrder = slideOrder;
        SetResourceReference(BackgroundProperty, SystemColors.WindowBrushKey);
        Padding = new Thickness(10, 6, 10, 8);
        var done = new Button { Content = "Done", Padding = new Thickness(10, 1, 10, 1), ToolTip = "Back to the inspector" };
        done.Click += (_, _) => Closed?.Invoke();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        DockPanel.SetDock(done, Dock.Right);
        head.Children.Add(done);
        var titles = new StackPanel();
        titles.Children.Add(new TextBlock { Text = "FEEDBACK", FontSize = 11, FontWeight = FontWeights.SemiBold, Opacity = 0.7 });
        titles.Children.Add(new TextBlock { Text = "red notes from Presenter View", FontSize = 11, Opacity = 0.5 });
        head.Children.Add(titles);
        Button B(string s, string tip, Action a) { var b = new Button { Content = s, Padding = new Thickness(8, 1, 8, 1), ToolTip = tip }; b.Click += (_, _) => a(); return b; }
        var nav = new DockPanel { Margin = new Thickness(0, 6, 0, 6) };
        var prev = B("‹", "Previous feedback", () => Step(-1));
        var next = B("›", "Next feedback", () => Step(1));
        var clear = B("Delete All", "Delete every note", () =>
        {
            if (MessageBox.Show(Window.GetWindow(this), "Delete every feedback note in this deck?", "Delete All Feedback", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
                store.RemoveAll();
        });
        clear.Margin = new Thickness(6, 0, 0, 0);
        DockPanel.SetDock(prev, Dock.Left); DockPanel.SetDock(clear, Dock.Right); DockPanel.SetDock(next, Dock.Right);
        nav.Children.Add(prev); nav.Children.Add(clear); nav.Children.Add(next); nav.Children.Add(counter);
        var top = new StackPanel();
        top.Children.Add(head); top.Children.Add(new Separator()); top.Children.Add(nav); top.Children.Add(AddNote);
        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);
        root.Children.Add(new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = list });
        Child = root;
        store.Changed += Reload;
        Reload();
    }

    /// Notes in slide order, as listed.
    List<FeedbackNote> Ordered => store.All.OrderBy(n => slideOrder(n.Scene)).ThenBy(n => n.Created).ToList();

    public void Reload()
    {
        list.Children.Clear();
        var all = Ordered;
        if (all.Count == 0) list.Children.Add(new TextBlock { Text = "No feedback", Opacity = 0.6, Margin = new Thickness(2, 6, 0, 0) });
        string? last = null;
        foreach (var n in all)
        {
            if (n.Scene != last)
            {
                last = n.Scene;
                list.Children.Add(new TextBlock { Text = slideLabel(n.Scene).ToUpperInvariant(), FontSize = 10.5, FontWeight = FontWeights.SemiBold, Opacity = 0.6, Margin = new Thickness(2, 8, 0, 2) });
            }
            var row = new DockPanel { Margin = new Thickness(0, 0, 0, 2) };
            var del = new Button { Content = "✕", Padding = new Thickness(5, 0, 5, 0), ToolTip = "Delete this note", VerticalAlignment = VerticalAlignment.Top };
            var id = n.Id;
            del.Click += (_, _) => store.Remove(id);
            DockPanel.SetDock(del, Dock.Right);
            row.Children.Add(del);
            var text = new Button
            {
                Content = new TextBlock { Text = n.Text.Length > 0 ? n.Text : "(empty note)", TextWrapping = TextWrapping.Wrap, Foreground = FeedbackLayer.Red },
                HorizontalContentAlignment = HorizontalAlignment.Left, Background = id == current ? new SolidColorBrush(Color.FromArgb(0x30, 0xff, 0x2d, 0x2d)) : Brushes.Transparent,
                BorderThickness = new Thickness(0), Padding = new Thickness(6, 3, 6, 3), ToolTip = "Show it on its slide",
            };
            text.Click += (_, _) => { current = id; Reload(); Go?.Invoke(n); };
            row.Children.Add(text);
            list.Children.Add(row);
        }
        var i = current == null ? -1 : all.FindIndex(n => n.Id == current);
        counter.Text = all.Count == 0 ? "" : i >= 0 ? $"{i + 1} of {all.Count}" : $"{all.Count} note{(all.Count == 1 ? "" : "s")}";
    }

    void Step(int d)
    {
        var all = Ordered;
        if (all.Count == 0) return;
        var i = current == null ? (d > 0 ? -1 : all.Count) : all.FindIndex(n => n.Id == current);
        var j = Math.Clamp(i + d, 0, all.Count - 1);
        current = all[j].Id;
        Reload();
        Go?.Invoke(all[j]);
    }
}
