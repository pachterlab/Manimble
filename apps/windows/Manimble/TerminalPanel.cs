using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Manimble;

/// The terminal under the slide (the Mac's TerminalPanel): a shell in the deck's working copy, for coding agents such
/// as Claude Code, Codex or Gemini CLI. ConPTY runs the shell; xterm.js in a WebView2 draws it. The shell gets
/// MANIMBLE_DECK (the working copy) and MANIMBLE_ORIGINAL_DECK, as on the Mac, and the Python environment first on PATH.
public sealed class TerminalPanel : Border
{
    readonly WebView2 web = new() { DefaultBackgroundColor = System.Drawing.Color.FromArgb(0x1b, 0x1b, 0x1e) };
    readonly TextBlock message = new() { Foreground = Brushes.Gray, Margin = new Thickness(12), TextWrapping = TextWrapping.Wrap };
    ConPty? pty;
    bool ready;
    short cols = 100, rows = 24;
    string? cwd, original, python;
    readonly System.Text.StringBuilder pending = new();
    readonly object pendingGate = new();
    System.Windows.Threading.DispatcherTimer? flush;

    public bool IsRunning => pty != null;

    public TerminalPanel()
    {
        Background = new SolidColorBrush(Color.FromRgb(0x1b, 0x1b, 0x1e));
        var g = new Grid();
        g.Children.Add(web);
        g.Children.Add(message);
        Child = g;
        Loaded += async (_, _) => await Init();
    }

    async Task Init()
    {
        if (web.CoreWebView2 != null) return;
        try
        {
            var data = Path.Combine(Paths.Base, "webview2");
            var env = await CoreWebView2Environment.CreateAsync(null, data);
            await web.EnsureCoreWebView2Async(env);
            var core = web.CoreWebView2!;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.SetVirtualHostNameToFolderMapping("terminal.manimble", Path.Combine(AppContext.BaseDirectory, "Terminal"),
                                                              CoreWebView2HostResourceAccessKind.Allow);
            core.WebMessageReceived += OnMessage;
            core.Navigate("https://terminal.manimble/terminal.html");
            message.Visibility = Visibility.Collapsed;
        }
        catch (Exception e)
        {
            message.Text = "The terminal needs the Microsoft Edge WebView2 runtime: " + e.Message;
            Log.Note("terminal: " + e);
        }
    }

    /// Runs a shell in `workDir` (the working copy); a running one is ended first.
    public void Start(string workDir, string originalDeck, string? pythonExe)
    {
        cwd = workDir; original = originalDeck; python = pythonExe;
        Stop();
        if (ready) Spawn();
    }

    void Spawn()
    {
        if (cwd == null || !Directory.Exists(cwd)) return;
        var env = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
            .ToDictionary(e => (string)e.Key, e => (string?)e.Value ?? "", StringComparer.OrdinalIgnoreCase);
        env["MANIMBLE_DECK"] = cwd;
        if (original != null) env["MANIMBLE_ORIGINAL_DECK"] = original;
        env["TERM"] = "xterm-256color";
        env["COLORTERM"] = "truecolor";
        if (python != null) env["PATH"] = Tools.SearchPath(env.GetValueOrDefault("PATH") ?? "", python);
        var shell = Tools.Which("pwsh.exe") is { } pwsh ? $"\"{pwsh}\" -NoLogo" : "powershell.exe -NoLogo";
        try
        {
            pty = ConPty.Start(shell, cwd, env, cols, rows);
            pty.Output += OnOutput;
            var mine = pty;
            pty.Exited += () => Dispatcher.BeginInvoke(() =>
            {
                if (pty != mine) return;
                pty?.Dispose(); pty = null;
                Send(new { type = "out", data = "\r\n\x1b[90m[the shell ended: File > New Terminal starts another]\x1b[0m\r\n" });
            });
        }
        catch (Exception e)
        {
            Send(new { type = "out", data = "Could not start the shell: " + e.Message + "\r\n" });
            Log.Note("terminal start: " + e);
        }
    }

    public void Stop()
    {
        var p = pty;
        pty = null;
        p?.Dispose();
        if (ready) Send(new { type = "clear" });
    }

    public void FocusTerminal()
    {
        web.Focus();
        Send(new { type = "focus" });
    }

    /// Types `text` into the shell (as if pasted), e.g. a command to start an agent.
    public void Type(string text) => pty?.Write(text);

    // output arrives in many small pieces: batch it so the page gets a few messages a second, not thousands
    void OnOutput(string s)
    {
        lock (pendingGate) pending.Append(s);
        Dispatcher.BeginInvoke(() =>
        {
            if (flush != null) return;
            flush = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
            flush.Tick += (_, _) =>
            {
                string chunk;
                lock (pendingGate) { chunk = pending.ToString(); pending.Clear(); }
                if (chunk.Length > 0) Send(new { type = "out", data = chunk });
                else { flush!.Stop(); flush = null; }
            };
            flush.Start();
        });
    }

    void Send(object msg)
    {
        try { web.CoreWebView2?.PostWebMessageAsJson(JsonSerializer.Serialize(msg)); } catch { }
    }

    void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        JsonElement m;
        try { m = JsonDocument.Parse(e.WebMessageAsJson).RootElement; } catch { return; }
        switch (m.GetProperty("type").GetString())
        {
            case "ready":
                ready = true;
                cols = (short)m.GetProperty("cols").GetInt32(); rows = (short)m.GetProperty("rows").GetInt32();
                if (pty == null && cwd != null) Spawn();
                break;
            case "in":
                pty?.Write(m.GetProperty("data").GetString() ?? "");
                break;
            case "resize":
                cols = (short)Math.Max(10, m.GetProperty("cols").GetInt32()); rows = (short)Math.Max(3, m.GetProperty("rows").GetInt32());
                pty?.Resize(cols, rows);
                break;
            case "copy":
                try { Clipboard.SetText(m.GetProperty("data").GetString() ?? ""); } catch { }
                break;
            case "paste":
                try { if (Clipboard.ContainsText()) Send(new { type = "paste", data = Clipboard.GetText() }); } catch { }
                break;
        }
    }
}
