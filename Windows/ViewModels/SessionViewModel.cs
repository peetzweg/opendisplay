using System.Windows;
using System.Windows.Input;
using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Services;

namespace OpenDisplay.Windows.ViewModels;

internal sealed class SessionViewModel : ObservableObject
{
    private readonly StreamingSession _session;
    private string _status = "Starting…";
    private long _framesSent;
    private double _megabitsPerSecond;

    public string Id => _session.Id;
    public string Name => _session.Name;
    public string Status { get => _status; private set => SetProperty(ref _status, value); }
    public long FramesSent { get => _framesSent; private set => SetProperty(ref _framesSent, value); }
    public double MegabitsPerSecond { get => _megabitsPerSecond; private set => SetProperty(ref _megabitsPerSecond, value); }
    public ICommand DisconnectCommand { get; }
    public event Action<SessionViewModel>? DisconnectRequested;

    public SessionViewModel(StreamingSession session)
    {
        _session = session;
        DisconnectCommand = new RelayCommand(() => DisconnectRequested?.Invoke(this));
        session.StatusChanged += status => Dispatch(() => Status = status);
        session.StatsChanged += (frames, mbps) => Dispatch(() =>
        {
            FramesSent = frames;
            MegabitsPerSecond = mbps;
        });
    }

    public Task RunAsync() => _session.RunAsync();
    public void Stop() => _session.Stop();

    private static void Dispatch(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) action();
        else dispatcher.BeginInvoke(action);
    }
}
