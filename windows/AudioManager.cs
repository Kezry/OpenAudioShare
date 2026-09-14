using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;
using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace AudioShare
{
    public enum CaptureMode
    {
        Default = 0,
        EventSync = 1,
        LowLatency = 2,
        Compatible = 3,
    }

    // Vendor DSP stacks shape the loopback mix differently; the profile picks
    // AGC parameters (and a recommended capture mode) to match.
    public enum CaptureProfile
    {
        Auto = 0,
        Generic = 1,
        Realtek = 2,
        Dolby = 3,
        SmartAudio = 4,
    }

    public class AudioFrameEventArgs : EventArgs
    {
        public byte[] Buffer { get; }
        public int BytesRecorded { get; }
        public int Channels { get; }
        public int ChannelMask { get; }

        public AudioFrameEventArgs(byte[] buffer, int bytesRecorded, int channels, int channelMask)
        {
            Buffer = buffer;
            BytesRecorded = bytesRecorded;
            Channels = channels;
            ChannelMask = channelMask;
        }
    }

    public class AudioManager
    {
        public static event EventHandler<AudioFrameEventArgs> AudioFrameAvailable;
        public static event EventHandler Stoped;
        public static event EventHandler<int> OnVolumeNotification;
        public static event EventHandler OnAudioResumed;
        // Language resource key describing a capture problem; Model shows the toast.
        public static event EventHandler<string> CaptureError;

        private const int MaxCaptureRestarts = 2;
        private const int MaxDeviceRecoveries = 3;
        private const int RestartDelayMs = 2000;

        private static readonly object _syncLock = new object();
        private static readonly MMDeviceEnumerator _deviceEnumerator = new MMDeviceEnumerator();
        private static readonly DeviceNotifications _deviceNotifications = new DeviceNotifications();
        private static bool _deviceNotificationsRegistered;

        private static WasapiCapture _capture;
        private static MMDevice _device;
        private static int _sampleRate;
        private static CaptureMode _mode = CaptureMode.Default;
        private static CaptureProfile _profile = CaptureProfile.Auto;
        private static CaptureProfile? _detectedProfile;
        private static int _channelCount = 2;
        private static int _channelMask = 0x3;
        private static bool _wasSilent = true;
        private static float _gain = 1f;
        private static bool _autoGain;
        private static double _agcEnvelope;
        private static double _agcGain = 1.0;
        private static int _captureRestarts;
        private static int _deviceRecoveries;
        private static string _awaitedDeviceId;
        private static Timer _restartTimer;

        public static int SampleRate => _sampleRate;
        public static int Channels => _channelCount;
        public static int ChannelMask => _channelMask;

        public static CaptureMode CaptureMode
        {
            get => _mode;
            set
            {
                if ((int)value < 0 || (int)value > (int)CaptureMode.Compatible)
                {
                    value = CaptureMode.Default;
                }
                _mode = value;
            }
        }

        public static CaptureProfile CaptureProfile
        {
            get => _profile;
            set
            {
                int v = (int)value;
                if (v < 0 || v > (int)CaptureProfile.SmartAudio)
                {
                    v = 0;
                }
                _profile = (CaptureProfile)v;
                ResolveProfileParams();
            }
        }

        public static CaptureProfile EffectiveProfile => _profile != CaptureProfile.Auto ? _profile : DetectedProfile;

        // Set once the user picks a capture mode themselves; until then a
        // driver profile may recommend a different one.
        public static bool CaptureModeChosen { get; set; }

        public static CaptureMode EffectiveCaptureMode
        {
            get
            {
                if (!CaptureModeChosen && _mode == CaptureMode.Default && EffectiveProfile == CaptureProfile.SmartAudio)
                {
                    // Lenovo SmartAudio / Intel SST loopback is a known
                    // stutterer with poll sync; event sync is steadier there.
                    return CaptureMode.EventSync;
                }
                return _mode;
            }
        }

        // Software boost applied to captured samples before they are handed to
        // speakers. Loopback taps the mix *after* endpoint volume, so machines
        // that keep Windows volume low (with loud amplified speakers) stream a
        // quiet signal; the receiver-side volume control cannot fix that.
        public static float Gain
        {
            get => _gain;
            set => _gain = Math.Max(0.25f, Math.Min(4f, value));
        }

        // Loudness normalization across machines. The loopback mix level varies
        // a lot between PCs even at 100% master volume (per-app mixer volumes,
        // driver enhancements, source loudness), so the adaptive gain converges
        // to a fixed RMS target; the manual gain slider still trims on top.
        private const double AgcMinGain = 0.25;
        private const double AgcSilencePeak = 64.0 / 32768.0;    // ~ -54 dBFS, don't chase noise
        private const double AgcEnvelopeTauSec = 0.5;
        // Effective values, resolved per capture profile.
        private static double _agcTarget = 0.12;                 // ~ -18 dBFS RMS
        private static double _agcMaxGain = 8.0;
        private static double _agcSlewDbPerSec = 6.0;            // keep gain moves inaudible

        private static void ResolveProfileParams()
        {
            switch (EffectiveProfile)
            {
                case CaptureProfile.Dolby:
                    // The Dolby APO already loudness-normalizes and limits;
                    // heavy AGC on top audibly pumps. Trim gently, stop early.
                    _agcTarget = 0.10;
                    _agcMaxGain = 2.0;
                    _agcSlewDbPerSec = 3.0;
                    break;
                case CaptureProfile.SmartAudio:
                    // MaxxAudio/SmartAudio stacks normalize too, just less hot.
                    _agcTarget = 0.11;
                    _agcMaxGain = 2.5;
                    _agcSlewDbPerSec = 3.0;
                    break;
                case CaptureProfile.Realtek:
                    // Stock Realtek mixes run quiet; aim slightly hotter.
                    _agcTarget = 0.14;
                    _agcMaxGain = 8.0;
                    _agcSlewDbPerSec = 6.0;
                    break;
                default:
                    _agcTarget = 0.12;
                    _agcMaxGain = 8.0;
                    _agcSlewDbPerSec = 6.0;
                    break;
            }
        }

        private static readonly string[] SmartAudioKeywords =
        {
            "maxxaudio", "maxx audio", "smartaudio", "smart audio", "waves",
            "conexant", "synaptics", "smart sound", "智音",
        };

        private static CaptureProfile DetectedProfile
        {
            get
            {
                if (!_detectedProfile.HasValue)
                {
                    _detectedProfile = DetectProfile();
                }
                return _detectedProfile.Value;
            }
        }

        // Vendor DSPs advertise themselves in machine-wide registry text;
        // there is no direct query API on net462, so fingerprint from three
        // read-only sources: adapter driver descriptions, service display
        // names, and installed-program entries.
        private static CaptureProfile DetectProfile()
        {
            var signatures = new List<KeyValuePair<string, string>>();
            try
            {
                using (var cls = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                    @"SYSTEM\CurrentControlSet\Control\Class\{4d36e96c-e325-11ce-bfc1-08002be10318}"))
                {
                    if (cls != null)
                    {
                        foreach (string name in cls.GetSubKeyNames())
                        {
                            using (var sub = cls.OpenSubKey(name))
                            {
                                string desc = sub?.GetValue("DriverDesc") as string;
                                if (!string.IsNullOrEmpty(desc))
                                {
                                    signatures.Add(new KeyValuePair<string, string>("driver", desc));
                                }
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Logger.Error("profile driver scan failed: " + ex.Message);
            }
            try
            {
                using (var services = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Services"))
                {
                    if (services != null)
                    {
                        foreach (string name in services.GetSubKeyNames())
                        {
                            using (var sub = services.OpenSubKey(name))
                            {
                                string display = sub?.GetValue("DisplayName") as string;
                                if (!string.IsNullOrEmpty(display))
                                {
                                    signatures.Add(new KeyValuePair<string, string>("service", display));
                                }
                            }
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Logger.Error("profile service scan failed: " + ex.Message);
            }
            foreach (string view in new[]
            {
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
                @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
            })
            {
                try
                {
                    using (var uninstall = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(view))
                    {
                        if (uninstall == null) continue;
                        foreach (string name in uninstall.GetSubKeyNames())
                        {
                            using (var sub = uninstall.OpenSubKey(name))
                            {
                                string display = sub?.GetValue("DisplayName") as string;
                                if (!string.IsNullOrEmpty(display))
                                {
                                    signatures.Add(new KeyValuePair<string, string>("program", display));
                                }
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    Logger.Error("profile program scan failed: " + ex.Message);
                }
            }
            // Dolby is checked first: it commonly layers on a Realtek stack.
            if (TryMatchSignature(signatures, "dolby", out string hit))
            {
                Logger.Info($"audio profile: Dolby (matched '{Shorten(hit)}')");
                return CaptureProfile.Dolby;
            }
            foreach (string keyword in SmartAudioKeywords)
            {
                if (TryMatchSignature(signatures, keyword, out hit))
                {
                    Logger.Info($"audio profile: SmartAudio (matched '{keyword}' in '{Shorten(hit)}')");
                    return CaptureProfile.SmartAudio;
                }
            }
            if (TryMatchSignature(signatures, "realtek", out hit))
            {
                Logger.Info($"audio profile: Realtek (matched '{Shorten(hit)}')");
                return CaptureProfile.Realtek;
            }
            Logger.Info("audio profile: Generic (no vendor DSP fingerprint found)");
            return CaptureProfile.Generic;
        }

        private static bool TryMatchSignature(List<KeyValuePair<string, string>> signatures, string keyword, out string hit)
        {
            foreach (var entry in signatures)
            {
                if (entry.Value.IndexOf(keyword, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    hit = entry.Key + ": " + entry.Value;
                    return true;
                }
            }
            hit = null;
            return false;
        }

        private static string Shorten(string text)
        {
            if (string.IsNullOrEmpty(text) || text.Length <= 80) return text;
            return text.Substring(0, 80) + "...";
        }

        public static bool AutoGain
        {
            get => _autoGain;
            set
            {
                _autoGain = value;
                _agcEnvelope = 0;
                _agcGain = 1.0;
            }
        }

        // Loopback only differs from a normal capture by the Loopback stream
        // flag; NAudio's WasapiLoopbackCapture hardcodes poll sync and a 100 ms
        // buffer, so the other modes come from this subclass instead.
        private class LoopbackCapture : WasapiCapture
        {
            public LoopbackCapture(MMDevice device, bool useEventSync, int bufferMs)
                : base(device, useEventSync, bufferMs)
            {
            }

            protected override AudioClientStreamFlags GetAudioClientStreamFlags()
            {
                return AudioClientStreamFlags.Loopback | base.GetAudioClientStreamFlags();
            }
        }

        private static WasapiCapture CreateCapture(MMDevice device)
        {
            switch (EffectiveCaptureMode)
            {
                case CaptureMode.EventSync:
                    return new LoopbackCapture(device, true, 100);
                case CaptureMode.LowLatency:
                    return new LoopbackCapture(device, true, 20);
                case CaptureMode.Compatible:
                    return new LoopbackCapture(device, false, 200);
                default:
                    // Historical path: poll sync, 100 ms buffer.
                    return new WasapiLoopbackCapture(device);
            }
        }

        public static int DefaultMask(int channels)
        {
            // Standard Microsoft channel order when the mask is unavailable.
            switch (channels)
            {
                case 1: return 0x4;                                                     // FC
                case 2: return 0x3;                                                     // FL FR
                case 3: return 0x7;                                                     // FL FR FC
                case 4: return 0x33;                                                    // FL FR BL BR
                case 5: return 0x37;                                                    // FL FR FC BL BR
                case 6: return 0x3F;                                                    // FL FR FC LFE BL BR
                case 7: return 0x13F;                                                   // FL FR FC LFE BC BL BR
                case 8: return 0x63F;                                                   // FL FR FC LFE BL BR SL SR
                default:
                    int mask = 0;
                    for (int i = 0; i < channels; i++) mask |= 1 << i;
                    return mask;
            }
        }

        private static void ReadMixFormat()
        {
            _channelCount = 2;
            _channelMask = 0x3;
            if (_device == null) return;
            try
            {
                using (var client = _device.AudioClient)
                {
                    var mix = client.MixFormat;
                    if (mix != null && mix.Channels > 0 && mix.Channels <= 18)
                    {
                        _channelCount = mix.Channels;
                    }
                    int mask = ReadChannelMask(mix);
                    if (IsValidChannelMask(mask, _channelCount))
                    {
                        _channelMask = mask;
                    }
                    else if (mask != 0)
                    {
                        Logger.Error($"driver reported malformed channel mask 0x{mask:X} for {_channelCount}ch, falling back to 0x{DefaultMask(_channelCount):X}");
                    }
                }
            }
            catch (Exception ex)
            {
                Logger.Error("read mix format error: " + ex.Message);
            }
            if (_channelMask == 0) _channelMask = DefaultMask(_channelCount);
            Logger.Info($"capture format: {_sampleRate}Hz {_channelCount}ch mask=0x{_channelMask:X} mode={EffectiveCaptureMode} profile={EffectiveProfile}");
        }

        private static int ReadChannelMask(WaveFormat format)
        {
            // NAudio 2.x keeps dwChannelMask private; it sits at offset 20 in the
            // serialized WAVEFORMATEXTENSIBLE structure.
            try
            {
                if (format == null) return 0;
                using (var ms = new MemoryStream())
                using (var writer = new BinaryWriter(ms))
                {
                    format.Serialize(writer);
                    var bytes = ms.ToArray();
                    if (bytes.Length >= 24)
                    {
                        return BitConverter.ToInt32(bytes, 20);
                    }
                }
            }
            catch (Exception)
            {
            }
            return 0;
        }

        private static bool IsValidChannelMask(int mask, int channels)
        {
            if (mask <= 0 || channels <= 0) return false;
            // Bits above SPEAKER_TOP_BACK_RIGHT (0x20000) are reserved, and
            // WAVEFORMATEXTENSIBLE requires exactly one set bit per channel.
            // Some drivers violate both (e.g. a Realtek reporting 2ch with
            // mask 0x200016); routing by such a mask mutes real channels.
            if ((mask & ~0x3FFFF) != 0) return false;
            int bits = 0;
            while (mask != 0)
            {
                bits += mask & 1;
                mask >>= 1;
            }
            return bits == channels;
        }

        public static void SetDevice(MMDevice device, int sampleRate, CaptureMode? mode = null, bool notifyStop = true)
        {
            lock (_syncLock)
            {
                if (mode.HasValue) CaptureMode = mode.Value;
                Logger.Info($"set device start mode={EffectiveCaptureMode} profile={EffectiveProfile} notifyStop={notifyStop}");
                if (_capture != null)
                {
                    _capture.DataAvailable -= SendAudioData;
                }
                _capture?.Dispose();
                _capture = null;
                if (notifyStop)
                {
                    Stoped?.Invoke(null, null);
                }
                if (_device != null)
                {
                    _device.AudioEndpointVolume.OnVolumeNotification -= OnVolumeChange;
                }
                if (device == null && sampleRate == 0)
                {
                    _device?.Dispose();
                }
                _device = device;
                if (_device != null)
                {
                    _awaitedDeviceId = null;
                }
                OnVolumeNotification?.Invoke(null, (int)((_device?.AudioEndpointVolume.MasterVolumeLevelScalar ?? 0) * 100));
                _sampleRate = sampleRate;
                if (_device == null)
                {
                    return;
                }
                ReadMixFormat();
                RebuildCapture();
                _captureRestarts = 0;
                _deviceRecoveries = 0;
                _device.AudioEndpointVolume.OnVolumeNotification += OnVolumeChange;
                Logger.Info("set device end");
            }
        }

        private static void RebuildCapture()
        {
            ResolveProfileParams();
            _capture = CreateCapture(_device);
            _capture.WaveFormat = new WaveFormat(_sampleRate, 16, _channelCount);
            _capture.DataAvailable += SendAudioData;
            _capture.RecordingStopped += OnRecordingStopped;
            RegisterDeviceNotifications();
            _agcEnvelope = 0;
            _agcGain = 1.0;
            if (AudioFrameAvailable != null)
            {
                StartCapture();
            }
        }

        private static void RegisterDeviceNotifications()
        {
            if (_deviceNotificationsRegistered) return;
            try
            {
                _deviceEnumerator.RegisterEndpointNotificationCallback(_deviceNotifications);
                _deviceNotificationsRegistered = true;
            }
            catch (Exception ex)
            {
                Logger.Error("register device notifications failed: " + ex.Message);
            }
        }

        public static void StartCapture()
        {
            if (_capture == null) return;
            try
            {
                if (_capture.CaptureState == CaptureState.Stopped)
                {
                    _capture.StartRecording();
                }
            }
            catch (Exception ex)
            {
                Logger.Error("start capture error: " + ex.Message);
                CaptureError?.Invoke(null, "captureError");
            }
        }

        public static void StopCapture()
        {
            try
            {
                _capture?.StopRecording();
            }
            catch (Exception ex)
            {
                Logger.Error("stop capture error: " + ex.Message);
            }
        }

        private static void OnRecordingStopped(object sender, StoppedEventArgs e)
        {
            // Intentional stops (device change, shutdown) carry no exception;
            // only a crashed capture thread needs recovery.
            if (e?.Exception == null) return;
            Logger.Error("capture stopped: " + e.Exception.Message);
            if (_device == null || _awaitedDeviceId != null) return;
            if (_captureRestarts >= MaxCaptureRestarts)
            {
                Logger.Error("capture restart limit reached");
                CaptureError?.Invoke(null, "captureError");
                return;
            }
            _captureRestarts++;
            if (_restartTimer == null)
            {
                _restartTimer = new Timer(RestartCapture);
            }
            _restartTimer.Change(RestartDelayMs, Timeout.Infinite);
        }

        private static void RestartCapture(object state)
        {
            // A dead capture cannot be resumed on the same AudioClient; rebuild
            // it from scratch. TryEnter so a concurrent UI SetDevice wins.
            if (!Monitor.TryEnter(_syncLock)) return;
            try
            {
                if (_device == null || _capture == null || _awaitedDeviceId != null) return;
                if (_capture.CaptureState == CaptureState.Capturing) return;
                Logger.Info("capture auto-restart");
                _capture.DataAvailable -= SendAudioData;
                _capture.Dispose();
                RebuildCapture();
            }
            catch (Exception ex)
            {
                Logger.Error("capture restart failed: " + ex.Message);
            }
            finally
            {
                Monitor.Exit(_syncLock);
            }
        }

        private static void OnCurrentDeviceLost(string deviceId, string reason)
        {
            if (_device == null || _awaitedDeviceId != null) return;
            if (!string.Equals(_device.ID, deviceId, StringComparison.OrdinalIgnoreCase)) return;
            Logger.Warning($"capture device lost ({reason})");
            _awaitedDeviceId = deviceId;
            _deviceRecoveries = 0;
            StopCapture();
            CaptureError?.Invoke(null, "captureDeviceLost");
        }

        private static void TryRecoverDevice(string deviceId, string reason)
        {
            if (_device == null || _awaitedDeviceId == null) return;
            if (!string.Equals(_awaitedDeviceId, deviceId, StringComparison.OrdinalIgnoreCase)) return;
            if (_deviceRecoveries >= MaxDeviceRecoveries)
            {
                _awaitedDeviceId = null;
                return;
            }
            MMDevice fresh = FindActiveDevice(deviceId);
            if (fresh == null) return;
            lock (_syncLock)
            {
                _awaitedDeviceId = null;
                _deviceRecoveries++;
                if (_device != null)
                {
                    _device.AudioEndpointVolume.OnVolumeNotification -= OnVolumeChange;
                }
                _device = fresh;
                OnVolumeNotification?.Invoke(null, (int)((_device?.AudioEndpointVolume.MasterVolumeLevelScalar ?? 0) * 100));
                _capture?.Dispose();
                _capture = null;
                Logger.Info($"capture device returned ({reason}), restarting capture");
                ReadMixFormat();
                RebuildCapture();
                _captureRestarts = 0;
            }
        }

        private static MMDevice FindActiveDevice(string deviceId)
        {
            try
            {
                foreach (var device in _deviceEnumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
                {
                    if (string.Equals(device.ID, deviceId, StringComparison.OrdinalIgnoreCase))
                    {
                        return device;
                    }
                    device.Dispose();
                }
            }
            catch (Exception ex)
            {
                Logger.Error("enumerate devices failed: " + ex.Message);
            }
            return null;
        }

        private class DeviceNotifications : IMMNotificationClient
        {
            public void OnDeviceStateChanged(string deviceId, DeviceState newState)
            {
                if (newState == DeviceState.Active)
                {
                    // Driver resets often re-activate the same endpoint without
                    // a remove/add pair, so recovery listens here too.
                    TryRecoverDevice(deviceId, "state active");
                }
                else
                {
                    OnCurrentDeviceLost(deviceId, "state " + newState);
                }
            }

            public void OnDeviceAdded(string deviceId)
            {
                TryRecoverDevice(deviceId, "added");
            }

            public void OnDeviceRemoved(string deviceId)
            {
                OnCurrentDeviceLost(deviceId, "removed");
            }

            public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
            {
                // Only a hint: the capture follows the user-picked device, so a
                // changed system default can leave speakers silent with no clue why.
                if (flow != DataFlow.Render || AudioFrameAvailable == null) return;
                if (role != Role.Console && role != Role.Multimedia) return;
                if (_device == null) return;
                if (string.Equals(_device.ID, defaultDeviceId, StringComparison.OrdinalIgnoreCase)) return;
                Logger.Info($"default render device changed to {defaultDeviceId}");
                CaptureError?.Invoke(null, "captureDeviceChanged");
            }

            public void OnPropertyValueChanged(string deviceId, PropertyKey key)
            {
            }
        }

        private static CancellationTokenSource SetRemoteVolumeCancel = null;
        private static async void OnVolumeChange(AudioVolumeNotificationData data)
        {
            SetRemoteVolumeCancel?.Cancel();
            SetRemoteVolumeCancel = new CancellationTokenSource();
            CancellationToken token = SetRemoteVolumeCancel.Token;
            await Task.Delay(200);
            if (token.IsCancellationRequested) return;
            OnVolumeNotification?.Invoke(null, data.Muted ? 0 : (int)(data.MasterVolume * 100));
        }

        private static void SendAudioData(object sender, WaveInEventArgs e)
        {
            if (e.BytesRecorded <= 0)
            {
                _wasSilent = true;
                return;
            }
            if (_wasSilent)
            {
                _wasSilent = false;
                OnAudioResumed?.Invoke(null, EventArgs.Empty);
            }
            ApplyGain(e.Buffer, e.BytesRecorded);
            AudioFrameAvailable?.Invoke(null, new AudioFrameEventArgs(e.Buffer, e.BytesRecorded, _channelCount, _channelMask));
        }

        private static void ApplyGain(byte[] buffer, int length)
        {
            if (_autoGain)
            {
                ApplyAutoGain(buffer, length);
                return;
            }
            if (_gain == 1f || length < 2) return;
            ScaleSamples(buffer, length, _gain);
        }

        private static void ApplyAutoGain(byte[] buffer, int length)
        {
            int samples = length >> 1;
            if (samples <= 0 || _sampleRate <= 0) return;
            long sumSq = 0;
            int maxAbs = 0;
            for (int i = 1; i < length; i += 2)
            {
                short sample = (short)(buffer[i - 1] | (buffer[i] << 8));
                sumSq += sample * sample;
                int abs = sample == short.MinValue ? short.MaxValue : Math.Abs(sample);
                if (abs > maxAbs) maxAbs = abs;
            }
            double peak = maxAbs / 32768.0;
            if (peak >= AgcSilencePeak)
            {
                double rms = Math.Sqrt((double)sumSq / samples) / 32768.0;
                double frameSec = samples / (double)(_sampleRate * Math.Max(1, _channelCount));
                double alpha = 1.0 - Math.Exp(-frameSec / AgcEnvelopeTauSec);
                _agcEnvelope += (rms - _agcEnvelope) * alpha;
                if (_agcEnvelope > 1e-6)
                {
                    double target = Math.Max(AgcMinGain, Math.Min(_agcMaxGain, _agcTarget / _agcEnvelope));
                    double slew = Math.Pow(10.0, _agcSlewDbPerSec * frameSec / 20.0);
                    if (target > _agcGain) _agcGain = Math.Min(target, _agcGain * slew);
                    else _agcGain = Math.Max(target, _agcGain / slew);
                }
            }
            ScaleSamples(buffer, length, _agcGain * _gain);
        }

        private static void ScaleSamples(byte[] buffer, int length, double gain)
        {
            if (gain == 1f || length < 2) return;
            for (int i = 0; i + 1 < length; i += 2)
            {
                short sample = (short)(buffer[i] | (buffer[i + 1] << 8));
                int scaled = (int)(sample * gain);
                if (scaled > short.MaxValue)
                {
                    scaled = short.MaxValue;
                }
                else if (scaled < short.MinValue)
                {
                    scaled = short.MinValue;
                }
                buffer[i] = (byte)scaled;
                buffer[i + 1] = (byte)(scaled >> 8);
            }
        }
    }
}
