using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ICSharpCode.AvalonEdit;
using ICSharpCode.AvalonEdit.Highlighting;
using Microsoft.Win32;

namespace Manimble;

/// What a Python plot runs: its own code, or a .py file it links to (relative to the deck folder, or absolute).
public sealed class PlotSpec
{
    public string? Code { get; set; }
    public string? File { get; set; }

    public bool SameAs(PlotSpec? o) => o != null && (o.Code ?? "") == (Code ?? "") && (o.File ?? "") == (File ?? "");
    public bool IsEmpty => string.IsNullOrWhiteSpace(Code) && string.IsNullOrWhiteSpace(File);
}

/// Python plots (the Mac's PythonPlot.swift): a picture on a slide drawn by running some Python. The picture is an
/// ordinary ImageMobject of `<stem>@<hash>.png` in the deck folder, and `<stem>.plot.json` beside it says what to run,
/// so the plot can be run again later; each new output gets its own file, so running it again is an edit like any
/// other (Ctrl+Z undoes it). The deck format is the Mac's, so a deck's plots work in both apps.
public static class PythonPlot
{
    public const string Template = """
        import numpy as np
        import matplotlib.pyplot as plt

        x = np.linspace(0, 2 * np.pi, 200)
        fig, ax = plt.subplots(figsize=(6, 4))
        ax.plot(x, np.sin(x), label="sin x")
        ax.plot(x, np.cos(x), label="cos x")
        ax.legend()
        """;

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, WriteIndented = true,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    /// The plot a picture belongs to: `plot1@1a2b3c4d.png` next to `plot1.plot.json`.
    public static (string dir, string stem)? Of(string? imagePath)
    {
        if (string.IsNullOrEmpty(imagePath) || !imagePath.EndsWith(".png", StringComparison.OrdinalIgnoreCase)) return null;
        var name = Path.GetFileNameWithoutExtension(imagePath);
        var at = name.LastIndexOf('@');
        if (at <= 0) return null;
        var stem = name[..at];
        var dir = Path.GetDirectoryName(imagePath) ?? "";
        return File.Exists(SpecPath(dir, stem)) ? (dir, stem) : null;
    }

    public static string SpecPath(string dir, string stem) => Path.Combine(dir, stem + ".plot.json");

    public static PlotSpec? Load(string dir, string stem)
    {
        try { return JsonSerializer.Deserialize<PlotSpec>(File.ReadAllText(SpecPath(dir, stem)), Json); } catch { return null; }
    }

    public static void Save(PlotSpec spec, string dir, string stem) =>
        File.WriteAllText(SpecPath(dir, stem), JsonSerializer.Serialize(spec, Json));

    public static string FreeStem(string dir)
    {
        int n = 1;
        while (File.Exists(SpecPath(dir, $"plot{n}"))) n++;
        return $"plot{n}";
    }

    // ---------------------------------------------------------------- the Python that runs plots

    static string? found;

    /// The interpreter chosen in the plot editor, else the first that can import matplotlib (the engine's own, which
    /// has it, then others on this PC), else the engine's.
    public static string Python(string? enginePython)
    {
        if (Settings.Current.PlotPython is { } chosen && File.Exists(chosen)) return chosen;
        if (found != null) return found;
        var c = new List<string>();
        if (Environment.GetEnvironmentVariable("MANIMBLE_PYTHON") is { Length: > 0 } e) c.Add(e);
        if (enginePython != null) c.Add(enginePython);
        if (Settings.Current.Python != null) c.Add(Settings.Current.Python);
        c.Add(Paths.InstalledPython);
        foreach (var p in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            if (p.Length > 0 && !p.Contains("WindowsApps", StringComparison.OrdinalIgnoreCase)) c.Add(Path.Combine(p.Trim('"'), "python.exe"));
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        foreach (var d in new[] { "miniforge3", "miniconda3", "anaconda3", "mambaforge" }) c.Add(Path.Combine(home, d, "python.exe"));
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var cand in c)
        {
            if (!File.Exists(cand) || !seen.Add(cand)) continue;
            try
            {
                var psi = new ProcessStartInfo(cand) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
                psi.ArgumentList.Add("-c"); psi.ArgumentList.Add("import matplotlib.pyplot");
                using var pr = Process.Start(psi);
                if (pr == null) continue;
                pr.StandardOutput.ReadToEnd(); pr.StandardError.ReadToEnd();
                if (!pr.WaitForExit(60000)) { try { pr.Kill(); } catch { } continue; }
                if (pr.ExitCode == 0) return found = cand;
            }
            catch { }
        }
        return found = enginePython ?? Paths.InstalledPython;
    }

