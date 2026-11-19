using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Manimble;

/// Small modal dialogs built in code (the Mac app's sheets and alerts).
public static class Dialogs
{
    static Window Make(Window owner, string title, double width)
    {
        return new Window
        {
            Title = title, Owner = owner, Width = width, SizeToContent = SizeToContent.Height,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
        };
    }

    static StackPanel Buttons(Window w, string ok, Action onOk)
    {
        var okB = new Button { Content = ok, IsDefault = true, MinWidth = 90, Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90, Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        okB.Click += (_, _) => onOk();
        return new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0), Children = { cancel, okB } };
    }

    /// Asks for a formula's LaTeX, showing it typeset by the engine as it is typed. Null when cancelled.
    public static string? Formula(Window owner, Engine engine, string initial = "x^2 + y^2 = z^2")
    {
        var w = Make(owner, "Insert Formula", 560);
        string? result = null;
        var box = new TextBox
        {
            Text = initial, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 14, AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap, MinHeight = 70, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        var preview = new Image { Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly, MaxHeight = 140, Margin = new Thickness(10) };
        var error = new TextBlock { Foreground = (Brush)Application.Current.Resources["ErrorBrush"], TextWrapping = TextWrapping.Wrap, FontSize = 12 };
        var previewHost = new Border { Background = Brushes.Black, MinHeight = 90, Margin = new Thickness(0, 10, 0, 0), CornerRadius = new CornerRadius(4), Child = preview };
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(450) };
        int seq = 0;
        timer.Tick += async (_, _) =>
        {
            timer.Stop();
            var mine = ++seq;
            var tex = box.Text;
            try
            {
                var r = await engine.Call<EditResult>("sprite", new JsonObject { ["kind"] = "tex", ["value"] = tex, ["font_size"] = 40.0, ["color"] = "#FFFFFF" });
                if (mine != seq) return;
                error.Text = r?.Error ?? "";
                preview.Source = r?.Path != null ? Images.Load(r.Path) : null;
            }
            catch (Exception e) { if (mine == seq) { error.Text = LastLine(e.Message); preview.Source = null; } }
        };
        box.TextChanged += (_, _) => { timer.Stop(); timer.Start(); };
        box.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) { result = box.Text; w.DialogResult = true; e.Handled = true; }
        };
        w.Content = new StackPanel
        {
            Margin = new Thickness(18),
            Children =
            {
                new TextBlock { Text = "LaTeX (math mode). Enter inserts, Shift+Enter starts a new line.", Margin = new Thickness(0, 0, 0, 8), Opacity = 0.8 },
                box, previewHost, error,
                Buttons(w, "Insert", () => { result = box.Text; w.DialogResult = true; }),
            },
        };
        w.Loaded += (_, _) => { box.Focus(); box.SelectAll(); timer.Start(); };
        return w.ShowDialog() == true && result?.Trim().Length > 0 ? result : null;
    }

    static string LastLine(string s) => s.Split('\n').Where(l => l.Trim().Length > 0).LastOrDefault()?.Trim() ?? s;

    /// Rows and columns of a new table. Null when cancelled.
    public static (int rows, int cols)? Table(Window owner, string style)
    {
        var w = Make(owner, style == "math" ? "Insert Math Table" : "Insert Word Table", 340);
        var rows = new TextBox { Text = "3", Width = 60, Margin = new Thickness(8, 0, 16, 0) };
        var cols = new TextBox { Text = "3", Width = 60, Margin = new Thickness(8, 0, 0, 0) };
        (int, int)? result = null;
        w.Content = new StackPanel
        {
            Margin = new Thickness(18),
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal,
                    Children = { new TextBlock { Text = "Rows", VerticalAlignment = VerticalAlignment.Center }, rows,
                                 new TextBlock { Text = "Columns", VerticalAlignment = VerticalAlignment.Center }, cols },
                },
                Buttons(w, "Insert", () =>
                {
                    if (int.TryParse(rows.Text, out var r) && int.TryParse(cols.Text, out var c) && r > 0 && c > 0 && r <= 30 && c <= 20)
                    { result = (r, c); w.DialogResult = true; }
                    else MessageBox.Show(w, "Rows 1–30 and columns 1–20", "Insert Table");
                }),
            },
        };
        w.Loaded += (_, _) => { rows.Focus(); rows.SelectAll(); };
        return w.ShowDialog() == true ? result : null;
    }
}
