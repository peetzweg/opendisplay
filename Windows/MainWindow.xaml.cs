using System.Windows;
using System.ComponentModel;

namespace OpenDisplay.Windows;

public partial class MainWindow : System.Windows.Window
{
    public MainWindow() => InitializeComponent();

    internal bool AllowClose { get; set; }
    internal event EventHandler? HiddenToTray;

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!AllowClose)
        {
            e.Cancel = true;
            HideToTray();
            return;
        }
        base.OnClosing(e);
    }

    protected override void OnStateChanged(EventArgs e)
    {
        base.OnStateChanged(e);
        if (WindowState == WindowState.Minimized) HideToTray();
    }

    private void HideToTray()
    {
        Hide();
        HiddenToTray?.Invoke(this, EventArgs.Empty);
    }

    internal void RestoreFromTray()
    {
        Show();
        WindowState = WindowState.Normal;
        Activate();
        Topmost = true;
        Topmost = false;
        Focus();
    }

    private void ExitButton_Click(object sender, RoutedEventArgs e) =>
        ((App)System.Windows.Application.Current).ExitApplication();
}
