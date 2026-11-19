using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Manimble;

/// The Script panel, in the inspector's place (View > Script…): the script of the build on screen as a list of steps
/// (Speak, Mouse, Pause) with Add buttons, and the deck's voice settings. ▶ on a step plays it on the slide; Play
/// Build plays them all. A Mouse step's track is set by clicking (a target) or dragging (a track) on the slide.
public sealed class ScriptPane : Border
{
    readonly ScriptStore store;
    readonly TextBlock where = new() { FontSize = 11, FontWeight = FontWeights.SemiBold, Opacity = 0.7, Margin = new Thickness(0, 0, 0, 6) };
    readonly StackPanel list = new();
    readonly TextBlock empty = new()
    {
        Text = "No script for this build. Add words to speak, pointer moves and pauses; Play ▸ Scripted Presentation plays them build by build.",
        TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.7, Margin = new Thickness(0, 4, 0, 4),
    };
    readonly Button playAll = new() { Content = "▶  Play Build", HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(10, 2, 10, 2) };
    readonly ComboBox voice = new() { MinWidth = 160 };
    readonly Slider rate = new() { Minimum = 0.3, Maximum = 0.7, Width = 140, VerticalAlignment = VerticalAlignment.Center, ToolTip = "Speaking speed" };
    readonly TextBox hold = new() { Width = 40, TextAlignment = TextAlignment.Right, ToolTip = "How long a build with no script stays up in a scripted presentation" };

    public string? Scene { get; private set; }
    public int Build { get; private set; }
    public string? Selected { get; private set; }
    public string? Capturing { get; private set; }

    public event Action? Closed;
    public event Action<ScriptStep>? PlayStep;
    public event Action? PlayAll;
    public event Action? StopPlaying;
    /// The step whose track is shown (and set) on the slide changed.
    public event Action? TracksChanged;

    bool playing;
    public bool Playing { get => playing; set { playing = value; playAll.Content = value ? "■  Stop" : "▶  Play Build"; } }

    public ScriptPane(ScriptStore store)
    {
        this.store = store;
        SetResourceReference(BackgroundProperty, SystemColors.WindowBrushKey);
        Padding = new Thickness(10, 6, 10, 8);

        var done = new Button { Content = "Done", Padding = new Thickness(10, 1, 10, 1), ToolTip = "Back to the inspector" };
        done.Click += (_, _) => Closed?.Invoke();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        DockPanel.SetDock(done, Dock.Right);
        head.Children.Add(done);
        var titles = new StackPanel();
        titles.Children.Add(new TextBlock { Text = "SCRIPT", FontSize = 11, FontWeight = FontWeights.SemiBold, Opacity = 0.7 });
        titles.Children.Add(new TextBlock { Text = "words to speak and pointer moves", FontSize = 11, Opacity = 0.5 });
        head.Children.Add(titles);

        Button Add(string label, string kind, string tip)
        {
            var b = new Button { Content = label, Margin = new Thickness(0, 0, 4, 0), Padding = new Thickness(8, 2, 8, 2), ToolTip = tip };
            b.Click += (_, _) => AddStep(kind);
            return b;
        }
        var adds = new WrapPanel { Margin = new Thickness(0, 0, 0, 6) };
        adds.Children.Add(Add("+ Speak", "speak", "Add words to be read out by text to speech"));
        adds.Children.Add(Add("+ Mouse", "move", "Add a pointer move: click on the slide for where it goes, or drag to trace its track"));
        adds.Children.Add(Add("+ Pause", "pause", "Add a pause"));

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = list };

