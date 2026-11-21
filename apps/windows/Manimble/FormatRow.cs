using System.IO;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Manimble;

/// The toolbar's Theme, Zoom and Dark Mode, and the formatting row under it, laid out as the Mac's FormatBar:
/// font | character styles | highlight, colour, clear | lists and indent | alignment, spacing, columns |
/// grid, snapping, guides … Script, View Feedback, find.
public partial class MainWindow
{
    // ================================================================ syncing the row with the selection

    /// Reflect the selected object (or nothing) in the row, control by control as the Mac does: font, bold, italic,
    /// lists and alignment are for text; size, decorations, highlight and clear also take a formula; colour takes
    /// anything but a picture.
    void UpdateFormatRow()
    {
        var o = scene != null && canvas.Selected.Count == 1 ? scene.Obj(canvas.Selected[0]) : null;
        bool isText = o?.Kind == "text", isTexty = o?.IsText == true, plain = isText && o!.TextOk == true;
        if (isText && !fontsLoaded)
        {
            FontCombo.ItemsSource = Fonts.SystemFontFamilies.Select(f => f.Source).OrderBy(n => n).ToList();
            fontsLoaded = true;
        }
        FontCombo.IsEnabled = isText;
        FontCombo.Text = isText ? o!.Font ?? scene!.Font ?? "" : "";
        SizeBox.IsEnabled = SizeStepper.IsEnabled = BiggerButton.IsEnabled = SmallerButton.IsEnabled = isTexty;
        SizeStepper.Opacity = isTexty ? 1 : 0.4;
        SizeBox.Text = isTexty && o!.FontSize is double fs ? fs.ToString("0.#") : "";
        foreach (var c in new Control[] { UnderlineButton, StrikeButton, HighlightButton, ClearFormatButton }) c.IsEnabled = isTexty;
        foreach (var c in new Control[] { BoldButton, ItalicButton, AlignLeftButton, AlignCenterButton, AlignRightButton, AlignJustifyButton,
                                          SpacingButton, ColumnsButton }) c.IsEnabled = isText;
        foreach (var c in new Control[] { SuperscriptButton, SubscriptButton, BulletsButton, NumbersButton, OutdentButton, IndentButton }) c.IsEnabled = plain;
        TextColorButton.IsEnabled = canvas.Selected.Count > 0 && o?.Kind != "image";
        TextColorBar.Background = new SolidColorBrush(o?.Color is string hex && TryColor(hex) is Color col ? col : Colors.White);

        BoldButton.IsChecked = isText && string.Equals(o!.Weight, "BOLD", StringComparison.OrdinalIgnoreCase);
        ItalicButton.IsChecked = isText && (string.Equals(o!.Slant, "ITALIC", StringComparison.OrdinalIgnoreCase)
                                            || string.Equals(o.Slant, "OBLIQUE", StringComparison.OrdinalIgnoreCase));
        var fmt = isTexty ? o!.Format : null;
        UnderlineButton.IsChecked = fmt?.Underline == true;
        StrikeButton.IsChecked = fmt?.Strike == true;
        HighlightIcon.Foreground = fmt?.Highlight is string h
            ? new SolidColorBrush(h.StartsWith('#') && TryColor(h) is Color hc ? hc : Color.FromRgb(0xFF, 0xD4, 0x00))
            : (Brush)HighlightButton.Foreground;
        BulletsButton.IsChecked = isText && TextTransform.IsBulleted(o!.Value);
        NumbersButton.IsChecked = isText && TextTransform.IsNumbered(o!.Value);
        var align = isText ? fmt?.Align ?? "left" : null;
        AlignLeftButton.IsChecked = align == "left";
        AlignCenterButton.IsChecked = align == "center";
        AlignRightButton.IsChecked = align == "right";
        AlignJustifyButton.IsChecked = false;
        // the Format menu mirrors the row
        foreach (var m in new[] { UnderlineItem, StrikeItem, HighlightMenu, ClearFormatItem, BiggerItem, SmallerItem }) m.IsEnabled = isTexty;
        foreach (var m in new[] { BoldItem, ItalicItem, AlignLeftItem, AlignCenterItem, AlignRightItem, JustifyItem, SpacingMenu, ColumnsMenu }) m.IsEnabled = isText;
        foreach (var m in new[] { SuperscriptItem, SubscriptItem, BulletsItem, NumbersItem, IndentItem, OutdentItem }) m.IsEnabled = plain;
        HyperlinkItem.IsEnabled = o?.Kind is "text" or "tex";
        BoldItem.IsChecked = BoldButton.IsChecked == true;
        ItalicItem.IsChecked = ItalicButton.IsChecked == true;
        UnderlineItem.IsChecked = UnderlineButton.IsChecked == true;
        StrikeItem.IsChecked = StrikeButton.IsChecked == true;
        BulletsItem.IsChecked = BulletsButton.IsChecked == true;
        NumbersItem.IsChecked = NumbersButton.IsChecked == true;
        AlignLeftItem.IsChecked = align == "left";
        AlignCenterItem.IsChecked = align == "center";
        AlignRightItem.IsChecked = align == "right";
        GridButton.IsChecked = canvas.ShowGrid;
        SnapButton.IsChecked = canvas.SnapEnabled;
        GuideVButton.IsEnabled = GuideHButton.IsEnabled = sceneName != null;
    }

