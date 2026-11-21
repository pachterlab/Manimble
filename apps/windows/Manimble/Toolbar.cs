using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace Manimble;

/// The toolbar buttons the Mac has that live nowhere else on Windows: Expand / Collapse All (the builds nested under
/// every slide in the navigator), the Shape menu with the draw tools, and Share (the Windows share sheet).
public partial class MainWindow
{
    // ================================================================ Expand All: builds under every slide

    /// Expand All: every slide lists its builds in the navigator (until Collapse All).
    bool buildsExpandedAll;
    /// Each slide's build pictures from `deck_pages`, for the slides other than the one on screen.
    Dictionary<string, List<string>> allBuildPages = new();
    /// The slides' thumbnails when `allBuildPages` was fetched: a change means some slide rendered again.
    string allBuildPagesKey = "";

    void ExpandAll_Click(object sender, RoutedEventArgs e) => ToggleExpandAllBuilds();

    void ToggleExpandAllBuilds()
    {
        if (workspace == null) return;
        buildsExpandedAll = !buildsExpandedAll;
        UpdateExpandAllButton();
        if (buildsExpandedAll) _ = FetchAllBuildPages();
        else { allBuildPages = new(); allBuildPagesKey = ""; }
        RefreshNavigatorBuilds();
        if (SlideList.SelectedItem != null) SlideList.ScrollIntoView(SlideList.SelectedItem);
    }

    /// The button and the menu item say what a click does: expand every slide's builds, or collapse them again.
    void UpdateExpandAllButton()
    {
        ExpandAllText.Text = buildsExpandedAll ? "Collapse All" : "Expand All";
        ExpandAllText.Tag = null;                         // the label the narrow-window layout restores
        ExpandAllGlyph.Text = buildsExpandedAll ? "" : "";
        ExpandAllButton.ToolTip = buildsExpandedAll ? "Fold away the builds listed under every slide" : "List the builds under every slide in the navigator";
        ExpandAllItem.Header = buildsExpandedAll ? "Collapse _All Builds" : "Expand _All Builds";
        LayoutToolBar();
    }

    string ThumbsKey() => state == null ? "" : string.Join("|", state.Scenes.Select(s => s.Name + "=" + s.Thumb));

    /// Fetches the build pictures of every slide (renders nothing: slides still rendering come in later, when their
    /// thumbnails change) and lists them.
    async Task FetchAllBuildPages()
    {
        if (!buildsExpandedAll || !engine.IsRunning) return;
        var key = ThumbsKey();
        DeckPages? d;
        try { d = await engine.Call<DeckPages>("deck_pages", new JsonObject { ["ahead"] = 0 }); }
        catch { return; }
        if (!buildsExpandedAll || d == null) return;
        allBuildPages = d.Slides.Where(s => s.Pages.Count > 0).GroupBy(s => s.Scene).ToDictionary(g => g.Key, g => g.First().Pages);
        allBuildPagesKey = key;
        RefreshNavigatorBuilds();
    }

    /// After a state reload: the deck rendered something new, so the nested builds are fetched again.
    void ExpandedBuildsAfterReload()
    {
        if (buildsExpandedAll && ThumbsKey() != allBuildPagesKey) _ = FetchAllBuildPages();
        else RefreshNavigatorBuilds();
    }

    /// Lists (or folds away) the builds under each slide, and marks the build on screen.
    void RefreshNavigatorBuilds()
    {
        foreach (var s in slides)
        {
            IReadOnlyList<string> paths = Array.Empty<string>();
            if (buildsExpandedAll)
            {
                if (s.Name == sceneName && scene?.Name == sceneName && scene?.Stops is { Count: > 1 } stops) paths = stops.Select(t => t.Png).ToList();
                else if (allBuildPages.TryGetValue(s.Name, out var p) && p.Count > 1) paths = p;
            }
            s.SetBuilds(paths, s.Name == sceneName ? stopIndex : -1);
        }
    }

