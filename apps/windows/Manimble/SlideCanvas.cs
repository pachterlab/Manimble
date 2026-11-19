using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Manimble;

/// The slide canvas (the Mac's Metal CanvasView). It shows the exact frame of a build when idle; while an object is
/// dragged, or while an optimistic edit waits for its verifying render, it composites the backdrop and the
/// per-object sprites the engine wrote, so edits show at once. Coordinates are frame pixels throughout: the frame
/// sits in a Viewbox, so a mouse position read against `frame` is already in the engine's coordinates.
public sealed class SlideCanvas : Border
{
    readonly Viewbox viewbox = new() { Stretch = Stretch.Uniform, StretchDirection = StretchDirection.Both };
    readonly Grid frame = new() { ClipToBounds = true, Background = Brushes.Black };
    readonly Image exact = new() { Stretch = Stretch.Fill };
    readonly Canvas composite = new() { IsHitTestVisible = false };
    readonly Canvas overlay = new() { Background = Brushes.Transparent };
    readonly TextBlock emptyText = new()
    {
        Foreground = new SolidColorBrush(Color.FromRgb(0x9a, 0x9b, 0xa0)), FontSize = 15,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(40),
    };

    public SceneData? Scene { get; private set; }
    public int StopIndex { get; private set; }
    public StopInfo? Stop => Scene?.Stops is { Count: > 0 } s ? s[Math.Clamp(StopIndex, 0, s.Count - 1)] : null;
    public List<int> Selected { get; } = new();
    /// Objects shown shifted by hand (a drag, or a move waiting for its render), frame px.
    public Dictionary<int, Vector> Overrides { get; } = new();

    public event Action? SelectionChanged;
    /// Objects dragged by (dx, dy) frame px.
    public event Action<List<int>, double, double>? MoveCommitted;
    /// Text or formula retyped.
    public event Action<int, string>? TextCommitted;
    /// Text typed into an empty layout placeholder.
    public event Action<Placeholder, string>? PlaceholderCommitted;

    int? hover;
    Point? downAt;
    bool dragging;
    Vector dragDelta;
    TextBox? editor;
    int? editingOid;
    Placeholder? editingPlaceholder;

    public bool IsEditingText => editor != null;

    public SlideCanvas()
    {
        Background = (Brush)Application.Current.Resources["CanvasBackBrush"];
        ClipToBounds = true;
        Focusable = true;
        FocusVisualStyle = null;
        frame.Children.Add(exact);
        frame.Children.Add(composite);
        frame.Children.Add(overlay);
        viewbox.Child = frame;
        viewbox.Margin = new Thickness(24);
        var host = new Grid();
        host.Children.Add(viewbox);
        host.Children.Add(emptyText);
        Child = host;
        frame.Width = 1280; frame.Height = 720;
        viewbox.Visibility = Visibility.Collapsed;
        emptyText.Text = "";
        overlay.MouseLeftButtonDown += OnDown;
        overlay.MouseMove += OnMove;
        overlay.MouseLeftButtonUp += OnUp;
        overlay.MouseLeave += (_, _) => { if (hover != null) { hover = null; DrawOverlay(); } };
        overlay.LostMouseCapture += (_, _) => { if (downAt != null && Mouse.LeftButton != MouseButtonState.Pressed) EndPress(commit: dragging); };
        SizeChanged += (_, _) => DrawOverlay();
    }

    double Scale => viewbox.ActualWidth > 0 && frame.Width > 0 ? viewbox.ActualWidth / frame.Width : 1;

    public void ShowMessage(string text)
    {
        emptyText.Text = text;
        emptyText.Visibility = Visibility.Visible;
        viewbox.Visibility = Visibility.Collapsed;
    }