        playAll.Click += (_, _) => { if (Playing) StopPlaying?.Invoke(); else PlayAll?.Invoke(); };
        voice.Items.Add(new ComboBoxItem { Content = "System voice", Tag = null });
        foreach (var v in ScriptPerformer.Voices()) voice.Items.Add(new ComboBoxItem { Content = v, Tag = v });
        voice.SelectedIndex = Math.Max(0, voice.Items.Cast<ComboBoxItem>().ToList().FindIndex(i => (string?)i.Tag == store.WindowsVoice));
        voice.SelectionChanged += (_, _) => { store.SetVoice((voice.SelectedItem as ComboBoxItem)?.Tag as string); };
        rate.Value = store.Rate;
        rate.ValueChanged += (_, _) => { store.SetRate((float)Math.Round(rate.Value, 2)); };
        hold.Text = store.Hold.ToString("0.##");
        hold.LostFocus += (_, _) => CommitHold();
        hold.KeyDown += (_, e) => { if (e.Key == Key.Enter) CommitHold(); };
        static TextBlock L(string s) => new() { Text = s, FontSize = 12, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
        var voiceRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        voiceRow.Children.Add(L("Voice")); voiceRow.Children.Add(voice);
        var rateRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        rateRow.Children.Add(L("Speaking speed")); rateRow.Children.Add(rate);
        var holdRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        holdRow.Children.Add(L("Builds with no script stay up")); holdRow.Children.Add(hold); holdRow.Children.Add(L(" s"));
        var foot = new StackPanel { Margin = new Thickness(0, 8, 0, 0) };
        foot.Children.Add(new Separator());
        foot.Children.Add(playAll); foot.Children.Add(voiceRow); foot.Children.Add(rateRow); foot.Children.Add(holdRow);

        var top = new StackPanel();
        top.Children.Add(head); top.Children.Add(new Separator()); top.Children.Add(where); top.Children.Add(adds);
        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top); DockPanel.SetDock(foot, Dock.Bottom);
        root.Children.Add(top); root.Children.Add(foot); root.Children.Add(scroll);
        Child = root;
        store.Changed += () => { if (!editingText) Rebuild(); TracksChanged?.Invoke(); };
    }

    void CommitHold()
    {
        if (double.TryParse(hold.Text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var h) ||
            double.TryParse(hold.Text, out h))
            store.SetHold(Math.Clamp(h, 0, 600));
        hold.Text = store.Hold.ToString("0.##");
    }

    /// The build on screen in the editor.
    public void SetPage(string? scene, int build)
    {
        if (scene == Scene && build == Build) return;
        Scene = scene; Build = build;
        Selected = null; Capturing = null;
        Rebuild();
        TracksChanged?.Invoke();
    }

    public List<ScriptStep> Steps => Scene == null ? new() : store.StepsOf(Scene, Build);

    void AddStep(string kind)
    {
        if (Scene == null) return;
        var s = store.Add(kind, Scene, Build);
        Selected = s.Id;
        Capturing = kind == "move" ? s.Id : null;       // a new move goes straight to setting its track
        Rebuild();
        TracksChanged?.Invoke();
    }

    /// A track set on the slide for the step being captured.
    public void Captured(List<Point> pts)
    {
        if (Capturing is not { } id) return;
        Capturing = null;
        store.Update(id, s => s.Path = pts.Select(p => new[] { Math.Round(p.X, 4), Math.Round(p.Y, 4) }).ToList());
        TracksChanged?.Invoke();
    }

    public void CancelCapture()
    {
        if (Capturing == null) return;
        Capturing = null;
        Rebuild();
        TracksChanged?.Invoke();
    }

    bool editingText;

    void Rebuild()
    {
        list.Children.Clear();
        where.Text = Scene == null ? "No slide" : $"{Scene} · build {Build + 1}";
        var steps = Steps;
        if (steps.Count == 0) { list.Children.Add(empty); return; }
        int n = 0, moves = 0;
        foreach (var s in steps)
        {
            n++;
            if (s.Kind == "move") moves++;
            list.Children.Add(Row(s, n, moves));
        }
    }

    FrameworkElement Row(ScriptStep s, int n, int moveNumber)
    {
        var sel = s.Id == Selected;
        var box = new Border
        {
            BorderThickness = new Thickness(sel ? 2 : 1), CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 4, 6, 6),
            Margin = new Thickness(0, 0, 0, 6),
            BorderBrush = sel ? (Brush)Application.Current.Resources["SelectionBrush"] : new SolidColorBrush(Color.FromArgb(0x40, 0x80, 0x80, 0x80)),
            Background = Brushes.Transparent,
        };
        box.PreviewMouseLeftButtonDown += (_, _) =>
        {
            if (Selected == s.Id) return;
            Selected = s.Id;
            foreach (var b in list.Children.OfType<Border>()) { b.BorderThickness = new Thickness(1); b.BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0x80, 0x80, 0x80)); }
            box.BorderThickness = new Thickness(2); box.BorderBrush = (Brush)Application.Current.Resources["SelectionBrush"];
            TracksChanged?.Invoke();
        };
        Button Small(string label, string tip, Action a)
        {
            var b = new Button { Content = label, Padding = new Thickness(5, 0, 5, 0), Margin = new Thickness(2, 0, 0, 0), FontSize = 11, ToolTip = tip, MinWidth = 22 };
            b.Click += (_, e) => { a(); e.Handled = true; };
            return b;
        }
        var title = s.Kind switch { "speak" => "Speak", "move" => $"Mouse {moveNumber}", _ => "Pause" };
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        var tools = new StackPanel { Orientation = Orientation.Horizontal };
        tools.Children.Add(Small("▶", "Play this step on the slide", () => PlayStep?.Invoke(s)));
        tools.Children.Add(Small("↑", "Earlier", () => store.Shift(s.Id, -1)));
        tools.Children.Add(Small("↓", "Later", () => store.Shift(s.Id, 1)));
        tools.Children.Add(Small("✕", "Remove this step", () => { if (Selected == s.Id) Selected = null; if (Capturing == s.Id) Capturing = null; store.Remove(s.Id); }));
        DockPanel.SetDock(tools, Dock.Right);
        head.Children.Add(tools);
        head.Children.Add(new TextBlock { Text = $"{n}.  {title}", FontWeight = FontWeights.SemiBold, FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
        var body = new StackPanel();
        body.Children.Add(head);
        switch (s.Kind)
        {
            case "speak":
            {
                var t = new TextBox { Text = s.Text, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 44, FontSize = 12.5, ToolTip = "The words to read out" };
                t.GotFocus += (_, _) => editingText = true;
                t.LostFocus += (_, _) => { editingText = false; store.Update(s.Id, x => x.Text = t.Text); };
                body.Children.Add(t);
                break;
            }
            case "pause":
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal };
                var t = new TextBox { Text = s.Seconds.ToString("0.##"), Width = 50, TextAlignment = TextAlignment.Right };
                void Commit()
                {
                    if (double.TryParse(t.Text, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) || double.TryParse(t.Text, out v))
                        store.Update(s.Id, x => x.Seconds = Math.Clamp(v, 0, 600));
                }
                t.LostFocus += (_, _) => Commit();
                t.KeyDown += (_, e) => { if (e.Key == Key.Enter) Commit(); };
                row.Children.Add(new TextBlock { Text = "Wait", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0), FontSize = 12 });
                row.Children.Add(t);
                row.Children.Add(new TextBlock { Text = " seconds", VerticalAlignment = VerticalAlignment.Center, FontSize = 12 });
                body.Children.Add(row);
                break;
            }
            case "move":
            {
                var pts = s.Points.Count;
                var set = new ToggleButton
                {
                    Content = Capturing == s.Id ? "Click or drag on the slide…" : pts == 0 ? "Set on Slide" : "Set Again",
                    IsChecked = Capturing == s.Id, Padding = new Thickness(8, 1, 8, 1), Margin = new Thickness(0, 0, 0, 4), HorizontalAlignment = HorizontalAlignment.Left,
                    ToolTip = "Click on the slide for where the pointer goes, or drag to trace its track",
                };
                set.Click += (_, _) =>
                {
                    Selected = s.Id;
                    Capturing = Capturing == s.Id ? null : s.Id;
                    Rebuild();
                    TracksChanged?.Invoke();
                };
                body.Children.Add(set);
                body.Children.Add(new TextBlock
                {
                    Text = pts == 0 ? "Not set yet" : pts == 1 ? "Goes straight to a point" : $"Follows a traced track ({pts} points)",
                    FontSize = 11.5, Opacity = 0.65, Margin = new Thickness(0, 0, 0, 4),
                });
                var speed = new ComboBox { Width = 100, FontSize = 12 };
                foreach (var (name, v) in ScriptStep.Speeds) speed.Items.Add(new ComboBoxItem { Content = name, Tag = v });
                speed.SelectedIndex = Array.FindIndex(ScriptStep.Speeds, x => Math.Abs(x.value - s.Speed) < 1e-6) is var k && k >= 0 ? k : 1;
                speed.SelectionChanged += (_, _) => { if ((speed.SelectedItem as ComboBoxItem)?.Tag is double v) store.Update(s.Id, x => x.Speed = v); };
                var wobble = new Slider { Minimum = 0, Maximum = 1, Value = s.Noise, Width = 90, VerticalAlignment = VerticalAlignment.Center, ToolTip = "Steady … a shaky hand" };
                wobble.PreviewMouseLeftButtonUp += (_, _) => store.Update(s.Id, x => x.Noise = Math.Round(wobble.Value, 2));
                wobble.LostFocus += (_, _) => store.Update(s.Id, x => x.Noise = Math.Round(wobble.Value, 2));
                var row = new WrapPanel();
                row.Children.Add(new TextBlock { Text = "Speed", FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) });
                row.Children.Add(speed);
                row.Children.Add(new TextBlock { Text = "Wobble", FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 4, 0) });
                row.Children.Add(wobble);
                body.Children.Add(row);
                break;
            }
        }
        box.Child = body;
        return box;
    }

    /// Fewer points for a traced track: drops those within a hair of the line through their neighbours.
    public static List<Point> Thin(List<Point> pts, double tolerance = 0.002)
    {
        if (pts.Count <= 2) return pts;
        var outp = new List<Point> { pts[0] };
        for (int i = 1; i < pts.Count - 1; i++)
        {
            Point a = outp[^1], b = pts[i], c = pts[i + 1];
            var len = (c - a).Length;
            var dist = len > 0 ? Math.Abs((c.X - a.X) * (a.Y - b.Y) - (a.X - b.X) * (c.Y - a.Y)) / len : (b - a).Length;
            if (dist > tolerance) outp.Add(b);
        }
        outp.Add(pts[^1]);
        return outp;
    }
}

