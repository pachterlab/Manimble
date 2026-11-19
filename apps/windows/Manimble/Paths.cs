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
            return here;
        }
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