    /// A new render of a slide. `keepOverrides`: an edit's own render landing (previews of other drags stay).
    public void SetScene(SceneData? sc, int stop, bool keepOverrides = false)
    {
        CancelEdit();
        var sameSlide = Scene?.Name == sc?.Name;
        Scene = sc;
        StopIndex = stop;
        if (!keepOverrides) Overrides.Clear();
        if (!sameSlide) Selected.Clear();
        if (sc?.Objects != null) Selected.RemoveAll(o => !sc.Objects.ContainsKey(o.ToString()));
        if (sc?.Stops is not { Count: > 0 })
        {
            if (sc != null) ShowMessage(sc.Error != null ? "This slide failed to render.\n\n" + LastLines(sc.Error, 6) : "Rendering…");
            return;
        }
        frame.Width = sc.FrameW;
        frame.Height = sc.FrameH;
        emptyText.Visibility = Visibility.Collapsed;
        viewbox.Visibility = Visibility.Visible;
        Redraw();
        SelectionChanged?.Invoke();
    }

    static string LastLines(string s, int n) => string.Join("\n", s.Split('\n').Where(l => l.Trim().Length > 0).TakeLast(n));

    public void SetStop(int stop)
    {
        if (Scene?.Stops == null) return;
        CancelEdit();
        StopIndex = Math.Clamp(stop, 0, Scene.Stops.Count - 1);
        var visible = VisibleIds();
        Selected.RemoveAll(o => !visible.Contains(o));
        Redraw();
        SelectionChanged?.Invoke();
    }

    HashSet<int> VisibleIds() => Stop?.Visible.Select(v => (int)v[0]).ToHashSet() ?? new();

    public void Redraw()
    {
        var st = Stop;
        if (st == null) return;
        bool compositing = dragging || Overrides.Count > 0 || Scene?.Optimistic == true;
        exact.Source = Images.Load(st.Png);
        exact.Visibility = compositing ? Visibility.Hidden : Visibility.Visible;
        composite.Children.Clear();
        if (compositing)
        {
            var bg = new Image { Source = Images.Load(st.Bg), Width = frame.Width, Height = frame.Height, Stretch = Stretch.Fill };
            composite.Children.Add(bg);
            foreach (var sp in st.Sprites.OrderBy(s => s.Z))
            {
                var img = new Image { Source = Images.Load(sp.File), Width = sp.W, Height = sp.H, Stretch = Stretch.Fill };
                var off = Offset(sp.Oid);
                if (Scene?.Optimistic == true && st.Xforms != null && st.Xforms.TryGetValue(sp.Oid.ToString(), out var x) && x.Length == 6)
                {
                    // a line attached to a moved object: its sprite mapped onto its new ends
                    Canvas.SetLeft(img, 0); Canvas.SetTop(img, 0);
                    var m = new Matrix(1, 0, 0, 1, sp.X, sp.Y) * new Matrix(x[0], x[1], x[2], x[3], x[4], x[5]);
                    m.Translate(off.X, off.Y);
                    img.RenderTransform = new MatrixTransform(m);
                }
                else
                {
                    Canvas.SetLeft(img, sp.X + off.X);
                    Canvas.SetTop(img, sp.Y + off.Y);
                }
                composite.Children.Add(img);
            }
        }
        DrawOverlay();
    }

    Vector Offset(int oid)
    {
        var v = Overrides.TryGetValue(oid, out var o) ? o : new Vector();
        if (dragging && Selected.Contains(oid)) v += dragDelta;
        return v;
    }

    /// Where an object is drawn: its text frame if it has one, else its ink box; shifted with a drag.
    public Rect? BoxOf(int oid)
    {
        var st = Stop;
        if (st == null) return null;
        var b = Scene?.Obj(oid)?.FrameBox ?? st.Box(oid);
        if (b is not Rect r) return null;
        var off = Offset(oid);
        r.Offset(off);
        return r;
    }

