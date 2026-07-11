using System.Windows;
using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Services;
using OpenDisplay.Windows.ViewModels;

namespace OpenDisplay.Windows;

public partial class App : System.Windows.Application
{
    private const string InstanceMutexName = @"Local\OpenDisplay.Windows.SingleInstance";
    private const string ActivationEventName = @"Local\OpenDisplay.Windows.Activate";
    private ReceiverDiscovery? _discovery;
    private TrayIconService? _trayIcon;
    private Mutex? _instanceMutex;
    private EventWaitHandle? _activationEvent;
    private CancellationTokenSource? _activationLifetime;
    private Task? _activationListener;
    private bool _ownsInstanceMutex;
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
            if (!ClaimSingleInstance())
            {
                Log.Info("Another OpenDisplay instance is already running; requesting activation");
                _activationEvent?.Set();
                Shutdown();
                return;
            }

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
            StartActivationListener();
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
        _activationLifetime?.Cancel();
        try { _activationListener?.Wait(TimeSpan.FromSeconds(1)); }
        catch (AggregateException) { }
        _activationListener = null;
        _activationLifetime?.Dispose();
        _activationLifetime = null;
        _activationEvent?.Dispose();
        _activationEvent = null;
        if (_ownsInstanceMutex)
        {
            try { _instanceMutex?.ReleaseMutex(); }
            catch (ApplicationException) { }
        }
        _instanceMutex?.Dispose();
        _instanceMutex = null;

        if (MainWindow?.DataContext is MainViewModel viewModel)
            viewModel.Dispose();
        _trayIcon?.Dispose();
        _trayIcon = null;
        _discovery?.Dispose();
        Log.Info($"Application exiting with code {e.ApplicationExitCode}");
        base.OnExit(e);
        Log.Close();
    }

    private bool ClaimSingleInstance()
    {
        _activationEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ActivationEventName);
        _instanceMutex = new Mutex(false, InstanceMutexName);
        try { _ownsInstanceMutex = _instanceMutex.WaitOne(0, false); }
        catch (AbandonedMutexException) { _ownsInstanceMutex = true; }
        return _ownsInstanceMutex;
    }

    private void StartActivationListener()
    {
        var activationEvent = _activationEvent;
        if (activationEvent is null) return;
        _activationLifetime = new CancellationTokenSource();
        var cancellationToken = _activationLifetime.Token;
        _activationListener = Task.Run(() =>
        {
            var handles = new WaitHandle[] { activationEvent, cancellationToken.WaitHandle };
            while (!cancellationToken.IsCancellationRequested)
            {
                if (WaitHandle.WaitAny(handles) != 0) return;
                Dispatcher.BeginInvoke(() =>
                {
                    if (MainWindow is MainWindow window) window.RestoreFromTray();
                });
            }
        }, cancellationToken);
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
