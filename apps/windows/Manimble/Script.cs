using System.IO;
using System.Speech.Synthesis;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Manimble;

/// One action of a slide's presentation script (the Mac's Script.swift): words to speak, a pointer move, or a pause.
/// Steps belong to one build of one slide and run in order when the show reaches that build (Play > Scripted
/// Presentation). They live in `script.json` beside the deck, not in the Python, so nothing renders.
public sealed class ScriptStep
{
    public string Id { get; set; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public string Scene { get; set; } = "";
    public int Build { get; set; }
    public string Kind { get; set; } = "speak";     // speak | move | pause
    public string Text { get; set; } = "";           // speak: the words
    public double Seconds { get; set; } = 1;         // pause
    /// move: [x, y] as fractions of the slide (y from the top). One point: straight there from wherever the pointer
    /// is; more: a traced track, joined from the pointer's position.
    public List<double[]> Path { get; set; } = new();
    public double Speed { get; set; } = 0.5;         // move: slide widths per second
    public double Noise { get; set; }                // move: 0 (steady) … 1 (a shaky hand)

    [JsonIgnore] public List<Point> Points => Path.Where(p => p.Length >= 2).Select(p => new Point(p[0], p[1])).ToList();

    public static readonly (string name, double value)[] Speeds = { ("Slow", 0.25), ("Medium", 0.5), ("Fast", 1.0), ("Very fast", 2.0) };

    public ScriptStep Clone() => new()
    {
        Id = Id, Scene = Scene, Build = Build, Kind = Kind, Text = Text, Seconds = Seconds,
        Path = Path.Select(p => p.ToArray()).ToList(), Speed = Speed, Noise = Noise,
    };
}

/// The deck's script, read from and written to `script.json` in the working copy (Save carries it to the original).
/// The file is the Mac app's; the Mac's voice is kept as it is, and the Windows voice goes beside it.
public sealed class ScriptStore
{
    public const float DefaultRate = 0.5f;           // AVSpeechUtteranceDefaultSpeechRate, the Mac's scale
    readonly string path;
    readonly bool keepEmptyFile;
    List<ScriptStep> steps = new();
    string? macVoice;
    public string? WindowsVoice { get; private set; }
    public float Rate { get; private set; } = DefaultRate;
    /// How long a build with no script stays up in a scripted presentation.
    public double Hold { get; private set; } = 3;
    public event Action? Changed;

    sealed class FileData
    {
        public int Version { get; set; } = 1;
        public string? Voice { get; set; }
        public string? WindowsVoice { get; set; }
        public float? Rate { get; set; }
        public double? Hold { get; set; }
        public List<ScriptStep> Steps { get; set; } = new();
    }

    static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true, WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public ScriptStore(string path, bool originalHasFile)
    {
        this.path = path;
        keepEmptyFile = originalHasFile;
        try
        {
            if (File.Exists(path) && JsonSerializer.Deserialize<FileData>(File.ReadAllText(path), Json) is { } f)
            {
                steps = f.Steps ?? new(); macVoice = f.Voice; WindowsVoice = f.WindowsVoice; Rate = f.Rate ?? Rate; Hold = f.Hold ?? Hold;
            }
        }
        catch (Exception e) { Log.Note("script.json unreadable: " + e.Message); }
    }

    void Save()
    {
        try
        {
            if (steps.Count == 0 && macVoice == null && WindowsVoice == null && Rate == DefaultRate && Hold == 3 && !keepEmptyFile)
            {
                if (File.Exists(path)) File.Delete(path);
            }
            else
            {
                var f = new FileData { Voice = macVoice, WindowsVoice = WindowsVoice, Rate = Rate, Hold = Hold, Steps = steps };
                File.WriteAllText(path, JsonSerializer.Serialize(f, Json));
            }
        }
        catch (Exception e) { Log.Note("script.json not saved: " + e.Message); }
        Changed?.Invoke();
    }

    public IReadOnlyList<ScriptStep> All => steps;
    public bool IsEmpty => steps.Count == 0;
    public List<ScriptStep> StepsOf(string scene, int build) => steps.Where(s => s.Scene == scene && s.Build == build).ToList();
    public ScriptStep? Step(string id) => steps.FirstOrDefault(s => s.Id == id);

    /// A new step at the end of the build's script.
    public ScriptStep Add(string kind, string scene, int build)
    {
        var s = new ScriptStep { Scene = scene, Build = build, Kind = kind };
        // a new move keeps the speed and wobble of the build's last one
        if (kind == "move" && StepsOf(scene, build).LastOrDefault(t => t.Kind == "move") is { } last) { s.Speed = last.Speed; s.Noise = last.Noise; }
        var i = steps.FindLastIndex(t => t.Scene == scene && t.Build == build);
        if (i >= 0) steps.Insert(i + 1, s); else steps.Add(s);
        Save();
        return s;
    }

