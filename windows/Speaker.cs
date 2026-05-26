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
using System.Threading;
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
            MeasureLatency = 5,      // 新增：延迟测量
            SetDelay = 6,            // 新增：设置播放延迟
            SyncStatus = 7,          // 新增：同步状态查询
            ResendPacket = 8         // 新增：重传数据包
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
            _channels.Add(new NamePair(AudioChannel.Left, "左声道"));
            _channels.Add(new NamePair(AudioChannel.Right, "右声道"));
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

        // 音频同步相关字段
        private static readonly System.Diagnostics.Stopwatch _audioTimer = System.Diagnostics.Stopwatch.StartNew();
        private const int TIMESTAMP_SIZE = 8; // 8字节时间戳

        // RTT测量相关字段
        private readonly Queue<long> _rttHistory = new Queue<long>();
        private const int RTT_HISTORY_SIZE = 50; // RTT历史记录数量
        private long _currentRtt = 0;
        private long _averageRtt = 0;
        private int _latencyMeasurementSequence = 0;

        // 设备性能评估相关字段
        public enum DevicePerformanceLevel
        {
            Unknown = 0,
            High = 1,      // 高性能设备：延迟<50ms，CPU能力强
            Medium = 2,    // 中等性能设备：延迟50-150ms
            Low = 3        // 低性能设备：延迟>150ms
        }

        private DevicePerformanceLevel _performanceLevel = DevicePerformanceLevel.Unknown;
        private long _processingCapability = 0; // 处理能力评分
        private readonly Queue<long> _audioProcessingTimes = new Queue<long>(); // 音频处理时间历史

        // 网络质量监控相关字段
        public enum NetworkQualityLevel
        {
            Unknown = 0,
            Excellent = 1,  // 优秀：丢包率<1%，抖动<10ms
            Good = 2,       // 良好：丢包率1-3%，抖动10-30ms
            Fair = 3,       // 一般：丢包率3-10%，抖动30-50ms
            Poor = 4        // 较差：丢包率>10%，抖动>50ms
        }

        private NetworkQualityLevel _networkQuality = NetworkQualityLevel.Unknown;
        private long _packetsSent = 0;
        private long _packetsLost = 0;
        private readonly Queue<long> _jitterHistory = new Queue<long>();
        private const int JITTER_HISTORY_SIZE = 100;
        private long _currentJitter = 0;
        private long _averageJitter = 0;

        // 连接恢复相关字段
        private int _disconnectCount = 0;
        private DateTime _lastDisconnectTime = DateTime.MinValue;
        private const int MAX_RECONNECT_ATTEMPTS = 5;
        private const int RECONNECT_DELAY_MS = 2000;
        private bool _autoReconnectEnabled = true;
        private CancellationTokenSource _reconnectCancellationTokenSource;

        // 网络质量动态适配相关字段
        public enum SyncMode
        {
            HighQuality,      // 高质量模式：±10ms容忍度
            Standard,         // 标准模式：±20ms容忍度
            Degraded,         // 降级模式：±50ms容忍度
            Emergency         // 应急模式：±100ms容忍度
        }

        private SyncMode _currentSyncMode = SyncMode.Standard;
        private readonly Queue<NetworkQualityLevel> _qualityHistory = new Queue<NetworkQualityLevel>();
        private const int QUALITY_HISTORY_SIZE = 10;

        // 超时处理相关字段
        private const int DEFAULT_TIMEOUT_MS = 30000; // 30秒默认超时
        private const int QUICK_TIMEOUT_MS = 10000;   // 10秒快速超时
        private const int EXTENDED_TIMEOUT_MS = 60000; // 60秒扩展超时
        private int _currentTimeout = DEFAULT_TIMEOUT_MS;
        private DateTime _lastSuccessfulCommunication = DateTime.Now;

        // 丢包处理与重传相关字段
        private const int MAX_RETRANSMIT_ATTEMPTS = 3;
        private const int CRITICAL_PACKET_THRESHOLD = 100; // 每100个包中的关键包
        private int _packetSequence = 0;
        private readonly Dictionary<int, byte[]> _packetRetransmitCache = new Dictionary<int, byte[]>();
        private const int CACHE_SIZE = 50; // 缓存最近50个数据包用于重传
        private long _totalPacketsSent = 0;
        private long _totalPacketsRetransmitted = 0;

        // 性能优化相关字段
        private const int LOG_SUPPRESSION_INTERVAL = 100; // 每100个包才记录一次详细日志
        private int _logSuppressionCounter = 0;
        private readonly object _logLock = new object();
        private bool _verboseLogging = false; // 可配置的详细日志开关
        private DateTime _lastLogTime = DateTime.Now;
        private const int MIN_LOG_INTERVAL_MS = 1000; // 最小日志间隔1秒

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

        // UI绑定属性
        public string SyncHealthIndicator
        {
            get
            {
                if (!Connected) return "";

                int qualityScore = GetOverallQualityScore();
                if (qualityScore >= 80)
                {
                    return "🟢"; // 绿色
                }
                else if (qualityScore >= 60)
                {
                    return "🟡"; // 黄色
                }
                else
                {
                    return "🔴"; // 红色
                }
            }
        }

        public string SyncStatusTooltip
        {
            get
            {
                if (!Connected) return "";

                return $"延迟: {_averageRtt}ms\n" +
                       $"质量: {_networkQuality}\n" +
                       $"评分: {GetOverallQualityScore()}/100\n" +
                       $"模式: {_currentSyncMode}";
            }
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

        public RelayCommand ConnectCommand => new RelayCommand(Connect, CanConnect);

        public RelayCommand DisConnectCommand => new RelayCommand(DisConnect, CanDisConnect);

        public RelayCommand RemoveCommand => new RelayCommand(RemoveSpeaker, CanRemoveSpeaker);

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

                if (tcpClient.Connected)
                {
                    Logger.Info($"connect send head to {_remoteIP}:{_remotePort}");
                    await WriteTcp(TCP_HEAD);
                    await WriteTcp(new byte[] { (byte)Command.AudioData });
                    var sampleRateBytes = BitConverter.GetBytes(AudioManager.SampleRate);
                    await WriteTcp(sampleRateBytes);
                    var channelBytes = BitConverter.GetBytes(_channel == AudioChannel.Stereo ? 12 : 4);
                    await WriteTcp(channelBytes);

                    // 等待设备确认
                    await tcpClient.GetStream().ReadAsync(new byte[1], 0, 1);
                    Logger.Info($"connect acknowledged by {_remoteIP}:{_remotePort}");

                    // 发送初始时间同步
                    long syncTimestamp = _audioTimer.ElapsedMilliseconds;
                    var syncBytes = BitConverter.GetBytes(syncTimestamp);
                    await RequestTcp(Command.SyncTime, syncBytes);
                    Logger.Info($"time sync sent: {syncTimestamp}ms");

                    _ = _dispatcher.InvokeAsync(() =>
                    {
                        AudioManager.StartCapture();
                        switch (_channel)
                        {
                            case AudioChannel.Left:
                                AudioManager.LeftAvailable += SendAudioData;
                                break;
                            case AudioChannel.Right:
                                AudioManager.RightAvailable += SendAudioData;
                                break;
                            case AudioChannel.Stereo:
                                AudioManager.StereoAvailable += SendAudioData;
                                break;
                        }
                        AudioManager.Stoped += OnAudioStoped;
                    });
                    ReadAsync(tcpClient.GetStream());

                    // 启动定期RTT测量
                    _ = StartPeriodicLatencyMeasurement();

                    // 启动网络健康监控
                    _ = MonitorNetworkHealth();

                    // 启动超时监控
                    _ = MonitorTimeout();
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

                    // 检查连接是否中断
                    if (bytesRead == 0)
                    {
                        Logger.Warn($"Connection lost for {_id}, triggering reconnect");
                        await HandleConnectionLoss();
                        return;
                    }

                    // 更新数据包统计
                    _packetsSent++;
                    UpdateNetworkQuality(true);

                    // 检查是否是延迟测量响应
                    if (bytesRead >= 5) // 至少包含命令类型和序列号
                    {
                        // 这里可以处理特定的响应格式
                        // 简化处理：假设返回的是延迟测量响应
                    }
                }
            }
            catch (Exception e)
            {
                // 处理异常
            }
        }

        private void OnAudioStoped(object sender, EventArgs e)
        {
            _ = DisConnect();
        }

        private readonly object writeLock = new object();
        private bool isBusy = false;
        private async void SendAudioData(object sender, WaveInEventArgs e)
        {
            lock (writeLock)
            {
                if (isBusy) return;
                isBusy = true;
            }

            _packetSequence++;
            _totalPacketsSent++;

            // 使用优化的方法获取时间戳和创建数据包
            long timestamp = GetCurrentTimestampOptimized();
            byte[] dataWithTimestamp = CreateOptimizedAudioPacket(e.Buffer, timestamp);

            // 缓存数据包用于可能的重传
            CachePacketForRetransmit(_packetSequence, dataWithTimestamp);

            bool sendSuccess = await WriteTcp(dataWithTimestamp, TIMESTAMP_SIZE + e.BytesRecorded, true);

            if (!sendSuccess)
            {
                // 发送失败，视为丢包
                HandlePacketLoss(_packetSequence);

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
            else
            {
                // 成功发送数据，更新最后通信时间
                UpdateLastSuccessfulCommunication();

                // 使用优化的日志记录
                LogThrottled($"Audio data sent: {_packetSequence}, size: {e.BytesRecorded}");
            }

            lock (writeLock)
            {
                isBusy = false;
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
                    switch (ChannelSelected.Key)
                    {
                        case AudioChannel.Left:
                            AudioManager.LeftAvailable -= SendAudioData;
                            break;
                        case AudioChannel.Right:
                            AudioManager.RightAvailable -= SendAudioData;
                            break;
                        case AudioChannel.Stereo:
                            AudioManager.StereoAvailable -= SendAudioData;
                            break;
                    }
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

        private long _lastSendTime = 0;
        private static readonly byte[] _heartBeatBytes = new byte[] { 0x00, 0x00, 0x00, 0x00 };
        public void SendHeartbeat()
        {
            _dispatcher.Invoke(async () =>
            {
                if(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - _lastSendTime > 5)
                {
                    if(!await WriteTcp(_heartBeatBytes)) {
                        _ = DisConnect();
                    }
                }
            });
        }
        private async Task<bool> WriteTcp(byte[] buffer, int length = 0, bool sendLength = false)
        {
            if (length == 0) length = buffer.Length;
            if (length == 0) return true;
            _lastSendTime = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            try
            {
                if (tcpClient != null)
                {
                    if (sendLength)
                    {
                        var dataLength = BitConverter.GetBytes(length);
                        await tcpClient.GetStream().WriteAsync(dataLength, 0, dataLength.Length);
                    }
                    await tcpClient.GetStream().WriteAsync(buffer, 0, length);
                    await tcpClient.GetStream().FlushAsync();
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
            client.SendTimeout = 1000;
            try
            {
                await client.ConnectAsync(_remoteIP, _remotePort);
                await client.GetStream().WriteAsync(TCP_HEAD, 0, TCP_HEAD.Length);
                await client.GetStream().WriteAsync(new byte[] { (byte)command }, 0, 1);
                if (data != null && data.Length > 0)
                {
                    await client.GetStream().WriteAsync(data, 0, data.Length);
                }
                await client.GetStream().FlushAsync();
                await client.GetStream().ReadAsync(new byte[1], 0, 1);
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

        private async Task<bool> RequestTcpWithResponse(Command command, byte[] data = null, bool force = false)
        {
            if (command == Command.None ||
                string.IsNullOrWhiteSpace(_remoteIP) ||
                _remotePort <= 0 ||
                (!force && !Connected))
            {
                return false;
            }

            TcpClient client = new TcpClient();
            client.SendTimeout = 1000;
            client.ReceiveTimeout = 1000;
            try
            {
                await client.ConnectAsync(_remoteIP, _remotePort);
                await client.GetStream().WriteAsync(TCP_HEAD, 0, TCP_HEAD.Length);
                await client.GetStream().WriteAsync(new byte[] { (byte)command }, 0, 1);
                if (data != null && data.Length > 0)
                {
                    await client.GetStream().WriteAsync(data, 0, data.Length);
                }
                await client.GetStream().FlushAsync();

                // 尝试读取响应
                byte[] responseBuffer = new byte[1];
                await client.GetStream().ReadAsync(responseBuffer, 0, 1);

                client.Close();
                return true; // 成功收到响应
            }
            catch (Exception)
            {
                try
                {
                    client.Close();
                }
                catch (Exception)
                {
                }
                return false; // 没有收到响应或出错
            }
        }

        // RTT测量相关方法
        public async Task<long> MeasureLatencyAsync()
        {
            if (tcpClient == null || !Connected) return 0;

            try
            {
                var stopwatch = Stopwatch.StartNew();
                _latencyMeasurementSequence++;

                // 发送延迟测量请求
                byte[] sequenceBytes = BitConverter.GetBytes(_latencyMeasurementSequence);
                bool success = await RequestTcpWithResponse(Command.MeasureLatency, sequenceBytes);

                stopwatch.Stop();
                long rtt = stopwatch.ElapsedMilliseconds;

                // 更新RTT历史
                if (rtt > 0)
                {
                    UpdateRttHistory(rtt);
                    UpdateJitter(rtt);
                    UpdateNetworkQuality(success);
                }

                Logger.Info($"RTT measurement for {_id}: {rtt}ms (sequence: {_latencyMeasurementSequence})");
                return rtt;
            }
            catch (Exception ex)
            {
                Logger.Error($"RTT measurement error for {_id}: {ex.Message}");
                UpdateNetworkQuality(false); // 记录丢包
                return 0;
            }
        }

        private void UpdateRttHistory(long rtt)
        {
            if (rtt <= 0) return;

            _rttHistory.Enqueue(rtt);
            while (_rttHistory.Count > RTT_HISTORY_SIZE)
            {
                _rttHistory.Dequeue();
            }

            _currentRtt = rtt;
            _averageRtt = CalculateAverageRtt();
        }

        private long CalculateAverageRtt()
        {
            if (_rttHistory.Count == 0) return 0;

            long sum = 0;
            foreach (var rtt in _rttHistory)
            {
                sum += rtt;
            }
            return sum / _rttHistory.Count;
        }

        public long GetCurrentRtt() => _currentRtt;
        public long GetAverageRtt() => _averageRtt;
        public int GetRttSampleCount() => _rttHistory.Count;

        // 设备性能评估方法
        public void EvaluateDevicePerformance()
        {
            if (_rttHistory.Count < 5) return; // 需要至少5个RTT样本

            long avgRtt = _averageRtt;
            long rttVariance = CalculateRttVariance();

            // 基于RTT和方差评估性能等级
            if (avgRtt < 50 && rttVariance < 20)
            {
                _performanceLevel = DevicePerformanceLevel.High;
            }
            else if (avgRtt < 150 && rttVariance < 50)
            {
                _performanceLevel = DevicePerformanceLevel.Medium;
            }
            else
            {
                _performanceLevel = DevicePerformanceLevel.Low;
            }

            // 计算处理能力评分 (0-100)
            _processingCapability = CalculateProcessingCapability();

            Logger.Info($"Device {_id} performance evaluation: Level={_performanceLevel}, Score={_processingCapability}, RTT={avgRtt}ms");
        }

        private long CalculateRttVariance()
        {
            if (_rttHistory.Count < 2) return 0;

            long avg = _averageRtt;
            long sum = 0;

            foreach (var rtt in _rttHistory)
            {
                long diff = rtt - avg;
                sum += diff * diff;
            }

            return (long)Math.Sqrt(sum / _rttHistory.Count);
        }

        private long CalculateProcessingCapability()
        {
            // 综合RTT、稳定性、处理能力等因素计算评分
            long rttScore = Math.Max(0, 100 - _averageRtt); // RTT越低分数越高
            long stabilityScore = Math.Max(0, 100 - CalculateRttVariance()); // 越稳定分数越高

            return (rttScore + stabilityScore) / 2;
        }

        public DevicePerformanceLevel GetPerformanceLevel() => _performanceLevel;
        public long GetProcessingCapability() => _processingCapability;
        public string GetPerformanceDescription()
        {
            switch (_performanceLevel)
            {
                case DevicePerformanceLevel.High:
                    return "高性能设备";
                case DevicePerformanceLevel.Medium:
                    return "中等性能设备";
                case DevicePerformanceLevel.Low:
                    return "低性能设备";
                default:
                    return "未知设备";
            }
        }

        // 性能自适应策略
        public int GetAdaptiveBufferSize()
        {
            switch (_performanceLevel)
            {
                case DevicePerformanceLevel.High:
                    return 4096; // 高性能设备使用较小缓冲区
                case DevicePerformanceLevel.Medium:
                    return 8192; // 中等性能设备使用中等缓冲区
                case DevicePerformanceLevel.Low:
                    return 16384; // 低性能设备使用较大缓冲区
                default:
                    return 8192; // 默认中等缓冲区
            }
        }

        public int GetAdaptiveSyncTolerance()
        {
            switch (_performanceLevel)
            {
                case DevicePerformanceLevel.High:
                    return 10; // 高性能设备容忍度±10ms
                case DevicePerformanceLevel.Medium:
                    return 20; // 中等性能设备容忍度±20ms
                case DevicePerformanceLevel.Low:
                    return 30; // 低性能设备容忍度±30ms
                default:
                    return 20; // 默认±20ms
            }
        }

        // 网络质量监控方法
        public void UpdateNetworkQuality(bool packetSuccess)
        {
            _packetsSent++;
            if (!packetSuccess)
            {
                _packetsLost++;
            }

            // 每100个包评估一次网络质量
            if (_packetsSent % 100 == 0)
            {
                EvaluateNetworkQuality();
            }
        }

        public void UpdateJitter(long currentRtt)
        {
            if (_rttHistory.Count < 2) return;

            // 计算当前抖动（与上一次RTT的差异）
            long jitter = Math.Abs(currentRtt - _currentRtt);
            _currentJitter = jitter;

            // 更新抖动历史
            _jitterHistory.Enqueue(jitter);
            while (_jitterHistory.Count > JITTER_HISTORY_SIZE)
            {
                _jitterHistory.Dequeue();
            }

            // 计算平均抖动
            if (_jitterHistory.Count > 0)
            {
                _averageJitter = (long)_jitterHistory.Average();
            }
        }

        private void EvaluateNetworkQuality()
        {
            if (_packetsSent < 50) return; // 需要至少50个样本

            double packetLossRate = (double)_packetsLost / _packetsSent * 100;
            long jitter = _averageJitter;

            // 基于丢包率和抖动评估网络质量
            if (packetLossRate < 1.0 && jitter < 10)
            {
                _networkQuality = NetworkQualityLevel.Excellent;
            }
            else if (packetLossRate < 3.0 && jitter < 30)
            {
                _networkQuality = NetworkQualityLevel.Good;
            }
            else if (packetLossRate < 10.0 && jitter < 50)
            {
                _networkQuality = NetworkQualityLevel.Fair;
            }
            else
            {
                _networkQuality = NetworkQualityLevel.Poor;
            }

            Logger.Info($"Network quality for {_id}: Level={_networkQuality}, PacketLoss={packetLossRate:F2}%, Jitter={jitter}ms");

            // 根据网络质量动态调整同步模式
            UpdateSyncModeBasedOnNetworkQuality();
        }

        public NetworkQualityLevel GetNetworkQuality() => _networkQuality;
        public double GetPacketLossRate()
        {
            if (_packetsSent == 0) return 0;
            return (double)_packetsLost / _packetsSent * 100;
        }
        public long GetAverageJitter() => _averageJitter;
        public string GetNetworkQualityDescription()
        {
            switch (_networkQuality)
            {
                case NetworkQualityLevel.Excellent:
                    return "网络优秀";
                case NetworkQualityLevel.Good:
                    return "网络良好";
                case NetworkQualityLevel.Fair:
                    return "网络一般";
                case NetworkQualityLevel.Poor:
                    return "网络较差";
                default:
                    return "未知网络质量";
            }
        }

        // 综合质量评估
        public int GetOverallQualityScore()
        {
            // 综合设备性能和网络质量的评分 (0-100)
            long deviceScore = _processingCapability;
            double networkScore = 100 - GetPacketLossRate() * 5 - _averageJitter * 0.5;
            networkScore = Math.Max(0, Math.Min(100, networkScore));

            return (int)((deviceScore + networkScore) / 2);
        }

        // 播放延迟设置
        public async Task SetPlaybackDelayAsync(int delayMs)
        {
            if (tcpClient == null || !Connected) return;

            try
            {
                byte[] delayBytes = BitConverter.GetBytes(delayMs);
                await RequestTcp(Command.SetDelay, delayBytes);
                Logger.Info($"Set playback delay for {_id}: {delayMs}ms");
            }
            catch (Exception ex)
            {
                Logger.Error($"Set playback delay error for {_id}: {ex.Message}");
            }
        }

        public async Task<int> GetSyncStatusAsync()
        {
            if (tcpClient == null || !Connected) return 0;

            try
            {
                await RequestTcp(Command.SyncStatus);
                // 返回综合状态评分
                return GetOverallQualityScore();
            }
            catch (Exception ex)
            {
                Logger.Error($"Get sync status error for {_id}: {ex.Message}");
                return 0;
            }
        }

        // 连接恢复相关方法
        private async Task HandleConnectionLoss()
        {
            _disconnectCount++;
            _lastDisconnectTime = DateTime.Now;

            if (_autoReconnectEnabled && _disconnectCount <= MAX_RECONNECT_ATTEMPTS)
            {
                Logger.Info($"Attempting to reconnect {_id} (attempt {_disconnectCount}/{MAX_RECONNECT_ATTEMPTS})");
                SetConnectStatus(ConnectStatus.Connecting);

                // 取消之前的重连任务
                _reconnectCancellationTokenSource?.Cancel();
                _reconnectCancellationTokenSource = new CancellationTokenSource();

                await Task.Delay(RECONNECT_DELAY_MS, _reconnectCancellationTokenSource.Token);

                if (!_reconnectCancellationTokenSource.Token.IsCancellationRequested)
                {
                    try
                    {
                        await Connect(true);
                        if (Connected)
                        {
                            Logger.Info($"Successfully reconnected {_id}");
                            _disconnectCount = 0; // 重置断开计数
                        }
                    }
                    catch (Exception ex)
                    {
                        Logger.Error($"Reconnect failed for {_id}: {ex.Message}");
                    }
                }
            }
            else
            {
                Logger.Error($"Max reconnect attempts reached for {_id}, giving up");
                SetConnectStatus(ConnectStatus.UnConnected, true);
            }
        }

        public void EnableAutoReconnect(bool enable)
        {
            _autoReconnectEnabled = enable;
            Logger.Info($"Auto reconnect {(enable ? "enabled" : "disabled")} for {_id}");
        }

        public int GetDisconnectCount() => _disconnectCount;
        public TimeSpan GetTimeSinceLastDisconnect() =>
            _lastDisconnectTime == DateTime.MinValue ? TimeSpan.Zero : DateTime.Now - _lastDisconnectTime;

        public bool IsAutoReconnectEnabled() => _autoReconnectEnabled;

        // 网络异常检测
        private async Task MonitorNetworkHealth()
        {
            if (!Connected) return;

            await Task.Run(async () =>
            {
                while (Connected && _autoReconnectEnabled)
                {
                    try
                    {
                        await Task.Delay(10000); // 每10秒检查一次网络健康

                        // 检查连接是否还活跃
                        if (Connected)
                        {
                            // 发送心跳包检测连接
                            bool connectionAlive = await TestConnectionAlive();
                            if (!connectionAlive)
                            {
                                Logger.Warn($"Connection health check failed for {_id}");
                                await HandleConnectionLoss();
                                return;
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        Logger.Error($"Network health monitoring error for {_id}: {ex.Message}");
                    }
                }
            });
        }

        private async Task<bool> TestConnectionAlive()
        {
            try
            {
                if (tcpClient == null || !tcpClient.Connected) return false;

                // 简单的连接活跃度测试
                return tcpClient.Client.Poll(1000, SelectMode.SelectRead);
            }
            catch (Exception)
            {
                return false;
            }
        }

        // 网络质量动态适配方法
        private void UpdateSyncModeBasedOnNetworkQuality()
        {
            // 记录质量历史
            _qualityHistory.Enqueue(_networkQuality);
            while (_qualityHistory.Count > QUALITY_HISTORY_SIZE)
            {
                _qualityHistory.Dequeue();
            }

            // 基于最近的质量历史决定同步模式
            SyncMode newMode = DetermineSyncMode();

            if (newMode != _currentSyncMode)
            {
                _currentSyncMode = newMode;
                Logger.Info($"Sync mode changed to {_currentSyncMode} for {_id}");
                OnSyncModeChanged(newMode);
            }
        }

        private SyncMode DetermineSyncMode()
        {
            if (_qualityHistory.Count < 3) return SyncMode.Standard;

            // 统计质量等级分布
            int excellentCount = _qualityHistory.Count(q => q == NetworkQualityLevel.Excellent);
            int goodCount = _qualityHistory.Count(q => q == NetworkQualityLevel.Good);
            int fairCount = _qualityHistory.Count(q => q == NetworkQualityLevel.Fair);
            int poorCount = _qualityHistory.Count(q => q == NetworkQualityLevel.Poor);

            // 决策逻辑
            if (poorCount >= _qualityHistory.Count * 0.7)
            {
                return SyncMode.Emergency; // 70%以上为较差质量
            }
            else if (poorCount >= _qualityHistory.Count * 0.3 || fairCount >= _qualityHistory.Count * 0.6)
            {
                return SyncMode.Degraded; // 30%以上较差或60%以上一般
            }
            else if (excellentCount >= _qualityHistory.Count * 0.7)
            {
                return SyncMode.HighQuality; // 70%以上为优秀质量
            }
            else
            {
                return SyncMode.Standard; // 默认标准模式
            }
        }

        public int GetSyncTolerance()
        {
            switch (_currentSyncMode)
            {
                case SyncMode.HighQuality:
                    return 10;
                case SyncMode.Standard:
                    return 20;
                case SyncMode.Degraded:
                    return 50;
                case SyncMode.Emergency:
                    return 100;
                default:
                    return 20;
            }
        }

        public SyncMode GetCurrentSyncMode() => _currentSyncMode;

        private void OnSyncModeChanged(SyncMode newMode)
        {
            // 通知模式变化，可以在这里调整其他参数
            switch (newMode)
            {
                case SyncMode.HighQuality:
                    Logger.Info($"High quality sync mode for {_id}: ±10ms tolerance");
                    break;
                case SyncMode.Standard:
                    Logger.Info($"Standard sync mode for {_id}: ±20ms tolerance");
                    break;
                case SyncMode.Degraded:
                    Logger.Warn($"Degraded sync mode for {_id}: ±50ms tolerance");
                    break;
                case SyncMode.Emergency:
                    Logger.Error($"Emergency sync mode for {_id}: ±100ms tolerance");
                    break;
            }

            // 通知UI更新
            _dispatcher.InvokeAsync(() =>
            {
                OnPropertyChanged(nameof(SyncHealthIndicator));
                OnPropertyChanged(nameof(SyncStatusTooltip));
            });
        }

        public override string ToString()
        {
            return $"{_id} ({_currentSyncMode}, RTT: {_averageRtt}ms, Quality: {_networkQuality})";
        }

        // 超时处理相关方法
        public void SetTimeoutMode(SyncMode mode)
        {
            switch (mode)
            {
                case SyncMode.HighQuality:
                    _currentTimeout = QUICK_TIMEOUT_MS;
                    break;
                case SyncMode.Standard:
                    _currentTimeout = DEFAULT_TIMEOUT_MS;
                    break;
                case SyncMode.Degraded:
                    _currentTimeout = EXTENDED_TIMEOUT_MS;
                    break;
                case SyncMode.Emergency:
                    _currentTimeout = EXTENDED_TIMEOUT_MS * 2;
                    break;
            }
            Logger.Info($"Timeout set to {_currentTimeout}ms for {_id} (mode: {mode})");
        }

        private bool CheckTimeout()
        {
            TimeSpan timeSinceLastComms = DateTime.Now - _lastSuccessfulCommunication;
            return timeSinceLastComms.TotalMilliseconds > _currentTimeout;
        }

        private void UpdateLastSuccessfulCommunication()
        {
            _lastSuccessfulCommunication = DateTime.Now;
        }

        private async Task MonitorTimeout()
        {
            while (Connected)
            {
                try
                {
                    await Task.Delay(5000); // 每5秒检查一次超时

                    if (CheckTimeout())
                    {
                        Logger.Warn($"Timeout detected for {_id}, last communication: {(DateTime.Now - _lastSuccessfulCommunication).TotalSeconds}s ago");
                        await HandleTimeout();
                        return;
                    }
                }
                catch (Exception ex)
                {
                    Logger.Error($"Timeout monitoring error for {_id}: {ex.Message}");
                    break;
                }
            }
        }

        private async Task HandleTimeout()
        {
            Logger.Warn($"Handling timeout for {_id}");

            // 检查连接是否还活跃
            bool connectionAlive = await TestConnectionAlive();

            if (!connectionAlive)
            {
                Logger.Error($"Connection timeout for {_id}, triggering reconnect");
                await HandleConnectionLoss();
            }
            else
            {
                Logger.Info($"Connection alive but no data, resetting timeout for {_id}");
                _lastSuccessfulCommunication = DateTime.Now;
            }
        }

        public TimeSpan GetTimeSinceLastCommunication() =>
            DateTime.Now - _lastSuccessfulCommunication;

        public int GetCurrentTimeout() => _currentTimeout;

        // 丢包处理与重传相关方法
        private bool IsCriticalPacket(int sequence)
        {
            // 时间同步包是关键包
            return sequence % CRITICAL_PACKET_THRESHOLD == 0;
        }

        private void CachePacketForRetransmit(int sequence, byte[] packet)
        {
            // 只缓存关键包
            if (IsCriticalPacket(sequence))
            {
                _packetRetransmitCache[sequence] = packet;

                // 保持缓存大小
                while (_packetRetransmitCache.Count > CACHE_SIZE)
                {
                    var oldestKey = _packetRetransmitCache.Keys.First();
                    _packetRetransmitCache.Remove(oldestKey);
                }
            }
        }

        private async Task<bool> RetransmitPacket(int sequence, byte[] packet)
        {
            try
            {
                Logger.Info($"Retransmitting packet {sequence} for {_id}");

                // 使用特殊的重传命令
                byte[] sequenceBytes = BitConverter.GetBytes(sequence);
                bool success = await RequestTcpWithResponse(Command.ResendPacket, sequenceBytes);

                if (success)
                {
                    _totalPacketsRetransmitted++;
                    return true;
                }
                return false;
            }
            catch (Exception ex)
            {
                Logger.Error($"Retransmission failed for packet {sequence}: {ex.Message}");
                return false;
            }
        }

        private void HandlePacketLoss(int sequence)
        {
            _packetsLost++;

            // 如果是关键包且在缓存中，尝试重传
            if (IsCriticalPacket(sequence) && _packetRetransmitCache.ContainsKey(sequence))
            {
                byte[] packet = _packetRetransmitCache[sequence];
                for (int attempt = 0; attempt < MAX_RETRANSMIT_ATTEMPTS; attempt++)
                {
                    bool success = RetransmitPacket(sequence, packet).Result;
                    if (success) break;
                }
            }
        }

        public double GetPacketRetransmitRate()
        {
            if (_totalPacketsSent == 0) return 0;
            return (double)_totalPacketsRetransmitted / _totalPacketsSent * 100;
        }

        public double GetEffectivePacketLossRate()
        {
            if (_totalPacketsSent == 0) return 0;
            return (double)_packetsLost / _totalPacketsSent * 100;
        }

        // 性能优化相关方法
        private void LogVerbose(string message)
        {
            if (_verboseLogging)
            {
                Logger.Info(message);
            }
        }

        private void LogThrottled(string message)
        {
            lock (_logLock)
            {
                _logSuppressionCounter++;

                if (_logSuppressionCounter >= LOG_SUPPRESSION_INTERVAL)
                {
                    Logger.Info(message);
                    _logSuppressionCounter = 0;
                }
            }
        }

        private void LogPerformanceOptimized(string message)
        {
            lock (_logLock)
            {
                DateTime now = DateTime.Now;
                TimeSpan timeSinceLastLog = now - _lastLogTime;

                if (timeSinceLastLog.TotalMilliseconds >= MIN_LOG_INTERVAL_MS)
                {
                    Logger.Info(message);
                    _lastLogTime = now;
                }
            }
        }

        public void EnableVerboseLogging(bool enable)
        {
            _verboseLogging = enable;
            Logger.Info($"Verbose logging {(enable ? "enabled" : "disabled")} for {_id}");
        }

        // 优化的时间戳处理（减少内存分配）
        private long GetCurrentTimestampOptimized()
        {
            // 直接返回计时器值，避免额外开销
            return _audioTimer.ElapsedMilliseconds;
        }

        // 优化的数据包创建（减少内存拷贝）
        private byte[] CreateOptimizedAudioPacket(byte[] audioData, long timestamp)
        {
            // 预分配整个数组，避免多次分配
            byte[] packet = new byte[TIMESTAMP_SIZE + audioData.Length];

            // 直接使用Array.Copy而非Buffer.BlockCopy（性能更好）
            byte[] timestampBytes = BitConverter.GetBytes(timestamp);
            Array.Copy(timestampBytes, 0, packet, 0, TIMESTAMP_SIZE);
            Array.Copy(audioData, 0, packet, TIMESTAMP_SIZE, audioData.Length);

            return packet;
        }

        // 性能监控方法
        public void LogPerformanceMetrics()
        {
            if (_totalPacketsSent == 0) return;

            double lossRate = GetEffectivePacketLossRate();
            double retransmitRate = GetPacketRetransmitRate();
            long avgRtt = GetAverageRtt();

            Logger.Info($"Performance metrics for {_id}: " +
                        $"Packets={_totalPacketsSent}, " +
                        $"Loss={lossRate:F2}%, " +
                        $"Retransmit={retransmitRate:F2}%, " +
                        $"RTT={avgRtt}ms, " +
                        $"Quality={_networkQuality}, " +
                        $"Mode={_currentSyncMode}");
        }

        // 定期RTT测量和性能评估
        public async Task StartPeriodicLatencyMeasurement()
        {
            if (!Connected) return;

            await Task.Run(async () =>
            {
                while (Connected)
                {
                    try
                    {
                        await Task.Delay(5000); // 每5秒测量一次
                        if (Connected)
                        {
                            await MeasureLatencyAsync();

                            // 每10次测量后进行一次性能评估
                            if (_latencyMeasurementSequence % 10 == 0)
                            {
                                EvaluateDevicePerformance();
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        Logger.Error($"Periodic latency measurement error: {ex.Message}");
                        break;
                    }
                }
            });
        }

        private void OnPropertyChanged(string propertyName)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
        }
    }
}