public partial class MainWindow
{
    ScriptStore? script;
    ScriptPane? scriptPane;
    ScriptPerformer? preview;
    readonly ScriptPointer previewPointer = new();
    List<Point>? trace;
    bool scriptedPending;

    /// The deck's script, read when a deck opens.
    void LoadScript()
    {
        HideScript();
        scriptPane = null;
        script = workspace is { } ws ? new ScriptStore(System.IO.Path.Combine(ws.Work, "script.json"), File.Exists(System.IO.Path.Combine(ws.Original, "script.json"))) : null;
    }

    void Script_Click(object sender, RoutedEventArgs e)
    {
        if (script == null) { Toast("Open a deck first", error: true); return; }
        if (scriptPane == null)
        {
            scriptPane = new ScriptPane(script);
            scriptPane.Closed += HideScript;
            scriptPane.TracksChanged += DrawScriptTracks;
            scriptPane.PlayStep += s => _ = PreviewSteps(new List<ScriptStep> { s }, script.PointerBefore(s.Id));
            scriptPane.PlayAll += () => _ = PreviewSteps(scriptPane.Steps, null);
            scriptPane.StopPlaying += StopScriptPreview;
        }
        if (SourcePane.Visibility != Visibility.Visible) { ShowSourceItem.IsChecked = true; ToggleSource_Click(this, new RoutedEventArgs()); }
        PanelHost.Child = scriptPane;
        PanelHost.Visibility = Visibility.Visible;
        ScriptPageChanged();
        DrawScriptTracks();
    }