    void DrawOverlay()
    {
        // the text editor survives a redraw; everything else is drawn again
        for (int i = overlay.Children.Count - 1; i >= 0; i--)
            if (overlay.Children[i] != editor) overlay.Children.RemoveAt(i);
        var st = Stop;
        if (st == null || Scene == null) return;
        double t = 1.5 / Scale;
        var accent = (Brush)Application.Current.Resources["SelectionBrush"];
        // empty layout boxes: "Click to add title"
        if (Scene.Placeholders != null)
            foreach (var ph in Scene.Placeholders)
            {
                if (editingPlaceholder?.Line == ph.Line) continue;
                var r = ph.Rect;
                var box = new Rectangle
                {
                    Width = r.Width, Height = r.Height, Stroke = new SolidColorBrush(Color.FromArgb(0x90, 0xa0, 0xa0, 0xa8)),
                    StrokeThickness = t, StrokeDashArray = new DoubleCollection { 4, 3 }, IsHitTestVisible = false,
                };
                Canvas.SetLeft(box, r.X); Canvas.SetTop(box, r.Y);
                overlay.Children.Add(box);
                var label = new TextBlock
                {
                    Text = ph.Prompt, Foreground = new SolidColorBrush(Color.FromArgb(0xb0, 0xc0, 0xc0, 0xc8)),
                    FontSize = Math.Max(14, Math.Min(r.Height * 0.4, ph.Size * 0.9)), IsHitTestVisible = false,
                    Width = r.Width, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap,
                };
                Canvas.SetLeft(label, r.X); Canvas.SetTop(label, r.Y + r.Height / 2 - label.FontSize * 0.7);
                overlay.Children.Add(label);
            }
        if (hover is int h && !Selected.Contains(h) && BoxOf(h) is Rect hb)
            overlay.Children.Add(Outline(hb, new SolidColorBrush(Color.FromArgb(0xa0, 0x4c, 0x8d, 0xff)), t));
        foreach (var oid in Selected)
            if (BoxOf(oid) is Rect sb)
            {
                overlay.Children.Add(Outline(sb, accent, t * 1.4));
                foreach (var (hx, hy) in new[] { (sb.Left, sb.Top), (sb.Right, sb.Top), (sb.Left, sb.Bottom), (sb.Right, sb.Bottom) })
                {
                    double s = 7 / Scale;
                    var k = new Rectangle { Width = s, Height = s, Fill = Brushes.White, Stroke = accent, StrokeThickness = t, IsHitTestVisible = false };
                    Canvas.SetLeft(k, hx - s / 2); Canvas.SetTop(k, hy - s / 2);
                    overlay.Children.Add(k);
                }
            }
    }

    static Rectangle Outline(Rect r, Brush b, double t)
    {
        var pad = t * 2;
        var rect = new Rectangle { Width = r.Width + 2 * pad, Height = r.Height + 2 * pad, Stroke = b, StrokeThickness = t, IsHitTestVisible = false };
        Canvas.SetLeft(rect, r.X - pad); Canvas.SetTop(rect, r.Y - pad);
        return rect;
    }

    /// The object under a frame-pixel point: the smallest box containing it, the topmost on a tie.
    public int? HitTest(Point p)
    {
        var st = Stop;
        if (st == null) return null;
        var z = st.Sprites.ToDictionary(s => s.Oid, s => s.Z);
        int? best = null;
        double bestArea = double.MaxValue, bestZ = double.MinValue;
        double slop = 4 / Scale;
        foreach (var v in st.Visible)
        {
            int oid = (int)v[0];
            if (BoxOf(oid) is not Rect r) continue;
            r.Inflate(slop, slop);
            if (!r.Contains(p)) continue;
            double area = r.Width * r.Height, zz = z.GetValueOrDefault(oid);
            if (area < bestArea - 1 || (Math.Abs(area - bestArea) <= 1 && zz > bestZ)) { best = oid; bestArea = area; bestZ = zz; }
        }
        return best;
    }

    /// The members of `oid`'s group (an object outside a group alone).
    List<int> WithGroup(int oid)
    {
        var g = Scene?.Obj(oid)?.Group;
        if (g == null || Scene?.Objects == null) return new() { oid };
        var visible = VisibleIds();
        return Scene.Objects.Where(kv => kv.Value.Group == g && int.TryParse(kv.Key, out var k) && visible.Contains(k))
                            .Select(kv => int.Parse(kv.Key)).ToList();
    }

