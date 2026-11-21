using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace Manimble;

/// PowerPoint-style ruler along the top (horizontal) or left (vertical) edge of the slide canvas (the Mac's RulerView).
///
/// Graduated in manim units with 0 at the slide's centre (negative left and below, positive right and above, as in
/// `move_to([x, y, 0])`), it shows the slide's extent, the selection's extent, the user's guides and the pointer, and
/// follows the zoom and scrolling. Drag from the ruler onto the slide to add a guide; drag a guide's marker to move it.
public sealed class Ruler : FrameworkElement
{
    public const double Thickness = 20;
    readonly SlideCanvas canvas;
    readonly bool horizontal;
    bool dragging;

    static readonly Brush Back = Frozen(Color.FromRgb(0x24, 0x24, 0x28));
    static readonly Brush SlideBand = Frozen(Color.FromArgb(0x16, 0xff, 0xff, 0xff));
    static readonly Brush SelectionBand = Frozen(Color.FromArgb(0x48, 0x4c, 0x8d, 0xff));
    static readonly Brush Minor = Frozen(Color.FromArgb(0x48, 0xff, 0xff, 0xff));
    static readonly Brush Major = Frozen(Color.FromArgb(0x9a, 0xff, 0xff, 0xff));
    static readonly Brush Label = Frozen(Color.FromArgb(0xb8, 0xff, 0xff, 0xff));
    static readonly Brush Pointer = Frozen(Color.FromArgb(0xd8, 0xff, 0xff, 0xff));
    static readonly Brush Edge = Frozen(Color.FromArgb(0x24, 0xff, 0xff, 0xff));
    public static readonly Brush GuideBrush = Frozen(Color.FromRgb(0x40, 0xd9, 0xff));
    static readonly Typeface Face = new("Consolas");

    static Brush Frozen(Color c) { var b = new SolidColorBrush(c); b.Freeze(); return b; }

    public Ruler(SlideCanvas canvas, bool horizontal)
    {
        this.canvas = canvas;
        this.horizontal = horizontal;
        ToolTip = horizontal ? "Drag down onto the slide to add a horizontal guide" : "Drag right onto the slide to add a vertical guide";
        ClipToBounds = true;
    }

    /// Where a frame-pixel coordinate along this ruler's axis lands in this ruler, in DIPs.
    double ViewPos(double framePx)
    {
        var p = canvas.FrameToElement(horizontal ? new Point(framePx, 0) : new Point(0, framePx), this);
        return horizontal ? p.X : p.Y;
    }

    /// Major step in units so labels are at least ~44 DIPs apart, and how many minor ticks it is divided into.
    static (double major, int minor) Step(double ppu)
    {
        foreach (var s in new[] { 0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10, 20 })
            if (s * ppu >= 44) return (s, s is 0.1 or 0.5 or 5 or 10 or 20 ? 5 : 4);
        return (50, 5);
    }