    void HideScript()
    {
        StopScriptPreview();
        if (PanelHost.Child is ScriptPane && PanelHost.Child == scriptPane) { scriptPane?.CancelCapture(); PanelHost.Visibility = Visibility.Collapsed; }
        canvas.Annotations.Children.Clear();
        SetCapture(false);
    }

    bool ScriptShown => scriptPane != null && PanelHost.Child == scriptPane && PanelHost.Visibility == Visibility.Visible;

    /// The editor moved to another slide or build.
    void ScriptPageChanged()
    {
        if (!ScriptShown) return;
        StopScriptPreview();
        scriptPane!.SetPage(sceneName, stopIndex);
    }

    // ---------------------------------------------------------------- the tracks on the canvas

    Rect FrameRect => new(0, 0, canvas.FrameSize.Width, canvas.FrameSize.Height);

    /// The selected move's track (dashed, from where the pointer was) and the capture hint, over the slide.
    void DrawScriptTracks()
    {
        var a = canvas.Annotations;
        a.Children.Clear();
        if (!ScriptShown || scriptPane == null) { SetCapture(false); return; }
        var r = FrameRect;
        var accent = (SolidColorBrush)Application.Current.Resources["SelectionBrush"];
        double px = 1 / Math.Max(0.05, canvas.CurrentZoom);           // strokes and labels in screen pixels
        Point? from = null;
        int n = 0;
        foreach (var s in scriptPane.Steps.Where(t => t.Kind == "move"))
        {
            n++;
            var pts = s.Points;
            if (pts.Count == 0) continue;
            var end = pts[^1];
            var prev = from;
            from = end;
            if (s.Id != scriptPane.Selected && s.Id != scriptPane.Capturing) continue;   // only the picked step's track shows
            var line = new Polyline { Stroke = accent, StrokeThickness = 3 * px, StrokeDashArray = new DoubleCollection { 3, 2.5 }, StrokeLineJoin = PenLineJoin.Round, IsHitTestVisible = false };
            line.Points.Add(Scale(prev ?? pts[0], r));
            foreach (var p in pts) line.Points.Add(Scale(p, r));
            a.Children.Add(line);
            var e = Scale(end, r);
            double rad = 11 * px;
            var ring = new Ellipse { Width = 2 * rad, Height = 2 * rad, Fill = accent, IsHitTestVisible = false };
            Canvas.SetLeft(ring, e.X - rad); Canvas.SetTop(ring, e.Y - rad);
            a.Children.Add(ring);
            var label = new TextBlock { Text = n.ToString(), Foreground = Brushes.White, FontWeight = FontWeights.Bold, FontSize = 13 * px, Width = 2 * rad, TextAlignment = TextAlignment.Center, IsHitTestVisible = false };
            Canvas.SetLeft(label, e.X - rad); Canvas.SetTop(label, e.Y - 9 * px);
            a.Children.Add(label);
        }
        var capturing = scriptPane.Capturing != null;
        if (capturing)
        {
            a.Children.Add(new Rectangle { Width = r.Width, Height = r.Height, Stroke = accent, StrokeThickness = 6 * px, IsHitTestVisible = false });
            var hint = new Border
            {
                Background = accent, CornerRadius = new CornerRadius(4 * px), Padding = new Thickness(10 * px, 4 * px, 10 * px, 4 * px), IsHitTestVisible = false,
                Child = new TextBlock { Text = "Click to set where the pointer goes, or drag to trace its track · Esc cancels", Foreground = Brushes.White, FontSize = 16 * px },
            };
            hint.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(hint, (r.Width - hint.DesiredSize.Width) / 2); Canvas.SetTop(hint, 12 * px);
            a.Children.Add(hint);
            if (trace is { Count: > 1 })
            {
                var t = new Polyline { Stroke = accent, StrokeThickness = 4 * px, StrokeLineJoin = PenLineJoin.Round, IsHitTestVisible = false };
                foreach (var p in trace) t.Points.Add(Scale(p, r));
                a.Children.Add(t);
            }
        }
        a.Children.Add(previewPointer.Shape);
        SetCapture(capturing);
    }