    public void Select(IEnumerable<int> oids)
    {
        Selected.Clear();
        Selected.AddRange(oids.Distinct());
        DrawOverlay();
        SelectionChanged?.Invoke();
    }

    public void SelectAll() => Select(VisibleIds());

    void OnDown(object sender, MouseButtonEventArgs e)
    {
        Focus();
        if (editor != null) { CommitEdit(); }
        var p = e.GetPosition(frame);
        var hit = HitTest(p);
        if (e.ClickCount == 2)
        {
            // a double-click retypes text and formulas; on anything else it is an ordinary press (a quick drag)
            if (hit is int h && Scene?.Obj(h) is { } o && (o.IsText || o.Kind == "table")) { BeginTextEdit(h); e.Handled = true; return; }
            if (hit == null && PlaceholderAt(p) is { } ph) { BeginPlaceholderEdit(ph); e.Handled = true; return; }
        }
        if (hit is int oid)
        {
            var members = WithGroup(oid);
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) || Keyboard.Modifiers.HasFlag(ModifierKeys.Control))
            {
                if (Selected.Contains(oid)) Selected.RemoveAll(members.Contains); else Selected.AddRange(members.Where(m => !Selected.Contains(m)));
                DrawOverlay();
                SelectionChanged?.Invoke();
            }
            else if (!Selected.Contains(oid)) Select(members);
            downAt = p;
            dragDelta = new Vector();
            overlay.CaptureMouse();
        }
        else if (PlaceholderAt(p) is { } ph)
        {
            Select(Array.Empty<int>());
            BeginPlaceholderEdit(ph);
        }
        else Select(Array.Empty<int>());
        e.Handled = true;
    }

    Placeholder? PlaceholderAt(Point p) => Scene?.Placeholders?.FirstOrDefault(ph => ph.Rect.Contains(p));

    void OnMove(object sender, MouseEventArgs e)
    {
        var p = e.GetPosition(frame);
        // the button went up somewhere else (another window took the release): end the press here
        if (downAt != null && e.LeftButton != MouseButtonState.Pressed) { EndPress(commit: dragging); return; }
        if (downAt is Point d && e.LeftButton == MouseButtonState.Pressed && Selected.Count > 0)
        {
            var delta = p - d;
            if (!dragging && delta.Length * Scale < 3) return;
            dragging = true;
            dragDelta = delta;
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))     // Shift constrains to horizontal or vertical
                dragDelta = Math.Abs(delta.X) > Math.Abs(delta.Y) ? new Vector(delta.X, 0) : new Vector(0, delta.Y);
            Redraw();
            return;
        }
        var h = HitTest(p);
        Cursor = h != null ? Cursors.SizeAll : PlaceholderAt(p) != null ? Cursors.IBeam : Cursors.Arrow;
        if (h != hover) { hover = h; DrawOverlay(); }
    }

    void OnUp(object sender, MouseButtonEventArgs e) => EndPress(commit: true);

    void EndPress(bool commit)
    {
        if (overlay.IsMouseCaptured) overlay.ReleaseMouseCapture();
        if (dragging && !commit) { dragging = false; dragDelta = new Vector(); Redraw(); }
        if (dragging)
        {
            var delta = dragDelta;
            foreach (var oid in Selected)
                Overrides[oid] = (Overrides.TryGetValue(oid, out var o) ? o : new Vector()) + delta;
            dragging = false;
            dragDelta = new Vector();
            Redraw();
            if (Math.Abs(delta.X) > 0.01 || Math.Abs(delta.Y) > 0.01) MoveCommitted?.Invoke(Selected.ToList(), delta.X, delta.Y);
        }
        downAt = null;
    }

    /// Shifts the selection by hand (arrow-key nudges) until its render lands.
    public void Nudge(double dx, double dy)
    {
        foreach (var oid in Selected)
            Overrides[oid] = (Overrides.TryGetValue(oid, out var o) ? o : new Vector()) + new Vector(dx, dy);
        Redraw();
    }

    public void ClearOverride(int oid) { if (Overrides.Remove(oid)) Redraw(); }

    // ---------------------------------------------------------------- text editing in place

    public void BeginTextEdit(int oid)
    {
        if (Scene?.Obj(oid) is not { } o || BoxOf(oid) is not Rect r) return;
        CancelEdit();
        Select(new[] { oid });
        editingOid = oid;
        var lines = Math.Max(1, o.Value.Split('\n').Length);
        var fontPx = o.Kind == "tex" || o.Kind == "table" ? 26 : Math.Clamp(r.Height / lines * 0.72, 12, 120);
        OpenEditor(new Rect(r.X - 6, r.Y - 4, Math.Max(r.Width + 12, 160), Math.Max(r.Height + 8, fontPx * 1.6)), o.Value, fontPx,
                   o.Kind == "tex" ? "LaTeX · Enter applies · Shift+Enter new line · Esc cancels" : "Enter applies · Shift+Enter new line · Esc cancels",
                   o.Kind == "tex" || o.Kind == "table");
    }

    void BeginPlaceholderEdit(Placeholder ph)
    {
        CancelEdit();
        editingPlaceholder = ph;
        var r = ph.Rect;
        OpenEditor(r, "", Math.Clamp(ph.Size * 0.9, 14, 90), ph.Prompt + " · Enter applies · Esc cancels", false);
        DrawOverlay();
    }

    void OpenEditor(Rect r, string text, double fontPx, string tip, bool mono)
    {
        editor = new TextBox
        {
            Text = text, FontSize = fontPx, AcceptsReturn = true, AcceptsTab = false, TextWrapping = TextWrapping.Wrap,
            Background = new SolidColorBrush(Color.FromArgb(0xee, 0x1e, 0x1f, 0x24)), Foreground = Brushes.White,
            CaretBrush = Brushes.White, BorderBrush = (Brush)Application.Current.Resources["SelectionBrush"],
            BorderThickness = new Thickness(2 / Scale), Width = r.Width, MinHeight = r.Height, Padding = new Thickness(4),
            ToolTip = tip, FontFamily = mono ? new FontFamily("Cascadia Mono, Consolas") : new FontFamily("Segoe UI"),
        };
        editor.Template = PlainTextBoxTemplate;   // the theme's template would repaint it light when focused
        Canvas.SetLeft(editor, r.X); Canvas.SetTop(editor, r.Y);
        editor.PreviewKeyDown += EditorKey;
        overlay.Children.Add(editor);
        editor.Loaded += (_, _) => { editor?.Focus(); editor?.SelectAll(); };
    }

    /// A text box drawn only as a border around its text, so it keeps the dark look over the slide.
    static readonly ControlTemplate PlainTextBoxTemplate = (ControlTemplate)System.Windows.Markup.XamlReader.Parse(
        "<ControlTemplate TargetType='TextBox' xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>" +
        "<Border Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' " +
        "BorderThickness='{TemplateBinding BorderThickness}' Padding='{TemplateBinding Padding}'>" +
        "<ScrollViewer x:Name='PART_ContentHost' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml' " +
        "VerticalScrollBarVisibility='Hidden' HorizontalScrollBarVisibility='Hidden'/></Border></ControlTemplate>");

    void EditorKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { CancelEdit(); Focus(); e.Handled = true; }
        else if (e.Key == Key.Enter && !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { CommitEdit(); Focus(); e.Handled = true; }
    }

    public void CommitEdit()
    {
        if (editor == null) return;
        var text = editor.Text;
        var oid = editingOid; var ph = editingPlaceholder;
        CancelEdit();
        if (oid is int o && Scene?.Obj(o) is { } obj && text != obj.Value) TextCommitted?.Invoke(o, text);
        else if (ph != null && text.Trim().Length > 0) PlaceholderCommitted?.Invoke(ph, text);
    }

    public void CancelEdit()
    {
        if (editor == null) return;
        overlay.Children.Remove(editor);
        editor = null;
        editingOid = null;
        var hadPh = editingPlaceholder != null;
        editingPlaceholder = null;
        if (hadPh) DrawOverlay();
    }
}
