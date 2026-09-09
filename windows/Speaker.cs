using Microsoft.Toolkit.Uwp.Notifications;
using NAudio.Wave;
using SharpAdbClient;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using NamePair = System.Collections.Generic.KeyValuePair<AudioShare.AudioChannel, string>;

namespace AudioShare
{
    public class Speaker : INotifyPropertyChanged, IDisposable
    {
        enum Command
        {
            None = 0,
            AudioData = 1,
            Volume = 2,
            SyncTime = 3,
            Stop = 4,
            MeasureLatency = 5,
            SetDelay = 6
        }
        public event PropertyChangedEventHandler PropertyChanged;
        public event EventHandler<Speaker> Remove;
        public event EventHandler<ConnectStatus> ConnectStatusChanged;
        private static readonly ObservableCollection<NamePair> _channels = new ObservableCollection<NamePair>();
        private static readonly byte[] TCP_HEAD = Encoding.Default.GetBytes("picapico-audio-share");
        private static readonly string REMOTE_SOCKET = "localabstract:picapico-audio-share";

        static Speaker()
        {
            _channels.Add(new NamePair(AudioChannel.Stereo, "立体声"));
            _channels.Add(new NamePair(AudioChannel.Left, "前置左"));
            _channels.Add(new NamePair(AudioChannel.Right, "前置右"));
            _channels.Add(new NamePair(AudioChannel.Center, "中置"));
            _channels.Add(new NamePair(AudioChannel.Lfe, "重低音"));
            _channels.Add(new NamePair(AudioChannel.SideLeft, "环绕左"));
            _channels.Add(new NamePair(AudioChannel.SideRight, "环绕右"));
            _channels.Add(new NamePair(AudioChannel.BackLeft, "后置左"));
            _channels.Add(new NamePair(AudioChannel.BackRight, "后置右"));
            _channels.Add(new NamePair(AudioChannel.BackCenter, "后置中"));
            _channels.Add(new NamePair(AudioChannel.None, "禁用"));
        }
        private TcpClient tcpClient = null;
        readonly AdbClient adbClient = new AdbClient();
        private string _remoteIP = string.Empty;
        private int _remotePort = -1;
        private readonly bool _isUSB = false;
        private readonly string _name = string.Empty;
        private string _id = string.Empty;
        private bool _disposed = false;
        private bool _retried = false;
        private readonly Dispatcher _dispatcher;

        public string Id => _id;

        public string Display
        {
            get => _isUSB ? $"{_name} [{_id}]" : _id;
            set { _id = value; }
        }
        public bool IdReadOnly => _isUSB || _connectStatus != ConnectStatus.UnConnected;
        public bool RemoveVisible => !_isUSB;
        public bool ChannelEnabled => _connectStatus == ConnectStatus.UnConnected;
        public bool ConnectEnabled => _channel != AudioChannel.None;
        private ConnectStatus _connectStatus = ConnectStatus.UnConnected;
        public bool Connected => _connectStatus == ConnectStatus.Connected;
        public bool Connecting => _connectStatus == ConnectStatus.Connecting;
        public bool UnConnected => _connectStatus != ConnectStatus.Connected;
        public ObservableCollection<NamePair> Channels => _channels;
        private AudioChannel _channel = AudioChannel.None;
        public NamePair ChannelSelected
        {
            get => _channels.FirstOrDefault(m => m.Key == _channel);
            set
            {
                _channel = value.Key;
                OnPropertyChanged(nameof(ConnectEnabled));
            }
        }

        public Speaker(Dispatcher dispatcher, string id, string name, AudioChannel channel, bool isUSB)
        {
            _id = id;
            _name = name;
            _channel = channel;
            _isUSB = isUSB;
            _dispatcher = dispatcher;
        }

        public Speaker(Dispatcher dispatcher, string id) : this(dispatcher, id, AudioChannel.None)
        {
        }

        public Speaker(Dispatcher dispatcher, string id, AudioChannel channel) : this(dispatcher, id, string.Empty, channel, false)
        {
        }

        public Speaker(Dispatcher dispatcher, string id, string name) : this(dispatcher, id, name, AudioChannel.None)
        {
        }

        public Speaker(Dispatcher dispatcher, string id, string name, AudioChannel channel) : this(dispatcher, id, name, channel, true)
        {
        }

