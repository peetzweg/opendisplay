using System.Windows;
using OpenDisplay.Windows.Services;
using OpenDisplay.Windows.ViewModels;

namespace OpenDisplay.Windows;

public partial class App : Application
{
    private ReceiverDiscovery? _discovery;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _discovery = new ReceiverDiscovery();
        var viewModel = new MainViewModel(
            _discovery,
            new VddVirtualDisplayProvider(new MonitorLocator()),
            new MonitorLocator(),
            new FfmpegLocator());

        var window = new MainWindow { DataContext = viewModel };
        MainWindow = window;
        window.Show();
        viewModel.Start();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (MainWindow?.DataContext is MainViewModel viewModel)
            viewModel.Dispose();
        _discovery?.Dispose();
        base.OnExit(e);
    }
}