    // ================================================================ font size stepper, colour

    void SizeUp_Click(object sender, RoutedEventArgs e) { if (SelectedObj?.FontSize is double fs) CommitFontSize(Math.Floor(fs) + 1); }
    void SizeDown_Click(object sender, RoutedEventArgs e) { if (SelectedObj?.FontSize is double fs) CommitFontSize(Math.Max(4, Math.Ceiling(fs) - 1)); }

    void TextColor_Click(object sender, RoutedEventArgs e) => ColorDropDown(TextColorButton);

    /// The palette under a colour control (the row's "A" or the inspector's swatch).
    void ColorDropDown(Button anchor)
    {
        if (canvas.Selected.Count == 0) return;
        var items = Palette.Select(p => (p.name, (string?)p.hex, (RoutedEventHandler)((_, _) => ApplyColor(p.hex)))).ToList();
        items.Add(("-", null, (_, _) => { }));
        items.Add(("Other (type #RRGGBB)…", null, (_, _) => { ColorBox.Focus(); ColorBox.SelectAll(); }));
        DropDown(anchor, items.ToArray());
    }

    // ================================================================ superscript and subscript

    void Superscript_Click(object sender, RoutedEventArgs e) => ApplyScript(superscript: true);
    void Subscript_Click(object sender, RoutedEventArgs e) => ApplyScript(superscript: false);

    /// Unicode super/subscript (Manim's Text has no per-character rise, so the characters themselves are swapped).
    /// While typing on the slide: the selected characters. With the text object merely selected: its whole text.
    void ApplyScript(bool superscript)
    {
        var kind = superscript ? "superscript" : "subscript";
        if (Single is not int s || SelectedObj is not { Kind: "text", TextOk: true } o)
        {
            Toast($"Select a text object first; {kind} applies to its text", error: true); return;
        }
        if (canvas.Editor is TextBox ed && canvas.EditingOid == s)
        {
            if (ed.SelectionLength == 0) { Toast($"Select the characters to make {kind}", error: true); return; }
            if (TextTransform.Script(ed.SelectedText, superscript) is not string conv) { Toast($"No {kind} form exists for these characters", error: true); return; }
            var at = ed.SelectionStart;
            ed.SelectedText = conv;
            ed.Select(at, conv.Length);
            ed.Focus();
            return;
        }
        if (TextTransform.Script(o.Value, superscript) is not string converted) { Toast($"No {kind} form exists for these characters", error: true); return; }
        CommitText(s, converted);
    }

    void CommitText(int oid, string text) => Submit(() => RunEdit(new JsonObject { ["oid"] = oid, ["op"] = "text", ["value"] = text }));

    // ================================================================ lists and indent