        private void SetConnectStatus(ConnectStatus connectStatus, bool toast = false)
        {
            if (_connectStatus == connectStatus) return;
            _dispatcher.InvokeAsync(() =>
            {
                if (toast && connectStatus == ConnectStatus.UnConnected && _connectStatus != connectStatus)
                {
                    var builder = new ToastContentBuilder()
                        .AddText($"{Display} {Languages.Language.GetLanguageText("disconnected")}");
                    if (!_disposed)
                    {
                        builder.AddButton(Languages.Language.GetLanguageText("reconnecte"), ToastActivationType.Foreground, _id);
                        builder.SetToastDuration(ToastDuration.Long);
                    }
                    builder.Show();
                }
                Logger.Info("set connect status start: " + connectStatus);
                _connectStatus = connectStatus;
                OnPropertyChanged(nameof(Connected));
                OnPropertyChanged(nameof(Connecting));
                OnPropertyChanged(nameof(UnConnected));
                OnPropertyChanged(nameof(IdReadOnly));
                OnPropertyChanged(nameof(RemoveVisible));
                OnPropertyChanged(nameof(ChannelEnabled));
                Logger.Info("set connect status end");
                ConnectStatusChanged?.Invoke(this, connectStatus);
            });
        }

        private RelayCommand _connectCommand;
        public RelayCommand ConnectCommand => _connectCommand ?? (_connectCommand = new RelayCommand(Connect, CanConnect));

        private RelayCommand _disConnectCommand;
        public RelayCommand DisConnectCommand => _disConnectCommand ?? (_disConnectCommand = new RelayCommand(DisConnect, CanDisConnect));

        private RelayCommand _removeCommand;
        public RelayCommand RemoveCommand => _removeCommand ?? (_removeCommand = new RelayCommand(RemoveSpeaker, CanRemoveSpeaker));

        public void SetVolume(int volume)
        {
            byte[] volumeBytes = BitConverter.GetBytes(volume);
            _ = RequestTcp(Command.Volume, volumeBytes);
        }

        public void SyncTime()
        {
            _ = RequestTcp(Command.SyncTime);
        }

        public void Dispose()
        {
            _disposed = true;
            _ = DisConnect();
        }

        private void Connect(object sender)
        {
            _ = Connect();
        }

        public async Task Connect(bool retry=false)
        {
            if (Connecting) return;
            _disposed = false;
            await DisConnect(false, retry);
            SetConnectStatus(ConnectStatus.Connecting);
            Logger.Info("connect start");
            try
            {
                tcpClient = new TcpClient();
                tcpClient.NoDelay = true;
                if (!retry)
                {
                    if (_isUSB)
                    {
                        if (!await EnsureDevice(_id))
                        {
                            throw new Exception("device not ready");
                        }
                        int port = await Utils.GetFreePort();
                        var device = adbClient.GetDevice(_id);
                        adbClient.RemoveRemoteForward(device, REMOTE_SOCKET);
                        adbClient.CreateForward(device, "tcp:" + port, REMOTE_SOCKET, true);
                        _remoteIP = "127.0.0.1";
                        _remotePort = port;
                    }
                    else
                    {
                        string pattern = @"^[\[]?(?<ip>\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}|([0-9A-Fa-f]{1,4}:){1,7}([0-9A-Fa-f]{1,4}|:))[\]]?(:(?<port>\d+))?$";
                        var match = Regex.Match(_id, pattern);
                        if (!match.Success)
                        {
                            MessageBox.Show(Application.Current.MainWindow,
                                Languages.Language.GetLanguageText("ipParseError"),
                                Application.Current.MainWindow.Title);
                            throw new Exception("address error");
                        }
                        var groupIP = match.Groups["ip"];
                        var groupPort = match.Groups["port"];
                        string ip = groupIP.Value;
                        if (!int.TryParse(groupPort?.Value ?? string.Empty, out int port))
                        {
                            port = 80;
                        }
                        if (!await EnsureDevice(ip, port))
                        {
                            throw new Exception("device not ready");
                        }
                        _remoteIP = ip;
                        _remotePort = port;
                    }
                }
                await RequestTcp(Command.Stop, force: true);
                IPAddress ipAddress = IPAddress.Parse(_remoteIP);
                await tcpClient.ConnectAsync(ipAddress, _remotePort);
                tcpClient.NoDelay = true;
                int channelCount = _channel == AudioChannel.Stereo ? 2 : 1;
                tcpClient.SendBufferSize = AudioManager.SampleRate * channelCount * 2 * 20 / 1000;

                if (tcpClient.Connected)
                {
                    Logger.Info("connect send head");
                    await WriteTcp(TCP_HEAD);
                    await WriteTcp(new byte[] { (byte)Command.AudioData });
                    var sampleRateBytes = BitConverter.GetBytes(AudioManager.SampleRate);
                    await WriteTcp(sampleRateBytes);
                    var channelBytes = BitConverter.GetBytes(_channel == AudioChannel.Stereo ? 12 : 4);
                    await WriteTcp(channelBytes);
                    await tcpClient.GetStream().ReadAsync(new byte[1], 0, 1);
                    _ = _dispatcher.InvokeAsync(() =>
                    {
                        AudioManager.StartCapture();
                        if (_channel != AudioChannel.None)
                        {
                            AudioManager.AudioFrameAvailable += SendAudioData;
                        }
                        AudioManager.Stoped += OnAudioStoped;
                    });
                    ReadAsync(tcpClient.GetStream());
                }
                SetConnectStatus(ConnectStatus.Connected);
                _retried = false;
            }
            catch (Exception ex)
            {
                await DisConnect();
                Logger.Error("connect error: " + ex.Message);
            }
            Logger.Info("connect end");
        }
        private readonly byte[] _receiveBuffer = new byte[512];
        private async void ReadAsync(NetworkStream stream)
        {
            try
            {
                while (stream.CanRead)
                {
                    int bytesRead = await stream.ReadAsync(_receiveBuffer, 0, _receiveBuffer.Length);
                    if (bytesRead == 0)
                    {
                        _ = DisConnect(true);
                        return;
                    }
                }
            }
            catch (Exception)
            {
            }
        }

