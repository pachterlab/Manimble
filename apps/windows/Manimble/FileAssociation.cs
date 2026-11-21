using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Manimble;

/// Opens .manimble packages with this Manimble on a double-click in Explorer, with their own icon (the Mac app's
/// CFBundleDocumentTypes). Registered for the current user only (HKCU\Software\Classes), so no administrator
/// rights are needed; a build inside a source checkout, or the Store package, leaves the association alone.
public static class FileAssociation
{
    const string Extension = ".manimble";
    const string ProgId = "Manimble.Project";

    [DllImport("shell32.dll")]
    static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    public static void RegisterIfNeeded()
    {
        if (Paths.CheckoutRoot != null) return;
        // the Store package declares the association in its manifest (msix\AppxManifest.xml), and its exe path
        // changes with every update, so it must not be written here
        if (Paths.IsPackaged) return;
        try
        {
            var exe = Environment.ProcessPath;
            if (exe == null) return;
            var command = $"\"{exe}\" \"%1\"";
            var icon = Path.Combine(AppContext.BaseDirectory, "ManimbleDocument.ico");
            if (!File.Exists(icon)) icon = $"\"{exe}\",0";
            using var classes = Registry.CurrentUser.CreateSubKey(@"Software\Classes");
            using (var existingCmd = classes.OpenSubKey($@"{ProgId}\shell\open\command"))
            using (var existingIcon = classes.OpenSubKey($@"{ProgId}\DefaultIcon"))
                if (existingCmd?.GetValue("") as string == command && existingIcon?.GetValue("") as string == icon) return;   // already this copy

            using (var ext = classes.CreateSubKey(Extension))
            {
                ext.SetValue("", ProgId);
                ext.SetValue("Content Type", "application/zip");
            }
            using (var prog = classes.CreateSubKey(ProgId))
            {
                prog.SetValue("", "Manimble Project");
                using (var di = prog.CreateSubKey("DefaultIcon"))
                    di.SetValue("", icon);
                using (var open = prog.CreateSubKey(@"shell\open"))
                    open.SetValue("FriendlyAppName", "Manimble");
                using (var cmd = prog.CreateSubKey(@"shell\open\command"))
                    cmd.SetValue("", command);
            }
            SHChangeNotify(0x08000000 /* SHCNE_ASSOCCHANGED */, 0, IntPtr.Zero, IntPtr.Zero);
            Log.Note("registered .manimble for " + exe);
        }
        catch (Exception e) { Log.Note("file association: " + e.Message); }
    }
}