    public void Update(string id, Action<ScriptStep> change)
    {
        var i = steps.FindIndex(s => s.Id == id);
        if (i < 0) return;
        var before = JsonSerializer.Serialize(steps[i], Json);
        var s = steps[i].Clone();
        change(s);
        if (JsonSerializer.Serialize(s, Json) == before) return;
        steps[i] = s;
        Save();
    }

    public void Remove(string id) { if (steps.RemoveAll(s => s.Id == id) > 0) Save(); }

    /// Swaps a step with its neighbour in the same build's script (-1: earlier, 1: later).
    public void Shift(string id, int d)
    {
        if (Step(id) is not { } s) return;
        var ids = StepsOf(s.Scene, s.Build).Select(t => t.Id).ToList();
        var k = ids.IndexOf(id);
        if (k + d < 0 || k + d >= ids.Count) return;
        int a = steps.FindIndex(t => t.Id == id), b = steps.FindIndex(t => t.Id == ids[k + d]);
        (steps[a], steps[b]) = (steps[b], steps[a]);
        Save();
    }

    public void SetVoice(string? v) { if (v == WindowsVoice) return; WindowsVoice = v; Save(); }
    public void SetRate(float r) { if (r == Rate) return; Rate = r; Save(); }
    public void SetHold(double h) { if (h == Hold) return; Hold = h; Save(); }

    /// Where the pointer is before a step runs: the end of the last move before it in its build (null: none yet).
    public Point? PointerBefore(string id)
    {
        if (Step(id) is not { } s) return null;
        Point? p = null;
        foreach (var t in StepsOf(s.Scene, s.Build))
        {
            if (t.Id == id) break;
            if (t.Kind == "move" && t.Points.Count > 0) p = t.Points[^1];
        }
        return p;
    }
}

/// The path of one move: a polyline in slide fractions, walked by arc length (in slide widths, so x and y count the
/// same on screen) with a sinusoidal ease, plus a smooth wobble that fades in and out.
public sealed class ScriptMotion
{
    readonly List<Point> points;
    readonly List<double> lengths = new() { 0 };
    readonly double aspect;
    readonly double noise;
    readonly double[] phases = new double[4];
    public double Duration { get; }

    public ScriptMotion(List<Point> points, Size size, double speed, double noise, string seed)
    {
        this.points = points;
        aspect = size.Width > 0 ? size.Height / size.Width : 9.0 / 16;
        for (int i = 1; i < Math.Max(1, points.Count); i++)
        {
            double dx = points[i].X - points[i - 1].X, dy = (points[i].Y - points[i - 1].Y) * aspect;
            lengths.Add(lengths[i - 1] + Math.Sqrt(dx * dx + dy * dy));
        }
        Duration = lengths[^1] > 0 ? Math.Max(0.2, lengths[^1] / Math.Max(0.02, speed)) : 0;
        this.noise = noise;
        // phases from the step's id, so a move wobbles the same way every time it plays (FNV-1a, as on the Mac)
        ulong h = 1469598103934665603;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(seed)) h = unchecked((h ^ b) * 1099511628211);
        for (int k = 0; k < 4; k++) phases[k] = ((h >> (k * 16)) & 0xFFFF) / 65536.0 * 2 * Math.PI;
    }

    public Point At(double t)
    {
        if (Duration <= 0 || points.Count < 2) return points.Count > 0 ? points[^1] : new Point();
        var u = Math.Clamp(t / Duration, 0, 1);
        var eased = u - Math.Sin(2 * Math.PI * u) / (2 * Math.PI);          // zero speed at both ends
        var d = eased * lengths[^1];
        int i = 1;
        while (i < lengths.Count - 1 && lengths[i] < d) i++;
        var seg = lengths[i] - lengths[i - 1];
        var f = seg > 0 ? (d - lengths[i - 1]) / seg : 1;
        var p = new Point(points[i - 1].X + (points[i].X - points[i - 1].X) * f, points[i - 1].Y + (points[i].Y - points[i - 1].Y) * f);
        if (noise > 0)
        {
            double env = Math.Sin(Math.PI * u), amp = noise * 0.012 * env;
            double nx = 0.6 * Math.Sin(2 * Math.PI * 1.3 * t + phases[0]) + 0.4 * Math.Sin(2 * Math.PI * 3.1 * t + phases[1]);
            double ny = 0.6 * Math.Sin(2 * Math.PI * 1.7 * t + phases[2]) + 0.4 * Math.Sin(2 * Math.PI * 2.6 * t + phases[3]);
            p.X += amp * nx;
            p.Y += amp * ny / aspect;
        }
        return p;
    }
}

