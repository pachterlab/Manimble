using System.IO;
using System.Windows.Media.Imaging;

namespace Manimble;

/// Loads the engine's PNGs and JPEGs into memory, so the files are never locked (the engine rewrites and deletes
/// them), with a small cache keyed by path and modification time.
public static class Images
{
    static readonly Dictionary<string, (DateTime stamp, BitmapSource img)> cache = new(StringComparer.OrdinalIgnoreCase);
    static readonly LinkedList<string> order = new();
    const int Max = 400;

    public static BitmapSource? Load(string? path, int decodeWidth = 0)
    {
        if (string.IsNullOrEmpty(path)) return null;
        try
        {
            var fi = new FileInfo(path);
            if (!fi.Exists) return null;
            var key = decodeWidth > 0 ? path + "|" + decodeWidth : path;
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
            cache[key] = (fi.LastWriteTimeUtc, bi);
            order.AddLast(key);
            while (order.Count > Max)
            {
                cache.Remove(order.First!.Value);
                order.RemoveFirst();
            }
            return bi;
        }
        catch (Exception e)
        {
            Log.Note($"image {path}: {e.Message}");
            return null;
        }
    }
}
