using NAudio.CoreAudioApi;
using NAudio.Wave;
using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace AudioShare
{
    public class AudioManager
    {
        public static event EventHandler<WaveInEventArgs> StereoAvailable;
        public static event EventHandler<WaveInEventArgs> LeftAvailable;
        public static event EventHandler<WaveInEventArgs> RightAvailable;
        public static event EventHandler Stoped;
        public static event EventHandler<int> OnVolumeNotification;
        public static event EventHandler OnAudioResumed;

        private static WasapiLoopbackCapture _capture;
        private static MMDevice _device;
        private static readonly Dispatcher _dispatcher;
        private static int _sampleRate;
        private static byte[] _leftBuffer;
        private static byte[] _rightBuffer;
        private static bool _wasSilent = true;

        static AudioManager()
        {
            _dispatcher = Dispatcher.CurrentDispatcher;
        }

        private AudioManager() { }

        public static int SampleRate => _sampleRate;

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
            _capture = new WasapiLoopbackCapture(device);
            _capture.WaveFormat = new WaveFormat(sampleRate, 16, 2);
            _capture.DataAvailable += SendAudioData;
            if (StereoAvailable != null || LeftAvailable != null || RightAvailable != null)
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
            Logger.Debug("set audio data start");
            StereoAvailable?.Invoke(null, e);
            bool canLeft = LeftAvailable != null;
            bool canRight = RightAvailable != null;
            if (canLeft || canRight)
            {
                int half = e.BytesRecorded / 2;
                if (_leftBuffer == null || _leftBuffer.Length < half)
                {
                    _leftBuffer = new byte[half];
                    _rightBuffer = new byte[half];
                }
                for (int i = 0, j = 0;
                    j < half;
                    i += 4, j += 2)
                {
                    if (canLeft)
                    {
                        _leftBuffer[j] = e.Buffer[i];
                        _leftBuffer[j + 1] = e.Buffer[i + 1];
                    }
                    if (canRight)
                    {
                        _rightBuffer[j] = e.Buffer[i + 2];
                        _rightBuffer[j + 1] = e.Buffer[i + 3];
                    }
                }
                _dispatcher.InvokeAsync(() =>
                {
                    if (canLeft) LeftAvailable?.Invoke(null, new WaveInEventArgs(_leftBuffer, half));
                    if (canRight) RightAvailable?.Invoke(null, new WaveInEventArgs(_rightBuffer, half));
                });
            }
            Logger.Debug("set audio data end");
        }
    }
}