    static Point Scale(Point p, Rect r) => new(r.X + r.Width * p.X, r.Y + r.Height * p.Y);

    Point ToSlide(Point framePx)
    {
        var fs = canvas.FrameSize;
        return new Point(Math.Clamp(framePx.X / fs.Width, 0, 1), Math.Clamp(framePx.Y / fs.Height, 0, 1));
    }

    bool captureHooked;

    /// While a move's track is being set, the slide takes clicks and drags for it instead of selecting objects.
    void SetCapture(bool on)
    {
        var a = canvas.Annotations;
        a.IsHitTestVisible = on;
        a.Background = on ? Brushes.Transparent : null;
        a.Cursor = on ? Cursors.Cross : null;
        if (!on || captureHooked) return;
        captureHooked = true;
        a.MouseLeftButtonDown += (_, e) =>
        {
            if (scriptPane?.Capturing == null) return;
            trace = new List<Point> { ToSlide(e.GetPosition(a)) };
            a.CaptureMouse();
            e.Handled = true;
        };
        a.MouseMove += (_, e) =>
        {
            if (trace == null || e.LeftButton != MouseButtonState.Pressed) return;
            var p = ToSlide(e.GetPosition(a));
            var fs = canvas.FrameSize;
            var l = trace[^1];
            if (Math.Sqrt(Math.Pow((p.X - l.X) * fs.Width, 2) + Math.Pow((p.Y - l.Y) * fs.Height, 2)) * canvas.CurrentZoom >= 3) { trace.Add(p); DrawScriptTracks(); }
        };
        a.MouseLeftButtonUp += (_, e) =>
        {
            if (trace == null) return;
            a.ReleaseMouseCapture();
            var fs = canvas.FrameSize;
            var first = trace[0];
            var span = trace.Max(p => Math.Sqrt(Math.Pow((p.X - first.X) * fs.Width, 2) + Math.Pow((p.Y - first.Y) * fs.Height, 2))) * canvas.CurrentZoom;
            // a press that hardly moved sets a target; a drag keeps the track
            var pts = ScriptPane.Thin(span < 6 ? new List<Point> { first } : trace);
            trace = null;
            scriptPane?.Captured(pts);
            e.Handled = true;
        };
    }

