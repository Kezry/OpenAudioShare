using NAudio.CoreAudioApi;
using NAudio.Wave;
using System;
using System.Threading;
using System.Threading.Tasks;

namespace AudioShare
{
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

        private static WasapiLoopbackCapture _capture;
        private static MMDevice _device;
        private static int _sampleRate;
        private static int _channelCount = 2;
        private static int _channelMask = 0x3;
        private static bool _wasSilent = true;

        public static int SampleRate => _sampleRate;
        public static int Channels => _channelCount;
        public static int ChannelMask => _channelMask;

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
                    if (mix is WaveFormatExtensible ext)
                    {
                        _channelMask = (int)ext.ChannelMask;
                    }
                }
            }
            catch (Exception ex)
            {
                Logger.Error("read mix format error: " + ex.Message);
            }
            if (_channelMask == 0) _channelMask = DefaultMask(_channelCount);
            Logger.Info($"capture format: {_sampleRate}Hz {_channelCount}ch mask=0x{_channelMask:X}");
        }

        public static void SetDevice(MMDevice device, int sampleRate)
        {
            Logger.Info("set device start");
            if (_capture != null)
            {
                _capture.DataAvailable -= SendAudioData;
            }
            _capture?.Dispose();
            Stoped?.Invoke(null, null);
            if (_device != null)
            {
                _device.AudioEndpointVolume.OnVolumeNotification -= OnVolumeChange;
            }
            if(device == null && sampleRate == 0)
            {
                _device?.Dispose();
            }
            _device = device;
            OnVolumeNotification?.Invoke(null, (int)((_device?.AudioEndpointVolume.MasterVolumeLevelScalar ?? 0) * 100));
            _sampleRate = sampleRate;
            if (_device == null)
            {
                _capture = null;
                return;
            }
            ReadMixFormat();
            // Capture the device's own channel layout (2.1/5.1/7.1...) instead of
            // forcing a stereo downmix, so each channel can be routed to its own
            // playback device. WASAPI auto-converts rate/depth/channels.
            _capture = new WasapiLoopbackCapture(device);
            _capture.WaveFormat = new WaveFormat(_sampleRate, 16, _channelCount);
            _capture.DataAvailable += SendAudioData;
            if (AudioFrameAvailable != null)
            {
                StartCapture();
            }
            _device.AudioEndpointVolume.OnVolumeNotification += OnVolumeChange;
            Logger.Info("set device end");
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
            catch (Exception)
            {

            }
        }

        public static void StopCapture()
        {
            try
            {
                _capture?.StopRecording();
            }
            catch (Exception)
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
            AudioFrameAvailable?.Invoke(null, new AudioFrameEventArgs(e.Buffer, e.BytesRecorded, _channelCount, _channelMask));
        }
    }
}
