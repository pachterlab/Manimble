using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace Manimble;

/// One Manim Slides slide (a `next_slide()` stop): the clip that plays when you advance to it.
public sealed class PresentSlide
{
    public string Scene { get; set; } = "";
    public int SceneIndex { get; set; }
    public int Number { get; set; }
    public int Index { get; set; }
    public int Count { get; set; }
    public string Kind { get; set; } = "video";      // video | image
    public string? File { get; set; }
    public string? RevFile { get; set; }
    public bool Loop { get; set; }
    public bool AutoNext { get; set; }
    public double Rate { get; set; } = 1;
    public double RevRate { get; set; } = 1;
    public string Notes { get; set; } = "";
    public string? BuildNotes { get; set; }
    public bool? Pending { get; set; }
}

public sealed class PresentDeck
{
    public List<PresentSlide> Slides { get; set; } = new();
    public List<int> Sections { get; set; } = new();
    public Dictionary<string, List<LinkRegion>>? Links { get; set; }   // by scene index: the slide's hyperlinks
}

/// The animated show (the Mac's AnimatedPlayer, the native replacement for `manim-slides present`): plays the clips
/// the engine built, build by build, full screen. Keys follow Manim Slides where they exist (Right next, Left
/// previous, Space play/pause, R replay, V reverse, Q quit) plus the slideshow's (B blank, P progress, Home/End, Esc);
/// 1-9 jump to the deck's chapters.
public sealed class AnimatedShowWindow : Window
{
    enum Mode { Play, End, Reverse }

    readonly Grid root = new() { Background = Brushes.Black };
    readonly Grid media = new() { Background = Brushes.Black };       // the slide alone (what Presenter View mirrors)
    readonly Image still = new() { Stretch = Stretch.Uniform };
    readonly MediaElement[] players = { NewPlayer(), NewPlayer() };
    int front = -1;                  // the player on screen
    readonly Rectangle progress = new() { Height = 3, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom };
    readonly TextBlock counter = new()
    {
        Foreground = new SolidColorBrush(Color.FromArgb(0xcc, 0xff, 0xff, 0xff)), FontSize = 13, Margin = new Thickness(16, 0, 16, 12),
        HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
    };
    readonly TextBlock placeholder = new()
    {
        Foreground = new SolidColorBrush(Color.FromArgb(0x90, 0xff, 0xff, 0xff)), FontSize = 26,
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed,
    };
    readonly Rectangle black = new() { Fill = Brushes.Black, Visibility = Visibility.Collapsed };
    /// Above the slide, in this window's coordinates: a scripted presentation's pointer and pause badge.
    public Canvas Overlay { get; } = new() { IsHitTestVisible = false };
    /// Sees each key first; true swallows it (a scripted presentation's Space pauses the script).
    public Func<Key, bool>? KeyFilter;
    readonly DispatcherTimer hideCursor = new() { Interval = TimeSpan.FromSeconds(2) };

    PresentDeck deck;
    int index;
    int generation;
    bool finished;
    bool showProgress = true;
    Mode mode;

    public event Action? Exited;
    public event Action? Changed;
    public PresentSlide? Current => index >= 0 && index < deck.Slides.Count ? deck.Slides[index] : null;
    public int PageIndex => index;
    public IReadOnlyList<PresentSlide> Slides => deck.Slides;
    public bool IsBlackedOut => black.Visibility == Visibility.Visible;
    public bool IsFinished => finished;

    static MediaElement NewPlayer() => new()
    {
        LoadedBehavior = MediaState.Manual, UnloadedBehavior = MediaState.Close, Stretch = Stretch.Uniform,
        ScrubbingEnabled = true, Opacity = 0, IsMuted = false,
    };

