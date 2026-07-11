using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Input;
using OpenDisplay.Windows.Infrastructure;
using OpenDisplay.Windows.Models;
using OpenDisplay.Windows.Services;

namespace OpenDisplay.Windows.ViewModels;

internal sealed class MainViewModel : ObservableObject, IDisposable
{
    private readonly ReceiverDiscovery _discovery;
    private readonly AdbDeviceWatcher _adbWatcher;
    private readonly IVirtualDisplayProvider _virtualDisplays;
    private readonly MonitorLocator _monitors;
    private readonly FfmpegLocator _ffmpeg;
    private readonly PreferencesStore _preferencesStore;
    private readonly Preferences _preferences;
    private readonly AsyncRelayCommand _connectCommand;
    private readonly RelayCommand _forgetManualCommand;
    private IReadOnlyList<ReceiverEndpoint> _wifiDevices = [];
    private IReadOnlyList<AdbDevice> _adbDevices = [];
    private ReceiverEndpoint? _selectedDevice;
    private string _manualHost = string.Empty;
    private CaptureMode _mode = CaptureMode.Extend;
    private StreamQuality _quality = StreamQuality.Best;
    private string _systemStatus = "Starting…";
    private bool _adbAvailable;

    public ObservableCollection<ReceiverEndpoint> Devices { get; } = [];
    public ObservableCollection<SessionViewModel> Sessions { get; } = [];
    public IReadOnlyList<CaptureMode> Modes { get; } = Enum.GetValues<CaptureMode>();
    public IReadOnlyList<StreamQuality> Qualities { get; } = Enum.GetValues<StreamQuality>();

    public ReceiverEndpoint? SelectedDevice
    {
        get => _selectedDevice;
        set
        {
            if (!SetProperty(ref _selectedDevice, value)) return;
            _connectCommand.RaiseCanExecuteChanged();
            _forgetManualCommand.RaiseCanExecuteChanged();
        }
    }

    public string ManualHost { get => _manualHost; set => SetProperty(ref _manualHost, value); }
    public CaptureMode Mode { get => _mode; set => SetProperty(ref _mode, value); }
    public StreamQuality Quality { get => _quality; set => SetProperty(ref _quality, value); }
    public string SystemStatus { get => _systemStatus; private set => SetProperty(ref _systemStatus, value); }
    public bool AdbAvailable { get => _adbAvailable; private set => SetProperty(ref _adbAvailable, value); }
    public Visibility AdbMissingVisibility => AdbAvailable ? Visibility.Collapsed : Visibility.Visible;
    public Visibility EmptySessionsVisibility => Sessions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

    public ICommand RefreshCommand { get; }
    public ICommand ConnectCommand => _connectCommand;
    public ICommand ConnectManualCommand { get; }
    public ICommand ForgetManualCommand => _forgetManualCommand;

    public MainViewModel(
        ReceiverDiscovery discovery,
        AdbDeviceWatcher adbWatcher,
        IVirtualDisplayProvider virtualDisplays,
        MonitorLocator monitors,
        FfmpegLocator ffmpeg,
        PreferencesStore preferencesStore)
    {
        _discovery = discovery;
        _adbWatcher = adbWatcher;
        _virtualDisplays = virtualDisplays;
        _monitors = monitors;
        _ffmpeg = ffmpeg;
        _preferencesStore = preferencesStore;
        _preferences = preferencesStore.Load();
        RefreshCommand = new AsyncRelayCommand(RefreshAsync);
        _connectCommand = new AsyncRelayCommand(ConnectSelectedAsync,
            () => SelectedDevice?.IsReady == true);
        ConnectManualCommand = new AsyncRelayCommand(ConnectManualAsync);
        _forgetManualCommand = new RelayCommand(ForgetSelectedManual,
            () => SelectedDevice?.Transport == ReceiverTransport.Manual);
        discovery.DevicesChanged += OnWifiDevicesChanged;
        discovery.Error += error => Dispatch(() => SystemStatus = error);
        adbWatcher.DevicesChanged += OnAdbDevicesChanged;
        Sessions.CollectionChanged += (_, _) => OnPropertyChanged(nameof(EmptySessionsVisibility));
    }

