using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;

namespace Manimble;

/// How an object is shown until the render of its edit lands: shifted and scaled about its centre (frame px).
public struct Preview
{
    public Vector Offset;
    public double Scale;
    public Preview(Vector offset, double scale = 1) { Offset = offset; Scale = scale; }
    public bool IsIdentity => Offset.Length < 0.01 && Math.Abs(Scale - 1) < 0.0005;
}

/// The slide canvas (the Mac's Metal CanvasView). It shows the exact frame of a build when idle; while an object is
/// dragged or resized, or while an optimistic edit waits for its verifying render, it composites the backdrop and the
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
    /// Objects shown moved or scaled by hand (a drag, or an edit waiting for its render).
    public Dictionary<int, Preview> Overrides { get; } = new();
    /// Lines shown with new ends (an endpoint drag waiting for its render): [sx, sy, ex, ey].
    public Dictionary<int, double[]> LineOverrides { get; } = new();

    public event Action? SelectionChanged;
    /// Objects dragged by (dx, dy) frame px.
    public event Action<List<int>, double, double>? MoveCommitted;
    /// An object scaled about its centre by a corner handle.
    public event Action<int, double>? ResizeCommitted;
    /// A line's ends dragged: [sx, sy, ex, ey].
    public event Action<int, double[]>? EndpointsCommitted;
    /// A shape or line drawn with a draw tool: tool, start and end (frame px).
    public event Action<string, Point, Point>? DrawCommitted;
    /// A freehand pen stroke.
    public event Action<List<Point>>? PenCommitted;
    /// The draw tool was put down (drawn once, or Esc).
    public event Action? DrawToolChanged;
    /// Text or formula retyped.
    public event Action<int, string>? TextCommitted;
    /// Text typed into an empty layout placeholder.
    public event Action<Placeholder, string>? PlaceholderCommitted;

    enum Mode { None, Press, Move, Resize, Endpoint, Marquee, Draw, Pen, Guide }
    Mode mode;
    int? hover;
    Point downAt;
    Vector dragDelta;              // a move in progress
    int dragOid;                   // the object of a resize or endpoint drag
    int dragEnd;                   // 0 = start, 1 = end of a line
    double dragScale = 1;          // a resize in progress
    Rect dragBox;                  // the box a resize started from
    Rect? band;                    // marquee or the shape being drawn
    readonly List<Point> penPoints = new();
    readonly List<List<Point>> pendingStrokes = new();
    (BitmapSource img, Rect r)? ghost;
    TextBox? editor;
    int? editingOid;
    Placeholder? editingPlaceholder;

    string? drawTool;
    /// The draw tool in hand: line, arrow, darrow, rectangle, ellipse or pen (null: select and move).
    public string? DrawTool
    {
        get => drawTool;
        set { drawTool = value; Cursor = value != null ? Cursors.Cross : Cursors.Arrow; DrawToolChanged?.Invoke(); DrawOverlay(); }
    }
    public Color PenColor { get; set; } = Colors.White;

    public bool IsEditingText => editor != null;
    public bool IsDragging => mode is Mode.Move or Mode.Resize or Mode.Endpoint;

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
        hRuler = new Ruler(this, horizontal: true);
        vRuler = new Ruler(this, horizontal: false);
        var host = new Grid();
        host.RowDefinitions.Add(rulerRow); host.RowDefinitions.Add(new RowDefinition());
        host.ColumnDefinitions.Add(rulerCol); host.ColumnDefinitions.Add(new ColumnDefinition());
        scroller.Content = viewbox;
        var corner = new Border { Background = new SolidColorBrush(Color.FromRgb(0x24, 0x24, 0x28)) };
        Grid.SetColumn(hRuler, 1);
        Grid.SetRow(vRuler, 1);
        Grid.SetRow(scroller, 1); Grid.SetColumn(scroller, 1);
        Grid.SetRow(emptyText, 1); Grid.SetColumn(emptyText, 1);
        host.Children.Add(corner);
        host.Children.Add(hRuler);
        host.Children.Add(vRuler);
        host.Children.Add(scroller);
        host.Children.Add(emptyText);
        scroller.ScrollChanged += (_, _) => RedrawRulers();
        // Ctrl+wheel zooms, as in other editors
        scroller.PreviewMouseWheel += (_, e) =>
        {
            if (!Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) return;
            ZoomBy(e.Delta > 0 ? 1.15 : 1 / 1.15);
            e.Handled = true;
        };
        scroller.SizeChanged += (_, _) => { if (zoom == null) DrawOverlay(); };
        Child = host;
        frame.Width = 1280; frame.Height = 720;
        viewbox.Visibility = Visibility.Collapsed;
        overlay.MouseLeftButtonDown += OnDown;
        overlay.MouseMove += OnMove;
        overlay.MouseLeftButtonUp += OnUp;
        // a right-click acts on what is under it: that object (and its group) becomes the selection first
        overlay.MouseRightButtonDown += (_, e) =>
        {
            if (editor != null) CommitEdit();
            var hit = HitTest(e.GetPosition(frame));
            if (hit is int h) { if (!Selected.Contains(h)) Select(WithGroup(h)); }
            else Select(Array.Empty<int>());
        };
        overlay.MouseLeave += (_, _) => { pointer = null; RedrawRulers(); if (hover != null) { hover = null; DrawOverlay(); } };
        overlay.LostMouseCapture += (_, _) => { if (mode != Mode.None && Mouse.LeftButton != MouseButtonState.Pressed) EndPress(commit: true); };
        SizeChanged += (_, _) => DrawOverlay();
        viewbox.SizeChanged += (_, _) => RedrawRulers();
    }

    // ---------------------------------------------------------------- rulers and guides

    readonly Ruler hRuler, vRuler;
    readonly RowDefinition rulerRow = new() { Height = new GridLength(Ruler.Thickness) };
    readonly ColumnDefinition rulerCol = new() { Width = new GridLength(Ruler.Thickness) };
    Point? pointer;
    int? dragGuide;

    /// Rulers along the top and left (View > Ruler).
    public bool ShowRulers
    {
        get => rulerRow.Height.Value > 0;
        set
        {
            rulerRow.Height = new GridLength(value ? Ruler.Thickness : 0);
            rulerCol.Width = new GridLength(value ? Ruler.Thickness : 0);
            hRuler.Visibility = vRuler.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    /// Guides the user added (frame px): dragged in from the rulers, moved by dragging, removed by dragging them off
    /// the slide; moves snap to them.
    public List<(bool vertical, double pos)> UserGuides { get; } = new();
    /// The guides changed by hand (to save them).
    public event Action? GuidesChanged;

    public bool HasSlide => viewbox.Visibility == Visibility.Visible && Stop != null;
    /// Frame pixels per manim unit.
    public double UnitPx => Scene?.Frame is { Length: >= 1 } f && f[0] > 0 ? frame.Width / f[0] : frame.Width / 14.222222222222221;
    /// The pointer over the slide, in frame pixels.
    public Point? PointerPosition => pointer;
    public Point FramePoint(MouseEventArgs e) => e.GetPosition(frame);
    public Point FrameToElement(Point p, Visual to)
    {
        try { return frame.TransformToVisual(to).Transform(p); } catch (InvalidOperationException) { return p; }
    }
    /// The selection's extent, for the rulers.
    public Rect? SelectedBox
    {
        get
        {
            Rect? u = null;
            foreach (var oid in Selected) if (BoxOf(oid) is Rect r) u = u is Rect a ? Rect.Union(a, r) : r;
            return u;
        }
    }

    void RedrawRulers()
    {
        if (!ShowRulers) return;
        hRuler.InvalidateVisual(); vRuler.InvalidateVisual();
    }

    public void SetGuides(IEnumerable<(bool vertical, double pos)> guides)
    {
        UserGuides.Clear(); UserGuides.AddRange(guides);
        DrawOverlay();
    }

    /// A new guide at the slide's centre (View > Add Vertical/Horizontal Guide).
    public void AddGuide(bool vertical)
    {
        UserGuides.Add((vertical, vertical ? frame.Width / 2 : frame.Height / 2));
        DrawOverlay();
        GuidesChanged?.Invoke();
    }

    public void ClearGuides()
    {
        UserGuides.Clear();
        DrawOverlay();
        GuidesChanged?.Invoke();
    }

    /// A brand-new guide dragged off a ruler (it starts under the pointer, off the slide).
    public void BeginGuideDrag(bool vertical, double pos)
    {
        UserGuides.Add((vertical, pos));
        dragGuide = UserGuides.Count - 1;
        DrawOverlay();
    }

    /// An existing guide dragged by its ruler marker.
    public void ContinueGuideDrag(int index)
    {
        if (index < 0 || index >= UserGuides.Count) return;
        dragGuide = index;
        DrawOverlay();
    }

    public void UpdateGuideDrag(double pos)
    {
        if (dragGuide is not int i || i >= UserGuides.Count) return;
        UserGuides[i] = (UserGuides[i].vertical, pos);
        DrawOverlay();
    }

    /// Drops the dragged guide: gone if it ended off the slide, else kept and saved.
    public void EndGuideDrag()
    {
        if (dragGuide is not int i) return;
        dragGuide = null;
        if (i < UserGuides.Count)
        {
            var g = UserGuides[i];
            if (g.pos < 0 || g.pos > (g.vertical ? frame.Width : frame.Height)) UserGuides.RemoveAt(i);
        }
        DrawOverlay();
        GuidesChanged?.Invoke();
    }

    /// The user guide under a frame point (within a few screen pixels).
    int? GuideAt(Point p)
    {
        double tol = 5 / Scale;
        for (int i = 0; i < UserGuides.Count; i++)
        {
            var g = UserGuides[i];
            if (Math.Abs((g.vertical ? p.X : p.Y) - g.pos) <= tol) return i;
        }
        return null;
    }

    double Scale => viewbox.ActualWidth > 0 && frame.Width > 0 ? viewbox.ActualWidth / frame.Width : 1;

    // ---------------------------------------------------------------- zoom, grid, snapping

    readonly ScrollViewer scroller = new()
    {
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false,
    };
    double? zoom;
    /// Screen pixels per frame pixel (device-independent); null fits the slide in the window.
    public double? Zoom
    {
        get => zoom;
        set
        {
            zoom = value is double z ? Math.Clamp(z, 0.1, 8) : null;
            if (zoom is double k)
            {
                viewbox.Width = frame.Width * k; viewbox.Height = frame.Height * k;
                scroller.HorizontalScrollBarVisibility = scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            }
            else
            {
                viewbox.Width = double.NaN; viewbox.Height = double.NaN;
                scroller.HorizontalScrollBarVisibility = scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
            }
            ZoomChanged?.Invoke();
            Dispatcher.BeginInvoke(DrawOverlay, System.Windows.Threading.DispatcherPriority.Loaded);
        }
    }
    public event Action? ZoomChanged;
    /// The zoom on screen now (the fitted one when fitting).
    public double CurrentZoom => Scale;
    public void ZoomBy(double f) => Zoom = CurrentZoom * f;

    bool showGrid;
    public bool ShowGrid { get => showGrid; set { showGrid = value; DrawOverlay(); } }
    public bool SnapEnabled { get; set; } = true;
    readonly List<(bool vertical, double pos)> guides = new();

    /// A move snapped so an edge or the centre of the moving box lines up with another object's or the slide's
    /// (within a few screen pixels); the lines it lines up on are drawn while dragging. Alt moves freely.
    Vector Snap(Vector delta)
    {
        guides.Clear();
        if (!SnapEnabled || Keyboard.Modifiers.HasFlag(ModifierKeys.Alt) || Stop == null) return delta;
        Rect? moving = null;
        foreach (var oid in Selected)
        {
            var b = Scene?.Obj(oid)?.FrameBox ?? Stop.Box(oid);
            if (b is not Rect r) continue;
            var p = Overrides.TryGetValue(oid, out var o) ? o.Offset : new Vector();
            r.Offset(p);
            moving = moving is Rect m ? Rect.Union(m, r) : r;
        }
        if (moving is not Rect mv) return delta;
        mv.Offset(delta);
        var xs = new List<double> { 0, frame.Width / 2, frame.Width };
        var ys = new List<double> { 0, frame.Height / 2, frame.Height };
        foreach (var v in Stop.Visible)
        {
            int oid = (int)v[0];
            if (Selected.Contains(oid)) continue;
            var r = new Rect(new Point(v[1], v[2]), new Point(v[3], v[4]));
            xs.AddRange(new[] { r.Left, r.Left + r.Width / 2, r.Right });
            ys.AddRange(new[] { r.Top, r.Top + r.Height / 2, r.Bottom });
        }
        foreach (var (vertical, pos) in UserGuides) (vertical ? xs : ys).Add(pos);
        if (showGrid && UnitPx * Scale > 4)
        {
            double u = UnitPx;
            for (double k = 1; frame.Width / 2 + k * u <= frame.Width + 0.5; k++) xs.AddRange(new[] { frame.Width / 2 + k * u, frame.Width / 2 - k * u });
            for (double k = 1; frame.Height / 2 + k * u <= frame.Height + 0.5; k++) ys.AddRange(new[] { frame.Height / 2 + k * u, frame.Height / 2 - k * u });
        }
        double tol = 6 / Scale;
        (double d, double t)? Best(double[] cands, List<double> targets)
        {
            (double d, double t)? best = null;
            foreach (var c in cands)
                foreach (var t in targets)
                {
                    var d = t - c;
                    if (Math.Abs(d) <= tol && (best == null || Math.Abs(d) < Math.Abs(best.Value.d))) best = (d, t);
                }
            return best;
        }
        if (Best(new[] { mv.Left, mv.Left + mv.Width / 2, mv.Right }, xs) is { } bx) { delta.X += bx.d; guides.Add((true, bx.t)); }
        if (Best(new[] { mv.Top, mv.Top + mv.Height / 2, mv.Bottom }, ys) is { } by) { delta.Y += by.d; guides.Add((false, by.t)); }
        return delta;
    }
    public Size FrameSize => new(frame.Width, frame.Height);

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
        if (!keepOverrides) { Overrides.Clear(); LineOverrides.Clear(); }
        if (!sameSlide) { Selected.Clear(); pendingStrokes.Clear(); ghost = null; }
        if (sc?.Objects != null) Selected.RemoveAll(o => !sc.Objects.ContainsKey(o.ToString()));
        if (sc?.Stops is not { Count: > 0 })
        {
            if (sc != null) ShowMessage(sc.Error != null ? "This slide failed to render.\n\n" + LastLines(sc.Error, 6) : "Rendering…");
            return;
        }
        frame.Width = sc.FrameW;
        frame.Height = sc.FrameH;
        if (zoom != null) Zoom = zoom;            // the zoomed size follows a deck of another frame size
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

    bool IsLine(int oid) => Stop?.Lines?.ContainsKey(oid.ToString()) == true;

    double[]? LineEnds(int oid)
    {
        if (LineOverrides.TryGetValue(oid, out var e)) return e;
        if (Stop?.Lines != null && Stop.Lines.TryGetValue(oid.ToString(), out var l) && l.Length >= 4)
        {
            var p = PreviewOf(oid);
            return new[] { l[0] + p.Offset.X, l[1] + p.Offset.Y, l[2] + p.Offset.X, l[3] + p.Offset.Y };
        }
        return null;
    }

    /// What the object is shown as now: its pending preview with the drag in progress on top.
    Preview PreviewOf(int oid)
    {
        var p = Overrides.TryGetValue(oid, out var o) ? o : new Preview(new Vector());
        if (p.Scale == 0) p.Scale = 1;
        if (mode == Mode.Move && Selected.Contains(oid)) p.Offset += dragDelta;
        if (mode == Mode.Resize && oid == dragOid) p.Scale *= dragScale;
        return p;
    }

    bool Compositing => mode is Mode.Move or Mode.Resize or Mode.Endpoint || Overrides.Count > 0 || LineOverrides.Count > 0
                        || Scene?.Optimistic == true;

    public void Redraw()
    {
        var st = Stop;
        if (st == null) return;
        bool compositing = Compositing;
        exact.Source = Images.Load(st.Png);
        exact.Visibility = compositing ? Visibility.Hidden : Visibility.Visible;
        composite.Children.Clear();
        if (compositing)
        {
            composite.Children.Add(new Image { Source = Images.Load(st.Bg), Width = frame.Width, Height = frame.Height, Stretch = Stretch.Fill });
            foreach (var sp in st.Sprites.OrderBy(s => s.Z))
            {
                if (LineOverrides.ContainsKey(sp.Oid) || (mode == Mode.Endpoint && sp.Oid == dragOid))
                {
                    AddLinePreview(sp.Oid);
                    continue;
                }
                var img = new Image { Source = Images.Load(sp.File), Width = sp.W, Height = sp.H, Stretch = Stretch.Fill };
                var pv = PreviewOf(sp.Oid);
                if (Scene?.Optimistic == true && st.Xforms != null && st.Xforms.TryGetValue(sp.Oid.ToString(), out var x) && x.Length == 6)
                {
                    // a line attached to a moved object: its sprite mapped onto its new ends
                    Canvas.SetLeft(img, 0); Canvas.SetTop(img, 0);
                    var m = new Matrix(1, 0, 0, 1, sp.X, sp.Y) * new Matrix(x[0], x[1], x[2], x[3], x[4], x[5]);
                    m.Translate(pv.Offset.X, pv.Offset.Y);
                    img.RenderTransform = new MatrixTransform(m);
                }
                else
                {
                    // scaled about the centre of the object's box (a group's sprites scale together about it)
                    var c = st.Box(sp.Oid) is Rect b ? new Point(b.X + b.Width / 2, b.Y + b.Height / 2) : new Point(sp.X + sp.W / 2, sp.Y + sp.H / 2);
                    var s = pv.Scale;
                    img.Width = sp.W * s; img.Height = sp.H * s;
                    Canvas.SetLeft(img, c.X + (sp.X - c.X) * s + pv.Offset.X);
                    Canvas.SetTop(img, c.Y + (sp.Y - c.Y) * s + pv.Offset.Y);
                }
                composite.Children.Add(img);
            }
        }
        DrawOverlay();
    }

    void AddLinePreview(int oid)
    {
        if (LineEnds(oid) is not { } e) return;
        var o = Scene?.Obj(oid);
        var stroke = Stop?.Lines?.TryGetValue(oid.ToString(), out var l) == true && l.Length >= 5 ? Math.Max(1, l[4]) : 3;
        composite.Children.Add(new Line
        {
            X1 = e[0], Y1 = e[1], X2 = e[2], Y2 = e[3], StrokeThickness = stroke, Stroke = BrushOf(o?.Color, Colors.White),
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        });
    }

    static Brush BrushOf(string? hex, Color fallback)
    {
        try { if (hex != null && hex.StartsWith('#')) return new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)); } catch { }
        return new SolidColorBrush(fallback);
    }

    /// Where an object is drawn: its text frame if it has one, else its ink box; moved and scaled with its preview.
    public Rect? BoxOf(int oid)
    {
        var st = Stop;
        if (st == null) return null;
        if (LineOverrides.ContainsKey(oid) || (mode == Mode.Endpoint && oid == dragOid))
        {
            if (LineEnds(oid) is { } e) return new Rect(new Point(e[0], e[1]), new Point(e[2], e[3]));
        }
        var b = Scene?.Obj(oid)?.FrameBox ?? st.Box(oid);
        if (b is not Rect r) return null;
        var pv = PreviewOf(oid);
        var c = new Point(r.X + r.Width / 2, r.Y + r.Height / 2) + pv.Offset;
        return new Rect(c.X - r.Width * pv.Scale / 2, c.Y - r.Height * pv.Scale / 2, r.Width * pv.Scale, r.Height * pv.Scale);
    }

    // ---------------------------------------------------------------- overlay

    Brush Accent => (Brush)Application.Current.Resources["SelectionBrush"];

    void DrawOverlay()
    {
        // the text editor survives a redraw; everything else is drawn again
        for (int i = overlay.Children.Count - 1; i >= 0; i--)
            if (overlay.Children[i] != editor) overlay.Children.RemoveAt(i);
        RedrawRulers();
        var st = Stop;
        if (st == null || Scene == null) return;
        double t = 1.5 / Scale;
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
        // pen strokes waiting for their render
        foreach (var s in pendingStrokes) overlay.Children.Add(Stroke(s));
        if (mode == Mode.Pen && penPoints.Count > 1) overlay.Children.Add(Stroke(penPoints));
        if (ghost is { } g)
        {
            var gi = new Image { Source = g.img, Width = g.r.Width, Height = g.r.Height, Opacity = 0.85, IsHitTestVisible = false };
            Canvas.SetLeft(gi, g.r.X); Canvas.SetTop(gi, g.r.Y);
            overlay.Children.Add(gi);
        }
        if (hover is int h && !Selected.Contains(h) && drawTool == null && BoxOf(h) is Rect hb)
            overlay.Children.Add(Outline(hb, new SolidColorBrush(Color.FromArgb(0xa0, 0x4c, 0x8d, 0xff)), t));
        foreach (var oid in Selected)
        {
            if (Selected.Count == 1 && IsLine(oid) && LineEnds(oid) is { } e)
            {
                overlay.Children.Add(new Line { X1 = e[0], Y1 = e[1], X2 = e[2], Y2 = e[3], Stroke = Accent, StrokeThickness = t, Opacity = 0.6, IsHitTestVisible = false });
                overlay.Children.Add(Handle(e[0], e[1], t, round: true));
                overlay.Children.Add(Handle(e[2], e[3], t, round: true));
                continue;
            }
            if (BoxOf(oid) is not Rect sb) continue;
            overlay.Children.Add(Outline(sb, Accent, t * 1.4));
            if (Selected.Count == 1)
                foreach (var c in Corners(sb)) overlay.Children.Add(Handle(c.X, c.Y, t, round: false));
        }
        if (showGrid)
        {
            // one line per manim unit, the centre lines stronger
            double step = UnitPx;
            var faint = new SolidColorBrush(Color.FromArgb(0x38, 0x80, 0xb0, 0xff));
            var strong = new SolidColorBrush(Color.FromArgb(0x70, 0x80, 0xb0, 0xff));
            for (double x = frame.Width / 2 % step; x < frame.Width; x += step)
                overlay.Children.Add(new Line { X1 = x, Y1 = 0, X2 = x, Y2 = frame.Height, StrokeThickness = t * 0.7, IsHitTestVisible = false,
                                                Stroke = Math.Abs(x - frame.Width / 2) < 1 ? strong : faint });
            for (double y = frame.Height / 2 % step; y < frame.Height; y += step)
                overlay.Children.Add(new Line { X1 = 0, Y1 = y, X2 = frame.Width, Y2 = y, StrokeThickness = t * 0.7, IsHitTestVisible = false,
                                                Stroke = Math.Abs(y - frame.Height / 2) < 1 ? strong : faint });
        }
        for (int i = 0; i < UserGuides.Count; i++)
        {
            var (vertical, pos) = UserGuides[i];
            double gt = i == dragGuide ? t * 1.5 : t;
            var b = i == dragGuide ? Ruler.GuideBrush : new SolidColorBrush(Color.FromArgb(0xcc, 0x40, 0xd9, 0xff));
            overlay.Children.Add(vertical
                ? new Line { X1 = pos, Y1 = 0, X2 = pos, Y2 = frame.Height, Stroke = b, StrokeThickness = gt, IsHitTestVisible = false }
                : new Line { X1 = 0, Y1 = pos, X2 = frame.Width, Y2 = pos, Stroke = b, StrokeThickness = gt, IsHitTestVisible = false });
        }
        foreach (var (vertical, pos) in guides)
        {
            var orange = new SolidColorBrush(Color.FromRgb(0xff, 0x8c, 0x1a));
            overlay.Children.Add(vertical
                ? new Line { X1 = pos, Y1 = 0, X2 = pos, Y2 = frame.Height, Stroke = orange, StrokeThickness = t, StrokeDashArray = new DoubleCollection { 4, 3 }, IsHitTestVisible = false }
                : new Line { X1 = 0, Y1 = pos, X2 = frame.Width, Y2 = pos, Stroke = orange, StrokeThickness = t, StrokeDashArray = new DoubleCollection { 4, 3 }, IsHitTestVisible = false });
        }
        if (band is Rect bd)
        {
            if (mode == Mode.Marquee)
                overlay.Children.Add(Placed(new Rectangle
                {
                    Width = bd.Width, Height = bd.Height, Stroke = Accent, StrokeThickness = t,
                    Fill = new SolidColorBrush(Color.FromArgb(0x28, 0x4c, 0x8d, 0xff)), IsHitTestVisible = false,
                }, bd.X, bd.Y));
            else if (mode == Mode.Draw && drawTool != null)
                overlay.Children.Add(DrawPreview(drawTool, downAt, bandEnd, t));
        }
    }

    Point bandEnd;

    UIElement DrawPreview(string tool, Point a, Point b, double t)
    {
        var brush = new SolidColorBrush(Color.FromRgb(0xff, 0xff, 0xff));
        if (tool is "line" or "arrow" or "darrow")
            return new Line { X1 = a.X, Y1 = a.Y, X2 = b.X, Y2 = b.Y, Stroke = brush, StrokeThickness = 4, IsHitTestVisible = false };
        var r = new Rect(a, b);
        Shape s = tool == "ellipse" ? new Ellipse() : new Rectangle();
        s.Width = r.Width; s.Height = r.Height; s.Stroke = brush; s.StrokeThickness = 4; s.IsHitTestVisible = false;
        return Placed(s, r.X, r.Y);
    }

    Polyline Stroke(List<Point> pts) => new()
    {
        Points = new PointCollection(pts), Stroke = new SolidColorBrush(PenColor), StrokeThickness = 4,
        StrokeLineJoin = PenLineJoin.Round, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
        IsHitTestVisible = false,
    };

    static UIElement Placed(FrameworkElement e, double x, double y) { Canvas.SetLeft(e, x); Canvas.SetTop(e, y); return e; }

    static Point[] Corners(Rect r) => new[] { r.TopLeft, r.TopRight, r.BottomLeft, r.BottomRight };

    UIElement Handle(double x, double y, double t, bool round)
    {
        double s = 8 / Scale;
        Shape k = round ? new Ellipse() : new Rectangle();
        k.Width = s; k.Height = s; k.Fill = Brushes.White; k.Stroke = Accent; k.StrokeThickness = t; k.IsHitTestVisible = false;
        return Placed(k, x - s / 2, y - s / 2);
    }

    static Rectangle Outline(Rect r, Brush b, double t)
    {
        var pad = t * 2;
        var rect = new Rectangle { Width = r.Width + 2 * pad, Height = r.Height + 2 * pad, Stroke = b, StrokeThickness = t, IsHitTestVisible = false };
        Canvas.SetLeft(rect, r.X - pad); Canvas.SetTop(rect, r.Y - pad);
        return rect;
    }

    // ---------------------------------------------------------------- insert previews

    /// Shows a new element where it will appear while its insert renders (centre offset from the frame centre).
    public void SetGhost(BitmapSource img, double cx, double cy, double w, double h)
    {
        ghost = (img, new Rect(frame.Width / 2 + cx - w / 2, frame.Height / 2 + cy - h / 2, w, h));
        DrawOverlay();
    }

    public void ClearGhost() { ghost = null; DrawOverlay(); }

    public void DropPendingStroke() { if (pendingStrokes.Count > 0) { pendingStrokes.RemoveAt(0); DrawOverlay(); } }

    // ---------------------------------------------------------------- hit testing and selection

    /// The object under a frame-pixel point: the smallest box containing it, the topmost on a tie.
    public int? HitTest(Point p)
    {
        var st = Stop;
        if (st == null) return null;
        var z = st.Sprites.GroupBy(s => s.Oid).ToDictionary(g => g.Key, g => g.Max(s => s.Z));
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

    /// A handle of the single selected object under `p`: (oid, corner index 0-3) for a box, (oid, 10 + end) for a line.
    (int oid, int which)? HandleAt(Point p)
    {
        if (Selected.Count != 1) return null;
        var oid = Selected[0];
        double r = 7 / Scale;
        if (IsLine(oid) && LineEnds(oid) is { } e)
        {
            if ((p - new Point(e[0], e[1])).Length <= r) return (oid, 10);
            if ((p - new Point(e[2], e[3])).Length <= r) return (oid, 11);
            return null;
        }
        if (BoxOf(oid) is not Rect b) return null;
        var cs = Corners(b);
        for (int i = 0; i < 4; i++) if ((p - cs[i]).Length <= r) return (oid, i);
        return null;
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

    // ---------------------------------------------------------------- mouse

    void OnDown(object sender, MouseButtonEventArgs e)
    {
        Focus();
        if (editor != null) CommitEdit();
        var p = e.GetPosition(frame);
        downAt = p;
        e.Handled = true;
        if (drawTool == "pen")
        {
            mode = Mode.Pen;
            penPoints.Clear(); penPoints.Add(p);
            overlay.CaptureMouse();
            return;
        }
        if (drawTool != null)
        {
            mode = Mode.Draw;
            bandEnd = p; band = new Rect(p, p);
            overlay.CaptureMouse();
            return;
        }
        if (HandleAt(p) is { } hd)
        {
            dragOid = hd.oid;
            if (hd.which >= 10) { mode = Mode.Endpoint; dragEnd = hd.which - 10; LineOverrides[hd.oid] = LineEnds(hd.oid)!.ToArray(); }
            else { mode = Mode.Resize; dragScale = 1; dragBox = BoxOf(hd.oid)!.Value; }
            overlay.CaptureMouse();
            return;
        }
        var hit = HitTest(p);
        if (e.ClickCount != 2 && GuideAt(p) is int gi)
        {
            mode = Mode.Guide;
            dragGuide = gi;
            overlay.CaptureMouse();
            DrawOverlay();
            return;
        }
        if (e.ClickCount == 2)
        {
            // a double-click retypes text and formulas; on anything else it is an ordinary press (a quick drag)
            if (hit is int h && Scene?.Obj(h) is { } o && (o.IsText || o.Kind == "table")) { BeginTextEdit(h); return; }
            if (hit == null && PlaceholderAt(p) is { } ph) { BeginPlaceholderEdit(ph); return; }
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
            mode = Mode.Press;
            dragDelta = new Vector();
            overlay.CaptureMouse();
        }
        else if (PlaceholderAt(p) is { } ph)
        {
            Select(Array.Empty<int>());
            BeginPlaceholderEdit(ph);
        }
        else
        {
            // empty space: drag a marquee to select what it encloses
            if (!Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) Select(Array.Empty<int>());
            mode = Mode.Marquee;
            band = new Rect(p, p);
            overlay.CaptureMouse();
        }
    }

    Placeholder? PlaceholderAt(Point p) => Scene?.Placeholders?.FirstOrDefault(ph => ph.Rect.Contains(p));

    void OnMove(object sender, MouseEventArgs e)
    {
        var p = e.GetPosition(frame);
        pointer = p;
        RedrawRulers();
        // the button went up somewhere else (another window took the release): end the press here
        if (mode != Mode.None && e.LeftButton != MouseButtonState.Pressed) { EndPress(commit: true); return; }
        switch (mode)
        {
            case Mode.Guide:
                if (dragGuide is int di && di < UserGuides.Count) UpdateGuideDrag(UserGuides[di].vertical ? p.X : p.Y);
                return;
            case Mode.Press or Mode.Move when Selected.Count > 0:
            {
                var delta = p - downAt;
                if (mode == Mode.Press && delta.Length * Scale < 3) return;
                mode = Mode.Move;
                dragDelta = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)     // Shift: horizontal or vertical only
                    ? (Math.Abs(delta.X) > Math.Abs(delta.Y) ? new Vector(delta.X, 0) : new Vector(0, delta.Y))
                    : Snap(delta);
                Redraw();
                return;
            }
            case Mode.Resize:
            {
                var c = new Point(dragBox.X + dragBox.Width / 2, dragBox.Y + dragBox.Height / 2);
                var d0 = Math.Max(1, Math.Sqrt(dragBox.Width * dragBox.Width + dragBox.Height * dragBox.Height) / 2);
                dragScale = Math.Max(0.05, (p - c).Length / d0);
                Redraw();
                return;
            }
            case Mode.Endpoint:
            {
                var ends = LineOverrides[dragOid];
                if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift))    // Shift: horizontal, vertical or 45°
                    p = Snap45(new Point(ends[dragEnd == 0 ? 2 : 0], ends[dragEnd == 0 ? 3 : 1]), p);
                ends[dragEnd * 2] = p.X; ends[dragEnd * 2 + 1] = p.Y;
                Redraw();
                return;
            }
            case Mode.Marquee or Mode.Draw:
                if (mode == Mode.Draw && Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) && drawTool is "line" or "arrow" or "darrow")
                    p = Snap45(downAt, p);
                bandEnd = p;
                band = new Rect(downAt, p);
                DrawOverlay();
                return;
            case Mode.Pen:
                if ((p - penPoints[^1]).Length * Scale >= 1.5) { penPoints.Add(p); DrawOverlay(); }
                return;
        }
        if (drawTool != null) return;
        if (HandleAt(p) is { } hd)
        {
            Cursor = hd.which >= 10 ? Cursors.Cross : hd.which is 0 or 3 ? Cursors.SizeNWSE : Cursors.SizeNESW;
            return;
        }
        if (GuideAt(p) is int g)
        {
            Cursor = UserGuides[g].vertical ? Cursors.SizeWE : Cursors.SizeNS;
            if (hover != null) { hover = null; DrawOverlay(); }
            return;
        }
        var h = HitTest(p);
        Cursor = h != null ? Cursors.SizeAll : PlaceholderAt(p) != null ? Cursors.IBeam : Cursors.Arrow;
        if (h != hover) { hover = h; DrawOverlay(); }
    }

    static Point Snap45(Point a, Point b)
    {
        var v = b - a;
        var ang = Math.Round(Math.Atan2(v.Y, v.X) / (Math.PI / 4)) * (Math.PI / 4);
        var len = v.Length;
        return new Point(a.X + Math.Cos(ang) * len, a.Y + Math.Sin(ang) * len);
    }

    void OnUp(object sender, MouseButtonEventArgs e) => EndPress(commit: true);

    void EndPress(bool commit)
    {
        var m = mode;
        mode = Mode.None;
        if (overlay.IsMouseCaptured) overlay.ReleaseMouseCapture();
        switch (m)
        {
            case Mode.Guide:
                EndGuideDrag();
                break;
            case Mode.Move:
            {
                var delta = dragDelta;
                dragDelta = new Vector();
                guides.Clear();
                if (commit && delta.Length > 0.01)
                {
                    foreach (var oid in Selected)
                    {
                        var p = Overrides.TryGetValue(oid, out var o) ? o : new Preview(new Vector());
                        if (p.Scale == 0) p.Scale = 1;
                        p.Offset += delta;
                        Overrides[oid] = p;
                    }
                    Redraw();
                    MoveCommitted?.Invoke(Selected.ToList(), delta.X, delta.Y);
                }
                else Redraw();
                break;
            }
            case Mode.Resize:
            {
                var s = dragScale;
                dragScale = 1;
                if (commit && Math.Abs(s - 1) > 0.002)
                {
                    var p = Overrides.TryGetValue(dragOid, out var o) ? o : new Preview(new Vector());
                    p.Scale = (p.Scale == 0 ? 1 : p.Scale) * s;
                    Overrides[dragOid] = p;
                    Redraw();
                    ResizeCommitted?.Invoke(dragOid, s);
                }
                else Redraw();
                break;
            }
            case Mode.Endpoint:
            {
                var ends = LineOverrides[dragOid];
                var orig = Stop?.Lines?.GetValueOrDefault(dragOid.ToString());
                bool moved = orig == null || Math.Abs(ends[0] - orig[0]) + Math.Abs(ends[1] - orig[1]) + Math.Abs(ends[2] - orig[2]) + Math.Abs(ends[3] - orig[3]) > 1;
                if (commit && moved) { Redraw(); EndpointsCommitted?.Invoke(dragOid, ends.ToArray()); }
                else { LineOverrides.Remove(dragOid); Redraw(); }
                break;
            }
            case Mode.Marquee:
            {
                var r = band;
                band = null;
                if (r is Rect b && b.Width * Scale >= 3 && b.Height * Scale >= 3)
                {
                    var inside = Stop?.Visible.Select(v => (int)v[0]).Where(o => BoxOf(o) is Rect ob && b.Contains(ob)).SelectMany(WithGroup).ToList() ?? new();
                    Select(Selected.Concat(inside));
                }
                else DrawOverlay();
                break;
            }
            case Mode.Draw:
            {
                var tool = drawTool;
                var a = downAt; var b = bandEnd;
                band = null;
                drawTool = null;
                Cursor = Cursors.Arrow;
                DrawToolChanged?.Invoke();
                DrawOverlay();
                if (commit && tool != null && (b - a).Length * Scale >= 6) DrawCommitted?.Invoke(tool, a, b);
                break;
            }
            case Mode.Pen:
            {
                var pts = penPoints.ToList();
                penPoints.Clear();
                double length = 0;
                for (int i = 1; i < pts.Count; i++) length += (pts[i] - pts[i - 1]).Length;
                if (commit && pts.Count >= 2 && length * Scale >= 4)
                {
                    pendingStrokes.Add(pts);
                    PenCommitted?.Invoke(pts);
                }
                DrawOverlay();                // the pen stays in hand for the next stroke (Esc puts it down)
                break;
            }
        }
    }

    /// Shifts the selection by hand (arrow-key nudges) until its render lands.
    public void Nudge(double dx, double dy)
    {
        foreach (var oid in Selected)
        {
            var p = Overrides.TryGetValue(oid, out var o) ? o : new Preview(new Vector());
            if (p.Scale == 0) p.Scale = 1;
            p.Offset += new Vector(dx, dy);
            Overrides[oid] = p;
        }
        Redraw();
    }

    public void ClearOverride(int oid)
    {
        var a = Overrides.Remove(oid);
        var b = LineOverrides.Remove(oid);
        if (a || b) Redraw();
    }

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
        OpenEditor(ph.Rect, "", Math.Clamp(ph.Size * 0.9, 14, 90), ph.Prompt + " · Enter applies · Esc cancels", false);
        DrawOverlay();
    }

    void OpenEditor(Rect r, string text, double fontPx, string tip, bool mono)
    {
        editor = new TextBox
        {
            Text = text, FontSize = fontPx, AcceptsReturn = true, AcceptsTab = false, TextWrapping = TextWrapping.Wrap,
            Background = new SolidColorBrush(Color.FromArgb(0xee, 0x1e, 0x1f, 0x24)), Foreground = Brushes.White,
            CaretBrush = Brushes.White, BorderBrush = Accent,
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
