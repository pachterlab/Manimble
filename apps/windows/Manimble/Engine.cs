using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;

namespace Manimble;

public sealed class EngineException(string message) : Exception(message);

/// Talks JSON lines to the Python engine (python -m manimble.rpc), as Engine.swift does on the Mac.
public sealed class Engine
{
    Process? proc;
    StreamWriter? stdin;
    int nextId = 1;
    readonly Dictionary<int, TaskCompletionSource<JsonElement>> pending = new();
    readonly object gate = new();
    readonly object writeGate = new();
    bool stopping;
    public string? Python { get; private set; }

    /// Events (`rendered`, `present`, ...) on the UI thread.
    public event Action<JsonElement>? EventReceived;
    /// The engine ended without Stop (crashed or could not start): its exit code, on the UI thread.
    public event Action<int>? Exited;

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowReadingFromString,
    };

    public bool IsRunning => proc is { HasExited: false };

    public void Start(string python)
    {
        Python = python;
        var psi = new ProcessStartInfo(python)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
        };
        psi.ArgumentList.Add("-u");
        psi.ArgumentList.Add("-X");
        psi.ArgumentList.Add("utf8");
        psi.ArgumentList.Add("-m");
        psi.ArgumentList.Add("manimble.rpc");
        psi.Environment["PYTHONPATH"] = Paths.Engine;
        psi.Environment["MANIMBLE_PYTHON"] = python;
        psi.Environment["PYTHONUNBUFFERED"] = "1";
        psi.Environment["PYTHONUTF8"] = "1";
        psi.Environment["PYTHONIOENCODING"] = "utf-8";
        // old packages manim pulls in (pydub) print SyntaxWarnings on every start of every worker
        psi.Environment["PYTHONWARNINGS"] = "ignore::SyntaxWarning";
        psi.Environment["PATH"] = Tools.SearchPath(psi.Environment["PATH"] ?? "", python);
        try { File.WriteAllText(Paths.LogFile, ""); } catch { }
        Log.Note(SystemSummary);
        Log.Note("engine " + Paths.Engine + " python " + python);
        stopping = false;
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) => { if (e.Data != null) Handle(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) AppendLog(e.Data); };
        p.Exited += (_, _) => Ended(p);
        p.Start();
        JobObject.Add(p);                    // render workers and builds die with the app
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        proc = p;
        stdin = p.StandardInput;
        stdin.AutoFlush = true;
    }

    public static string SystemSummary =>
        $"Manimble {typeof(Engine).Assembly.GetName().Version} on {RuntimeInformation.OSDescription} ({RuntimeInformation.OSArchitecture})";

    static readonly object logGate = new();
    static void AppendLog(string line)
    {
        lock (logGate)
        {
            try { File.AppendAllText(Paths.LogFile, line + Environment.NewLine); } catch { }
        }
    }

    public void Stop()
    {
        stopping = true;
        try { stdin?.Close(); } catch { }
        try
        {
            // closing stdin lets the engine stop its workers; whatever is left is killed with its children
            if (proc is { HasExited: false } && !proc.WaitForExit(1500)) proc.Kill(true);
            proc?.WaitForExit(3000);
        }
        catch { }
    }

    void Ended(Process p)
    {
        Application.Current?.Dispatcher.BeginInvoke(() =>
        {
            if (p != proc) return;
            List<TaskCompletionSource<JsonElement>> waiting;
            lock (gate) { waiting = pending.Values.ToList(); pending.Clear(); }
            foreach (var t in waiting) t.TrySetException(new EngineException("The Manimble engine stopped"));
            stdin = null;
            if (!stopping) Exited?.Invoke(p.ExitCode);
        });
    }

    void Handle(string line)
    {
        JsonElement obj;
        try { obj = JsonDocument.Parse(line).RootElement.Clone(); }
        catch { AppendLog("[stdout] " + line); return; }
        if (obj.ValueKind != JsonValueKind.Object) return;
        if (obj.TryGetProperty("event", out _))
        {
            Application.Current?.Dispatcher.BeginInvoke(() => EventReceived?.Invoke(obj));
            return;
        }
        if (!obj.TryGetProperty("id", out var idEl) || !idEl.TryGetInt32(out var id)) return;
        TaskCompletionSource<JsonElement>? t;
        lock (gate) { pending.Remove(id, out t); }
        if (t == null) return;
        if (obj.TryGetProperty("error", out var err) && err.ValueKind == JsonValueKind.String)
            t.TrySetException(new EngineException(err.GetString() ?? "error"));
        else
            t.TrySetResult(obj.TryGetProperty("result", out var r) ? r : default);
    }

    /// Sends `cmd` with `args` and returns the result element. Throws EngineException on an engine error.
    public Task<JsonElement> Raw(string cmd, object? args = null)
    {
        var t = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        int id;
        lock (gate) { id = nextId++; pending[id] = t; }
        JsonObject req = args switch
        {
            null => new JsonObject(),
            JsonObject j => (JsonObject)j.DeepClone(),
            _ => JsonSerializer.SerializeToNode(args, args.GetType())!.AsObject(),
        };
        req["id"] = id;
        req["cmd"] = cmd;
        var w = stdin;
        if (w == null)
        {
            lock (gate) pending.Remove(id);
            t.TrySetException(new EngineException("engine not running"));
            return t.Task;
        }
        try
        {
            var text = req.ToJsonString();
            lock (writeGate) w.WriteLine(text);
        }
        catch
        {
            lock (gate) pending.Remove(id);
            t.TrySetException(new EngineException("The Manimble engine stopped"));
        }
        return t.Task;
    }

    public async Task<T> Call<T>(string cmd, object? args = null)
    {
        var r = await Raw(cmd, args);
        if (r.ValueKind == JsonValueKind.Undefined) return default!;
        return r.Deserialize<T>(Json)!;
    }

    /// Like Call, but returns null instead of throwing (the Mac app's `try?`).
    public async Task<T?> TryCall<T>(string cmd, object? args = null) where T : class
    {
        try { return await Call<T>(cmd, args); }
        catch (Exception e) { Log.Note($"{cmd} failed: {e.Message}"); return null; }
    }
}

/// A Windows job that kills every process in it when the app exits, so manim workers never outlive Manimble.
static class JobObject
{
    static IntPtr handle;

    public static void Add(Process p)
    {
        try
        {
            if (handle == IntPtr.Zero)
            {
                handle = CreateJobObject(IntPtr.Zero, null);
                var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                info.BasicLimitInformation.LimitFlags = 0x2000;  // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                int len = Marshal.SizeOf(info);
                var ptr = Marshal.AllocHGlobal(len);
                Marshal.StructureToPtr(info, ptr, false);
                SetInformationJobObject(handle, 9, ptr, (uint)len);
                Marshal.FreeHGlobal(ptr);
            }
            AssignProcessToJobObject(handle, p.Handle);
        }
        catch (Exception e) { Log.Note("job object: " + e.Message); }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong a, b, c, d, e, f; }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string? name);
    [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
    [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}
