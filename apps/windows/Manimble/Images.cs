using System.IO;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Manimble;

/// How slides are shown; nothing is written to the deck (Format > Apply Dark Mode to Deck does that).
public enum ColorView { Normal, Dark, Invert }

/// Loads the engine's PNGs and JPEGs into memory, so the files are never locked (the engine rewrites and deletes
/// them), with a small cache keyed by path and modification time. In dark mode or with inverted colours every
/// frame comes back mapped, so the canvas, thumbnails and slideshow all show the same view; the inserted pictures on
/// it keep their own colours (from the engine's pics.json beside each frame) unless View > Recolor Images Too is on.
public static class Images
{
    static readonly Dictionary<string, (DateTime stamp, BitmapSource img)> cache = new(StringComparer.OrdinalIgnoreCase);
    static readonly LinkedList<string> order = new();
    const int Max = 400;

    /// The view now; set it, then redraw whatever shows pictures.
    public static ColorView View { get; set; } = ColorView.Normal;

    /// View > Recolor Images Too: inserted pictures are mapped with the rest (off: a white icon stays white).
    public static bool RecolorImages { get; set; }

    /// `map` false: the file as it is in any view (a picture's own sprite on the canvas).
    public static BitmapSource? Load(string? path, int decodeWidth = 0, bool map = true)
    {
        if (string.IsNullOrEmpty(path)) return null;
        try
        {
            var fi = new FileInfo(path);
            if (!fi.Exists) return null;
            var view = map ? View : ColorView.Normal;
            var key = (decodeWidth > 0 ? path + "|" + decodeWidth : path) + (view == ColorView.Normal ? "" : "|" + view)
                      + (view != ColorView.Normal && RecolorImages ? "|i" : "");
            if (cache.TryGetValue(key, out var c) && c.stamp == fi.LastWriteTimeUtc) return c.img;
            var bytes = File.ReadAllBytes(path);
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.CacheOption = BitmapCacheOption.OnLoad;
            bi.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            if (decodeWidth > 0) bi.DecodePixelWidth = decodeWidth;
            bi.StreamSource = new MemoryStream(bytes);
            bi.EndInit();
            bi.Freeze();
            BitmapSource img = view == ColorView.Normal ? bi : Mapped(bi, view, path);
            cache[key] = (fi.LastWriteTimeUtc, img);
            order.AddLast(key);
            while (order.Count > Max)
            {
                cache.Remove(order.First!.Value);
                order.RemoveFirst();
            }
            return img;
        }
        catch (Exception e)
        {
            Log.Note($"image {path}: {e.Message}");
            return null;
        }
    }

    /// A picture read once, outside the cache (the editor's large zoom tiles), mapped to the view like the rest.
    public static BitmapSource? LoadUncached(string path, bool map = true)
    {
        try
        {
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.CacheOption = BitmapCacheOption.OnLoad;
            bi.CreateOptions = BitmapCreateOptions.IgnoreColorProfile;
            bi.StreamSource = new MemoryStream(File.ReadAllBytes(path));
            bi.EndInit();
            bi.Freeze();
            return View == ColorView.Normal || !map ? bi : Mapped(bi, View, path);
        }
        catch (Exception e)
        {
            Log.Note($"image {path}: {e.Message}");
            return null;
        }
    }

    // Chroma (max - min) below Lo is fully flipped, above Hi kept: the Mac's DarkMode.map and engine/manimble/darkmode.py.
    const float Lo = 0.12f, Hi = 0.28f;