/// The pointer drawn over the slide: a classic arrow, sized from the slide's height, with its tip at the point.
public sealed class ScriptPointer
{
    public readonly System.Windows.Shapes.Path Shape = new()
    {
        Fill = Brushes.White, Stroke = Brushes.Black, StrokeLineJoin = PenLineJoin.Round, IsHitTestVisible = false, Visibility = Visibility.Collapsed,
        Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 4, ShadowDepth = 1.5, Opacity = 0.35 },
    };
    double drawnFor;

    /// Puts the tip at `p` (fractions of `rect`, y from the top) in the canvas holding the shape; null hides it.
    public void Place(Point? p, Rect rect)
    {
        if (p is not Point q || rect.Width <= 0) { Shape.Visibility = Visibility.Collapsed; return; }
        var h = Math.Max(14, rect.Height * 0.045);
        if (h != drawnFor)
        {
            drawnFor = h;
            var k = h / 20;                // drawn in a 12 × 20 box, tip at the origin
            var pts = new[] { (0, 0), (0, 17), (4, 13.2), (7, 19.6), (9.4, 18.6), (6.5, 12.2), (12, 12.2) };
            var g = new StreamGeometry();
            using (var c = g.Open())
            {
                c.BeginFigure(new Point(0, 0), true, true);
                foreach (var (x, y) in pts.Skip(1)) c.LineTo(new Point(x * k, y * k), true, true);
            }
            g.Freeze();
            Shape.Data = g;
            Shape.StrokeThickness = Math.Max(1, 1.1 * k);
        }
        Canvas.SetLeft(Shape, rect.X + rect.Width * q.X);
        Canvas.SetTop(Shape, rect.Y + rect.Height * q.Y);
        Shape.Visibility = Visibility.Visible;
    }
}

/// Runs steps: speaks with Windows' text to speech, glides the pointer, waits. Shared by the editor (a click on a
/// step plays it) and the scripted presentation. It waits a frame at a time so it can be paused and stopped.
public sealed class ScriptPerformer : IDisposable
{
    readonly SpeechSynthesizer synth = new();
    bool speaking;
    public string? Voice;
    public float Rate = ScriptStore.DefaultRate;
    public Point? Pointer;
    public Action<Point?> Draw = _ => { };
    public Func<Size> SlideSize = () => new Size(16, 9);
    public Func<bool> Interrupt = () => false;
    public bool Stopped { get; private set; }
    bool paused;

    public ScriptPerformer()
    {
        try { synth.SetOutputToDefaultAudioDevice(); } catch { }
        synth.SpeakCompleted += (_, _) => speaking = false;
    }

    public static List<string> Voices()
    {
        try { using var s = new SpeechSynthesizer(); return s.GetInstalledVoices().Where(v => v.Enabled).Select(v => v.VoiceInfo.Name).ToList(); }
        catch { return new(); }
    }

    public bool Paused
    {
        get => paused;
        set
        {
            if (value == paused) return;
            paused = value;
            if (!speaking) return;
            try { if (paused) synth.Pause(); else synth.Resume(); } catch { }
        }
    }

    public void Stop()
    {
        Stopped = true;
        try { synth.SpeakAsyncCancelAll(); if (paused) synth.Resume(); } catch { }
        speaking = false;
    }

    public void Dispose() { Stop(); synth.Dispose(); }

    bool Halted => Stopped || Interrupt();

    async Task<bool> Frame()
    {
        await Task.Delay(16);
        return !Halted;
    }

    /// Waits `seconds` of unpaused time.
    public async Task Wait(double seconds)
    {
        var left = seconds;
        var last = DateTime.UtcNow;
        while (left > 0)
        {
            if (!await Frame()) return;
            var now = DateTime.UtcNow;
            if (!paused) left -= (now - last).TotalSeconds;
            last = now;
        }
    }

    public async Task Perform(ScriptStep s)
    {
        if (Halted) return;
        switch (s.Kind)
        {
            case "pause": await Wait(s.Seconds); break;
            case "speak": await Speak(s.Text); break;
            case "move": await Move(s); break;
        }
    }

    public async Task Speak(string text)
    {
        var t = text.Trim();
        if (t.Length == 0) return;
        try
        {
            if (Voice != null && synth.Voice.Name != Voice) synth.SelectVoice(Voice);
        }
        catch { }
        // the Mac's rate scale (0.3 slow … 0.5 normal … 0.7 fast) onto SAPI's -10 … 10
        synth.Rate = (int)Math.Clamp(Math.Round((Rate - 0.5) * 25), -10, 10);
        speaking = true;
        try { synth.SpeakAsync(t); }
        catch (Exception e) { Log.Note("speech: " + e.Message); speaking = false; return; }
        if (paused) try { synth.Pause(); } catch { }
        while (speaking)
        {
            if (!await Frame()) { try { synth.SpeakAsyncCancelAll(); } catch { } speaking = false; return; }
        }
    }

