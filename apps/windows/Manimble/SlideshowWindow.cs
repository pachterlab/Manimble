using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Manimble;

/// A full-screen slideshow of the deck's exact frames, one per build (deck_pages). The animated show from
/// `present` clips comes later; this is the static show the Mac app falls back to. Like the animated show, it has a
/// slide and build counter and a progress bar along the bottom (Play > Show Slide and Build Numbers; P shows or
/// hides them).
public sealed class SlideshowWindow : Window
{
    static SlideshowWindow? open;
    readonly Engine engine;
    readonly Image image = new() { Stretch = Stretch.Uniform };
    readonly TextBlock info = new()
    {
        Foreground = Brushes.Gray, FontSize = 14, Margin = new Thickness(16), HorizontalAlignment = HorizontalAlignment.Right,
        VerticalAlignment = VerticalAlignment.Bottom,
    };
    readonly Rectangle progress = new() { Height = 3, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom };
    readonly TextBlock counter = new()
    {
        Foreground = new SolidColorBrush(Color.FromArgb(0xcc, 0xff, 0xff, 0xff)), FontSize = 13, Margin = new Thickness(16, 0, 16, 12),
        HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
    };
    bool showProgress = Settings.Current.ShowSlideNumbers;
    readonly TextBlock waiting = new()
    {
        Foreground = Brushes.Gray, FontSize = 22, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        Text = "Rendering…", Visibility = Visibility.Collapsed,
    };
    List<DeckSlide> deck = new();
    int slide, page;
    readonly string startScene;
    readonly int startPage;
    bool black;
    readonly ShowZoom zoom;

    public SlideshowWindow(Engine engine, string startScene, int startPage)
    {
        this.engine = engine;
        this.startScene = startScene;
        this.startPage = startPage;
        Title = "Manimble Slideshow";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        Background = Brushes.Black;
        WindowState = WindowState.Maximized;
        Topmost = true;
        Cursor = Cursors.None;
        var g = new Grid();
        g.Children.Add(image);
        g.Children.Add(waiting);
        g.Children.Add(info);
        progress.Fill = (Brush)Application.Current.Resources["SelectionBrush"];
        g.Children.Add(progress);
        g.Children.Add(counter);
        Content = g;
        SizeChanged += (_, _) => UpdateChrome();
        KeyDown += OnKey;
        // a click (or a touch tap) opens the hyperlink under it, else advances; a pinch zooms
        zoom = new ShowZoom(this, image, p => Click(TranslatePoint(p, image)));
        MouseLeftButtonDown += (_, e) => Click(e.GetPosition(image));
        MouseRightButtonDown += (_, _) => Step(-1);
        MouseMove += (_, e) =>
        {
            Cursor = LinkAt(e.GetPosition(image)) != null ? Cursors.Hand : Cursors.Arrow;
            hideCursor.Stop(); hideCursor.Start();
        };
        hideCursor.Tick += (_, _) => { hideCursor.Stop(); Cursor = Cursors.None; };
        Loaded += async (_, _) => await Fetch(startScene, 3, first: true);
        Closed += (_, _) => { if (open == this) open = null; };
        open?.Close();
        open = this;
    }

    readonly System.Windows.Threading.DispatcherTimer hideCursor = new() { Interval = TimeSpan.FromSeconds(2) };

    /// The main window passes engine events on: a slide that finished rendering may be the one the show waits for.
    public static void Forward(JsonElement ev)
    {
        if (open == null || ev.GetProperty("event").GetString() != "rendered") return;
        if (open.deck.Any(s => s.Pending == true)) _ = open.Fetch(null, 0, first: false);
    }