    public static void ForgetFound() => found = null;

    // ---------------------------------------------------------------- running

    /// Runs the script, then saves the last matplotlib figure, unless the code saved a picture to MANIMBLE_PLOT_OUT
    /// itself (plotly, seaborn's own savefig, PIL…).
    const string Runner = """
        import os, runpy, sys
        script, out = sys.argv[1], sys.argv[2]
        sys.argv = [script]
        sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
        try:
            runpy.run_path(script, run_name="__main__")
        except Exception as e:                  # the traceback from the plot's own code on, not this runner's
            import traceback
            tb = e.__traceback__
            while tb is not None and tb.tb_frame.f_code.co_filename != script:
                tb = tb.tb_next
            traceback.print_exception(type(e), e, tb or e.__traceback__)
            sys.exit(1)
        plt = sys.modules.get("matplotlib.pyplot")
        if not os.path.exists(out) and plt is not None and plt.get_fignums():
            plt.gcf().savefig(out, dpi=200, bbox_inches="tight")
        if not os.path.exists(out):
            sys.exit("The code ran but drew nothing: plot with matplotlib, or save a PNG to os.environ['MANIMBLE_PLOT_OUT'].")
        """;

    public sealed class RunError : Exception
    {
        public bool NoSeaborn { get; init; }
        public string Python { get; init; } = "";
        public RunError(string m) : base(m) { }
    }

    /// Runs a plot and returns the PNG it drew. Its own code runs in the deck folder, a linked file in its own folder.
    public static async Task<byte[]> Run(PlotSpec spec, string deck, string python)
    {
        var tmp = Path.Combine(Path.GetTempPath(), "manimble-plot-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tmp);
        try
        {
            string script, cwd;
            if (!string.IsNullOrEmpty(spec.File))
            {
                script = Path.IsPathRooted(spec.File) ? spec.File : Path.GetFullPath(Path.Combine(deck, spec.File.Replace('/', Path.DirectorySeparatorChar)));
                if (!File.Exists(script)) throw new RunError("Can't find " + script);
                cwd = Path.GetDirectoryName(script)!;
            }
            else
            {
                script = Path.Combine(tmp, "plot.py");
                await File.WriteAllTextAsync(script, spec.Code ?? "", new UTF8Encoding(false));
                cwd = deck;
            }
            var run = Path.Combine(tmp, "run.py");
            var outPng = Path.Combine(tmp, "out.png");
            await File.WriteAllTextAsync(run, Runner, new UTF8Encoding(false));
            var psi = new ProcessStartInfo(python)
            {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = cwd,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
            };
            psi.ArgumentList.Add(run); psi.ArgumentList.Add(script); psi.ArgumentList.Add(outPng);
            psi.Environment["MPLBACKEND"] = "Agg";
            psi.Environment["MANIMBLE_PLOT_OUT"] = outPng;
            psi.Environment["PYTHONUNBUFFERED"] = "1";
            psi.Environment["PYTHONIOENCODING"] = "utf-8";
            psi.Environment.Remove("PYTHONPATH"); psi.Environment.Remove("PYTHONHOME");
            Process p;
            try { p = Process.Start(psi) ?? throw new RunError("Could not start " + python); }
            catch (System.ComponentModel.Win32Exception e) { throw new RunError($"Could not start {python}: {e.Message}"); }
            using (p)
            {
                var so = p.StandardOutput.ReadToEndAsync();
                var se = p.StandardError.ReadToEndAsync();
                bool timedOut = false;
                using (var cts = new CancellationTokenSource(TimeSpan.FromMinutes(5)))
                {
                    try { await p.WaitForExitAsync(cts.Token); }
                    catch (OperationCanceledException) { timedOut = true; try { p.Kill(true); } catch { } await p.WaitForExitAsync(); }
                }
                var log = ((await so) + "\n" + (await se)).Trim();
                if (!timedOut && p.ExitCode == 0 && File.Exists(outPng)) return await File.ReadAllBytesAsync(outPng);
                var msg = string.Join("\n", log.Replace("\r\n", "\n").Split('\n').TakeLast(14));
                if (timedOut) msg = "The code ran for 5 minutes and was stopped.\n" + msg;
                if (log.Contains("No module named 'seaborn'")) throw new RunError(msg) { NoSeaborn = true, Python = python };
                if (log.Contains("No module named"))
                    msg += $"\n\nThis Python ({python}) is missing a package: install it there, or choose another Python below.";
                throw new RunError(msg.Length == 0 ? $"The code failed (exit {p.ExitCode})." : msg) { Python = python };
            }
        }
        finally { try { Directory.Delete(tmp, true); } catch { } }
    }

    /// Installs seaborn into the Python that runs plots (pip, else uv for an environment made without pip); returns
    /// the installer's output when it failed.
    public static async Task<string?> InstallSeaborn(string python)
    {
        async Task<(int code, string log)> Exec(string exe, params string[] args)
        {
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var a in args) psi.ArgumentList.Add(a);
            psi.Environment.Remove("PYTHONPATH"); psi.Environment.Remove("PYTHONHOME");
            try
            {
                using var p = Process.Start(psi)!;
                var so = p.StandardOutput.ReadToEndAsync(); var se = p.StandardError.ReadToEndAsync();
                await p.WaitForExitAsync();
                return (p.ExitCode, ((await so) + "\n" + (await se)).Trim());
            }
            catch (Exception e) { return (-1, e.Message); }
        }
        var (code, log) = await Exec(python, "-m", "pip", "install", "--disable-pip-version-check", "seaborn");
        if (code == 0) return null;
        if (log.Contains("No module named pip"))
        {
            (code, log) = await Exec("uv", "pip", "install", "--python", python, "seaborn");
            if (code == 0) return null;
        }
        return string.Join("\n", log.Replace("\r\n", "\n").Split('\n').TakeLast(14));
    }

