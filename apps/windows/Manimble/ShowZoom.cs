using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace Manimble;

/// Zoom and pan of the slide in a show window: a touchpad pinch (which Windows sends as Ctrl + mouse wheel) or a
/// touchscreen pinch zooms about the fingers, the wheel or a finger drag pans while zoomed in, Esc goes back to the
/// whole slide. `target` (the slide alone, not the progress bar or counter) is scaled; it always covers the area it
/// filled at 1×. A touch tap is handed to `onTap` (touch manipulation stops taps turning into clicks).
public sealed class ShowZoom
{
    readonly Window window;
    readonly FrameworkElement target;
    readonly MatrixTransform transform = new();
    public double Scale { get; private set; } = 1;
    Vector offset;
    public const double MaxScale = 8;
    public bool IsZoomed => Scale > 1.001;

    public ShowZoom(Window window, FrameworkElement target, Action<Point> onTap)
    {
        this.window = window;
        this.target = target;
        target.RenderTransform = transform;
        if (target.Parent is FrameworkElement parent) parent.ClipToBounds = true;
        window.PreviewMouseWheel += (_, e) =>
        {
            if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { ZoomTo(Scale * Math.Pow(1.0015, e.Delta), At(e)); e.Handled = true; }
            else if (IsZoomed) { Pan(new Vector(0, e.Delta * 0.5)); e.Handled = true; }
        };
        window.IsManipulationEnabled = true;
        window.ManipulationStarting += (_, e) => { e.ManipulationContainer = window; e.Mode = ManipulationModes.All; };
        window.ManipulationDelta += (_, e) =>
        {
            var d = e.DeltaManipulation;
            var origin = window.TranslatePoint(e.ManipulationOrigin, Parent);
            if (Math.Abs(d.Scale.X - 1) > 1e-4) ZoomTo(Scale * d.Scale.X, origin);
            if (IsZoomed) Pan(d.Translation);
            e.Handled = true;
        };
        window.ManipulationCompleted += (_, e) =>
        {
            var t = e.TotalManipulation;
            if (t.Translation.Length < 12 && Math.Abs(t.Scale.X - 1) < 0.03) onTap(e.ManipulationOrigin);
            e.Handled = true;
        };
        target.SizeChanged += (_, _) => Apply();
    }

    FrameworkElement Parent => target.Parent as FrameworkElement ?? target;
    Point At(MouseEventArgs e) => e.GetPosition(Parent);

    /// Zoom to `s` keeping `p` (in the target's parent) where it is.
    public void ZoomTo(double s, Point p)
    {
        var s2 = Math.Clamp(s, 1, MaxScale);
        var c = new Point((p.X - offset.X) / Scale, (p.Y - offset.Y) / Scale);
        offset = new Vector(p.X - c.X * s2, p.Y - c.Y * s2);
        Scale = s2;
        Apply();
    }

    public void Pan(Vector d) { offset += d; Apply(); }

    public void Reset() { Scale = 1; offset = default; Apply(); }

    void Apply()
    {
        double w = target.ActualWidth, h = target.ActualHeight;
        offset.X = Math.Min(0, Math.Max(w - w * Scale, offset.X));
        offset.Y = Math.Min(0, Math.Max(h - h * Scale, offset.Y));
        if (Scale <= 1.001) { Scale = 1; offset = default; }
        transform.Matrix = new Matrix(Scale, 0, 0, Scale, offset.X, offset.Y);
    }
}