    protected override void OnRender(DrawingContext dc)
    {
        double length = horizontal ? ActualWidth : ActualHeight, thick = Thickness;
        dc.DrawRectangle(Back, null, new Rect(0, 0, ActualWidth, ActualHeight));
        var fs = canvas.FrameSize;
        if (!canvas.HasSlide || fs.Width <= 0) { DrawEdge(dc); return; }
        double extent = horizontal ? fs.Width : fs.Height;

        // the slide's extent, a little lighter than the surroundings
        double s0 = ViewPos(0), s1 = ViewPos(extent);
        dc.DrawRectangle(SlideBand, null, Along(Math.Min(s0, s1), Math.Max(s0, s1)));

        // the selection's extent
        if (canvas.SelectedBox is Rect box)
        {
            double a = ViewPos(horizontal ? box.Left : box.Top), z = ViewPos(horizontal ? box.Right : box.Bottom);
            dc.DrawRectangle(SelectionBand, null, Along(Math.Min(a, z), Math.Max(a, z)));
        }

        // ticks and labels: frame y grows down, manim y up, so the vertical ruler counts the other way
        double ppu = (s1 - s0) / extent * canvas.UnitPx;               // DIPs per unit
        double center = ViewPos(extent / 2);
        double dir = horizontal ? 1 : -1;
        var (major, minorN) = Step(Math.Abs(ppu));
        double minorStep = major / minorN;
        double u0 = (0 - center) / ppu * dir, u1 = (length - center) / ppu * dir;
        double first = Math.Floor(Math.Min(u0, u1) / minorStep) * minorStep, last = Math.Ceiling(Math.Max(u0, u1) / minorStep) * minorStep;
        int decimals = major >= 1 ? 0 : major == 0.25 ? 2 : 1;
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        for (int k = (int)Math.Round(first / minorStep); k * minorStep <= last + minorStep / 1000; k++)
        {
            double u = k * minorStep, pos = center + u * ppu * dir;
            if (pos < -1 || pos > length + 1) continue;
            bool isMajor = k % minorN == 0;
            bool isHalf = !isMajor && minorN % 2 == 0 && k % (minorN / 2) == 0;
            double len = isMajor ? thick : isHalf ? thick * 0.42 : thick * 0.26;
            dc.DrawRectangle(isMajor ? Major : Minor, null, Tick(pos, len));
            if (!isMajor) continue;
            var text = new FormattedText((Math.Abs(u) < minorStep / 1000 ? 0 : u).ToString("F" + decimals, CultureInfo.InvariantCulture),
                                         CultureInfo.InvariantCulture, FlowDirection.LeftToRight, Face, 9, Label, dpi);
            if (horizontal) dc.DrawText(text, new Point(pos + 3, 1));
            else
            {
                // turned to read bottom to top, as on PowerPoint's vertical ruler
                dc.PushTransform(new RotateTransform(-90, 1, pos - 3));
                dc.DrawText(text, new Point(1, pos - 3));
                dc.Pop();
            }
        }

        // guide markers (the top ruler shows the vertical guides, the left one the horizontal guides)
        foreach (var g in canvas.UserGuides)
        {
            if (g.vertical != horizontal) continue;
            double pos = ViewPos(g.pos), h = 6;
            var tri = new StreamGeometry();
            using (var c = tri.Open())
            {
                if (horizontal) { c.BeginFigure(new Point(pos - h / 2, thick), true, true); c.LineTo(new Point(pos + h / 2, thick), false, false); c.LineTo(new Point(pos, thick - h), false, false); }
                else { c.BeginFigure(new Point(thick, pos - h / 2), true, true); c.LineTo(new Point(thick, pos + h / 2), false, false); c.LineTo(new Point(thick - h, pos), false, false); }
            }
            tri.Freeze();
            dc.DrawGeometry(GuideBrush, null, tri);
        }

        if (canvas.PointerPosition is Point cur)
            dc.DrawRectangle(Pointer, null, Tick(ViewPos(horizontal ? cur.X : cur.Y), thick));
        DrawEdge(dc);
    }

    void DrawEdge(DrawingContext dc) =>
        dc.DrawRectangle(Edge, null, horizontal ? new Rect(0, ActualHeight - 1, ActualWidth, 1) : new Rect(ActualWidth - 1, 0, 1, ActualHeight));

    Rect Along(double lo, double hi) => horizontal ? new Rect(lo, 0, Math.Max(0, hi - lo), Thickness) : new Rect(0, lo, Thickness, Math.Max(0, hi - lo));

    /// A 1-DIP tick rising from the edge next to the slide.
    Rect Tick(double pos, double len) => horizontal ? new Rect(Math.Round(pos) - 0.5, Thickness - len, 1, len) : new Rect(Thickness - len, Math.Round(pos) - 0.5, len, 1);

    /// The user guide whose marker is under a point on this ruler.
    int? MarkerAt(Point p)
    {
        double v = horizontal ? p.X : p.Y;
        for (int i = 0; i < canvas.UserGuides.Count; i++)
        {
            var g = canvas.UserGuides[i];
            if (g.vertical == horizontal && Math.Abs(ViewPos(g.pos) - v) <= 5) return i;
        }
        return null;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (dragging)
        {
            var fp = canvas.FramePoint(e);
            canvas.UpdateGuideDrag(horizontal ? fp.Y : fp.X);
            return;
        }
        // over a marker: it slides along the ruler; elsewhere a new guide comes off it across the slide
        Cursor = canvas.HasSlide ? ((MarkerAt(e.GetPosition(this)) != null) == horizontal ? Cursors.SizeWE : Cursors.SizeNS) : null;
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (!canvas.HasSlide) return;
        var fp = canvas.FramePoint(e);
        if (MarkerAt(e.GetPosition(this)) is int i) canvas.ContinueGuideDrag(i);
        else canvas.BeginGuideDrag(vertical: !horizontal, horizontal ? fp.Y : fp.X);   // top ruler: a horizontal guide
        dragging = true;
        CaptureMouse();
        e.Handled = true;
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (!dragging) return;
        dragging = false;
        ReleaseMouseCapture();
        canvas.EndGuideDrag();
        e.Handled = true;
    }

    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        if (!dragging) return;
        dragging = false;
        canvas.EndGuideDrag();
    }
}