    // ---------------------------------------------------------------- previews in the editor

    async Task PreviewSteps(List<ScriptStep> steps, Point? start)
    {
        StopScriptPreview();
        if (script == null || scriptPane == null || steps.Count == 0) return;
        var p = new ScriptPerformer { Voice = script.WindowsVoice, Rate = script.Rate, Pointer = start };
        preview = p;
        p.SlideSize = () => canvas.FrameSize;
        p.Draw = q => previewPointer.Place(q, FrameRect);
        if (!canvas.Annotations.Children.Contains(previewPointer.Shape)) canvas.Annotations.Children.Add(previewPointer.Shape);
        p.Draw(start);
        scriptPane.Playing = true;
        foreach (var s in steps)
        {
            await p.Perform(s);
            if (p.Stopped) break;
        }
        if (preview == p) { await p.Wait(0.6); if (preview == p) StopScriptPreview(); }
    }

    void StopScriptPreview()
    {
        preview?.Dispose();
        preview = null;
        previewPointer.Place(null, Rect.Empty);
        if (scriptPane != null) scriptPane.Playing = false;
    }

    // ---------------------------------------------------------------- the scripted presentation

    async void ScriptedPresentation_Click(object sender, RoutedEventArgs e) => await StartScripted(null);
    async void ScriptedPresentationCurrent_Click(object sender, RoutedEventArgs e) => await StartScripted(sceneName);

    async Task StartScripted(string? from)
    {
        if (workspace == null || script == null) return;
        if (script.IsEmpty) Toast($"This deck has no script yet (View ▸ Script…): every build stays up {script.Hold:0.#} s");
        await FinishEdits();
        HideScript();
        var start = from ?? state?.Scenes.FirstOrDefault(s => s.Hidden != true)?.Name;
        if (start == null) return;
        scriptedPending = true;
        await StartPresent(start);              // the animated show: the script runs on its pages
        if (!presentPending && animatedShow == null) scriptedPending = false;
    }

    /// The show just opened: a scripted presentation starts its script on it.
    void StartScriptOn(AnimatedShowWindow show)
    {
        if (!scriptedPending || script == null) return;
        scriptedPending = false;
        new ScriptRunner(script, show).Start();
    }
}
