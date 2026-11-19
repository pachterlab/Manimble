using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Manimble;

/// First-launch setup (the Mac app's Setup.swift). Checks for what the engine needs (a Python that imports manim,
/// a LaTeX for formulas) and, once the user agrees, installs what is missing with install_dependencies.ps1.
/// Whatever is already on the PC is used as it is.
public sealed class SetupWindow : Window
{
    public sealed record Status(string? Python, bool Latex)
    {
        public bool Complete => Python != null && Latex;
    }

    static bool testUsed;

    /// Slow (it starts Pythons to see whether they import manim).
    /// MANIMBLE_TEST_SETUP=python,tex[,install]: the first check reports those as missing (and presses Install).
    public static async Task<Status> Check()
    {
        var test = Environment.GetEnvironmentVariable("MANIMBLE_TEST_SETUP");
        if (!string.IsNullOrEmpty(test) && !testUsed)
        {
            testUsed = true;
            var parts = test.Split(',');
            return new Status(parts.Contains("python") ? null : await Tools.FindPython(), !parts.Contains("tex") && Tools.HasLatex());
        }
        return new Status(await Tools.FindPython(), Tools.HasLatex());
    }

    /// install_dependencies.ps1: next to Manimble.exe in a build, else in apps\windows of the checkout.
    public static string? Script
    {
        get
        {
            var here = Path.Combine(AppContext.BaseDirectory, "install_dependencies.ps1");
            if (File.Exists(here)) return here;
            if (Paths.CheckoutRoot is { } root)
            {
                var p = Path.Combine(root, "apps", "windows", "install_dependencies.ps1");
                if (File.Exists(p)) return p;
            }
            return null;
        }
    }

    readonly Status status;
    readonly CheckBox pythonBox = new() { FontWeight = FontWeights.SemiBold };
    readonly CheckBox texBox = new() { FontWeight = FontWeights.SemiBold };
    readonly Button installButton = MakeButton("Install");
    readonly Button otherPythonButton = MakeButton("Use Another Python…");
    readonly Button laterButton = MakeButton("Not Now");
    readonly ProgressBar progress = new() { Height = 6, IsIndeterminate = true, Visibility = Visibility.Collapsed, Margin = new Thickness(0, 14, 0, 0) };
    readonly TextBlock stepLabel = new() { Visibility = Visibility.Collapsed, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
    readonly TextBox log = new()
    {
        IsReadOnly = true, Height = 160, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        Visibility = Visibility.Collapsed, Margin = new Thickness(0, 8, 0, 0),
    };
    /// The last install's output (the engine starts manimble.log afresh each time it starts).
    static string SetupLog => Path.Combine(Paths.Base, "setup.log");
    Process? proc;
    bool installedPython, installedTex, finished;

    /// Called once when the window goes away, with what was installed (the engine can start, or should restart
    /// to find the new LaTeX on its PATH).
    public Action<bool, bool>? OnDone;
    public Action? OnChoosePython;

    static Button MakeButton(string text) =>
        new() { Content = text, MinWidth = 90, Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(12, 4, 12, 4) };

    public SetupWindow(Status status, Window? owner)
    {
        this.status = status;
        Title = "Set Up Manimble";
        Width = 580;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        Owner = owner;
        WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen;
        ShowInTaskbar = owner == null;

        var title = new TextBlock
        {
            Text = status.Complete ? "Everything Manimble needs is installed" : "Manimble needs a few more things",
            FontSize = 16, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8),
        };
        var body = new TextBlock
        {
            Text = "Manimble draws slides with Manim, which runs in Python and uses LaTeX for formulas. Ticked items are " +
                   "downloaded and installed for you alone (no administrator rights); anything already on this PC is used as it is.",
            TextWrapping = TextWrapping.Wrap, Opacity = 0.75, Margin = new Thickness(0, 0, 0, 16),
        };
        var pythonRow = Row(pythonBox, "Python with Manim", status.Python,
            $"Downloads about 150 MB; uses about 600 MB in {Path.Combine(Paths.Base, "python")}. " +
            "Python itself comes from winget when none is installed.");
        var texRow = Row(texBox, "LaTeX (MiKTeX)", status.Latex ? "a LaTeX installation (MiKTeX, TinyTeX or TeX Live)" : null,
            "Downloads about 150 MB with winget, installed for you alone. Only formulas need it; MiKTeX fetches the " +
            "packages a formula uses the first time it is needed.");

        installButton.IsDefault = true;
        installButton.IsEnabled = !status.Complete && Script != null;
        installButton.Click += (_, _) => Install();
        otherPythonButton.Margin = new Thickness(0);
        otherPythonButton.Visibility = status.Python == null ? Visibility.Visible : Visibility.Collapsed;
        otherPythonButton.Click += (_, _) => { var choose = OnChoosePython; Finish(); choose?.Invoke(); };
        laterButton.Content = status.Python == null ? "Quit" : status.Complete ? "Close" : "Not Now";
        laterButton.IsCancel = true;
        laterButton.Click += (_, _) => Later();

        var buttons = new DockPanel { Margin = new Thickness(0, 18, 0, 0), LastChildFill = false };
        DockPanel.SetDock(otherPythonButton, Dock.Left);
        buttons.Children.Add(otherPythonButton);
        var right = new StackPanel { Orientation = Orientation.Horizontal, Children = { laterButton, installButton } };
        DockPanel.SetDock(right, Dock.Right);
        buttons.Children.Add(right);

        var stack = new StackPanel { Margin = new Thickness(24, 20, 24, 20), Children = { title, body, pythonRow, texRow, progress, stepLabel, log } };
        if (Script == null)
            stack.Children.Add(new TextBlock
            {
                Text = "install_dependencies.ps1 is missing from this copy of Manimble, so nothing can be installed from here.",
                TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources["ErrorBrush"], Margin = new Thickness(0, 10, 0, 0),
            });
        stack.Children.Add(buttons);
        Content = stack;
        Closing += (_, e) =>
        {
            if (finished) return;
            KillProc();
            // the close box with no Python to run: same as Quit (the app can do nothing without one)
            if (status.Python == null && !installedPython) { finished = true; OnDone = null; Application.Current.Shutdown(); return; }
            finished = true;
            var done = OnDone; OnDone = null;
            done?.Invoke(installedPython, installedTex);
        };
        Loaded += (_, _) =>
        {
            if (Environment.GetEnvironmentVariable("MANIMBLE_TEST_SETUP")?.Contains("install") == true && installButton.IsEnabled)
                Dispatcher.BeginInvoke(Install, System.Windows.Threading.DispatcherPriority.Background);
        };
    }

