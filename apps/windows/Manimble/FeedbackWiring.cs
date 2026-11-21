using System.IO;
using System.Windows;

namespace Manimble;

/// The feedback layer in the editor: the deck's notes over the canvas (moved, retyped and deleted there), the
/// feedback list in the inspector's place, and the store Presenter View's Feedback Mode writes to.
public partial class MainWindow
{
    FeedbackStore? feedback;
    FeedbackPane? feedbackPane;
    readonly FeedbackLayer editorFeedback = new();
    bool feedbackHooked;

    void HookFeedback()
    {
        if (feedbackHooked) return;
        feedbackHooked = true;
        canvas.AddLayer(editorFeedback);
        editorFeedback.SlideRect = () => new Rect(0, 0, canvas.FrameSize.Width, canvas.FrameSize.Height);
        editorFeedback.PixelSize = () => 1 / Math.Max(0.05, canvas.CurrentZoom);
        editorFeedback.Added += () => { if (feedbackPane != null) feedbackPane.AddNote.IsChecked = false; editorFeedback.Placing = false; };
        canvas.ZoomChanged += () => Dispatcher.BeginInvoke(editorFeedback.Relayout, System.Windows.Threading.DispatcherPriority.Loaded);
        canvas.SizeChanged += (_, _) => editorFeedback.Relayout();
    }

    /// The deck's notes, read when a deck opens.
    void LoadFeedback()
    {
        HookFeedback();
        HideFeedbackPane();
        feedbackPane = null;
        feedback = workspace is { } ws ? new FeedbackStore(Path.Combine(ws.Work, "feedback.json"), File.Exists(Path.Combine(ws.Original, "feedback.json"))) : null;
        editorFeedback.Store = feedback;
        editorFeedback.Scene = null;
        WatchFeedbackCount();
    }

    /// The editor moved to another slide or build: its notes come along.
    void FeedbackPageChanged()
    {
        editorFeedback.Scene = sceneName;
        editorFeedback.Build = stopIndex;
        editorFeedback.Relayout();
    }

    string SlideLabel(string scene)
    {
        var i = state?.Scenes.FindIndex(s => s.Name == scene) ?? -1;
        return i >= 0 ? $"Slide {i + 1} · {scene}" : scene;
    }

    int SlideOrder(string scene) { var i = state?.Scenes.FindIndex(s => s.Name == scene) ?? -1; return i < 0 ? int.MaxValue : i; }

    void Feedback_Click(object sender, RoutedEventArgs e)
    {
        if (feedback == null) { Toast("Open a deck first", error: true); return; }
        if (feedbackPane == null)
        {
            feedbackPane = new FeedbackPane(feedback, SlideLabel, SlideOrder);
            feedbackPane.Closed += HideFeedbackPane;
            feedbackPane.Go += async n =>
            {
                if (sceneName != n.Scene) await SelectScene(n.Scene);
                if (sceneName == n.Scene) _ = Dispatcher.BeginInvoke(() => editorFeedback.Focus(n.Id), System.Windows.Threading.DispatcherPriority.Loaded);
            };
            feedbackPane.AddNote.Click += (_, _) => editorFeedback.Placing = feedbackPane.AddNote.IsChecked == true && sceneName != null;
        }
        HideScript();
        if (SourcePane.Visibility != Visibility.Visible) { ShowSourceItem.IsChecked = true; ToggleSource_Click(this, new RoutedEventArgs()); }
        PanelHost.Child = feedbackPane;
        PanelHost.Visibility = Visibility.Visible;
        feedbackPane.Reload();
    }

    void HideFeedbackPane()
    {
        editorFeedback.Placing = false;
        if (feedbackPane != null) feedbackPane.AddNote.IsChecked = false;
        if (PanelHost.Child == feedbackPane && feedbackPane != null) PanelHost.Visibility = Visibility.Collapsed;
    }
}
