using System.Drawing;
using System.Windows.Forms;

namespace OpenDisplay.Windows.Infrastructure;

internal sealed class TrayIconService : IDisposable
{
    private readonly MainWindow _window;
    private readonly NotifyIcon _notifyIcon;
    private readonly ContextMenuStrip _menu;
    private readonly Icon _icon;
    private bool _disposed;
    private bool _balloonShown;

    public TrayIconService(MainWindow window, Action exit)
    {
        _window = window;
        _icon = LoadIcon();
        _menu = new ContextMenuStrip();

        var openItem = new ToolStripMenuItem("Open OpenDisplay") { Font = new Font(SystemFonts.MenuFont, FontStyle.Bold) };
        openItem.Click += (_, _) => RestoreWindow();
        var exitItem = new ToolStripMenuItem("Exit");
        exitItem.Click += (_, _) => _window.Dispatcher.BeginInvoke(exit);
        _menu.Items.Add(openItem);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(exitItem);

        _notifyIcon = new NotifyIcon
        {
            Icon = _icon,
            Text = "OpenDisplay",
            ContextMenuStrip = _menu,
            Visible = true
        };
        _notifyIcon.DoubleClick += (_, _) => RestoreWindow();
        _notifyIcon.MouseClick += (_, args) =>
        {
            if (args.Button == MouseButtons.Left) RestoreWindow();
        };
        window.HiddenToTray += (_, _) =>
        {
            Log.Info("Control window hidden to notification area");
            if (_balloonShown) return;
            _balloonShown = true;
            _notifyIcon.ShowBalloonTip(1800, "OpenDisplay",
                "OpenDisplay is still running. Click the tray icon to reopen it.", ToolTipIcon.Info);
        };
    }

    private void RestoreWindow() => _window.Dispatcher.BeginInvoke(() =>
    {
        if (_disposed) return;
        _window.RestoreFromTray();
        Log.Info("Control window restored from notification area");
    });

    private static Icon LoadIcon()
    {
        try
        {
            if (Environment.ProcessPath is { } executable &&
                Icon.ExtractAssociatedIcon(executable) is { } icon)
                return icon;
        }
        catch (Exception ex) { Log.Warn($"Could not load application icon: {ex.Message}"); }
        return (Icon)SystemIcons.Application.Clone();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _menu.Dispose();
        _icon.Dispose();
    }
}
