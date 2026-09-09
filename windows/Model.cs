using Microsoft.Toolkit.Uwp.Notifications;
using NAudio.CoreAudioApi;
using SharpAdbClient;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using DeviceState = NAudio.CoreAudioApi.DeviceState;
using NamePair = System.Collections.Generic.KeyValuePair<string, string>;
using SampleRatePair = System.Collections.Generic.KeyValuePair<int, string>;

namespace AudioShare
{
    public class Model : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        private readonly Settings _settings = Settings.Load();

        private readonly Dispatcher _dispatcher;
        private readonly DispatcherTimer _heartBeatTimer;
        private UdpClient _udpListener;
        private CancellationTokenSource _audioChangeSyncCancel;
        public Model()
        {
            _dispatcher = Dispatcher.CurrentDispatcher;
            AudioManager.OnVolumeNotification += OnVolumeChanged;
            AudioManager.OnAudioResumed += OnAudioResumed;
            ToastNotificationManagerCompat.OnActivated += OnToastActivated;
            ConnectUdp();
            _heartBeatTimer = new DispatcherTimer();
            _heartBeatTimer.Tick += SendHeartbeat;
            _heartBeatTimer.Interval = TimeSpan.FromSeconds(5);
            _heartBeatTimer.IsEnabled = true;
            _heartBeatTimer.Start();
        }

        private void SendHeartbeat(object sender, EventArgs e)
        {
            foreach (var item in Speakers)
            {
                if(item.Connected)
                {
                    item.SendHeartbeat();
                }
            }
        }

        private async void OnAudioResumed(object sender, EventArgs e)
        {
            var connected = Speakers.Where(s => s.Connected).ToList();
            if (connected.Count < 2) return;
            _audioChangeSyncCancel?.Cancel();
            _audioChangeSyncCancel = new CancellationTokenSource();
            var token = _audioChangeSyncCancel.Token;
            try
            {
                await Task.Delay(2000, token);
                if (!token.IsCancellationRequested)
                {
                    Logger.Info("Audio resumed, syncing devices...");
                    await MeasureAndSyncDevices(Speakers.Where(s => s.Connected).ToList());
                }
            }
            catch (TaskCanceledException) { }
        }

        private const int SyncHysteresisMs = 15;

        private async Task MeasureAndSyncDevices(List<Speaker> devices, bool applyNow = false)
        {
            await Task.WhenAll(devices.Select(s => s.MeasureLatencyAsync()));
            var validDevices = devices.Where(s => s.LastRTT > 0).ToList();
            if (validDevices.Count < 2) return;
            int maxRTT = validDevices.Max(s => s.LastRTT);
            foreach (var speaker in validDevices)
            {
                int delayMs = maxRTT - speaker.LastRTT;
                // Measurement noise must not trigger a retune on every track change;
                // only significant shifts are sent, and automatic ones take effect at
                // the next track when each device rebuilds its delay backlog.
                if (Math.Abs(delayMs - speaker.LastSentDelay) >= SyncHysteresisMs)
                {
                    await speaker.SetDelay(delayMs, applyNow);
                    speaker.LastSentDelay = delayMs;
                }
            }
            Logger.Info($"Multi-device sync: maxRTT={maxRTT}ms, devices={validDevices.Count}, applyNow={applyNow}");
        }

        private void OnToastActivated(ToastNotificationActivatedEventArgsCompat e)
        {
            var speaker = Speakers.FirstOrDefault(m => m.UnConnected && m.Id == e.Argument);
            if (speaker != null)
            {
                _ = speaker.Connect();
            }
        }

        private async void ConnectUdp()
        {
            for (int i = 58261; i < 58271; i++)
            {
                try
                {
                    _udpListener = new UdpClient(i);
                    _udpListener.EnableBroadcast = true;
                    break;
                }
                catch (Exception)
                {
                }
            }
            if (_udpListener == null) return;
            SearchSpeakers(null);
            while (true)
            {
                UdpReceiveResult result;
                try
                {
                    result = await _udpListener.ReceiveAsync();
                }
                catch (Exception ex)
                {
                    // Network adapter changes reset the socket; keep listening.
                    Logger.Error("udp receive error: " + ex.Message);
                    if (_udpListener == null) return;
                    continue;
                }
                string message = Encoding.UTF8.GetString(result.Buffer);
                var messages = message.Split('@');
                if (messages.Length < 2 || messages[0] != "picapico-audio-share") continue;
                if (int.TryParse(messages[1], out int port) && port > 0 && port < 65535)
                {
                    Logger.Info("Received message " + result.RemoteEndPoint.Address.ToString());
                    await _dispatcher.InvokeAsync(() =>
                    {
                        AddIPSpeaker(result.RemoteEndPoint.Address.ToString(), port);
                    });
                }
            }
        }

