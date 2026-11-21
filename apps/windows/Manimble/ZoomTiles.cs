using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Manimble;

// Sharp text and shapes when the editor canvas is zoomed in (the Mac app's ZoomTiles.swift).
//
// A render's frames and sprites are bitmaps at the deck's frame size (1280 px wide, typically), so the canvas
// magnifies them once it shows more than one device pixel per frame pixel. Once the zoom and scroll settle, the
// canvas asks the engine (`hires`) to draw the visible part of the shown build again at the screen's density: the
// whole frame there, the part no sprite owns, and each sprite's part. Manim's objects are vectors, so these tiles
// are exact at any zoom. They are drawn over the low-res pixels and only while they still match: the same render
// (stop png), build and colour view, nothing previewed on the object (a drag, resize or replacement keeps its own
// sprite).

/// One tile from `hires`: a picture covering frame px [x, x+w) × [y, y+h).
public sealed class HiresTile
{
    public string File { get; set; } = "";
    public double X { get; set; }
    public double Y { get; set; }
    public double W { get; set; }
    public double H { get; set; }
    public int? Oid { get; set; }
}

public sealed class HiresResult
{
    public double? Scale { get; set; }
    public HiresTile? Full { get; set; }
    public HiresTile? Bg { get; set; }
    public List<HiresTile>? Sprites { get; set; }
    public bool? Stale { get; set; }
    public string? Error { get; set; }
}

/// What the canvas would like drawn sharply: the build shown (`Png`), device px per frame px, frame-px region.
public sealed record HiresWant(string Png, double Scale, double X0, double Y0, double X1, double Y1);

public sealed partial class SlideCanvas
{
    sealed record HiresTex(BitmapSource Img, Rect Box);
    sealed record HiresSet(string Png, ColorView View, bool Recolor, double Scale, Rect Region, HiresTex? Full, HiresTex? Bg, Dictionary<int, HiresTex> Sprites);

    /// Below this many device pixels per frame pixel the render's own bitmaps are sharp enough.
    const double HiresThreshold = 1.1;

    /// Asked for sharp tiles of the build on screen (the host calls the engine's `hires`); null: nothing to show.
    public Func<HiresWant, Task<HiresResult?>>? WantHires;

    HiresSet? hires;
    HiresWant? hiresAsked;
    bool hiresInFlight, hiresQueued;
    DispatcherTimer? hiresTimer;

    /// Tiles usable for the stop on screen right now (null when they belong to another render, build or view).
    HiresSet? LiveHires => hires is { } h && Stop is { } s && h.Png == s.Png && h.View == Images.View && h.Recolor == Images.RecolorImages && Scene?.Optimistic != true ? h : null;

    double DeviceScale => Scale * VisualTreeHelper.GetDpi(this).DpiScaleX;

    /// The frame-px region of the view (with some margin for small scrolls) and the density it shows the slide at.
    HiresWant? HiresNeed()
    {
        if (Stop is not { } s || WantHires == null || !HasSlide || frame.Width <= 0 || scroller.ActualWidth <= 0) return null;
        var device = DeviceScale;
        if (device < HiresThreshold) return null;
        Rect r;
        try { r = scroller.TransformToDescendant(frame).TransformBounds(new Rect(0, 0, scroller.ActualWidth, scroller.ActualHeight)); }
        catch (InvalidOperationException) { return null; }
        double fw = frame.Width, fh = frame.Height;
        double mx = r.Width * 0.15, my = r.Height * 0.15;
        double x0 = Math.Max(-fw, r.Left - mx), x1 = Math.Min(2 * fw, r.Right + mx);
        double y0 = Math.Max(-fh, r.Top - my), y1 = Math.Min(2 * fh, r.Bottom + my);
        if (x1 <= x0 || y1 <= y0) return null;
        return new HiresWant(s.Png, Math.Min(16, Math.Ceiling(device * 4) / 4), x0, y0, x1, y1);
    }

    /// Whether the tiles in hand already show `w`'s region at least as sharply (and not wastefully finer).
    static bool Covers(HiresSet h, HiresWant w)
    {
        if (h.Png != w.Png || h.View != Images.View || h.Recolor != Images.RecolorImages || h.Scale + 0.01 < w.Scale || h.Scale > w.Scale * 2.5) return false;
        // the margin is slack: the visible part (the region less its margin) has to be inside
        double mx = (w.X1 - w.X0) * 0.15 / 1.3, my = (w.Y1 - w.Y0) * 0.15 / 1.3;
        return h.Region.Left <= w.X0 + mx + 1 && h.Region.Top <= w.Y0 + my + 1
            && h.Region.Right >= w.X1 - mx - 1 && h.Region.Bottom >= w.Y1 - my - 1;
    }

    /// After every redraw, scroll and zoom: once the view has settled on something the tiles don't cover, ask for new ones.
    void HiresCheck()
    {
        if (HiresNeed() is not { } w)
        {
            // zoomed back out: tiles far finer than the screen would only alias
            if (hires is { } h && (Stop is not { } s || h.Png != s.Png || h.Scale > DeviceScale * 2.5))
            {
                hires = null;
                Redraw();
            }
            hiresTimer?.Stop();
            return;
        }
        if (hires is { } have && Covers(have, w)) { hiresTimer?.Stop(); return; }
        if (w == hiresAsked) return;
        if (hiresTimer == null)
        {
            hiresTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(0.25) };
            hiresTimer.Tick += (_, _) => { hiresTimer.Stop(); HiresFire(); };
        }
        hiresTimer.Stop();
        hiresTimer.Start();
    }

    async void HiresFire()
    {
        if (HiresNeed() is not { } w || WantHires == null) return;
        if (hires is { } h && Covers(h, w)) return;
        if (hiresInFlight) { hiresAsked = w; hiresQueued = true; return; }   // sent when the one in flight returns
        hiresAsked = w;
        hiresInFlight = true;
        HiresResult? r = null;
        try { r = await WantHires(w); }
        catch (Exception e) { Log.Note("canvas: zoom tiles: " + e.Message); }
        hiresInFlight = false;
        if (hiresQueued)
        {
            hiresQueued = false;
            hiresAsked = null;
            HiresFire();
        }
        if (r == null || r.Error != null || r.Stale == true || r.Scale is not double scale || Stop is not { } s || s.Png != w.Png)
        {
            if (r?.Error != null || r?.Stale == true) Log.Note("canvas: no zoom tiles: " + (r.Error ?? "stale render"));
            return;
        }
        var view = Images.View;
        HiresTex? Load(HiresTile? t) =>
            t != null && Images.LoadUncached(t.File, map: Images.RecolorImages || t.Oid is not int o || Scene?.Obj(o)?.Kind != "image") is { } img
                ? new HiresTex(img, new Rect(t.X, t.Y, t.W, t.H)) : null;
        var sprites = new Dictionary<int, HiresTex>();
        foreach (var t in r.Sprites ?? new()) if (t.Oid is int oid && Load(t) is { } x) sprites[oid] = x;
        hires = new HiresSet(w.Png, view, Images.RecolorImages, scale, new Rect(new Point(w.X0, w.Y0), new Point(w.X1, w.Y1)), Load(r.Full), Load(r.Bg), sprites);
        Redraw();
    }

    static Image TileImage(HiresTex t)
    {
        var img = new Image { Source = t.Img, Width = t.Box.Width, Height = t.Box.Height, Stretch = Stretch.Fill };
        RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
        Canvas.SetLeft(img, t.Box.X); Canvas.SetTop(img, t.Box.Y);
        return img;
    }
}
