using System.Windows;
using System.Windows.Threading;

namespace Manimble;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnUnhandled;
        FileAssociation.RegisterIfNeeded();
        var w = new MainWindow();
        MainWindow = w;
        w.Show();
        // `Manimble.exe <deck folder>` opens it (also what a file association or a shortcut passes)
        var deck = e.Args.FirstOrDefault(a => !a.StartsWith("--"));
        w.Start(deck);
    }

    void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Note("unhandled: " + e.Exception);
        MessageBox.Show(e.Exception.Message, "Manimble", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }
}