    /// Writes a plot's output into the deck folder as `<stem>@<hash>.png` (once per distinct picture); returns its name.
    public static string Store(byte[] png, string stem, string dir)
    {
        var h = Convert.ToHexString(SHA256.HashData(png).AsSpan(0, 4)).ToLowerInvariant();
        var name = $"{stem}@{h}.png";
        var path = Path.Combine(dir, name);
        if (!File.Exists(path)) File.WriteAllBytes(path, png);
        return name;
    }
}

/// The plot editor: the plot's code, or a linked .py file, the Python that runs it, and the last error.
public sealed class PlotEditor : Window
{
    readonly RadioButton codeMode = new() { Content = "Code", GroupName = "mode", Margin = new Thickness(0, 0, 12, 0) };
    readonly RadioButton fileMode = new() { Content = "File", GroupName = "mode" };
    readonly TextEditor code = new()
    {
        FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12.5, ShowLineNumbers = true,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        BorderThickness = new Thickness(1), BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0x80, 0x80, 0x80)), Padding = new Thickness(4),
    };
    readonly TextBox file = new() { Margin = new Thickness(0, 0, 6, 0) };
    readonly DockPanel filePanel = new() { Margin = new Thickness(0, 4, 0, 0) };
    readonly TextBlock pythonLabel = new() { FontSize = 11.5, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBox error = new()
    {
        IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 170, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11.5, Margin = new Thickness(0, 6, 0, 0),
    };
    readonly string deck;
    readonly string? enginePython;

    /// What to run, set when Render was pressed (null: cancelled).
    public PlotSpec? Result { get; private set; }

    public PlotEditor(Window owner, PlotSpec spec, string? errorText, string deck, string? enginePython)
    {
        this.deck = deck;
        this.enginePython = enginePython;
        Owner = owner;
        Title = "Python Plot";
        Width = 640; Height = 520; MinWidth = 420; MinHeight = 320;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        code.SyntaxHighlighting = HighlightingManager.Instance.GetDefinition("Python");
        code.Text = spec.Code ?? PythonPlot.Template;
        code.Options.ConvertTabsToSpaces = true;
        code.Options.IndentationSize = 4;
        file.Text = spec.File ?? "";
        error.Foreground = (Brush)Application.Current.Resources["ErrorBrush"];
        error.Text = errorText ?? "";
        error.Visibility = string.IsNullOrEmpty(errorText) ? Visibility.Collapsed : Visibility.Visible;

        var modes = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 6) };
        modes.Children.Add(codeMode); modes.Children.Add(fileMode);
        var choose = new Button { Content = "Choose…", Padding = new Thickness(10, 2, 10, 2) };
        choose.Click += (_, _) => ChooseFile();
        DockPanel.SetDock(choose, Dock.Right);
        filePanel.Children.Add(choose);
        filePanel.Children.Add(file);
        var fileHint = new TextBlock
        {
            Text = "A .py file that plots with Matplotlib (or saves a PNG to os.environ['MANIMBLE_PLOT_OUT']). It runs in its own folder.",
            TextWrapping = TextWrapping.Wrap, FontSize = 11.5, Opacity = 0.7, Margin = new Thickness(0, 6, 0, 0),
        };
        var fileBox = new StackPanel();
        fileBox.Children.Add(filePanel); fileBox.Children.Add(fileHint);

        var changePy = new Button { Content = "Change…", Padding = new Thickness(8, 1, 8, 1), FontSize = 11.5, Margin = new Thickness(6, 0, 0, 0) };
        changePy.Click += (_, _) => ChoosePython();
        var pyRow = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
        DockPanel.SetDock(changePy, Dock.Right);
        pyRow.Children.Add(changePy); pyRow.Children.Add(pythonLabel);

        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 80, Margin = new Thickness(0, 0, 8, 0) };
        var render = new Button { Content = "Render", IsDefault = false, MinWidth = 80, ToolTip = "Ctrl+Enter" };
        cancel.Click += (_, _) => { Result = null; Close(); };
        render.Click += (_, _) => Commit();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        buttons.Children.Add(cancel); buttons.Children.Add(render);

        var bottom = new StackPanel();
        bottom.Children.Add(error); bottom.Children.Add(pyRow); bottom.Children.Add(buttons);
        var root = new DockPanel { Margin = new Thickness(12) };
        DockPanel.SetDock(modes, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(modes);
        root.Children.Add(bottom);
        var body = new Grid();
        body.Children.Add(code); body.Children.Add(fileBox);
        root.Children.Add(body);
        Content = root;

        codeMode.Checked += (_, _) => { code.Visibility = Visibility.Visible; fileBox.Visibility = Visibility.Collapsed; };
        fileMode.Checked += (_, _) => { code.Visibility = Visibility.Collapsed; fileBox.Visibility = Visibility.Visible; };
        if (!string.IsNullOrEmpty(spec.File)) fileMode.IsChecked = true; else codeMode.IsChecked = true;
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Enter && Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) { Commit(); e.Handled = true; } };
        Loaded += (_, _) => { UpdatePython(); if (codeMode.IsChecked == true) code.Focus(); };
    }

    void UpdatePython() => pythonLabel.Text = "Runs with " + PythonPlot.Python(enginePython);

    void ChooseFile()
    {
        var dlg = new OpenFileDialog { Title = "Choose the plot's Python file", Filter = "Python files|*.py|All files|*.*", InitialDirectory = deck };
        if (dlg.ShowDialog(this) == true) file.Text = dlg.FileName;
    }

    void ChoosePython()
    {
        var dlg = new OpenFileDialog { Title = "Choose the Python that runs plots", Filter = "python.exe|python.exe;python3.exe|Programs|*.exe" };
        if (dlg.ShowDialog(this) != true) return;
        Settings.Current.PlotPython = dlg.FileName;
        Settings.Current.Save();
        PythonPlot.ForgetFound();
        UpdatePython();
    }

    void Commit()
    {
        Result = fileMode.IsChecked == true ? new PlotSpec { File = file.Text.Trim() } : new PlotSpec { Code = code.Text };
        if (Result.IsEmpty) { Result = null; return; }
        Close();
    }
}

