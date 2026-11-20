using System.Text.Json;
using System.Windows;

namespace Manimble;

// The engine's replies (docs/developers/protocol.md), as Models.swift decodes them on the Mac.

public sealed class SceneSummary
{
    public string Name { get; set; } = "";
    public string File { get; set; } = "";
    public int Line { get; set; }
    public string Status { get; set; } = "";
    public string? Thumb { get; set; }
    public int? Stops { get; set; }
    public string? Error { get; set; }
    public bool? Hidden { get; set; }
}

public sealed class StateInfo
{
    public string Deck { get; set; } = "";
    public string Path { get; set; } = "";
    public List<SceneSummary> Scenes { get; set; } = new();
    public List<SceneSummary> UnusedScenes { get; set; } = new();
    public bool CanUndo { get; set; }
    public bool CanRedo { get; set; }
    public string UndoLabel { get; set; } = "";
    public bool HasPresent { get; set; }
}

public sealed class SpriteInfo
{
    public int Oid { get; set; }
    public string File { get; set; } = "";
    public double X { get; set; }
    public double Y { get; set; }
    public double W { get; set; }
    public double H { get; set; }
    public double Z { get; set; }
}

public sealed class StopInfo
{
    public string Png { get; set; } = "";
    public string Bg { get; set; } = "";
    public List<double[]> Visible { get; set; } = new();
    public List<SpriteInfo> Sprites { get; set; } = new();
    public Dictionary<string, double[]>? Lines { get; set; }
    public Dictionary<string, double[]>? Xforms { get; set; }
    public Dictionary<string, List<double[]>>? Cells { get; set; }
    public Dictionary<string, List<double[]>>? Glyphs { get; set; }

    public Rect? Box(int oid)
    {
        foreach (var v in Visible)
            if (v.Length >= 5 && (int)v[0] == oid) return new Rect(new Point(v[1], v[2]), new Point(v[3], v[4]));
        return null;
    }
}

public sealed class SharedInfo
{
    public string Name { get; set; } = "";
    public int Uses { get; set; }
    public string Rel { get; set; } = "";
}

public sealed class FormatInfo
{
    public bool? Underline { get; set; }
    public bool? Strike { get; set; }
    public string? Highlight { get; set; }
    public string? Align { get; set; }
    public int? Columns { get; set; }
    public double? LineSpacing { get; set; }
    public string? Valign { get; set; }
    public string? Link { get; set; }
}

public sealed class ObjInfo
{
    public string Kind { get; set; } = "";
    public string Value { get; set; } = "";
    public double? FontSize { get; set; }
    public string? Color { get; set; }
    public string? Font { get; set; }
    public string? Weight { get; set; }
    public string? Slant { get; set; }
    public JsonElement? Italic { get; set; }
    public JsonElement? Bold { get; set; }
    public JsonElement? Colors { get; set; }
    public JsonElement? Decorations { get; set; }
    public int Siblings { get; set; }
    public string Loc { get; set; } = "";
    public bool? TextOk { get; set; }
    public string? TextLoc { get; set; }
    public string? TextNote { get; set; }
    public SharedInfo? Shared { get; set; }
    public string? Image { get; set; }
    public string? ImagePath { get; set; }
    public string? Shape { get; set; }
    public double? Rotation { get; set; }
    public double[]? Dims { get; set; }
    public FormatInfo? Format { get; set; }
    public double[]? Frame { get; set; }
    public int? Group { get; set; }
    public int[]? Follows { get; set; }

    public Rect? FrameBox => Frame is { Length: 4 } f ? new Rect(new Point(f[0], f[1]), new Point(f[2], f[3])) : null;
    public bool IsText => Kind is "text" or "tex";

    /// A table's cells as text (its value is the rows as JSON; numbers written as in the source).
    public List<List<string>> TableRows()
    {
        var rows = new List<List<string>>();
        try
        {
            using var doc = System.Text.Json.JsonDocument.Parse(Value);
            if (doc.RootElement.ValueKind != System.Text.Json.JsonValueKind.Array) return rows;
            foreach (var r in doc.RootElement.EnumerateArray())
            {
                var row = new List<string>();
                if (r.ValueKind == System.Text.Json.JsonValueKind.Array)
                    foreach (var c in r.EnumerateArray())
                        row.Add(c.ValueKind switch
                        {
                            System.Text.Json.JsonValueKind.String => c.GetString() ?? "",
                            System.Text.Json.JsonValueKind.Number => c.GetDouble() is var v && v == Math.Round(v) && Math.Abs(v) < 1e15
                                ? ((long)v).ToString(System.Globalization.CultureInfo.InvariantCulture)
                                : v.ToString(System.Globalization.CultureInfo.InvariantCulture),
                            _ => c.ToString(),
                        });
                rows.Add(row);
            }
        }
        catch (System.Text.Json.JsonException) { }
        return rows;
    }
}

public sealed class ChangedLines
{
    public string? File { get; set; }
    public List<int[]>? Ranges { get; set; }
}

public sealed class SourceInfo
{
    public string File { get; set; } = "";
    public int Start { get; set; }
    public int End { get; set; }
    public string Text { get; set; } = "";
    public ChangedLines? Changed { get; set; }
}

public sealed class Placeholder
{
    public int Line { get; set; }
    public string Role { get; set; } = "";
    public string Prompt { get; set; } = "";
    public int Size { get; set; }
    public double[] Box { get; set; } = Array.Empty<double>();
    public Rect Rect => Box.Length == 4 ? new Rect(new Point(Box[0], Box[1]), new Point(Box[2], Box[3])) : Rect.Empty;
}