    public AnimatedShowWindow(PresentDeck d, int startScene, Screen? screen = null, Window? reference = null)
    {
        deck = d;
        Title = "Manimble Show";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        Background = Brushes.Black;
        Topmost = true;
        ShowInTaskbar = true;
        root.Children.Add(media);
        media.Children.Add(still);
        foreach (var p in players)
        {
            media.Children.Add(p);
            p.MediaOpened += OnOpened;
            p.MediaEnded += OnEnded;
            p.MediaFailed += (s, e) => { Log.Note("show clip failed: " + e.ErrorException?.Message); finished = true; Changed?.Invoke(); };
        }
        progress.Fill = (Brush)Application.Current.Resources["SelectionBrush"];
        root.Children.Add(placeholder);
        root.Children.Add(progress);
        root.Children.Add(counter);
        root.Children.Add(Overlay);
        root.Children.Add(black);
        Content = root;
        if (screen != null && reference != null) screen.Place(this, reference);
        Loaded += (_, _) =>
        {
            WindowState = WindowState.Maximized;
            var i = deck.Slides.FindIndex(s => s.SceneIndex >= startScene);
            Show(i < 0 ? 0 : i, Mode.Play);
        };
        KeyDown += OnKey;
        // a click opens the hyperlink under it, else advances
        MouseLeftButtonDown += (_, e) =>
        {
            if (LinkAt(e.GetPosition(media), media.RenderSize) is { } url) Tools.OpenUrl(url);
            else Next();
        };
        MouseRightButtonDown += (_, _) => Previous();
        MouseMove += (_, e) =>
        {
            Cursor = LinkAt(e.GetPosition(media), media.RenderSize) != null ? Cursors.Hand : Cursors.Arrow;
            hideCursor.Stop(); hideCursor.Start();
        };
        hideCursor.Tick += (_, _) => { hideCursor.Stop(); Cursor = Cursors.None; };
        Cursor = Cursors.None;
        SizeChanged += (_, _) => UpdateChrome();
        Closed += (_, _) => { foreach (var p in players) p.Close(); Exited?.Invoke(); };
    }

    /// The pages again, as slides that were still building get their clips (`present` "update" events). The show
    /// stays on the build it is showing; a page that was a placeholder comes back at the end of its clip.
    public void Update(PresentDeck d)
    {
        if (d.Slides.Count == 0) return;
        var old = Current;
        deck = d;
        var i = Math.Min(index, d.Slides.Count - 1);
        if (old != null)
        {
            var j = d.Slides.FindIndex(s => s.Scene == old.Scene && s.Index == old.Index);
            if (j < 0) j = d.Slides.FindIndex(s => s.Scene == old.Scene);
            if (j < 0) j = d.Slides.FindIndex(s => s.Number >= old.Number);
            i = j < 0 ? d.Slides.Count - 1 : j;
        }
        index = i;
        if (old?.Pending == true && (d.Slides[i].Pending != true || d.Slides[i].File != old.File)) Show(i, Mode.End);
        else { UpdateChrome(); Changed?.Invoke(); }
    }

    // ---------------------------------------------------------------- loading clips

    void Show(int i, Mode m)
    {
        if (i < 0 || i >= deck.Slides.Count) return;
        index = i;
        mode = m;
        generation++;
        finished = false;
        var slide = deck.Slides[i];
        UpdateChrome();
        placeholder.Text = $"Building slide {slide.Number + 1}…";
        placeholder.Visibility = slide.Pending == true && slide.File == null ? Visibility.Visible : Visibility.Collapsed;
        if (slide.Kind == "image")
        {
            HideVideo();
            still.Source = slide.File != null ? Images.Load(slide.File) : null;
            finished = true;
            Changed?.Invoke();
            return;
        }
        var path = m == Mode.Reverse ? slide.RevFile ?? slide.File : slide.File;
        if (path == null || !File.Exists(path))
        {
            finished = true;                             // nothing to play: settle the page so stepping goes on
            Changed?.Invoke();
            return;
        }
        // load into the player that is not on screen; it is shown once its first frame is ready (OnOpened)
        var back = players[front == 0 ? 1 : 0];
        back.Tag = generation;
        back.Opacity = 0;
        back.Source = new Uri(path);
        back.SpeedRatio = Math.Max(0.1, m == Mode.Reverse ? slide.RevRate : slide.Rate);
        back.Play();
        if (m == Mode.End) back.Pause();
    }

