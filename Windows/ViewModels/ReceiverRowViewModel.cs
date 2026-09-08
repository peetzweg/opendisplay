using System.ComponentModel;
using System.Windows.Input;
using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Models;
using MediaBrush = System.Windows.Media.Brush;
using MediaBrushes = System.Windows.Media.Brushes;

namespace OpenDisplay.Windows.ViewModels;

/// <summary>
/// A receiver and, when connected, its session in the same list row.
/// </summary>
internal sealed class ReceiverRowViewModel : ObservableObject, IDisposable
{
    private ReceiverEndpoint _endpoint;
    private SessionViewModel? _session;

    public ReceiverRowViewModel(ReceiverEndpoint endpoint, Action<ReceiverRowViewModel> action)
    {
        _endpoint = endpoint;
        ActionCommand = new RelayCommand(() => action(this));
    }

    public string Id => _endpoint.Id;
    public ReceiverEndpoint Endpoint => _endpoint;
    public string Name => _endpoint.Name;
    public string TransportLabel => _endpoint.TransportLabel;
    public bool IsReady => _endpoint.IsReady;
    public SessionViewModel? Session => _session;
    public bool CanToggle => _session is not null || IsReady;
    public string Status => _session?.Status ?? (IsReady ? "Available" : "Unavailable");
    public string Activity => _session is null
        ? TransportLabel
        : $"{_session.FramesSent} frames / {_session.MegabitsPerSecond:F1} Mbps";
    public string ActionLabel => _session is null ? "Connect" : "Disconnect";
    public MediaBrush StatusBrush => _session?.StatusBrush ??
        (IsReady ? MediaBrushes.Gray : MediaBrushes.IndianRed);
    public ICommand ActionCommand { get; }

    public void Update(ReceiverEndpoint endpoint, SessionViewModel? session)
    {
        var endpointChanged = _endpoint != endpoint;
        if (endpointChanged) _endpoint = endpoint;
        SetSession(session);
        if (!endpointChanged) return;
        OnPropertyChanged(nameof(Endpoint));
        OnPropertyChanged(nameof(Name));
        OnPropertyChanged(nameof(TransportLabel));
        OnPropertyChanged(nameof(IsReady));
        OnPropertyChanged(nameof(CanToggle));
        OnPropertyChanged(nameof(Status));
        OnPropertyChanged(nameof(Activity));
        OnPropertyChanged(nameof(StatusBrush));
    }

    private void SetSession(SessionViewModel? session)
    {
        if (ReferenceEquals(_session, session)) return;
        if (_session is not null) _session.PropertyChanged -= OnSessionPropertyChanged;
        _session = session;
        if (_session is not null) _session.PropertyChanged += OnSessionPropertyChanged;
        OnPropertyChanged(nameof(Session));
        OnPropertyChanged(nameof(CanToggle));
        OnPropertyChanged(nameof(Status));
        OnPropertyChanged(nameof(Activity));
        OnPropertyChanged(nameof(ActionLabel));
        OnPropertyChanged(nameof(StatusBrush));
    }

    private void OnSessionPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(SessionViewModel.Status) or nameof(SessionViewModel.StatusBrush))
        {
            OnPropertyChanged(nameof(Status));
            OnPropertyChanged(nameof(StatusBrush));
        }
        if (e.PropertyName is nameof(SessionViewModel.FramesSent) or nameof(SessionViewModel.MegabitsPerSecond))
            OnPropertyChanged(nameof(Activity));
    }

    public void Dispose()
    {
        if (_session is not null) _session.PropertyChanged -= OnSessionPropertyChanged;
    }
}