        private void OnAudioStoped(object sender, EventArgs e)
        {
            _ = DisConnect();
        }

        private readonly object writeLock = new object();
        private bool isBusy = false;
        private int[] _extractIndices;
        private int _extractKey = -1;
        private byte[] _extractBuffer;
        private AudioChannel _missingChannelLogged = AudioChannel.None;

        private static readonly Dictionary<AudioChannel, int> ChannelBits = new Dictionary<AudioChannel, int>
        {
            { AudioChannel.Left, 0x1 },          // FRONT_LEFT
            { AudioChannel.Right, 0x2 },         // FRONT_RIGHT
            { AudioChannel.Center, 0x4 },        // FRONT_CENTER
            { AudioChannel.Lfe, 0x8 },           // LOW_FREQUENCY
            { AudioChannel.BackLeft, 0x10 },     // BACK_LEFT
            { AudioChannel.BackRight, 0x20 },    // BACK_RIGHT
            { AudioChannel.BackCenter, 0x100 },  // BACK_CENTER
            { AudioChannel.SideLeft, 0x200 },    // SIDE_LEFT
            { AudioChannel.SideRight, 0x400 },   // SIDE_RIGHT
        };

        private static int IndexOfBit(int mask, int bit, int channels)
        {
            if ((mask & bit) == 0) return -1;
            int index = 0;
            for (int m = 1; m < bit; m <<= 1)
            {
                if ((mask & m) != 0) index++;
            }
            return index < channels ? index : -1;
        }

        private int[] ResolveChannelIndices(int channels, int mask)
        {
            if (_channel == AudioChannel.None) return null;
            if (_channel == AudioChannel.Stereo)
            {
                int frontLeft = IndexOfBit(mask, 0x1, channels);
                int frontRight = IndexOfBit(mask, 0x2, channels);
                if (frontLeft < 0 && frontRight < 0 && channels > 0)
                {
                    // Layout without front pair (e.g. mono mix): fold it to both.
                    frontLeft = 0;
                    frontRight = Math.Min(1, channels - 1);
                }
                if (frontLeft < 0 || frontRight < 0) return null;
                return new[] { frontLeft, frontRight };
            }
            if (!ChannelBits.TryGetValue(_channel, out int bit)) return null;
            int index = IndexOfBit(mask, bit, channels);
            if (index < 0)
            {
                if (_missingChannelLogged != _channel)
                {
                    _missingChannelLogged = _channel;
                    Logger.Error($"{Display}: channel {_channel} not present in capture layout ({channels}ch mask=0x{mask:X}), muted");
                }
                return null;
            }
            return new[] { index };
        }