        private static readonly byte[] _discoverProbe = Encoding.UTF8.GetBytes("picapico-audio-share-find");

        private async void SearchSpeakers(object sender)
        {
            if (_udpListener == null) return;
            Logger.Info("search speakers start");
            try
            {
                for (int repeat = 0; repeat < 3; repeat++)
                {
                    for (int port = 58261; port <= 58270; port++)
                    {
                        await _udpListener.SendAsync(_discoverProbe, _discoverProbe.Length, "255.255.255.255", port);
                    }
                    await Task.Delay(300);
                }
            }
            catch (Exception ex)
            {
                Logger.Error("search speakers error: " + ex.Message);
            }
            Logger.Info("search speakers end");
        }

        private void OnVolumeChanged(object sender, int volume)
        {
            // Volume notifications arrive on a threadpool thread; the Volume setter
            // touches the Speakers collection and must run on the UI thread.
            _dispatcher.InvokeAsync(() =>
            {
                if (VolumeFollowSystem) Volume = volume;
            });
        }

        private readonly List<MMDevice> _audioDevices = new List<MMDevice>();
        public ObservableCollection<NamePair> AudioDevices { get; private set; } = new ObservableCollection<NamePair>();
        public ObservableCollection<Speaker> Speakers { get; private set; } = new ObservableCollection<Speaker>();
        public ObservableCollection<SampleRatePair> SampleRates => new ObservableCollection<SampleRatePair>()
        {
            new SampleRatePair(192000, "192kHz"),
            new SampleRatePair(176400, "176.4kHz"),
            new SampleRatePair(96000, "96kHz"),
            new SampleRatePair(48000, "48kHz"),
            new SampleRatePair(44100, "44.1kHz"),
            new SampleRatePair(16000, "16kHz"),
            new SampleRatePair(8000, "8kHz"),
        };
        public ImageSource Icon => Utils.AppIcon;
        public string Title => Languages.Language.GetLanguageText("title") + " " + Utils.VersionName;
        public void UpdateTitle()
        {
            OnPropertyChanged(nameof(Title));
        }
        public bool IsStartup
        {
            get => IsStartupEnabled();
            set
            {
                SetStartup(value);
            }
        }
        private int _connectedCount = 0;
        public bool Connected => _connectedCount > 0;
        public bool AudioEnabled => _connectedCount <= 0 && _connectingCount <= 0;
        public bool UnConnected => _connectedCount <= 0;
        public int ConnectedCount
        {
            get => _connectedCount;
            set
            {
                _connectedCount = value;
                OnPropertyChanged(nameof(ConnectedCount));
                OnPropertyChanged(nameof(Connected));
                OnPropertyChanged(nameof(UnConnected));
                OnPropertyChanged(nameof(AudioEnabled));
            }
        }
        private int _connectingCount = 0;
        public int ConnectingCount
        {
            get => _connectingCount;
            set
            {
                _connectingCount = value;
                OnPropertyChanged(nameof(AudioEnabled));
            }
        }
        public NamePair AudioSelected
        {
            get => AudioDevices.FirstOrDefault(m => m.Key == _settings.AudioId);
            set
            {
                _settings.AudioId = value.Key;
                var mDevice = _audioDevices.FirstOrDefault(m => m.ID == _settings.AudioId);
                if (VolumeFollowSystem)
                {
                    try
                    {
                        Volume = mDevice.AudioEndpointVolume.Mute ? 0 : (int)(mDevice.AudioEndpointVolume.MasterVolumeLevelScalar * 100);
                    }
                    catch (Exception)
                    {
                    }
                }
                Stop();
                AudioManager.SetDevice(mDevice, _settings.SampleRate);
                OnPropertyChanged(nameof(AudioSelected));
            }
        }
        public SampleRatePair SampleRate
        {
            get => SampleRates.FirstOrDefault(m => m.Key == _settings.SampleRate);
            set
            {
                _settings.SampleRate = value.Key;
                var mDevice = _audioDevices.FirstOrDefault(m => m.ID == _settings.AudioId);
                Stop();
                AudioManager.SetDevice(mDevice, _settings.SampleRate);
            }
        }
        public int Volume
        {
            get => _settings.Volume;
            set
            {
                if(_settings.Volume == value) return;
                _settings.Volume = value;
                OnPropertyChanged(nameof(Volume));
                foreach (var speaker in Speakers)
                {
                    if (speaker.Connected)
                    {
                        speaker.SetVolume(value);
                    }
                }
            }
        }
        private bool _adbLoading = false;
        public bool AdbLoading
        {
            get => _adbLoading;
            set
            {
                _adbLoading = value;
                OnPropertyChanged(nameof(AdbLoading));
            }
        }
        public bool IsIP => !_settings.IsUSB;
        public bool IsUSB
        {
            get => _settings.IsUSB;
            set
            {
                if (_settings.IsUSB == value) return;
                ResetSpeakerSetting();
                _settings.IsUSB = value;
                if (value && string.IsNullOrWhiteSpace(Utils.FindAdbPath()))
                {
                    _settings.IsUSB = false;
                    MessageBox.Show(Application.Current.MainWindow, Languages.Language.GetLanguageText("adbMisMatch"),
                        Application.Current.MainWindow.Title);
                }
                else
                {
                    _ = RefreshSpeakers();
                }
                OnPropertyChanged(nameof(IsUSB));
                OnPropertyChanged(nameof(IsIP));
                OnPropertyChanged(nameof(AddIPSpeakerVisible));
            }
        }
        private bool _addIPSpeakerVisible = true;
        public bool AddIPSpeakerVisible
        {
            get => _addIPSpeakerVisible && IsIP;
            set
            {
                _addIPSpeakerVisible = value;
                OnPropertyChanged(nameof(AddIPSpeakerVisible));
            }
        }
        public bool VolumeFollowSystem
        {
            get => _settings.VolumeFollowSystem;
            set
            {
                _settings.VolumeFollowSystem = value;
                if (value)
                {
                    var mDevice = _audioDevices.FirstOrDefault(m => m.ID == _settings.AudioId);
                    if (VolumeFollowSystem)
                    {
                        try
                        {
                            Volume = mDevice.AudioEndpointVolume.Mute ? 0 : (int)(mDevice.AudioEndpointVolume.MasterVolumeLevelScalar * 100);
                        }
                        catch (Exception)
                        {
                        }
                    }
                }
                OnPropertyChanged(nameof(VolumeCustom));
            }
        }
        public bool VolumeCustom => !_settings.VolumeFollowSystem;

