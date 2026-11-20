using System.IO;
using System.Text.Json;

namespace Manimble;

/// Where Manimble keeps its files: %LOCALAPPDATA%\Manimble (the Mac app's ~/Library/Application Support/Manimble).
public static class Paths
{
    public static string Base
    {
        get
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Manimble");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    public static string LogFile => Path.Combine(Base, "manimble.log");
    public static string SettingsFile => Path.Combine(Base, "settings.json");
    public static string InstalledPython => Path.Combine(Base, "python", "Scripts", "python.exe");

    /// The shared engine: next to Manimble.exe in a build, else MANIMBLE_ENGINE, else the checkout's engine folder.
    public static string Engine
    {
        get
        {
            var env = Environment.GetEnvironmentVariable("MANIMBLE_ENGINE");
            if (!string.IsNullOrEmpty(env) && Directory.Exists(Path.Combine(env, "manimble"))) return env;
            var here = Path.Combine(AppContext.BaseDirectory, "engine");
            // running from a source checkout: prefer the live engine so engine edits need no rebuild
            var checkout = CheckoutRoot;
            if (checkout != null) return Path.Combine(checkout, "engine");
            if (IsPackaged) return packagedEngine.Value;
            return here;
        }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    static extern int GetCurrentPackageFullName(ref uint length, System.Text.StringBuilder? name);

    /// Installed from the Microsoft Store (an MSIX package) rather than the zip or the installer.
    public static bool IsPackaged { get; } = DetectPackage();

    static bool DetectPackage()
    {
        try { uint n = 0; return GetCurrentPackageFullName(ref n, null) != 15700 /* APPMODEL_ERROR_NO_PACKAGE */; }
        catch { return false; }
    }

    /// A package's install folder is read-only, so Python could not keep the engine's compiled __pycache__ there and
    /// would recompile it in every process. The packaged app runs a copy in %LOCALAPPDATA%\Manimble\engine\{version}
    /// instead, made on first start of each version (older copies are removed).
    static readonly Lazy<string> packagedEngine = new(() =>
    {
        var bundled = Path.Combine(AppContext.BaseDirectory, "engine");
        try
        {
            var version = typeof(Paths).Assembly.GetName().Version?.ToString() ?? "0";
            var root = Path.Combine(Base, "engine");
            var dest = Path.Combine(root, version);
            if (!File.Exists(Path.Combine(dest, "manimble", "rpc.py")))
            {
                var tmp = dest + ".tmp";
                if (Directory.Exists(tmp)) Directory.Delete(tmp, true);
                CopyTree(bundled, tmp);
                if (Directory.Exists(dest)) Directory.Delete(dest, true);
                Directory.Move(tmp, dest);
            }
            foreach (var old in Directory.GetDirectories(root))
                if (!string.Equals(old, dest, StringComparison.OrdinalIgnoreCase))
                    try { Directory.Delete(old, true); } catch { }
            return dest;
        }
        catch (Exception e)
        {
            Log.Note("engine copy: " + e.Message);
            return bundled;
        }
    });

    static void CopyTree(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var f in Directory.GetFiles(from)) File.Copy(f, Path.Combine(to, Path.GetFileName(f)));
        foreach (var d in Directory.GetDirectories(from))
            if (Path.GetFileName(d) != "__pycache__") CopyTree(d, Path.Combine(to, Path.GetFileName(d)));
    }

    /// The repository checkout this build lives in (apps\windows\...\bin\...), if any.
    public static string? CheckoutRoot
    {
        get
        {
            var d = new DirectoryInfo(AppContext.BaseDirectory);
            while (d != null)
            {
                if (File.Exists(Path.Combine(d.FullName, "engine", "manimble", "rpc.py")) &&
                    Directory.Exists(Path.Combine(d.FullName, "apps", "windows"))) return d.FullName;
                d = d.Parent;
            }
            return null;
        }
    }
}

public static class Log
{
    static readonly object gate = new();

    /// A line from the app in the log, next to what the engine writes there.
    public static void Note(string s)
    {
        lock (gate)
        {
            try { File.AppendAllText(Paths.LogFile, "[app] " + s + Environment.NewLine); } catch { }
        }
    }

    public static string Tail(int lines = 12)
    {
        try
        {
            using var fs = new FileStream(Paths.LogFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var r = new StreamReader(fs);
            var all = r.ReadToEnd().Split('\n');
            return string.Join("\n", all.TakeLast(lines)).Trim();
        }
        catch { return ""; }
    }
}

/// The app's saved choices (the Mac app's UserDefaults).
public sealed class Settings
{
    public string? Python { get; set; }
    public List<string> RecentDecks { get; set; } = new();
    public bool ShowSource { get; set; } = true;
    public bool ShowAnimations { get; set; } = true;
    public int AnimationHeight { get; set; } = 720;
    public double? WindowWidth { get; set; }
    public double? WindowHeight { get; set; }
    public bool WindowMaximized { get; set; }
    /// "Not Now" in the setup window when only LaTeX was missing: later launches don't ask again.
    public bool SkipLatexSetup { get; set; }
    /// Rulers along the slide (View > Ruler).
    public bool ShowRulers { get; set; } = true;
    /// The Python that runs Python plots, when chosen in the plot editor (else the first with matplotlib).
    public string? PlotPython { get; set; }
    /// The user's guides per deck (the original folder, lower-cased): [1 = vertical / 0 = horizontal, frame px].
    public Dictionary<string, List<double[]>> Guides { get; set; } = new();

    static Settings? current;
    public static Settings Current => current ??= Load();

    static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(Paths.SettingsFile)) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        try { File.WriteAllText(Paths.SettingsFile, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true })); }
        catch { }
    }

    public void AddRecent(string deck)
    {
        RecentDecks.RemoveAll(d => string.Equals(d, deck, StringComparison.OrdinalIgnoreCase));
        RecentDecks.Insert(0, deck);
        if (RecentDecks.Count > 12) RecentDecks.RemoveRange(12, RecentDecks.Count - 12);
        Save();
    }
}