    void Bullets_Click(object sender, RoutedEventArgs e) => TransformText((t, _) => TextTransform.ToggleBullets(t));
    void Numbers_Click(object sender, RoutedEventArgs e) => TransformText((t, _) => TextTransform.ToggleNumbers(t));
    void Indent_Click(object sender, RoutedEventArgs e) => TransformText((t, sel) => TextTransform.Indent(t, sel, +4));
    void Outdent_Click(object sender, RoutedEventArgs e) => TransformText((t, sel) => TextTransform.Indent(t, sel, -4));

    /// A whole-string change to the selected text: in the box while typing on the slide (the selected lines), else
    /// written to the source.
    void TransformText(Func<string, (int first, int last)?, string> f)
    {
        if (Single is not int s || SelectedObj is not { Kind: "text", TextOk: true } o)
        {
            UpdateFormatRow(); Toast("Select a text object first", error: true); return;
        }
        if (canvas.Editor is TextBox ed && canvas.EditingOid == s)
        {
            var lines = ed.SelectionLength > 0 ? TextTransform.LineRange(ed.Text, ed.SelectionStart, ed.SelectionLength) : ((int, int)?)null;
            var edited = f(ed.Text, lines);
            if (edited != ed.Text) { ed.Text = edited; ed.CaretIndex = edited.Length; }
            ed.Focus();
            return;
        }
        var changed = f(o.Value, null);
        if (changed == o.Value) { UpdateFormatRow(); return; }
        CommitText(s, changed);
    }

    // ================================================================ justify, columns

    void Justify_Click(object sender, RoutedEventArgs e)
    {
        UpdateFormatRow();
        Toast("Manim cannot justify text with manual line breaks; use left, centre or right", error: true);
    }

    void Columns_Click(object sender, RoutedEventArgs e)
    {
        if (Single is null || SelectedObj is not { Kind: "text" }) return;
        DropDown(ColumnsButton, ColumnCounts.Select(c => (c.name, (string?)null, (RoutedEventHandler)((_, _) => SetColumns(c.n)))).ToArray());
    }

    void SetColumns(int n)
    {
        if (Single is not int s || SelectedObj is not { Kind: "text" } o) return;
        if (n > 1 && !o.Value.Contains('\n') && (o.Format?.Columns ?? 1) == 1)
        {
            Toast("Columns lay out the lines of a text; add lines with Shift+Enter while typing first", error: true); return;
        }
        Submit(() => RunEdit(new JsonObject { ["oid"] = s, ["op"] = "columns", ["value"] = n }));
    }

    // ================================================================ grid and snapping (the View menu's items mirror these)

    void GridButton_Click(object sender, RoutedEventArgs e) { GridItem.IsChecked = GridButton.IsChecked == true; canvas.ShowGrid = GridItem.IsChecked; }
    void SnapButton_Click(object sender, RoutedEventArgs e)
    {
        SnapItem.IsChecked = SnapButton.IsChecked == true;
        canvas.SnapEnabled = SnapItem.IsChecked;
        Toast(canvas.SnapEnabled ? "Snapping on: hold Alt to drag freely" : "Snapping off");
    }

    // ================================================================ Script and View Feedback

    void ScriptButton_Click(object sender, RoutedEventArgs e)
    {
        if (ScriptShown) HideScript(); else Script_Click(sender, e);   // again puts the edit panel back
        SyncPanelButtons();
    }

    void FeedbackButton_Click(object sender, RoutedEventArgs e)
    {
        if (feedbackPane != null && PanelHost.Child == feedbackPane && PanelHost.Visibility == Visibility.Visible) HideFeedbackPane();
        else Feedback_Click(sender, e);
        SyncPanelButtons();
    }

    /// Lit while its panel is up in the top right; View Feedback counts the notes and is greyed out until there are any.
    void SyncPanelButtons()
    {
        var up = PanelHost.Visibility == Visibility.Visible;
        ScriptButton.IsChecked = up && scriptPane != null && PanelHost.Child == scriptPane;
        FeedbackButton.IsChecked = up && feedbackPane != null && PanelHost.Child == feedbackPane;
        var n = feedback?.All.Count ?? 0;
        FeedbackButtonText.Text = n > 0 ? $"View Feedback ({n})" : "View Feedback";
        FeedbackButton.IsEnabled = n > 0 || FeedbackButton.IsChecked == true;
        ScriptButton.IsEnabled = workspace != null;
    }