    /// Glides along the step's track from where the pointer is, easing in and out, with the step's wobble.
    public async Task Move(ScriptStep s)
    {
        var target = s.Points;
        if (target.Count == 0) return;
        var start = Pointer ?? new Point(0.5, 0.5);
        var track = new ScriptMotion(new List<Point> { start }.Concat(target).ToList(), SlideSize(), s.Speed, s.Noise, s.Id);
        Pointer = start; Draw(start);
        double t = 0;
        var last = DateTime.UtcNow;
        while (t < track.Duration)
        {
            if (!await Frame()) break;
            var now = DateTime.UtcNow;
            if (!paused) t += (now - last).TotalSeconds;
            last = now;
            Pointer = track.At(Math.Min(t, track.Duration));
            Draw(Pointer);
        }
        if (!Halted) { Pointer = target[^1]; Draw(Pointer); }
    }
}

/// Plays the deck by itself: on every page, the build's script (or a hold of a few seconds when it has none), then on
/// to the next page; the end of the deck ends the show. Space (or K) pauses and resumes; the arrows and clicks still
/// move through the show, and the script picks up on the page they reach.
public sealed class ScriptRunner
{
    readonly ScriptStore store;
    readonly AnimatedShowWindow show;
    readonly ScriptPerformer performer = new();
    readonly ScriptPointer pointer = new();
    readonly Border badge = new()
    {
        Background = new SolidColorBrush(Color.FromArgb(0x99, 0, 0, 0)), CornerRadius = new CornerRadius(6), Padding = new Thickness(12, 4, 12, 4),
        Child = new TextBlock { Text = "❚❚  Paused · space to resume", Foreground = Brushes.White, FontSize = 14 },
        Visibility = Visibility.Collapsed, IsHitTestVisible = false,
    };
    bool running;

    public ScriptRunner(ScriptStore store, AnimatedShowWindow show)
    {
        this.store = store;
        this.show = show;
        performer.Voice = store.WindowsVoice;
        performer.Rate = store.Rate;
    }

    public void Start()
    {
        show.Overlay.Children.Add(pointer.Shape);
        Canvas.SetLeft(badge, 16); Canvas.SetTop(badge, 16);
        show.Overlay.Children.Add(badge);
        performer.Draw = p => pointer.Place(p, show.SlideRect);
        performer.SlideSize = () => show.SlideRect.Size;
        // space pauses instead of advancing; every other key and click works as in the show
        show.KeyFilter = k =>
        {
            if (k is not (System.Windows.Input.Key.Space or System.Windows.Input.Key.K)) return false;
            performer.Paused = !performer.Paused;
            badge.Visibility = performer.Paused ? Visibility.Visible : Visibility.Collapsed;
            return true;
        };
        show.Exited += Stop;
        running = true;
        _ = Run();
    }

    public void Stop()
    {
        running = false;
        performer.Dispose();
        show.Overlay.Children.Remove(pointer.Shape);
        show.Overlay.Children.Remove(badge);
    }

    async Task Run()
    {
        string? lastScene = null;
        while (running && !performer.Stopped)
        {
            // the page's picture or clip first
            while (!show.ScriptPageReady)
            {
                await Task.Delay(50);
                if (!running || performer.Stopped) return;
            }
            var i = show.PageIndex;
            if (show.Current is not { } page) return;
            if (page.Scene != lastScene) { performer.Draw(null); performer.Pointer = null; lastScene = page.Scene; }   // a new slide: the pointer waits for its first move
            performer.Interrupt = () => show.PageIndex != i;
            var steps = store.StepsOf(page.Scene, page.Index);
            if (steps.Count == 0) await performer.Wait(store.Hold);
            foreach (var s in steps)
            {
                await performer.Perform(s);
                if (performer.Stopped || show.PageIndex != i) break;
            }
            performer.Interrupt = () => false;
            if (!running || performer.Stopped) return;
            if (show.PageIndex != i) continue;                   // the presenter went elsewhere: script from there
            await performer.Wait(0.4);
            if (!running || performer.Stopped) return;
            if (show.PageIndex != i) continue;
            if (i >= show.Slides.Count - 1) { show.Close(); return; }
            show.Next();
            while (show.PageIndex == i && running && !performer.Stopped) await Task.Delay(30);
        }
    }
}