        public bool AcrylicVisible => Utils.IsAcrylicSupported;

        public bool Acrylic
        {
            get => _settings.Acrylic;
            set
            {
                _settings.Acrylic = value;
                OnPropertyChanged(nameof(Acrylic));
                _settings.Save();
            }
        }

        public RelayCommand RefreshAudiosCommand => new RelayCommand(RefreshAudios, CanRefreshAudios);

        public RelayCommand RefreshSpeakersCommand => new RelayCommand(RefreshSpeakers, CanRefreshSpeakers);

        public RelayCommand AddIPSpeakerCommand => new RelayCommand(AddIPSpeaker, CanAddIPSpeaker);

        public RelayCommand SearchSpeakersCommand => new RelayCommand(SearchSpeakers, CanSearchSpeakers);

        public RelayCommand ConnectAllCommand => new RelayCommand(ConnectAll, CanConnectAll);

        public RelayCommand DisconnectAllCommand => new RelayCommand(DisconnectAll, CanDisconnectAll);

        public RelayCommand SyncDevicesCommand => new RelayCommand(SyncDevices, CanSyncDevices);

        public bool AutoConnect
        {
            get => _settings.AutoConnect;
            set
            {
                _settings.AutoConnect = value;
                _settings.Save();
                OnPropertyChanged(nameof(AutoConnect));
            }
        }

        private bool CanConnectAll(object sender)
        {
            return Speakers.Any(s => s.UnConnected);
        }

        private bool CanDisconnectAll(object sender)
        {
            return Speakers.Any(s => s.Connected || s.Connecting);
        }

        private async void ConnectAll(object sender)
        {
            foreach (var speaker in Speakers.Where(s => s.UnConnected).ToList())
            {
                _ = speaker.Connect();
                await Task.Delay(200);
            }
        }

        private async void DisconnectAll(object sender)
        {
            foreach (var speaker in Speakers.Where(s => s.Connected || s.Connecting).ToList())
            {
                speaker.DisConnectCommand.Execute(null);
                await Task.Delay(100);
            }
        }

        private bool CanSyncDevices(object sender)
        {
            return Speakers.Count(s => s.Connected) >= 2;
        }