        private async void SendAudioData(object sender, AudioFrameEventArgs e)
        {
            lock (writeLock)
            {
                if (isBusy) return;
                isBusy = true;
            }
            try
            {
                int frameBytes = e.Channels * 2;
                int frames = e.BytesRecorded / frameBytes;
                int key = (e.Channels << 16) ^ e.ChannelMask;
                if (key != _extractKey)
                {
                    _extractKey = key;
                    _extractIndices = ResolveChannelIndices(e.Channels, e.ChannelMask);
                }
                if (_extractIndices == null || frames <= 0) return;
                int stride = _extractIndices.Length;
                int needed = frames * stride * 2;
                if (_extractBuffer == null || _extractBuffer.Length < needed)
                {
                    _extractBuffer = new byte[needed];
                }
                for (int f = 0; f < frames; f++)
                {
                    int sourceFrame = f * frameBytes;
                    int targetFrame = f * stride * 2;
                    for (int c = 0; c < stride; c++)
                    {
                        int source = sourceFrame + _extractIndices[c] * 2;
                        int target = targetFrame + c * 2;
                        _extractBuffer[target] = e.Buffer[source];
                        _extractBuffer[target + 1] = e.Buffer[source + 1];
                    }
                }
                if (!(await WriteTcp(_extractBuffer, needed, true)))
                {
                    if (!_retried && Connected)
                    {
                        _retried = true;
                        await Connect(true);
                    }
                    else
                    {
                        await DisConnect(true);
                    }
                }
            }
            finally
            {
                lock (writeLock)
                {
                    isBusy = false;
                }
            }
        }

        private async Task<bool> EnsureDevice(string host, int port)
        {
            bool result = await Utils.PortIsOpen(host, port);
            string adbPath = Utils.FindAdbPath();
            if (string.IsNullOrWhiteSpace(adbPath)) return result;
            DeviceData device;
            bool needDisconnect = false;
            try
            {
                await Utils.EnsureAdb(adbPath);
                device = adbClient.GetDevices().FirstOrDefault(m => m.Serial?.StartsWith(host) ?? false);
                needDisconnect = device == null;
                if (device == null)
                {
                    if (!await Utils.PortIsOpen(host, 5555)) return result;
                    await Utils.RunCommandAsync(adbPath, $"connect {host}:5555");
                    device = adbClient.GetDevices().FirstOrDefault(m => m.Serial?.StartsWith(host) ?? false);
                }
                if (device == null) return result;
                result = await EnsureDevice(device);
            }
            catch (Exception)
            {
                return result;
            }
            if (needDisconnect) await Utils.RunCommandAsync(adbPath, $"disconnect {host}:5555");
            return result;
        }

        private Task<bool> EnsureDevice(string serial)
        {
            return EnsureDevice(adbClient.GetDevices().FirstOrDefault(m => m.Serial == serial));
        }

        private async Task<bool> EnsureDevice(DeviceData device)
        {
            if (device == null) return false;

            if (string.IsNullOrWhiteSpace(device.Serial)) return false;
            string adbPath = Utils.FindAdbPath();
            if (string.IsNullOrWhiteSpace(adbPath)) return false;
            await Utils.RunCommandAsync(adbPath, "start-server");
            string result = await Utils.RunAdbShellCommandAsync(adbClient, "dumpsys package com.picapico.audioshare|grep versionName", device);
            if (result.Contains(Utils.VersionName))
            {
                await Utils.RunAdbShellCommandAsync(adbClient, "am start -W -n com.picapico.audioshare/.MainActivity", device);
                return true;
            }
            string appPath = Process.GetCurrentProcess()?.MainModule.FileName ?? string.Empty;
            if (string.IsNullOrWhiteSpace(appPath)) return false;
            string apkPath = Path.Combine(Path.GetDirectoryName(appPath), Path.GetFileNameWithoutExtension(appPath) + ".apk");
            if (!File.Exists(apkPath))
            {
                MessageBox.Show(Application.Current.MainWindow, Languages.Language.GetLanguageText("apkMisMatch") +
                    Languages.Language.GetLanguageText("or") +
                    Languages.Language.GetLanguageText("apkExistsTips"),
                    Application.Current.MainWindow.Title);
                return false;
            }

            await adbClient.PushAsync(device, apkPath, "/data/local/tmp/audioshare.apk");
            await Utils.RunAdbShellCommandAsync(adbClient,
                "/system/bin/pm uninstall com.picapico.audioshare;" +
                "/system/bin/pm install -r /data/local/tmp/audioshare.apk;" +
                "rm -f /data/local/tmp/audioshare.apk;" +
                "dumpsys deviceidle whitelist +com.picapico.audioshare;", device);
            Logger.Info("install apk success");

            result = await Utils.RunAdbShellCommandAsync(adbClient, "dumpsys package com.picapico.audioshare|grep versionName", device);
            if (result.Contains(Utils.VersionName))
            {
                await Utils.RunAdbShellCommandAsync(adbClient, "am start -W -n com.picapico.audioshare/.MainActivity", device);
                return true;
            }
            MessageBox.Show(Application.Current.MainWindow,
                Languages.Language.GetLanguageText("apkMisMatch"),
                Application.Current.MainWindow.Title);
            return false;
        }