    async Task Fetch(string? current, int ahead, bool first)
    {
        var args = new JsonObject { ["ahead"] = ahead };
        if (current != null) args["current"] = current;
        DeckPages? d;
        try { d = await engine.Call<DeckPages>("deck_pages", args); }
        catch (Exception e) { info.Text = "Could not build the show: " + e.Message; return; }
        if (d == null) return;
        var name = first ? startScene : deck.ElementAtOrDefault(slide)?.Scene;
        deck = d.Slides;
        if (deck.Count == 0) { info.Text = "No slides to show"; return; }
        var i = deck.FindIndex(s => s.Scene == name);
        if (i >= 0) slide = i;
        if (first) page = Math.Min(startPage, Math.Max(0, deck[slide].Pages.Count - 1));
        ShowPage();
    }

    void ShowPage()
    {
        if (deck.Count == 0) return;
        var s = deck[slide];
        if (s.Pages.Count == 0)
        {
            image.Source = null;
            waiting.Text = s.Error != null ? $"{s.Scene} failed to render" : $"Rendering {s.Scene}…";
            waiting.Visibility = Visibility.Visible;
            if (s.Pending == true) _ = Fetch(s.Scene, 1, first: false);
        }
        else
        {
            waiting.Visibility = Visibility.Collapsed;
            page = Math.Clamp(page, 0, s.Pages.Count - 1);
            image.Source = black ? null : Images.Load(s.Pages[page]);
        }
        info.Text = "";
        UpdateChrome();
    }

    /// Builds a slide has (its pages, or the count the engine expects while it still renders).
    static int BuildsOf(DeckSlide s) => Math.Max(1, Math.Max(s.Pages.Count, s.Builds ?? 0));

    /// The counter ("slide / slides  ·  build/builds") and the progress bar (builds shown so far over all builds).
    void UpdateChrome()
    {
        var on = showProgress && deck.Count > 0;
        counter.Visibility = progress.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (!on) return;
        var s = deck[slide];
        var builds = BuildsOf(s);
        counter.Text = $"{slide + 1} / {deck.Count}" + (builds > 1 ? $"  ·  {page + 1}/{builds}" : "");
        double done = deck.Take(slide).Sum(BuildsOf) + page + 1, total = deck.Sum(BuildsOf);
        progress.Width = ActualWidth * done / Math.Max(1, total);
    }

    void Click(Point p) { if (LinkAt(p) is { } url) Tools.OpenUrl(url); else Step(+1); }

    /// The hyperlink under a point of the (possibly zoomed) image, in its own unzoomed coordinates.
    string? LinkAt(Point p)
    {
        if (black || slide >= deck.Count || image.Source is not System.Windows.Media.Imaging.BitmapSource b || b.PixelHeight == 0) return null;
        var regions = deck[slide].Links?.ElementAtOrDefault(page);
        if (regions == null || regions.Count == 0) return null;
        return LinkRegion.Fraction(p, image.RenderSize, (double)b.PixelWidth / b.PixelHeight) is { } f ? LinkRegion.At(regions, f) : null;
    }

    void Step(int d)
    {
        if (deck.Count == 0) return;
        black = false;
        var s = deck[slide];
        var was = slide;
        if (d > 0)
        {
            if (page + 1 < s.Pages.Count) page++;
            else if (slide + 1 < deck.Count) { slide++; page = 0; }
            else { Close(); return; }
        }
        else
        {
            if (page > 0) page--;
            else if (slide > 0) { slide--; page = Math.Max(0, deck[slide].Pages.Count - 1); }
        }
        if (slide != was) zoom.Reset();
        ShowPage();
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Escape: if (zoom.IsZoomed) zoom.Reset(); else Close(); break;
            case Key.Right or Key.Down or Key.Space or Key.PageDown or Key.Enter or Key.N: Step(+1); break;
            case Key.Left or Key.Up or Key.PageUp or Key.Back: Step(-1); break;
            case Key.P: showProgress = !showProgress; UpdateChrome(); break;
            case Key.Home: slide = 0; page = 0; zoom.Reset(); ShowPage(); break;
            case Key.End: slide = deck.Count - 1; page = 0; zoom.Reset(); ShowPage(); break;
            case Key.B or Key.OemPeriod: black = !black; ShowPage(); break;
            default: return;
        }
        e.Handled = true;
    }
}