        private async void SyncDevices(object sender)
        {
            var connected = Speakers.Where(s => s.Connected).ToList();
            if (connected.Count >= 2)
            {
                await MeasureAndSyncDevices(connected, applyNow: true);
            }
        }

        public void RefreshAudios()
        {
            RefreshAudios(null);
        }

        public void Stop()
        {
            foreach (var speaker in Speakers)
            {
                speaker.Dispose();
            }
        }

        readonly AdbClient _adbClient = new AdbClient();
        public async Task RefreshSpeakers()
        {
            var connectedSpeakers = Speakers.Where(speaker => speaker.Connected).ToList();
            if (IsUSB)
            {
                string adbPath = Utils.FindAdbPath();
                if (string.IsNullOrWhiteSpace(adbPath))
                {
                    IsUSB = false;
                    Stop();
                    return;
                }
                AdbLoading = true;
                await Utils.RunCommandAsync(adbPath, "start-server");
                await Utils.RunCommandAsync(adbPath, "devices");
                var devices = _adbClient.GetDevices();
                Speakers.Clear();
                devices.Sort((a, b) => a.Name.CompareTo(b.Name));
                foreach (var item in devices)
                {
                    if (item.State != SharpAdbClient.DeviceState.Online) continue;
                    var connectedSpeaker = connectedSpeakers.FirstOrDefault(m => m.Id == item.Serial);
                    if (connectedSpeaker != null)
                    {
                        Speakers.Add(connectedSpeaker);
                    }
                    else
                    {
                        var marketingName = await Utils.RunAdbShellCommandAsync(_adbClient, "getprop ro.config.marketing_name", item);
                        if (string.IsNullOrWhiteSpace(marketingName))
                        {
                            var manufacturer = await Utils.RunAdbShellCommandAsync(_adbClient, "getprop ro.product.manufacturer", item);
                            marketingName = $"{manufacturer.Trim()} {item.Model}";
                        }
                        var savedSpeaker = _settings.AdbDevices.FirstOrDefault(m => m.Id == item.Serial);
                        var speaker = new Speaker(_dispatcher, item.Serial, marketingName.Trim(), savedSpeaker?.Channel ?? AudioChannel.None);
                        speaker.Remove += OnRemoveSpeaker;
                        speaker.ConnectStatusChanged += OnConnectStatusChanged;
                        Speakers.Add(speaker);
                    }
                }
                AdbLoading = false;
            }
            else
            {
                Speakers.Clear();
                HashSet<string> addresses = new HashSet<string>();
                foreach (var item in _settings.IPDevices)
                {
                    if (addresses.Contains(item.Id)) continue;
                    addresses.Add(item.Id);
                    var connectedSpeaker = connectedSpeakers.FirstOrDefault(m => m.Id == item.Id);
                    if (connectedSpeaker != null)
                    {
                        Speakers.Add(connectedSpeaker);
                    }
                    else
                    {
                        var speaker = new Speaker(_dispatcher, item.Id, item.Channel);
                        speaker.Remove += OnRemoveSpeaker;
                        speaker.ConnectStatusChanged += OnConnectStatusChanged;
                        Speakers.Add(speaker);
                    }
                }
            }
            foreach (var speaker in connectedSpeakers)
            {
                if (!Speakers.Any(m => m.Id == speaker.Id))
                {
                    speaker.Dispose();
                }
            }
        }

        private void AddIPSpeaker(object sender)
        {
            if (IsUSB) return;
            for (int i = 2; i < 255; i++)
            {
                string id = $"192.168.1.{i}:8088";
                if (!_settings.IPDevices.Any(m => m.Id == id))
                {
                    _settings.IPDevices.Add(new Settings.Device(id, AudioChannel.None));
                    var speaker = new Speaker(_dispatcher, id, AudioChannel.None);
                    speaker.Remove += OnRemoveSpeaker;
                    speaker.ConnectStatusChanged += OnConnectStatusChanged;
                    Speakers.Add(speaker);
                    return;
                }
            }
            AddIPSpeakerVisible = false;
        }

        private void AddIPSpeaker(string ip, int port)
        {
            string id = $"{ip}:{port}";
            if (!_settings.IPDevices.Any(m => m.Id == id))
            {
                _settings.IPDevices.Add(new Settings.Device(id, AudioChannel.None));
                if (!IsUSB)
                {
                    var speaker = new Speaker(_dispatcher, id, AudioChannel.None);
                    speaker.Remove += OnRemoveSpeaker;
                    speaker.ConnectStatusChanged += OnConnectStatusChanged;
                    Speakers.Add(speaker);
                }
                _settings.Save();
                return;
            }
        }