    void OnOpened(object? sender, RoutedEventArgs e)
    {
        if (sender is not MediaElement p || p.Tag is not int gen || gen != generation) return;
        if (mode == Mode.End && p.NaturalDuration.HasTimeSpan)
        {
            p.Pause();
            p.Position = p.NaturalDuration.TimeSpan - TimeSpan.FromMilliseconds(17);
            finished = true;
        }
        // swap: the new clip on top, the old one stopped
        var old = front >= 0 ? players[front] : null;
        front = Array.IndexOf(players, p);
        Panel.SetZIndex(p, 2);
        if (old != null && old != p) { Panel.SetZIndex(old, 1); old.Stop(); old.Opacity = 0; old.Source = null; }
        p.Opacity = 1;
        still.Source = null;
        Changed?.Invoke();
    }

    void OnEnded(object? sender, RoutedEventArgs e)
    {
        if (sender is not MediaElement p || p.Tag is not int gen || gen != generation) return;
        var slide = deck.Slides[index];
        if (mode == Mode.Play && slide.Loop) { p.Position = TimeSpan.Zero; p.Play(); return; }
        if (mode == Mode.Play && slide.AutoNext && index + 1 < deck.Slides.Count) { Show(index + 1, Mode.Play); return; }
        finished = true;
        p.Pause();
        Changed?.Invoke();
    }

    void HideVideo()
    {
        foreach (var p in players) { p.Stop(); p.Opacity = 0; p.Source = null; }
        front = -1;
    }

    void UpdateChrome()
    {
        if (deck.Slides.Count == 0) return;
        var s = deck.Slides[Math.Clamp(index, 0, deck.Slides.Count - 1)];
        var total = deck.Slides[^1].Number + 1;
        counter.Text = $"{s.Number + 1} / {total}" + (s.Count > 1 ? $"  ·  {s.Index + 1}/{s.Count}" : "");
        counter.Visibility = showProgress ? Visibility.Visible : Visibility.Collapsed;
        progress.Visibility = showProgress ? Visibility.Visible : Visibility.Collapsed;
        progress.Width = ActualWidth * (index + 1) / Math.Max(1, deck.Slides.Count);
    }

    // ---------------------------------------------------------------- navigation

    public void Next()
    {
        if (index == deck.Slides.Count - 1) { if (finished) Close(); }
        else Show(index + 1, Mode.Play);
    }
    public void Previous() { if (index > 0) Show(index - 1, Mode.End); }

    /// The width/height of the slide on screen (the clip's, else the still's, else 16:9).
    double Aspect
    {
        get
        {
            if (front >= 0 && players[front].NaturalVideoWidth > 0) return (double)players[front].NaturalVideoWidth / players[front].NaturalVideoHeight;
            if (still.Source is System.Windows.Media.Imaging.BitmapSource b && b.PixelHeight > 0) return (double)b.PixelWidth / b.PixelHeight;
            return 16.0 / 9;
        }
    }

    /// The hyperlink at point `p` of an area of size `area` showing the slide (this window, or Presenter View's mirror).
    public string? LinkAt(Point p, Size area)
    {
        if (Current is not { } s || IsBlackedOut || deck.Links == null) return null;
        if (!deck.Links.TryGetValue(s.SceneIndex.ToString(), out var regions) || regions.Count == 0) return null;
        return LinkRegion.Fraction(p, area, Aspect) is { } f ? LinkRegion.At(regions, f) : null;
    }
    public void Go(int i) => Show(i, Mode.Play);

    /// Where the slide is drawn in this window (letterboxed to its aspect).
    public Rect SlideRect
    {
        get
        {
            double w = root.ActualWidth, h = root.ActualHeight, a = Aspect;
            if (w <= 0 || h <= 0) return Rect.Empty;
            return w / h > a ? new Rect((w - h * a) / 2, 0, h * a, h) : new Rect(0, (h - w / a) / 2, w, w / a);
        }
    }