    /// A click on a nested build shows it, opening its slide first when it is another one.
    async void BuildThumb_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if ((sender as FrameworkElement)?.Tag is not BuildThumb b) return;
        e.Handled = true;                                  // not a click on the slide row: no reselect, no drag
        if (b.Scene != sceneName)
        {
            await SelectScene(b.Scene);
            if (sceneName != b.Scene) return;
        }
        ShowStop(b.Index);
        buildFocused = true;                               // Ctrl+C now copies this build, not the slide
        if (SlideList.ItemContainerGenerator.ContainerFromItem(SlideList.SelectedItem) is ListBoxItem li) li.Focus(); else SlideList.Focus();
    }

    // ================================================================ Shape: shapes, draw tools and the pen

    void ShapeButton_Click(object sender, RoutedEventArgs e)
    {
        if (canvas.DrawTool != null) { canvas.DrawTool = null; return; }        // a second click puts the tool down
        var m = new ContextMenu { PlacementTarget = ShapeButton, Placement = PlacementMode.Bottom };
        void Add(ItemsControl into, string header, string tag, RoutedEventHandler h, string? tip = null)
        {
            var mi = new MenuItem { Header = header, Tag = tag, ToolTip = tip };
            mi.Click += h;
            into.Items.Add(mi);
        }
        foreach (var (title, kind) in new[] { ("Rectangle", "rectangle"), ("Rounded Rectangle", "rounded"), ("Circle", "circle"), ("Ellipse", "ellipse"),
                                              ("Triangle", "triangle"), ("Line", "line"), ("Arrow", "arrow"), ("Double Arrow", "darrow") })
            Add(m, title, kind, InsertShape_Click);
        m.Items.Add(new Separator());
        foreach (var (title, kind) in new[] { ("Draw Line", "line"), ("Draw Arrow", "arrow"), ("Draw Double Arrow", "darrow"),
                                              ("Draw Rectangle", "rectangle"), ("Draw Ellipse", "ellipse") })
            Add(m, title, kind, DrawTool_Click, "Then drag on the slide (Shift snaps the angle or keeps it square)");
        m.Items.Add(new Separator());
        var pen = new MenuItem { Header = "Pen (freehand)", Tag = "pen", InputGestureText = "Ctrl+Shift+P",
                                 ToolTip = "Draw freehand on the slide; each stroke becomes a smooth curve in the source. Esc ends the pen." };
        pen.Click += DrawTool_Click;
        m.Items.Add(pen);
        var colors = new MenuItem { Header = "Pen Color" };
        foreach (var (name, hex) in PenSwatches)
        {
            var mi = new MenuItem
            {
                Header = name, IsCheckable = true, IsChecked = hex == penColor,
                Icon = new System.Windows.Shapes.Ellipse { Width = 12, Height = 12, Fill = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)) },
            };
            mi.Click += (_, _) => SetPenColor(hex);
            colors.Items.Add(mi);
        }
        m.Items.Add(colors);
        m.IsOpen = true;
    }

    void UpdateShapeButtonText() => ShapeButtonText.Text = canvas.DrawTool switch
    {
        null => "Shape ▾", "pen" => "Pen (Esc ends)", "darrow" => "Drawing: double arrow", var t => "Drawing: " + t,
    };

    // ================================================================ Share

    void ShareButton_Click(object sender, RoutedEventArgs e)
    {
        var m = new ContextMenu { PlacementTarget = ShareButton, Placement = PlacementMode.Bottom };
        void Add(string header, RoutedEventHandler h)
        {
            var mi = new MenuItem { Header = header, IsEnabled = workspace != null };
            mi.Click += h;
            m.Items.Add(mi);
        }
        Add("Share PDF (one page per slide)…", async (_, _) => await SharePdf(builds: false));
        Add("Share PDF (every build)…", async (_, _) => await SharePdf(builds: true));
        m.Items.Add(new Separator());
        Add("Export PowerPoint (.pptx)…", ExportPowerPoint_Click);
        Add("Export Beamer (.tex)…", ExportBeamer_Click);
        Add("Export Movie (.mp4)…", ExportMovie_Click);
        m.Items.Add(new Separator());
        Add("Save PDF…", ExportPdf_Click);
        m.IsOpen = true;
    }

    /// Writes the deck to a PDF in Manimble's export folder and offers it to the Windows share sheet.
    async Task SharePdf(bool builds)
    {
        if (workspace == null || engine.Python == null) return;
        var dir = Path.Combine(Paths.Base, "export");
        string path;
        try { Directory.CreateDirectory(dir); path = Path.Combine(dir, DeckBaseName + ".pdf"); }
        catch (Exception ex) { Toast("Could not make the export folder: " + ex.Message, error: true); return; }
        if (!await WritePdf(path, builds)) return;
        try { ShowShareSheet(path); }
        catch (Exception ex)
        {
            Log.Note("share sheet: " + ex.Message);
            Toast("Sharing is not available here; the PDF is in Explorer");
            Tools.Reveal(path);
        }
    }

    string? sharePath;
    bool shareHooked;

    [ComImport, Guid("3A3DCD6C-3EAB-43DC-BCDE-45671CE800C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDataTransferManagerInterop
    {
        IntPtr GetForWindow([In] IntPtr appWindow, [In] ref Guid riid);
        void ShowShareUIForWindow(IntPtr appWindow);
    }

    static readonly Guid DataTransferManagerIid = new(0xa5caee9b, 0x8708, 0x49d1, 0x8d, 0x36, 0x67, 0xd2, 0x5a, 0x8d, 0xa0, 0x0c);

    /// The Windows share sheet (as the Mac's sharing picker) for the file at `path`.
    void ShowShareSheet(string path)
    {
        sharePath = path;
        var hwnd = new WindowInteropHelper(this).Handle;
        var interop = Windows.ApplicationModel.DataTransfer.DataTransferManager.As<IDataTransferManagerInterop>();
        if (!shareHooked)
        {
            var iid = DataTransferManagerIid;
            var manager = WinRT.MarshalInterface<Windows.ApplicationModel.DataTransfer.DataTransferManager>.FromAbi(interop.GetForWindow(hwnd, ref iid));
            manager.DataRequested += async (_, args) =>
            {
                var file = sharePath;
                if (file == null) return;
                var deferral = args.Request.GetDeferral();
                try
                {
                    args.Request.Data.Properties.Title = Path.GetFileName(file);
                    args.Request.Data.Properties.Description = "A Manimble presentation";
                    var item = await Windows.Storage.StorageFile.GetFileFromPathAsync(file);
                    args.Request.Data.SetStorageItems(new[] { item });
                }
                catch (Exception ex) { args.Request.FailWithDisplayText("Could not share the PDF: " + ex.Message); }
                finally { deferral.Complete(); }
            };
            shareHooked = true;
        }
        interop.ShowShareUIForWindow(hwnd);
    }
}