        private async Task DisConnect(bool toast=false, bool retry = false)
        {
            if (_connectStatus == ConnectStatus.UnConnected) return;
            SetConnectStatus(ConnectStatus.UnConnected, toast);
            Logger.Info("disconnect start");
            if (!retry)
            {
                _remoteIP = string.Empty;
                _remotePort = -1;
            }
            try
            {
                AudioManager.Stoped -= OnAudioStoped;
            }
            catch (Exception)
            {
            }
            await _dispatcher.InvokeAsync(() =>
            {
                try
                {
                    AudioManager.AudioFrameAvailable -= SendAudioData;
                }
                catch (Exception)
                {
                }
            });
            try
            {
                tcpClient?.Close();
            }
            catch (Exception ex)
            {
                Logger.Error("stop tcp error: " + ex.Message);
            }
            tcpClient = null;
            Logger.Info("disconnect end");
        }

        private void DisConnect(object sender)
        {
            _ = DisConnect();
        }

        private void RemoveSpeaker(object sender)
        {
            Remove?.Invoke(null, this);
        }

        private bool CanConnect(object sender)
        {
            return true;
        }
        private bool CanDisConnect(object sender)
        {
            return true;
        }
        private bool CanRemoveSpeaker(object sender)
        {
            return _connectStatus == ConnectStatus.UnConnected;
        }

        private int _lastSendTime = 0;
        private static readonly byte[] _heartBeatBytes = new byte[] { 0x00, 0x00, 0x00, 0x00 };
        private readonly byte[] _lengthBuffer = new byte[4];
        private byte[] _sendPacketBuffer;
        public void SendHeartbeat()
        {
            if (unchecked(Environment.TickCount - _lastSendTime) > 5000)
            {
                _ = WriteTcp(_heartBeatBytes).ContinueWith(t =>
                {
                    if (!t.Result) _ = DisConnect(true);
                });
            }
        }
        private async Task<bool> WriteTcp(byte[] buffer, int length = 0, bool sendLength = false)
        {
            if (length == 0) length = buffer.Length;
            if (length == 0) return true;
            _lastSendTime = Environment.TickCount;
            try
            {
                if (tcpClient != null)
                {
                    var stream = tcpClient.GetStream();
                    if (sendLength)
                    {
                        int total = 4 + length;
                        if (_sendPacketBuffer == null || _sendPacketBuffer.Length < total)
                            _sendPacketBuffer = new byte[total];
                        _sendPacketBuffer[0] = (byte)(length & 0xFF);
                        _sendPacketBuffer[1] = (byte)((length >> 8) & 0xFF);
                        _sendPacketBuffer[2] = (byte)((length >> 16) & 0xFF);
                        _sendPacketBuffer[3] = (byte)((length >> 24) & 0xFF);
                        Buffer.BlockCopy(buffer, 0, _sendPacketBuffer, 4, length);
                        await stream.WriteAsync(_sendPacketBuffer, 0, total);
                    }
                    else
                    {
                        await stream.WriteAsync(buffer, 0, length);
                    }
                    if (length > tcpClient.SendBufferSize)
                    {
                        tcpClient.SendBufferSize = length;
                    }
                    return true;
                }
            }
            catch (Exception ex)
            {
                Logger.Error("write tcp error: " + ex.Message);
            }
            return false;
        }