    public void Start()
    {
        _discovery.Start();
        _adbWatcher.Start();
        var encoder = _ffmpeg.Find();
        SystemStatus = encoder is null
            ? "FFmpeg not found. Put ffmpeg.exe beside OpenDisplay.exe, on PATH, or set OPENDISPLAY_FFMPEG."
            : $"Ready · encoder: {encoder} · virtual display: {_virtualDisplays.Name}";
        RebuildDevices();
    }

    private async Task RefreshAsync()
    {
        SystemStatus = "Searching for WiFi and ADB receivers…";
        await Task.WhenAll(_discovery.RefreshAsync(), _adbWatcher.RefreshAsync());
    }

    private async Task ConnectSelectedAsync()
    {
        if (SelectedDevice is not { IsReady: true } endpoint) return;
        if (endpoint.Transport == ReceiverTransport.Manual)
        {
            try { endpoint = await ManualEndpointParser.ParseAsync(endpoint.Name); }
            catch (Exception ex) when (ex is FormatException or System.Net.Sockets.SocketException or ArgumentException)
            {
                SystemStatus = $"Invalid receiver address: {ex.Message}";
                return;
            }
        }
        await ConnectEndpointAsync(endpoint);
    }

    private async Task ConnectManualAsync()
    {
        try
        {
            var endpoint = await ManualEndpointParser.ParseAsync(ManualHost);
            var parsed = ManualEndpointParser.ParseHostAndPort(ManualHost);
            _preferences.ManualEndpoints.Add(ManualEndpointParser.Format(parsed.Host, parsed.Port));
            _preferencesStore.Save(_preferences);
            RebuildDevices(endpoint.Id);
            await ConnectEndpointAsync(endpoint);
        }
        catch (Exception ex) when (ex is FormatException or System.Net.Sockets.SocketException or ArgumentException)
        {
            SystemStatus = $"Invalid receiver address: {ex.Message}";
        }
    }

    private Task ConnectEndpointAsync(ReceiverEndpoint endpoint)
    {
        if (Sessions.Any(session => session.TargetId == endpoint.Id)) return Task.CompletedTask;
        var executable = _ffmpeg.Find();
        if (executable is null)
        {
            SystemStatus = "Cannot connect: ffmpeg.exe was not found.";
            return Task.CompletedTask;
        }

        if (endpoint.Transport == ReceiverTransport.Adb && endpoint.AdbSerial is { } serial)
        {
            _preferences.DisabledAdbDevices.Remove(serial);
            _preferencesStore.Save(_preferences);
        }
        var session = new StreamingSession(endpoint, Mode, Quality,
            _virtualDisplays, _monitors, executable);
        var viewModel = new SessionViewModel(session);
        viewModel.DisconnectRequested += Disconnect;
        viewModel.Ended += EndSession;
        viewModel.HelloReceived += OnSessionHello;
        Sessions.Add(viewModel);
        SystemStatus = $"Starting {Mode.ToString().ToLowerInvariant()} session for {endpoint.Name} over {endpoint.TransportLabel}.";
        _ = viewModel.RunAsync();
        return Task.CompletedTask;
    }

    private void Disconnect(SessionViewModel session)
    {
        if (session.Transport == ReceiverTransport.Adb && session.AdbSerial is { } serial)
        {
            _preferences.DisabledAdbDevices.Add(serial);
            _preferencesStore.Save(_preferences);
        }
        EndSession(session);
        SystemStatus = $"Disconnected {session.Name}.";
    }

    private void EndSession(SessionViewModel session)
    {
        session.Stop();
        Sessions.Remove(session);
    }