public partial class MainWindow
{
    /// The plot (folder and stem) an object on the slide shows, if it is a Python plot.
    (string dir, string stem)? PlotOf(int oid) =>
        scene?.Obj(oid) is { Kind: "image", ImagePath: { } p } ? PythonPlot.Of(p) : null;

    void InsertPythonPlot_Click(object sender, RoutedEventArgs e)
    {
        if (sceneName == null || workspace == null) { Toast("Open a deck and pick a slide first", error: true); return; }
        OpenPlotEditor(new PlotSpec { Code = PythonPlot.Template }, null, null);
    }

    void EditPlot(int oid)
    {
        if (PlotOf(oid) is not { } pl || PythonPlot.Load(pl.dir, pl.stem) is not { } spec) return;
        OpenPlotEditor(spec, oid, null);
    }

    /// ▶ on a plot: runs its code again; the picture changes only if the output did.
    void RerunPlot(int oid)
    {
        if (PlotOf(oid) is not { } pl || PythonPlot.Load(pl.dir, pl.stem) is not { } spec) return;
        CommitPlot(spec, oid, force: true);
    }

    void OpenPlotEditor(PlotSpec spec, int? oid, string? error)
    {
        if (workspace is not { } ws) return;
        var ed = new PlotEditor(this, spec, error, ws.Work, engine.Python);
        ed.ShowDialog();
        if (ed.Result is { } s) CommitPlot(s, oid, force: false);
    }