        private void RefreshSpeakers(object sender)
        {
            _ = RefreshSpeakers();
        }

        public void ResetSpeakerSetting()
        {
            if (IsUSB)
            {
                _settings.AdbDevices.Clear();
                foreach (var speaker in Speakers)
                {
                    _settings.AdbDevices.Add(new Settings.Device(speaker.Id, speaker.ChannelSelected.Key));
                }
            }
            else
            {
                _settings.IPDevices.Clear();
                foreach (var speaker in Speakers)
                {
                    _settings.IPDevices.Add(new Settings.Device(speaker.Id, speaker.ChannelSelected.Key));
                }
            }
        }

        private void RefreshAudios(object sender)
        {
            Stop();
            AudioManager.StopCapture();
            AudioManager.SetDevice(null, _settings.SampleRate);
            MMDeviceEnumerator enumerator = new MMDeviceEnumerator();
            _audioDevices.Clear();
            AudioDevices.Clear();
            MMDeviceCollection devices = enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active);
            MMDevice mDevice = null;
            foreach (var device in devices)
            {
                _audioDevices.Add(device);
                AudioDevices.Add(new NamePair(device.ID, device.FriendlyName));
                if (_settings.AudioId == device.ID) mDevice = device;
            }
            if (mDevice == null) mDevice = devices.FirstOrDefault();
            AudioSelected = new NamePair(mDevice?.ID, mDevice?.FriendlyName);
        }

        private static void SetStartup(bool startup)
        {
            string startupFolderPath = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
            string appPath = Process.GetCurrentProcess()?.MainModule.FileName ?? string.Empty;
            string lnkPath = Path.Combine(startupFolderPath, Path.GetFileNameWithoutExtension(appPath) + ".lnk");
            var exists = File.Exists(lnkPath);
            if (exists && startup) return;
            if (!exists && !startup) return;
            if (startup)
            {
                ShellLink.Shortcut.CreateShortcut(appPath, "startup").WriteToFile(lnkPath);
            }
            else
            {
                File.Delete(lnkPath);
            }
        }

        private static bool IsStartupEnabled()
        {
            string startupFolderPath = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
            string appPath = Process.GetCurrentProcess()?.MainModule.FileName ?? string.Empty;
            string lnkPath = Path.Combine(startupFolderPath, Path.GetFileNameWithoutExtension(appPath) + ".lnk");
            return File.Exists(lnkPath);
        }

        private bool CanRefreshAudios(object sender)
        {
            return true;
        }

        private bool CanRefreshSpeakers(object sender)
        {
            return true;
        }

        private bool CanAddIPSpeaker(object sender)
        {
            return IsIP;
        }

        private bool CanSearchSpeakers(object sender)
        {
            return IsIP;
        }

        private void OnRemoveSpeaker(object sender, Speaker speaker)
        {
            speaker?.Dispose();
            Speakers.Remove(speaker);
            ResetSpeakerSetting();
            _settings.Save();
        }

        private static CancellationTokenSource SetConnectStatusCancel = null;
        private async void OnConnectStatusChanged(object sender, ConnectStatus status)
        {
            if (status == ConnectStatus.Connecting) return;
            SetConnectStatusCancel?.Cancel();
            SetConnectStatusCancel = new CancellationTokenSource();
            CancellationToken token = SetConnectStatusCancel.Token;
            await Task.Delay(200);
            if (token.IsCancellationRequested) return;
            Logger.Info("connect status changed start");
            if (status == ConnectStatus.Connected)
            {
                if (sender != null && sender is Speaker)
                {
                    ((Speaker)sender)?.SetVolume(Volume);
                }
                List<Speaker> allConnected = Speakers.Where(speaker => speaker.Connected).ToList();
                foreach (var speaker in allConnected)
                {
                    if (speaker.Connected) speaker.SyncTime();
                }
                ResetSpeakerSetting();
                _settings.Save();
                if (allConnected.Count >= 2)
                {
                    _ = Task.Run(async () =>
                    {
                        await Task.Delay(1000);
                        await _dispatcher.InvokeAsync(async () => await MeasureAndSyncDevices(allConnected));
                    });
                }
            }
            if (status != ConnectStatus.Connecting)
            {
                ConnectedCount = Speakers.Where(m => m.Connected).Count();
            }
            ConnectingCount = Speakers.Where(m => m.Connecting).Count();
            Logger.Info("connect status changed end");
        }

        private void OnPropertyChanged(string propertyName)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}
