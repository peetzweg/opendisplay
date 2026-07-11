using System.Collections.ObjectModel;
using System.Net;
using System.Windows;
using System.Windows.Input;
using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Models;
using OpenDisplay.Windows.Services;

namespace OpenDisplay.Windows.ViewModels;

internal sealed class MainViewModel : ObservableObject, IDisposable
{
    private readonly ReceiverDiscovery _discovery;
    private readonly IVirtualDisplayProvider _virtualDisplays;
    private readonly MonitorLocator _monitors;
    private readonly FfmpegLocator _ffmpeg;
    private ReceiverEndpoint? _selectedDevice;
    private string _manualHost = "127.0.0.1:9000";
    private CaptureMode _mode = CaptureMode.Extend;
    private StreamQuality _quality = StreamQuality.Best;
    private string _systemStatus = "Starting…";

    public ObservableCollection<ReceiverEndpoint> Devices { get; } = [];
    public ObservableCollection<SessionViewModel> Sessions { get; } = [];
    public IReadOnlyList<CaptureMode> Modes { get; } = Enum.GetValues<CaptureMode>();
    public IReadOnlyList<StreamQuality> Qualities { get; } = Enum.GetValues<StreamQuality>();

    public ReceiverEndpoint? SelectedDevice
    {
        get => _selectedDevice;
        set => SetProperty(ref _selectedDevice, value);
    }

    public string ManualHost { get => _manualHost; set => SetProperty(ref _manualHost, value); }
    public CaptureMode Mode { get => _mode; set => SetProperty(ref _mode, value); }
    public StreamQuality Quality { get => _quality; set => SetProperty(ref _quality, value); }
    public string SystemStatus { get => _systemStatus; private set => SetProperty(ref _systemStatus, value); }
    public Visibility EmptySessionsVisibility => Sessions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    public ICommand RefreshCommand { get; }
    public ICommand ConnectCommand { get; }

    public MainViewModel(
        ReceiverDiscovery discovery,
        IVirtualDisplayProvider virtualDisplays,
        MonitorLocator monitors,
        FfmpegLocator ffmpeg)
    {
        _discovery = discovery;
        _virtualDisplays = virtualDisplays;
        _monitors = monitors;
        _ffmpeg = ffmpeg;
        RefreshCommand = new AsyncRelayCommand(RefreshAsync);
        ConnectCommand = new AsyncRelayCommand(ConnectAsync);
        discovery.DevicesChanged += ReplaceDevices;
        discovery.Error += error => Dispatch(() => SystemStatus = error);
        Sessions.CollectionChanged += (_, _) => OnPropertyChanged(nameof(EmptySessionsVisibility));
    }

    public void Start()
    {
        _discovery.Start();
        var encoder = _ffmpeg.Find();
        SystemStatus = encoder is null
            ? "FFmpeg not found. Put ffmpeg.exe beside OpenDisplay.exe, on PATH, or set OPENDISPLAY_FFMPEG."
            : $"Ready · encoder: {encoder} · virtual display: {_virtualDisplays.Name}";
    }

    private async Task RefreshAsync()
    {
        SystemStatus = "Searching for receivers…";
        await _discovery.RefreshAsync();
    }

    private Task ConnectAsync()
    {
        var executable = _ffmpeg.Find();
        if (executable is null)
        {
            SystemStatus = "Cannot connect: ffmpeg.exe was not found.";
            return Task.CompletedTask;
        }

        ReceiverEndpoint endpoint;
        try { endpoint = SelectedDevice ?? ParseManualEndpoint(ManualHost); }
        catch (Exception ex)
        {
            SystemStatus = $"Invalid receiver address: {ex.Message}";
            return Task.CompletedTask;
        }

        var session = new StreamingSession(endpoint, Mode, Quality,
            _virtualDisplays, _monitors, executable);
        var viewModel = new SessionViewModel(session);
        viewModel.DisconnectRequested += Disconnect;
        Sessions.Add(viewModel);
        SystemStatus = $"Starting {Mode.ToString().ToLowerInvariant()} session for {endpoint.Name}.";
        _ = viewModel.RunAsync();
        return Task.CompletedTask;
    }

    private void Disconnect(SessionViewModel session)
    {
        session.Stop();
        Sessions.Remove(session);
        SystemStatus = $"Disconnected {session.Name}.";
    }

    private void ReplaceDevices(IReadOnlyList<ReceiverEndpoint> devices) => Dispatch(() =>
    {
        var previous = SelectedDevice?.Id;
        Devices.Clear();
        foreach (var device in devices) Devices.Add(device);
        SelectedDevice = Devices.FirstOrDefault(x => x.Id == previous) ?? Devices.FirstOrDefault();
        SystemStatus = Devices.Count == 0
            ? "No WiFi receivers found; enter an address manually or open the receiver app."
            : $"Found {Devices.Count} receiver{(Devices.Count == 1 ? string.Empty : "s")}.";
    });

    private static ReceiverEndpoint ParseManualEndpoint(string value)
    {
        var text = value.Trim();
        var separator = text.LastIndexOf(':');
        var host = separator > 0 ? text[..separator] : text;
        var port = separator > 0 ? int.Parse(text[(separator + 1)..]) : 9000;
        if (port is < 1 or > 65535) throw new ArgumentOutOfRangeException(nameof(value), "Port must be 1–65535.");
        if (!IPAddress.TryParse(host.Trim('[', ']'), out var address))
        {
            var addresses = Dns.GetHostAddresses(host);
            address = addresses.FirstOrDefault(x => x.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                ?? addresses.First();
        }
        return new ReceiverEndpoint($"manual:{host}:{port}", host, address, port);
    }

    private static void Dispatch(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher is null || dispatcher.CheckAccess()) action();
        else dispatcher.BeginInvoke(action);
    }

    public void Dispose()
    {
        foreach (var session in Sessions.ToArray()) session.Stop();
        Sessions.Clear();
    }
}