    private void ForgetSelectedManual()
    {
        if (SelectedDevice is not { Transport: ReceiverTransport.Manual } endpoint) return;
        _preferences.ManualEndpoints.RemoveWhere(value =>
        {
            try
            {
                var parsed = ManualEndpointParser.ParseHostAndPort(value);
                return $"manual:{parsed.Host}:{parsed.Port}" == endpoint.Id;
            }
            catch (FormatException) { return false; }
        });
        _preferencesStore.Save(_preferences);
        RebuildDevices();
    }

    private void OnWifiDevicesChanged(IReadOnlyList<ReceiverEndpoint> devices) => Dispatch(() =>
    {
        _wifiDevices = devices;
        RebuildDevices();
    });

    private void OnAdbDevicesChanged(IReadOnlyList<AdbDevice> devices, bool available) => Dispatch(() =>
    {
        _adbDevices = devices;
        AdbAvailable = available;
        OnPropertyChanged(nameof(AdbMissingVisibility));
        RebuildDevices();
        foreach (var device in devices.Where(device => device.Ready &&
                     !_preferences.DisabledAdbDevices.Contains(device.Serial) &&
                     !HasSessionForAdbDevice(device.Serial)))
            _ = ConnectEndpointAsync(device.ToEndpoint());
    });

    private void OnSessionHello(SessionViewModel session, ReceiverHello hello)
    {
        if (hello.Id is not { Length: > 0 } receiverId) return;
        if (session.AdbSerial is { } serial)
        {
            _preferences.AdbReceiverIds[serial] = receiverId;
            _preferencesStore.Save(_preferences);
        }

        // The receiver accepts one sender. If discovery and ADB raced on a
        // first-time device, prefer the cable and retire the WiFi twin as soon
        // as both hello messages reveal the shared install id.
        var adbTwin = Sessions.FirstOrDefault(candidate =>
            candidate.Transport == ReceiverTransport.Adb && candidate.ReceiverId == receiverId);
        if (adbTwin is not null)
        {
            foreach (var wifiTwin in Sessions.Where(candidate =>
                         candidate.Transport == ReceiverTransport.Wifi &&
                         candidate.ReceiverId == receiverId).ToArray())
                EndSession(wifiTwin);
        }
        RebuildDevices();
    }

    private bool HasSessionForAdbDevice(string serial)
    {
        if (Sessions.Any(session => session.AdbSerial == serial)) return true;
        return _preferences.AdbReceiverIds.TryGetValue(serial, out var receiverId) &&
               Sessions.Any(session => session.ReceiverId == receiverId);
    }

    private void RebuildDevices(string? selectId = null)
    {
        var previous = selectId ?? SelectedDevice?.Id;
        var combined = new List<ReceiverEndpoint>();
        combined.AddRange(_adbDevices.Select(device => device.ToEndpoint()));
        var adbReceiverIds = _adbDevices
            .Select(device => _preferences.AdbReceiverIds.GetValueOrDefault(device.Serial))
            .Where(id => id is not null)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        combined.AddRange(_wifiDevices.Where(device =>
            device.ReceiverId is null || !adbReceiverIds.Contains(device.ReceiverId)));
        foreach (var value in _preferences.ManualEndpoints.OrderBy(value => value))
        {
            try
            {
                var (host, port) = ManualEndpointParser.ParseHostAndPort(value);
                var address = System.Net.IPAddress.TryParse(host, out var parsed)
                    ? parsed : System.Net.IPAddress.None;
                combined.Add(new ReceiverEndpoint($"manual:{host}:{port}", ManualEndpointParser.Format(host, port),
                    address, port, Transport: ReceiverTransport.Manual));
            }
            catch (FormatException) { }
        }

        Devices.Clear();
        foreach (var device in combined.DistinctBy(device => device.Id)) Devices.Add(device);
        SelectedDevice = Devices.FirstOrDefault(device => device.Id == previous) ?? Devices.FirstOrDefault();
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
        _adbWatcher.Dispose();
    }
}
