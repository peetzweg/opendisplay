using System.Windows;
using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Services;
using OpenDisplay.Windows.ViewModels;

namespace OpenDisplay.Windows;

public partial class App : System.Windows.Application
{
    private ReceiverDiscovery? _discovery;
    private TrayIconService? _trayIcon;
    private bool _exitRequested;

    public App()
    {
        Log.Initialize();
        DispatcherUnhandledException += (_, eventArgs) =>
        {
            Log.Error("Unhandled UI exception", eventArgs.Exception);
            eventArgs.Handled = true;
            ShowFatalError(eventArgs.Exception);
            if (MainWindow is MainWindow window) window.AllowClose = true;
            Shutdown(-1);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, eventArgs) =>
            Log.Error("Unhandled process exception", eventArgs.ExceptionObject as Exception);
        TaskScheduler.UnobservedTaskException += (_, eventArgs) =>
        {
            Log.Error("Unobserved background task exception", eventArgs.Exception);
            eventArgs.SetObserved();
        };
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        try
        {
            base.OnStartup(e);
            Log.Info($"Starting OpenDisplay {typeof(App).Assembly.GetName().Version}");
            Log.Info($"Runtime: {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}; " +
                     $"OS: {System.Runtime.InteropServices.RuntimeInformation.OSDescription}; " +
                     $"Architecture: {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}");
            Log.Info($"Executable directory: {AppContext.BaseDirectory}; working directory: {Environment.CurrentDirectory}");

            _discovery = new ReceiverDiscovery();
            var adbLocator = new AdbLocator();
            var adbWatcher = new AdbDeviceWatcher(adbLocator);
            var monitors = new MonitorLocator();
            var ffmpeg = new FfmpegLocator();
            var vddPipe = new VddPipeClient();
            var viewModel = new MainViewModel(
                _discovery,
                adbWatcher,
                new VddVirtualDisplayProvider(monitors),
                monitors,
                ffmpeg,
                new PreferencesStore(),
                new DependencyDiagnostics(_discovery, ffmpeg, adbLocator, vddPipe, monitors));

            var window = new MainWindow { DataContext = viewModel };
            MainWindow = window;
            _trayIcon = new TrayIconService(window, ExitApplication);
            window.Show();
            viewModel.Start();
        }
        catch (Exception ex)
        {
            Log.Error("Application startup failed", ex);
            ShowFatalError(ex);
            Shutdown(-1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (MainWindow?.DataContext is MainViewModel viewModel)
            viewModel.Dispose();
        _trayIcon?.Dispose();
        _trayIcon = null;
        _discovery?.Dispose();
        Log.Info($"Application exiting with code {e.ApplicationExitCode}");
        base.OnExit(e);
        Log.Close();
    }

    private void ExitApplication()
    {
        if (_exitRequested) return;
        _exitRequested = true;
        Log.Info("Exit requested from notification area");
        _trayIcon?.Dispose();
        _trayIcon = null;
        if (MainWindow is MainWindow window)
        {
            window.AllowClose = true;
            window.Close();
        }
        Shutdown();
    }

    private static void ShowFatalError(Exception exception)
    {
        var log = Log.FilePath.Length > 0 ? Log.FilePath : "no log file could be created";
        try
        {
            System.Windows.MessageBox.Show(
                $"OpenDisplay encountered an unexpected error and must close.\n\n" +
                $"{exception.Message}\n\nLog: {log}",
                "OpenDisplay error", System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Error);
        }
        catch { }
    }
}