    public static (float r, float g, float b) MapColor(float r, float g, float b, ColorView view)
    {
        switch (view)
        {
            case ColorView.Normal: return (r, g, b);
            case ColorView.Invert: return (1 - r, 1 - g, 1 - b);
        }
        float mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b));
        float t = Math.Clamp((mx - mn - Lo) / (Hi - Lo), 0, 1);
        float k = (1 - t * t * (3 - 2 * t)) * (1 - mx - mn);
        return (r + k, g + k, b + k);
    }

    public static Color MapColor(Color c, ColorView view)
    {
        var (r, g, b) = MapColor(c.R / 255f, c.G / 255f, c.B / 255f, view);
        return Color.FromArgb(c.A, ToByte(r), ToByte(g), ToByte(b));
    }

    static byte ToByte(float v) => (byte)Math.Clamp((int)MathF.Round(v * 255), 0, 255);

    /// A frame mapped to the view, with the inserted pictures' own pixels put back unless they are recoloured too.
    static BitmapSource Mapped(BitmapSource src, ColorView view, string path)
    {
        var boxes = RecolorImages ? new List<double[]>() : PictureBoxes(path);
        return Map(src, view, boxes);
    }

    static readonly Dictionary<string, Dictionary<string, List<double[]>>> picsByDir = new(StringComparer.OrdinalIgnoreCase);
    sealed class Pics { public Dictionary<string, List<double[]>>? pages { get; set; } }

    /// Where the inserted pictures sit on a rendered frame, from pics.json beside it ([x0, y0, x1, y1] fractions of
    /// the slide, y from the top; written by the engine). Render folders are never rewritten, so a found file is kept.
    public static List<double[]> PictureBoxes(string path)
    {
        var dir = Path.GetDirectoryName(path) ?? "";
        lock (picsByDir)
        {
            if (!picsByDir.TryGetValue(dir, out var pages))
            {
                try
                {
                    var f = Path.Combine(dir, "pics.json");
                    if (!File.Exists(f)) return new();
                    pages = JsonSerializer.Deserialize<Pics>(File.ReadAllText(f))?.pages ?? new();
                }
                catch (Exception e) { Log.Note($"pics.json in {dir}: {e.Message}"); return new(); }
                picsByDir[dir] = pages;
            }
            return pages.TryGetValue(Path.GetFileName(path), out var b) ? b.Where(x => x.Length == 4).ToList() : new();
        }
    }

    /// A picture with every pixel mapped (premultiplied alpha is undone first, so edges keep their colour).
    static BitmapSource Map(BitmapSource src, ColorView view, List<double[]> keep)
    {
        var conv = new FormatConvertedBitmap(src, PixelFormats.Bgra32, null, 0);
        int w = conv.PixelWidth, h = conv.PixelHeight, stride = w * 4;
        var px = new byte[stride * h];
        conv.CopyPixels(px, stride, 0);
        // pixels inside a picture's box are left as they are
        var kept = keep.Count == 0 ? null : new bool[w * h];
        if (kept != null)
            foreach (var b in keep)
            {
                int x0 = Math.Clamp((int)Math.Round(b[0] * w), 0, w), x1 = Math.Clamp((int)Math.Round(b[2] * w), 0, w);
                int y0 = Math.Clamp((int)Math.Round(b[1] * h), 0, h), y1 = Math.Clamp((int)Math.Round(b[3] * h), 0, h);
                for (int y = y0; y < y1; y++) Array.Fill(kept, true, y * w + x0, Math.Max(0, x1 - x0));
            }
        var lut = new Dictionary<int, int>();
        for (int i = 0; i < px.Length; i += 4)
        {
            if (kept != null && kept[i >> 2]) continue;
            byte a = px[i + 3];
            if (a == 0) continue;
            int rgb = px[i + 2] << 16 | px[i + 1] << 8 | px[i];
            if (!lut.TryGetValue(rgb, out var m))
            {
                var (r, g, b) = MapColor(px[i + 2] / 255f, px[i + 1] / 255f, px[i] / 255f, view);
                m = ToByte(r) << 16 | ToByte(g) << 8 | ToByte(b);
                if (lut.Count < 1 << 20) lut[rgb] = m;
            }
            px[i + 2] = (byte)(m >> 16); px[i + 1] = (byte)(m >> 8); px[i] = (byte)m;
        }
        var outImg = BitmapSource.Create(w, h, src.DpiX, src.DpiY, PixelFormats.Bgra32, null, px, stride);
        outImg.Freeze();
        return outImg;
    }
}