    FeedbackStore? countedFeedback;
    /// The feedback count follows the deck's notes (called when a deck's notes are read).
    void WatchFeedbackCount()
    {
        if (countedFeedback != null) countedFeedback.Changed -= OnFeedbackChanged;
        countedFeedback = feedback;
        if (feedback != null) feedback.Changed += OnFeedbackChanged;
        SyncPanelButtons();
    }
    void OnFeedbackChanged() => Dispatcher.BeginInvoke(SyncPanelButtons);

    // ================================================================ the row gives way on a narrow window

    /// The Mac detaches the paragraph group, then the view group, when the bar runs out of room; so does this.
    void FormatRow_SizeChanged(object sender, SizeChangedEventArgs e) => LayoutFormatRow();

    void LayoutFormatRow()
    {
        double Want(FrameworkElement el) { el.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity)); return el.DesiredSize.Width; }
        var panelLabels = new[] { ScriptButton, FeedbackButton }.Select(b => ((Panel)b.Content).Children[1]).ToList();
        var findOptions = new UIElement[] { FindCase, FindWord, FindRegex, FindNotes };
        void Show(IEnumerable<UIElement> els, bool on)
        {
            foreach (var el in els)
            {
                el.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
                for (DependencyObject? p = el; p != null && p != FormatRow; p = VisualTreeHelper.GetParent(p)) (p as UIElement)?.InvalidateMeasure();
            }
        }
        void Narrow(bool on)
        {
            FindBoxHost.Width = on ? 100 : 150;
            FindCount.MinWidth = on ? 0 : 52;
            foreach (var el in new FrameworkElement[] { FindBoxHost, FindCount, FindGroup }) el.InvalidateMeasure();
        }
        // what gives way, in order, when font, find and the panel buttons don't fit together (the window's narrowest)
        var steps = new Action<bool>[]
        {
            on => Show(panelLabels, !on),                                    // Script and View Feedback: icons only
            Narrow,                                                          // a shorter find box
            on => Show(new UIElement[] { BiggerButton, SmallerButton }, !on), // the stepper and Ctrl+Shift+. / , stay
            on => Show(findOptions, !on),                                    // match case and the like keep their setting
        };
        foreach (var s in steps) s(false);
        double Room() => FormatRow.ActualWidth - Want(FindGroup) - Want(PanelButtons) - Want(FontGroup) - 12;
        foreach (var s in steps) { if (Room() >= 0) break; s(true); }
        var room = Room();
        ParaGroup.Visibility = ViewGroup.Visibility = Visibility.Visible;
        double para = Want(ParaGroup), view = Want(ViewGroup);
        ViewGroup.Visibility = room >= para + view ? Visibility.Visible : Visibility.Collapsed;
        ParaGroup.Visibility = room >= para ? Visibility.Visible : Visibility.Collapsed;
        // a narrow window with the paragraph group gone still has room for the view group alone
        if (ParaGroup.Visibility == Visibility.Collapsed && room >= view) ViewGroup.Visibility = Visibility.Visible;
    }

    // ================================================================ toolbar: labels give way on a narrow window

    /// When the toolbar runs out of room the insert buttons drop their labels (icon and tooltip stay, a drop-down
    /// keeps its ▾), then New Slide, Dark Mode, Terminal and Share do too, so nothing is pushed under Zoom.
    void ToolBarRow_SizeChanged(object sender, SizeChangedEventArgs e) => LayoutToolBar();

    void LayoutToolBar()
    {
        var all = ToolButtons.Children.OfType<ButtonBase>().Concat(ToolRight.Children.OfType<ButtonBase>()).ToList();
        var always = new HashSet<ButtonBase> { NewSlideButton, DarkModeButton, TerminalButton, ShareButton };
        double Need()
        {
            // a label changed deep inside a button: everything up to the toolbar must measure again, or Measure
            // hands back the size it had before
            foreach (var b in all)
                if (b.Content is Panel { Children.Count: >= 2 } p)
                    for (DependencyObject? el = p.Children[1]; el != null && el != ToolBarRow; el = VisualTreeHelper.GetParent(el))
                        (el as UIElement)?.InvalidateMeasure();
            ToolButtons.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            ToolRight.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            return ToolButtons.DesiredSize.Width + ToolRight.DesiredSize.Width + 8;
        }
        foreach (var b in all) SetToolLabel(b, compact: false);
        if (Need() <= ToolBarRow.ActualWidth) return;
        foreach (var b in all.Where(b => !always.Contains(b))) SetToolLabel(b, compact: true);
        if (Need() <= ToolBarRow.ActualWidth) return;
        foreach (var b in always) SetToolLabel(b, compact: true);
    }

    static void SetToolLabel(ButtonBase b, bool compact)
    {
        if (b.Content is not Panel { Children.Count: >= 2 } p || p.Children[1] is not TextBlock label) return;
        label.Tag ??= label.Text;
        var full = (string)label.Tag;
        if (!compact) { label.Text = full; label.Visibility = Visibility.Visible; p.Children[0].SetValue(MarginProperty, new Thickness(0, 0, 6, 0)); return; }
        if (full.EndsWith('▾')) label.Text = "▾"; else label.Visibility = Visibility.Collapsed;
        p.Children[0].SetValue(MarginProperty, new Thickness(0, 0, full.EndsWith('▾') ? 3 : 0, 0));
        b.ToolTip ??= full.TrimEnd('▾', ' ');
    }

    // ================================================================ toolbar: Theme

    void ThemeButton_Click(object sender, RoutedEventArgs e)
    {
        if (workspace == null) { Toast("Open a deck first", error: true); return; }
        var m = new ContextMenu { PlacementTarget = ThemeButton, Placement = PlacementMode.Bottom };
        foreach (var t in DeckTheme.All())
        {
            var mi = new MenuItem { Header = t.Name, Icon = ThemeSwatch(t) };
            mi.Click += (_, _) => ApplyTheme(t);
            m.Items.Add(mi);
        }
        m.Items.Add(new Separator());
        var bg = new MenuItem { Header = "Background…" };
        bg.Click += Background_Click;
        m.Items.Add(bg);
        m.IsOpen = true;
    }

    static Border ThemeSwatch(DeckTheme t) => new()
    {
        Width = 26, Height = 16, CornerRadius = new CornerRadius(3), BorderBrush = Brushes.Gray, BorderThickness = new Thickness(0.5),
        Background = new SolidColorBrush(TryColor(t.Background) ?? Colors.Black),
        Child = new TextBlock
        {
            Text = "Aa", FontSize = 9, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center, Foreground = new SolidColorBrush(TryColor(t.Text) ?? Colors.White),
        },
    };

    // ================================================================ toolbar: Zoom

    static readonly (string label, double? zoom)[] ZoomLevels =
    {
        ("Fit", null), ("25%", 0.25), ("50%", 0.5), ("75%", 0.75), ("100%", 1.0), ("150%", 1.5), ("200%", 2.0), ("300%", 3.0),
    };
    bool syncingZoom;

    void SetUpZoomCombo()
    {
        foreach (var (label, _) in ZoomLevels) ZoomCombo.Items.Add(label);
        canvas.ZoomChanged += () => Dispatcher.BeginInvoke(SyncZoomCombo, System.Windows.Threading.DispatcherPriority.Loaded);
        canvas.SizeChanged += (_, _) => { if (canvas.Zoom == null) SyncZoomCombo(); };
        SyncZoomCombo();
    }

    void ZoomCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (syncingZoom || ZoomCombo.SelectedIndex < 0 || ZoomCombo.SelectedIndex >= ZoomLevels.Length) return;
        canvas.Zoom = ZoomLevels[ZoomCombo.SelectedIndex].zoom;
        canvas.Focus();
    }

    /// "Fit (NN%)" while fitting; another zoom (Ctrl+= and so on) shows as an extra entry, as on the Mac.
    void SyncZoomCombo()
    {
        syncingZoom = true;
        try
        {
            while (ZoomCombo.Items.Count > ZoomLevels.Length) ZoomCombo.Items.RemoveAt(ZoomLevels.Length);
            if (canvas.Zoom is double z)
            {
                var label = $"{Math.Round(z * 100)}%";
                var i = Array.FindIndex(ZoomLevels, l => l.label == label);
                if (i < 0) { ZoomCombo.Items.Add(label); i = ZoomCombo.Items.Count - 1; }
                ZoomCombo.Items[0] = "Fit";
                ZoomCombo.SelectedIndex = i;
            }
            else
            {
                ZoomCombo.Items[0] = canvas.HasSlide ? $"Fit ({Math.Round(canvas.CurrentZoom * 100)}%)" : "Fit";
                ZoomCombo.SelectedIndex = 0;
            }
        }
        finally { syncingZoom = false; }
    }

    // ================================================================ toolbar: Dark Mode (view only)

    void DarkModeButton_Click(object sender, RoutedEventArgs e) => SetColorView(Images.View == ColorView.Dark ? ColorView.Normal : ColorView.Dark);
    void DarkModeItem_Click(object sender, RoutedEventArgs e) => SetColorView(Images.View == ColorView.Dark ? ColorView.Normal : ColorView.Dark);
    void InvertColorsItem_Click(object sender, RoutedEventArgs e) => SetColorView(Images.View == ColorView.Invert ? ColorView.Normal : ColorView.Invert);

    /// View > Recolor Images Too: inserted pictures follow dark mode / inverted colours too (off by default).
    void RecolorImagesItem_Click(object sender, RoutedEventArgs e)
    {
        Images.RecolorImages = RecolorImagesItem.IsChecked;
        Settings.Current.RecolorImages = Images.RecolorImages; Settings.Current.Save();
        if (Images.View != ColorView.Normal) SetColorView(Images.View, save: false);
    }

    /// Show the slides in dark mode, with inverted colours, or as they are: every picture is mapped as it is loaded,
    /// so the canvas, the navigator and the slideshow redraw from it. Nothing is written to the deck.
    void SetColorView(ColorView view, bool save = true)
    {
        Images.View = view;
        DarkModeButton.IsChecked = DarkModeItem.IsChecked = view == ColorView.Dark;
        InvertColorsItem.IsChecked = view == ColorView.Invert;
        RecolorImagesItem.IsChecked = Images.RecolorImages;
        if (save) { Settings.Current.ColorView = view.ToString(); Settings.Current.Save(); }
        foreach (var s in slides) s.RefreshAll();
        if (scene?.Stops != null) ShowStop(stopIndex);
    }

    void RestoreColorView()
    {
        Images.RecolorImages = Settings.Current.RecolorImages;
        SetColorView(Enum.TryParse<ColorView>(Settings.Current.ColorView, out var v) ? v : ColorView.Normal, save: false);
    }

    // ================================================================ headless check: MANIMBLE_TEST_FORMAT=<dir>

    /// Opens on a deck (the command line's), selects its first text object, and writes format.log and window
    /// pictures (format-*.png) to the directory: the row with text selected, then in dark mode, then exits.
    async Task FormatTest(string dir)
    {
        Directory.CreateDirectory(dir);
        var log = Path.Combine(dir, "format.log");
        File.WriteAllText(log, "");
        void Log(string s) => File.AppendAllText(log, s + Environment.NewLine);
        void Shot(string name)
        {
            UpdateLayout();
            var dpi = VisualTreeHelper.GetDpi(this);
            var root = (FrameworkElement)Content;
            var rtb = new RenderTargetBitmap((int)(root.ActualWidth * dpi.DpiScaleX), (int)(root.ActualHeight * dpi.DpiScaleY),
                                             dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
            var dv = new DrawingVisual();
            using (var dc = dv.RenderOpen())
            {
                dc.DrawRectangle(SystemColors.WindowBrush, null, new Rect(0, 0, root.ActualWidth, root.ActualHeight));
                dc.DrawRectangle(new VisualBrush(root), null, new Rect(0, 0, root.ActualWidth, root.ActualHeight));
            }
            rtb.Render(dv);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(rtb));
            using var f = File.Create(Path.Combine(dir, name));
            enc.Save(f);
        }
        try
        {
            for (int i = 0; i < 600 && (scene == null || !canvas.HasSlide); i++) await Task.Delay(100);
            await Task.Delay(500);
            Log($"deck: {(workspace != null)} scene={sceneName} zoom='{ZoomCombo.Text}' find={FindGroup.IsEnabled} feedback='{FeedbackButtonText.Text}'");
            Shot("format-none.png");
            Log($"nothing selected: font={FontCombo.IsEnabled} bold={BoldButton.IsEnabled} color={TextColorButton.IsEnabled} para={ParaGroup.Visibility} view={ViewGroup.Visibility} " +
                $"width={ActualWidth} toolbar fits={ToolButtons.ActualWidth + ToolRight.ActualWidth <= ToolBarRow.ActualWidth}");
            WindowState = WindowState.Normal; Width = 1900; await Task.Delay(500);
            Log($"wide (1900): para={ParaGroup.Visibility} view={ViewGroup.Visibility}");
            Shot("format-wide.png");
            Width = 1440; await Task.Delay(500);
            var text = scene?.Objects?.FirstOrDefault(kv => kv.Value.Kind == "text");
            if (text is { Key: string k } && int.TryParse(k, out var oid))
            {
                canvas.Select(new[] { oid });
                await Task.Delay(300);
                Log($"text selected ({Short(text.Value.Value.Value)}): font='{FontCombo.Text}' size='{SizeBox.Text}' bold={BoldButton.IsEnabled}/{BoldButton.IsChecked} " +
                    $"super={SuperscriptButton.IsEnabled} bullets={BulletsButton.IsEnabled} color={TextColorButton.IsEnabled} align={AlignLeftButton.IsChecked}/{AlignCenterButton.IsChecked}");
                Shot("format-text.png");
            }
            else Log("no text object on the first slide");
            canvas.Zoom = 1.5;
            await Task.Delay(300);
            Log($"zoom 150%: combo='{ZoomCombo.Text}'");
            canvas.Zoom = null;
            await Task.Delay(300);
            Log($"zoom fit: combo='{ZoomCombo.Text}'");
            var before = Images.View;
            SetColorView(ColorView.Dark, save: false);
            await Task.Delay(500);
            Log($"dark: button={DarkModeButton.IsChecked} menu={DarkModeItem.IsChecked} view={Images.View}");
            Shot("format-dark.png");
            SetColorView(before, save: false);
            Width = 900;
            await Task.Delay(500);
            Log($"narrow (900): para={ParaGroup.Visibility} view={ViewGroup.Visibility} toolbar fits={ToolButtons.ActualWidth + ToolRight.ActualWidth <= ToolBarRow.ActualWidth}");
            Log($"widths: row={FormatRow.ActualWidth} font={FontGroup.ActualWidth} para={ParaGroup.DesiredSize.Width} view={ViewGroup.DesiredSize.Width} panel={PanelButtons.ActualWidth} find={FindGroup.ActualWidth}");
            Shot("format-narrow.png");
            Width = 1440;
            ToggleExpandAllBuilds();
            for (int i = 0; i < 50 && allBuildPages.Count == 0; i++) await Task.Delay(100);
            if (slides.LastOrDefault(s => s.Builds.Count > 0) is { } listed) SlideList.ScrollIntoView(listed);
            await Task.Delay(500);
            Log($"expand all:button='{ExpandAllText.Text}' menu='{ExpandAllItem.Header}' slides with builds listed={slides.Count(s => s.Builds.Count > 0)} " +
                $"of {slides.Count(s => allBuildPages.TryGetValue(s.Name, out var p) && p.Count > 1 || s.Name == sceneName && scene?.Stops?.Count > 1)}");
            Shot("format-expanded.png");
            ToggleExpandAllBuilds();
            await Task.Delay(300);
            Log($"collapse all: button='{ExpandAllText.Text}' slides with builds listed={slides.Count(s => s.Builds.Count > 0)}");
            Log("done");
        }
        catch (Exception ex) { Log("error: " + ex); }
        Application.Current.Shutdown();
    }
}