    /// The page is up and still: its picture loaded or its clip played (a looping clip once it is on screen).
    public bool ScriptPageReady => finished || (Current?.Loop == true && front >= 0);
    void Replay() => Show(index, Mode.Play);
    void Reverse() => Show(index, Mode.Reverse);

    void PlayPause()
    {
        if (finished) { Next(); return; }
        if (front < 0) return;
        var p = players[front];
        if (p.Tag is int g && g == generation && paused) { p.Play(); paused = false; }
        else { p.Pause(); paused = true; }
        Changed?.Invoke();
    }
    bool paused;

    public void ToggleBlack()
    {
        black.Visibility = black.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;
        Changed?.Invoke();
    }

    /// The live picture of the show, for Presenter View to mirror.
    public Visual Stage => media;

    void OnKey(object sender, KeyEventArgs e)
    {
        if (HandleKey(e.Key == Key.System ? e.SystemKey : e.Key)) e.Handled = true;
    }

    /// A key of the show (also sent by Presenter View); true when it was one.
    public bool HandleKey(Key key)
    {
        if (KeyFilter?.Invoke(key) == true) return true;
        if (key is >= Key.D1 and <= Key.D9 || key is >= Key.NumPad1 and <= Key.NumPad9)
        {
            // 1-9: the deck's chapters (sections), as in Manim Slides
            var n = key >= Key.NumPad1 ? key - Key.NumPad1 : key - Key.D1;
            if (n < deck.Sections.Count)
            {
                var j = deck.Slides.FindIndex(s => s.SceneIndex >= deck.Sections[n]);
                if (j >= 0) Show(j, Mode.Play);
            }
            return true;
        }
        switch (key)
        {
            case Key.Escape or Key.Q: Close(); break;
            case Key.Right or Key.Down or Key.PageDown or Key.Enter or Key.N: Next(); break;
            case Key.Left or Key.Up or Key.PageUp or Key.Back: Previous(); break;
            case Key.Space: PlayPause(); break;
            case Key.R: Replay(); break;
            case Key.V: Reverse(); break;
            case Key.B or Key.OemPeriod: ToggleBlack(); break;
            case Key.P: showProgress = !showProgress; UpdateChrome(); break;
            case Key.Home: Show(0, Mode.Play); break;
            case Key.End: Show(deck.Slides.Count - 1, Mode.End); break;
            default: return false;
        }
        return true;
    }
}

/// A display (EnumDisplayMonitors), for putting the show on one monitor and Presenter View on another. Bounds are
/// physical pixels; `Place` turns them into the window's device-independent units.
public sealed record Screen(Int32Rect Bounds, bool Primary)
{
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct RECT { public int L, T, R, B; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    delegate bool MonitorEnum(IntPtr h, IntPtr hdc, IntPtr rect, IntPtr data);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnum cb, IntPtr data);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    public IntPtr Handle { get; init; }

    public static List<Screen> All()
    {
        var outp = new List<Screen>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h, _, _, _) =>
        {
            var mi = new MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<MONITORINFO>() };
            if (GetMonitorInfo(h, ref mi))
                outp.Add(new Screen(new Int32Rect(mi.rcMonitor.L, mi.rcMonitor.T, mi.rcMonitor.R - mi.rcMonitor.L, mi.rcMonitor.B - mi.rcMonitor.T),
                                    (mi.dwFlags & 1) != 0) { Handle = h });
            return true;
        }, IntPtr.Zero);
        return outp;
    }

    /// The display a window is on.
    public static IntPtr Of(Window w) => MonitorFromWindow(new System.Windows.Interop.WindowInteropHelper(w).Handle, 2);

    /// Moves `w` onto this display (before it is maximized there).
    public void Place(Window w, Window reference)
    {
        var dpi = VisualTreeHelper.GetDpi(reference);
        w.WindowStartupLocation = WindowStartupLocation.Manual;
        w.Left = Bounds.X / dpi.DpiScaleX + 40;
        w.Top = Bounds.Y / dpi.DpiScaleY + 40;
        w.Width = 800; w.Height = 600;
    }
}