    static FrameworkElement Row(CheckBox box, string name, string? found, string offer)
    {
        box.Content = name;
        box.IsChecked = true;
        box.IsEnabled = found == null;
        var detail = new TextBlock
        {
            Text = found != null ? "Found: " + found : offer, TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.7,
            Margin = new Thickness(22, 2, 0, 0),
        };
        return new StackPanel { Margin = new Thickness(0, 0, 0, 12), Children = { box, detail } };
    }

    void Install()
    {
        var script = Script;
        if (script == null) return;
        var wantPython = status.Python == null && pythonBox.IsChecked == true;
        var wantTex = !status.Latex && texBox.IsChecked == true;
        if (!wantPython && !wantTex) { Finish(); return; }
        foreach (var c in new Control[] { installButton, otherPythonButton, pythonBox, texBox }) c.IsEnabled = false;
        laterButton.Content = "Cancel";
        progress.Visibility = stepLabel.Visibility = log.Visibility = Visibility.Visible;
        progress.IsIndeterminate = true;
        stepLabel.Foreground = SystemColors.ControlTextBrush;
        stepLabel.Text = "Starting…";
        log.Clear();

        var psi = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
                                  "-Requirements", Path.Combine(Paths.Engine, "requirements.txt") })
            psi.ArgumentList.Add(a);
        if (wantTex) psi.ArgumentList.Add("-WithLatex");
        if (!wantPython) psi.ArgumentList.Add("-SkipPython");
        // pip and uv print progress bars that only make sense on a console
        psi.Environment["PIP_PROGRESS_BAR"] = "off";
        psi.Environment["UV_NO_PROGRESS"] = "1";
        psi.Environment["PYTHONIOENCODING"] = "utf-8";
        try { File.WriteAllText(SetupLog, "powershell " + string.Join(" ", psi.ArgumentList) + Environment.NewLine); } catch { }
        try
        {
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (_, e) => { if (e.Data != null) Dispatcher.BeginInvoke(() => Consume(e.Data)); };
            p.ErrorDataReceived += (_, e) => { if (e.Data != null) Dispatcher.BeginInvoke(() => Consume(e.Data)); };
            p.Exited += (_, _) => Dispatcher.BeginInvoke(() => Exited(p, wantPython, wantTex));
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            proc = p;
        }
        catch (Exception e) { Append(e.Message); Failed(); }
    }

    /// "== " lines name the step; everything else goes to the log.
    void Consume(string line)
    {
        if (line.StartsWith("== "))
        {
            stepLabel.Text = line[3..] + (line == "== Done" ? "." : "…");
            Append(line[3..]);
        }
        else if (line.Trim().Length > 0) Append(line);
    }

    void Append(string s)
    {
        log.AppendText(s + Environment.NewLine);
        log.ScrollToEnd();
        try { File.AppendAllText(SetupLog, s + Environment.NewLine); } catch { }
    }

    void Exited(Process p, bool wantPython, bool wantTex)
    {
        if (proc != p) return;      // cancelled
        proc = null;
        p.WaitForExit();            // the last lines of output
        var code = p.ExitCode;
        p.Dispose();
        if (code != 0) { Failed(); return; }
        if (wantPython) installedPython = true;
        if (wantTex) installedTex = true;
        progress.IsIndeterminate = false;
        progress.Value = progress.Maximum;
        stepLabel.Text = "Done.";
        Finish();
    }

    void Failed()
    {
        progress.Visibility = Visibility.Collapsed;
        stepLabel.Text = "Installation did not finish. The log above (also in setup.log) says why; you can try again.";
        stepLabel.Foreground = (Brush)Application.Current.Resources["ErrorBrush"];
        installButton.Content = "Try Again";
        installButton.IsEnabled = true;
        pythonBox.IsEnabled = status.Python == null && !installedPython;
        texBox.IsEnabled = !status.Latex;
        otherPythonButton.IsEnabled = true;
        laterButton.Content = status.Python == null && !installedPython ? "Quit" : "Not Now";
    }

    void Later()
    {
        if (proc != null)
        {
            KillProc();
            Failed();
            stepLabel.Text = "Cancelled.";
            return;
        }
        if (status.Python == null && !installedPython) { finished = true; OnDone = null; Application.Current.Shutdown(); return; }
        if (!status.Latex) { Settings.Current.SkipLatexSetup = true; Settings.Current.Save(); }
        Finish();
    }

    void KillProc()
    {
        var p = proc;
        proc = null;
        if (p == null) return;
        try { p.Kill(true); } catch { }
    }

    void Finish()
    {
        if (finished) return;
        finished = true;
        var done = OnDone; OnDone = null;
        Close();
        done?.Invoke(installedPython, installedTex);
    }
}