/// Bullets, numbering, indentation and Unicode super/subscripts for plain `Text` strings (the Mac's TextTransform).
static class TextTransform
{
    static readonly Regex Marker = new(@"^(\s*)(?:[•\-–▪◦]|\d+[.)])\s+");

    static string[] Lines(string s) => s.Split('\n');

    /// (indent, rest) with any list marker removed.
    static (string indent, string rest) Strip(string line)
    {
        var m = Marker.Match(line);
        if (m.Success) return (m.Groups[1].Value, line[m.Length..]);
        var indent = new string(line.TakeWhile(c => c is ' ' or '\t').ToArray());
        return (indent, line[indent.Length..]);
    }

    static bool HasMarker(string line) => Marker.IsMatch(line);
    static IEnumerable<string> NonEmpty(string s) => Lines(s).Where(l => l.Trim().Length > 0);

    public static bool IsBulleted(string s)
    {
        var ls = NonEmpty(s).ToList();
        return ls.Count > 0 && ls.All(l => HasMarker(l) && !char.IsDigit(l.Trim()[0]));
    }

    public static bool IsNumbered(string s)
    {
        var ls = NonEmpty(s).ToList();
        return ls.Count > 0 && ls.All(l => HasMarker(l) && char.IsDigit(l.Trim()[0]));
    }