public sealed class SceneData
{
    public string Name { get; set; } = "";
    public string Status { get; set; } = "";
    public double[]? Size { get; set; }
    public double[]? Frame { get; set; }
    public List<StopInfo>? Stops { get; set; }
    public Dictionary<string, ObjInfo>? Objects { get; set; }
    public SourceInfo? Source { get; set; }
    public string? Error { get; set; }
    public string? Notes { get; set; }
    public List<string>? BuildNotes { get; set; }
    public string? AltText { get; set; }
    public List<Placeholder>? Placeholders { get; set; }
    public string? Font { get; set; }
    public string? TextColor { get; set; }
    public string? Theme { get; set; }
    public bool? Optimistic { get; set; }

    public ObjInfo? Obj(int oid) => Objects != null && Objects.TryGetValue(oid.ToString(), out var o) ? o : null;
    // `size` is the frame in pixels (what every box is measured in); `frame` is the same frame in manim units
    public double FrameW => Size is { Length: >= 2 } s ? s[0] : 1280;
    public double FrameH => Size is { Length: >= 2 } s ? s[1] : 720;
}

public sealed class EditResult
{
    public bool? Ok { get; set; }
    public string? Message { get; set; }
    public string? Error { get; set; }
    public int? Siblings { get; set; }
    public ChangedLines? Changed { get; set; }
    public bool? PageNumber { get; set; }
    public bool? OneBuild { get; set; }
    public bool? Optimistic { get; set; }
    public string? Select { get; set; }
    public int? Stop { get; set; }
    public string? Label { get; set; }
    public int? Line { get; set; }
    public string? File { get; set; }
    public int? Mark { get; set; }
    public string? Text { get; set; }
    public string? Path { get; set; }
}

public sealed class DeckSlide
{
    public string Scene { get; set; } = "";
    public List<string> Pages { get; set; } = new();
    public bool? Pending { get; set; }
    public int? Builds { get; set; }
    public string? Error { get; set; }
    public string? Notes { get; set; }
    public List<string>? BuildNotes { get; set; }
    public List<List<LinkRegion>>? Links { get; set; }     // each page's clickable hyperlinks
}

public sealed class DeckPages
{
    public List<DeckSlide> Slides { get; set; } = new();
}

public sealed class OidMap
{
    public string? Dir { get; set; }
    public Dictionary<string, string?> Map { get; set; } = new();
}

/// A transparent PNG of one element (`sprite`, `insert_sprite`): `cx`/`cy` are its centre's offset from the frame centre.
public sealed class SpriteResult
{
    public string? File { get; set; }
    public string? Path { get; set; }
    public double? W { get; set; }
    public double? H { get; set; }
    public double? Cx { get; set; }
    public double? Cy { get; set; }
    public string? Error { get; set; }
}

public sealed class DependencyFailure
{
    public string Scene { get; set; } = "";
    public string Error { get; set; } = "";
}

/// dependency_report: the files the deck's code opened while every slide rendered.
public sealed class DependencyReport
{
    public List<string> Dependencies { get; set; } = new();
    public int ScannedScenes { get; set; }
    public int TotalScenes { get; set; }
    public List<DependencyFailure> Failures { get; set; } = new();
}

/// A hyperlink's clickable area on a rendered page: fractions of the slide, y from the top (the engine sends
/// [x0, x1, y0, y1, url]). Text with a link opens it when clicked in a show or Presenter View.
[System.Text.Json.Serialization.JsonConverter(typeof(LinkRegionConverter))]
public sealed class LinkRegion
{
    public double X0, X1, Y0, Y1;
    public string Url = "";

    /// The link under a point given as fractions of the slide; the last one drawn wins where linked texts overlap.
    public static string? At(IEnumerable<LinkRegion>? regions, Point f) =>
        regions?.LastOrDefault(r => r.X0 <= f.X && f.X <= r.X1 && r.Y0 <= f.Y && f.Y <= r.Y1)?.Url;

    /// A point of an area showing the slide letterboxed (Stretch.Uniform) as fractions of the slide, or null off it.
    public static Point? Fraction(Point p, Size area, double aspect)
    {
        if (area.Width <= 0 || area.Height <= 0 || aspect <= 0) return null;
        double w = area.Width, h = w / aspect;
        if (h > area.Height) { h = area.Height; w = h * aspect; }
        double x = (p.X - (area.Width - w) / 2) / w, y = (p.Y - (area.Height - h) / 2) / h;
        return x is >= 0 and <= 1 && y is >= 0 and <= 1 ? new Point(x, y) : null;
    }
}

public sealed class LinkRegionConverter : System.Text.Json.Serialization.JsonConverter<LinkRegion>
{
    public override LinkRegion Read(ref Utf8JsonReader r, Type t, JsonSerializerOptions o)
    {
        var a = JsonSerializer.Deserialize<JsonElement>(ref r, o);
        return new LinkRegion
        {
            X0 = a[0].GetDouble(), X1 = a[1].GetDouble(), Y0 = a[2].GetDouble(), Y1 = a[3].GetDouble(), Url = a[4].GetString() ?? "",
        };
    }

    public override void Write(Utf8JsonWriter w, LinkRegion v, JsonSerializerOptions o)
    {
        w.WriteStartArray();
        w.WriteNumberValue(v.X0); w.WriteNumberValue(v.X1); w.WriteNumberValue(v.Y0); w.WriteNumberValue(v.Y1); w.WriteStringValue(v.Url);
        w.WriteEndArray();
    }
}