        private static readonly byte[] _latencyCmdBytes = new byte[] { (byte)Command.MeasureLatency };
        private readonly byte[] _responseBuffer = new byte[1];

        private static async Task<T> WithTimeout<T>(Task<T> task, int timeoutMs, string action)
        {
            // ReceiveTimeout/ConnectAsync timeouts do not apply to async APIs.
            Task finished = await Task.WhenAny(task, Task.Delay(timeoutMs));
            if (finished != task) throw new TimeoutException(action + " timeout");
            return await task;
        }

        private static async Task WithTimeout(Task task, int timeoutMs, string action)
        {
            Task finished = await Task.WhenAny(task, Task.Delay(timeoutMs));
            if (finished != task) throw new TimeoutException(action + " timeout");
            await task;
        }

        private async Task RequestTcp(Command command, byte[] data = null, bool force=false)
        {
            if (command == Command.None ||
                string.IsNullOrWhiteSpace(_remoteIP) ||
                _remotePort <= 0 ||
                (!force && !Connected))
            {
                return;
            }
            TcpClient client = new TcpClient();
            client.NoDelay = true;
            try
            {
                await WithTimeout(client.ConnectAsync(_remoteIP, _remotePort), 3000, "connect");
                var stream = client.GetStream();
                await stream.WriteAsync(TCP_HEAD, 0, TCP_HEAD.Length);
                await stream.WriteAsync(new byte[] { (byte)command }, 0, 1);
                if (data != null && data.Length > 0)
                {
                    await stream.WriteAsync(data, 0, data.Length);
                }
                await WithTimeout(stream.ReadAsync(_responseBuffer, 0, 1), 3000, "read");
            }
            catch (Exception)
            {
            }
            try
            {
                client.Close();
            }
            catch (Exception)
            {
            }
        }

        private int _lastRTT = 0;
        private double _smoothedRTT = 0;
        private int _lastSentDelay = 0;
        public int LastSentDelay
        {
            get => _lastSentDelay;
            set => _lastSentDelay = value;
        }
        public int LastRTT
        {
            get => _lastRTT;
            private set
            {
                if (_lastRTT != value)
                {
                    _lastRTT = value;
                    OnPropertyChanged(nameof(LastRTT));
                    OnPropertyChanged(nameof(QualityColor));
                }
            }
        }

        public System.Windows.Media.Brush QualityColor
        {
            get
            {
                if (_lastRTT <= 20) return System.Windows.Media.Brushes.Green;
                if (_lastRTT <= 50) return System.Windows.Media.Brushes.Yellow;
                return System.Windows.Media.Brushes.Red;
            }
        }

        public async Task<long> MeasureLatencyAsync()
        {
            if (string.IsNullOrWhiteSpace(_remoteIP) || _remotePort <= 0 || !Connected)
                return -1;

            TcpClient client = new TcpClient();
            client.NoDelay = true;
            try
            {
                long start = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                await WithTimeout(client.ConnectAsync(_remoteIP, _remotePort), 3000, "connect");
                var stream = client.GetStream();
                await stream.WriteAsync(TCP_HEAD, 0, TCP_HEAD.Length);
                await stream.WriteAsync(_latencyCmdBytes, 0, 1);
                await WithTimeout(stream.ReadAsync(_responseBuffer, 0, 1), 3000, "read");
                long rtt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - start;
                if (_smoothedRTT == 0)
                    _smoothedRTT = rtt;
                else
                    _smoothedRTT = 0.6 * rtt + 0.4 * _smoothedRTT;
                LastRTT = (int)Math.Round(_smoothedRTT);
                return rtt;
            }
            catch (Exception)
            {
                LastRTT = -1;
                return -1;
            }
            finally
            {
                try { client.Close(); } catch (Exception) { }
            }
        }

        public async Task SetDelay(int delayMs, bool applyNow = false)
        {
            if (delayMs < 0) delayMs = 0;
            byte[] data = new byte[5];
            BitConverter.GetBytes(delayMs).CopyTo(data, 0);
            data[4] = (byte)(applyNow ? 1 : 0);
            await RequestTcp(Command.SetDelay, data);
        }

        private void OnPropertyChanged(string propertyName)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}