    public static string ToggleBullets(string s)
    {
        var on = IsBulleted(s);
        return string.Join("\n", Lines(s).Select(l =>
        {
            if (l.Trim().Length == 0) return l;
            var (ind, rest) = Strip(l);
            return on ? ind + rest : ind + "• " + rest;
        }));
    }

    public static string ToggleNumbers(string s)
    {
        var on = IsNumbered(s);
        int n = 0;
        return string.Join("\n", Lines(s).Select(l =>
        {
            if (l.Trim().Length == 0) return l;
            var (ind, rest) = Strip(l);
            n++;
            return on ? ind + rest : $"{ind}{n}. {rest}";
        }));
    }

    /// Indent (+) or outdent (−) the given lines (all when null) by four spaces.
    public static string Indent(string s, (int first, int last)? which, int delta) =>
        string.Join("\n", Lines(s).Select((l, i) =>
        {
            if (which is var (a, b) && (i < a || i > b)) return l;
            if (delta > 0) return "    " + l;
            int k = 0;
            while (k < 4 && k < l.Length && l[k] == ' ') k++;
            return l[k..];
        }));

    /// Line indexes covered by a selection of the string.
    public static (int first, int last) LineRange(string s, int start, int length)
    {
        start = Math.Clamp(start, 0, s.Length);
        var a = s[..start].Count(c => c == '\n');
        var end = Math.Clamp(start + Math.Max(0, length - 1), 0, s.Length);
        var b = s[..end].Count(c => c == '\n');
        return (a, Math.Max(a, b));
    }

    static readonly Dictionary<char, char> Sup = Zip("0123456789+-=()abcdefghijklmnoprstuvwxyzABDEGHIJKLMNOPRTUVW",
                                                     "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂ");
    static readonly Dictionary<char, char> Sub = Zip("0123456789+-=()aehijklmnoprstuvx", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ");

    static Dictionary<char, char> Zip(string from, string to)
    {
        var d = new Dictionary<char, char>();
        for (int i = 0; i < Math.Min(from.Length, to.Length); i++) d[from[i]] = to[i];
        return d;
    }

    /// Convert to (or, when everything already is, back from) super/subscript. Null when nothing can be converted.
    public static string? Script(string s, bool superscript)
    {
        var map = superscript ? Sup : Sub;
        var back = map.ToDictionary(kv => kv.Value, kv => kv.Key);
        var convertible = s.Where(c => map.ContainsKey(c) || back.ContainsKey(c)).ToList();
        if (convertible.Count == 0) return null;
        var allScripted = convertible.All(back.ContainsKey);
        return new string(s.Select(c => allScripted ? back.GetValueOrDefault(c, c) : map.GetValueOrDefault(c, c)).ToArray());
    }
}
