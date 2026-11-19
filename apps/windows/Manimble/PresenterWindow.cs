using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Manimble;

/// Presenter View (the Mac's PresenterController): on the presenter's display, the show as the audience sees it
/// (mirrored live from the show window), the next build, the speaker notes, the elapsed time and the clock; the show
/// itself runs full screen on the other display, or behind this window with one display. Keys drive the show.
public sealed class PresenterWindow : Window
{
    readonly AnimatedShowWindow show;
    readonly Func<string, int, string?> nextStill;      // the exact frame of (scene, build), from deck_pages
    readonly Border live = new() { Background = Brushes.Black, CornerRadius = new CornerRadius(4) };
    readonly Image next = new() { Stretch = Stretch.Uniform };
    readonly TextBlock nextLabel = new() { Foreground = Brushes.Gray, FontSize = 13, Margin = new Thickness(0, 0, 0, 4) };
    readonly TextBox notes = new()
    {
        IsReadOnly = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        FontSize = 22, Background = Brushes.Transparent, Foreground = Brushes.White, BorderThickness = new Thickness(0),
    };
    readonly TextBlock timer = new() { Foreground = Brushes.White, FontSize = 34, FontWeight = FontWeights.SemiBold };
    readonly TextBlock clock = new() { Foreground = Brushes.Gray, FontSize = 18, Margin = new Thickness(16, 0, 0, 0), VerticalAlignment = VerticalAlignment.Bottom };
    readonly TextBlock counter = new() { Foreground = Brushes.Gray, FontSize = 18, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom };
    readonly TextBlock state = new() { Foreground = Brushes.Gray, FontSize = 14, Margin = new Thickness(0, 6, 0, 0) };
    readonly DispatcherTimer tick = new() { Interval = TimeSpan.FromSeconds(1) };
    DateTime started = DateTime.Now;
    TimeSpan pausedFor;
    DateTime? pausedAt;

    public PresenterWindow(AnimatedShowWindow show, Func<string, int, string?> nextStill)
    {
        this.show = show;
        this.nextStill = nextStill;
        Title = "Manimble Presenter View";
        Background = new SolidColorBrush(Color.FromRgb(0x14, 0x14, 0x16));
        WindowState = WindowState.Maximized;
        live.Child = new Rectangle16x9(new VisualBrush(show.Stage) { Stretch = Stretch.Uniform });

        var grid = new Grid { Margin = new Thickness(20) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        DockPanel.SetDock(counter, Dock.Right);
        top.Children.Add(counter);
        top.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Children = { timer, clock } });
        Grid.SetColumnSpan(top, 3);
        grid.Children.Add(top);

        var left = new DockPanel();
        DockPanel.SetDock(state, Dock.Bottom);
        left.Children.Add(state);
        left.Children.Add(live);
        Grid.SetRow(left, 1);
        grid.Children.Add(left);

