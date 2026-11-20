using System.Diagnostics;
using System.IO;

namespace Manimble;

/// Finding Python and the programs the engine runs (LaTeX, ffmpeg): the Windows side of Engine.findPython / Setup.
public static class Tools
{
    static string Local => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    static string Roaming => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    static string ProgramFiles => Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);

    /// Folders that hold a TeX distribution's programs (MiKTeX per-user or for all users, TinyTeX, TeX Live).
    public static IEnumerable<string> TexDirs()
    {
        yield return Path.Combine(Local, "Programs", "MiKTeX", "miktex", "bin", "x64");
        yield return Path.Combine(ProgramFiles, "MiKTeX", "miktex", "bin", "x64");
        yield return Path.Combine(Roaming, "TinyTeX", "bin", "windows");
        yield return Path.Combine(Roaming, "TinyTeX", "bin", "win32");
        foreach (var year in Enumerable.Range(2020, 12).Reverse())
            yield return $@"C:\texlive\{year}\bin\windows";
    }

    /// PATH for the engine: the Python environment's Scripts folder (manim-slides, ffmpeg wrappers), TeX and the rest.
    public static string SearchPath(string current, string python)
    {
        var dirs = new List<string>();
        var pyDir = Path.GetDirectoryName(python);
        if (pyDir != null) dirs.Add(pyDir);
        dirs.AddRange(TexDirs().Where(Directory.Exists));
        dirs.AddRange(current.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries));
        return string.Join(Path.PathSeparator, dirs.Distinct(StringComparer.OrdinalIgnoreCase));
    }

    public static bool HasLatex() =>
        TexDirs().Any(d => File.Exists(Path.Combine(d, "latex.exe"))) || Which("latex.exe") != null;

    public static string? Which(string exe)
    {
        foreach (var d in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var p = Path.Combine(d.Trim('"'), exe);
                if (File.Exists(p)) return p;
            }
            catch { }
        }
        return null;
    }

    /// The candidates, best first: an explicit or saved choice, the environment the installer made, a checkout's
    /// .venv, then Pythons on PATH (not the Microsoft Store's python.exe stub).
    public static IEnumerable<string> PythonCandidates()
    {
        var env = Environment.GetEnvironmentVariable("MANIMBLE_PYTHON");
        if (!string.IsNullOrEmpty(env)) yield return env;
        if (!string.IsNullOrEmpty(Settings.Current.Python)) yield return Settings.Current.Python!;
        yield return Paths.InstalledPython;
        if (Paths.CheckoutRoot is { } root) yield return Path.Combine(root, ".venv", "Scripts", "python.exe");
        foreach (var exe in new[] { "python.exe", "python3.exe" })
        {
            foreach (var d in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            {
                if (d.Contains("WindowsApps", StringComparison.OrdinalIgnoreCase)) continue;
                string p;
                try { p = Path.Combine(d.Trim('"'), exe); } catch { continue; }
                if (File.Exists(p)) yield return p;
            }
        }
    }

    public static async Task<string?> FindPython()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var c in PythonCandidates())
        {
            if (!File.Exists(c) || !seen.Add(Path.GetFullPath(c))) continue;
            if (await CanImportManim(c)) return c;
        }
        return null;
    }

    /// Whether `python` imports manim and Pillow. The first import after an install compiles and caches a lot,
    /// so this allows a minute and a half.
    public static async Task<bool> CanImportManim(string python)
    {
        try
        {
            var psi = new ProcessStartInfo(python) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
            psi.ArgumentList.Add("-c");
            psi.ArgumentList.Add("import manim, PIL");
            using var p = Process.Start(psi)!;
            _ = p.StandardOutput.ReadToEndAsync();
            _ = p.StandardError.ReadToEndAsync();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(90));
            try { await p.WaitForExitAsync(cts.Token); }
            catch (OperationCanceledException) { try { p.Kill(true); } catch { } return false; }
            return p.ExitCode == 0;
        }
        catch { return false; }
    }

    /// Opens a folder or file with its default program (Explorer for folders).
    public static void Reveal(string path)
    {
        try
        {
            if (File.Exists(path)) Process.Start("explorer.exe", $"/select,\"{path}\"");
            else Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception e) { Log.Note("reveal: " + e.Message); }
    }

    public static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }
}