    /// Runs a plot and puts what it draws on the slide: a new picture, or the plot `oid` pointed at its new output.
    async void CommitPlot(PlotSpec spec, int? oid, bool force)
    {
        if (workspace is not { } ws || sceneName is not { } name) return;
        var old = oid is int o ? PlotOf(o) : null;
        if (old is { } od && !force && PythonPlot.Load(od.dir, od.stem) is { } was && was.SameAs(spec)) return;
        // a file inside the deck's own subfolders is kept relative (and stays live through the working copy's links)
        if (spec.File is { } f && f.StartsWith(ws.Original + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
        {
            var rel = f[(ws.Original.Length + 1)..];
            if (rel.Contains(Path.DirectorySeparatorChar)) spec.File = rel.Replace(Path.DirectorySeparatorChar, '/');
        }
        var python = PythonPlot.Python(engine.Python);
        Busy(+1, "Running the plot's code…");
        byte[] png;
        try { png = await PythonPlot.Run(spec, ws.Work, python); }
        catch (PythonPlot.RunError e) when (e.NoSeaborn) { Busy(-1); OfferSeaborn(e.Python, spec, oid); return; }
        catch (Exception e)
        {
            Busy(-1);
            Toast("The plot's code failed", error: true);
            if (sceneName == name) OpenPlotEditor(spec, oid, e.Message);
            return;
        }
        Busy(-1);
        var dir = old?.dir ?? ws.Work;
        var stem = old?.stem ?? PythonPlot.FreeStem(ws.Work);
        string file;
        try
        {
            file = PythonPlot.Store(png, stem, dir);
            PythonPlot.Save(spec, dir, stem);
        }
        catch (Exception e) { MessageBox.Show(this, e.Message, "Could not save the plot", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
        if (oid is not int id)
        {
            Insert("image", new JsonObject { ["file"] = file, ["path"] = Path.Combine(dir, file), ["width"] = 6 });
            return;
        }
        if (scene?.Obj(id)?.Image == file) { Toast("The plot is up to date"); return; }
        Submit(async () =>
        {
            var req = new JsonObject
            {
                ["scene"] = name, ["stop"] = sceneName == name ? stopIndex : 0, ["items"] = new JsonArray(),
                ["replace_image"] = new JsonObject { ["oid"] = id, ["file"] = file },
            };
            if (sceneName == name && Seen is { } seen) req["seen"] = seen;
            Busy(+1, "Rendering…");
            EditResult? r = null; string? failure = null;
            try { r = await engine.Call<EditResult>("insert_many", req); } catch (Exception e) { failure = e.Message; }
            Busy(-1);
            if (r?.Ok != true) { Toast(failure ?? r?.Error ?? "could not update the plot", error: true); return; }
            if (sceneName == name) await LoadScene(name, keepStop: true);
            await ReloadState();
            Toast("Plot updated · Ctrl+Z goes back to the old one");
        });
    }

    /// The plot needs seaborn and the Python running it lacks it: offers to install it there and run the plot again.
    async void OfferSeaborn(string python, PlotSpec spec, int? oid)
    {
        var name = sceneName;
        var answer = MessageBox.Show(this,
            $"This plot uses seaborn, which the Python that runs plots doesn't have:\n{python}\n\nManimble can install it there (pip install seaborn) and then run the plot again.",
            "Seaborn isn't installed", MessageBoxButton.OKCancel, MessageBoxImage.Question);
        if (answer != MessageBoxResult.OK)
        {
            if (sceneName == name) OpenPlotEditor(spec, oid, $"ModuleNotFoundError: No module named 'seaborn'\n\nInstall seaborn into {python}, or choose another Python below.");
            return;
        }
        Busy(+1, "Installing seaborn…");
        var failure = await PythonPlot.InstallSeaborn(python);
        Busy(-1);
        if (failure != null)
        {
            Toast("Could not install seaborn", error: true);
            if (sceneName == name) OpenPlotEditor(spec, oid, "pip install seaborn failed:\n" + failure);
            return;
        }
        Toast("Seaborn installed");
        CommitPlot(spec, oid, force: true);
    }
}