        var right = new Grid();
        right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1.4, GridUnitType.Star) });
        right.Children.Add(nextLabel);
        var nextBox = new Border { Background = Brushes.Black, CornerRadius = new CornerRadius(4), Child = next };
        Grid.SetRow(nextBox, 1);
        right.Children.Add(nextBox);
        var notesLabel = new TextBlock { Text = "Notes", Foreground = Brushes.Gray, FontSize = 13, Margin = new Thickness(0, 14, 0, 4) };
        Grid.SetRow(notesLabel, 2);
        right.Children.Add(notesLabel);
        Grid.SetRow(notes, 3);
        right.Children.Add(notes);
        Grid.SetRow(right, 1); Grid.SetColumn(right, 2);
        grid.Children.Add(right);

        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 14, 0, 0) };
        Button B(string text, string tip, Action a)
        {
            var b = new Button { Content = text, ToolTip = tip, Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(0, 0, 8, 0), Focusable = false };
            b.Click += (_, _) => a();
            return b;
        }
        bar.Children.Add(B("◀ Previous", "Left arrow", show.Previous));
        bar.Children.Add(B("Next ▶", "Right arrow, Space", show.Next));
        bar.Children.Add(B("Black screen", "B", show.ToggleBlack));
        bar.Children.Add(B("Reset timer", "R… T", ResetTimer));
        bar.Children.Add(B("Pause timer", "", PauseTimer));
        bar.Children.Add(B("End show", "Esc", () => show.Close()));
        Grid.SetRow(bar, 2); Grid.SetColumnSpan(bar, 3);
        grid.Children.Add(bar);
        Content = grid;

        show.Changed += Refresh;
        show.Exited += () => { tick.Stop(); Close(); };
        tick.Tick += (_, _) => UpdateTime();
        tick.Start();
        KeyDown += (_, e) =>
        {
            var key = e.Key == Key.System ? e.SystemKey : e.Key;
            if (key == Key.T) { ResetTimer(); e.Handled = true; return; }
            if (key == Key.Space) { show.Next(); e.Handled = true; return; }
            if (show.HandleKey(key)) e.Handled = true;
        };
        Closed += (_, _) => { tick.Stop(); if (show.IsLoaded) show.Close(); };
        Loaded += (_, _) => { Refresh(); UpdateTime(); };
    }

    void ResetTimer() { started = DateTime.Now; pausedFor = TimeSpan.Zero; pausedAt = null; UpdateTime(); }

    void PauseTimer()
    {
        if (pausedAt is DateTime p) { pausedFor += DateTime.Now - p; pausedAt = null; }
        else pausedAt = DateTime.Now;
        UpdateTime();
    }

    void UpdateTime()
    {
        var now = DateTime.Now;
        var elapsed = (pausedAt ?? now) - started - pausedFor;
        timer.Text = $"{(int)elapsed.TotalHours:0}:{elapsed.Minutes:00}:{elapsed.Seconds:00}" + (pausedAt != null ? "  (paused)" : "");
        clock.Text = now.ToString("t");
    }

    void Refresh()
    {
        var cur = show.Current;
        if (cur == null) return;
        var slides = show.Slides;
        var total = slides.Count > 0 ? slides[^1].Number + 1 : 0;
        counter.Text = $"Slide {cur.Number + 1} of {total}" + (cur.Count > 1 ? $" · build {cur.Index + 1} of {cur.Count}" : "");
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(cur.Notes)) parts.Add(cur.Notes.Trim());
        if (!string.IsNullOrWhiteSpace(cur.BuildNotes)) parts.Add(cur.BuildNotes!.Trim());
        notes.Text = parts.Count > 0 ? string.Join("\n\n", parts) : "No notes for this slide.";
        notes.Foreground = parts.Count > 0 ? Brushes.White : Brushes.Gray;
        var i = show.PageIndex;
        if (i + 1 < slides.Count)
        {
            var n = slides[i + 1];
            nextLabel.Text = n.Scene == cur.Scene ? $"Next: build {n.Index + 1} of {n.Count}" : $"Next: slide {n.Number + 1}";
            next.Source = Images.Load(nextStill(n.Scene, n.Index));
        }
        else
        {
            nextLabel.Text = "Next: end of the show";
            next.Source = null;
        }
        state.Text = show.IsBlackedOut ? "The audience sees a black screen (B)" : show.IsFinished ? "Build done" : "Playing";
    }
}

/// A 16:9 area filled with a brush: the presenter's mirror of the show keeps the slide's proportions.
sealed class Rectangle16x9 : Decorator
{
    readonly System.Windows.Shapes.Rectangle rect = new();
    public Rectangle16x9(Brush b) { rect.Fill = b; Child = rect; }
    protected override Size MeasureOverride(Size s) => Fit(s);
    protected override Size ArrangeOverride(Size s) { rect.Arrange(new Rect(Fit(s))); return s; }
    static Size Fit(Size s)
    {
        if (double.IsInfinity(s.Width) || double.IsInfinity(s.Height)) return new Size(640, 360);
        var w = Math.Min(s.Width, s.Height * 16 / 9);
        return new Size(w, w * 9 / 16);
    }
}
