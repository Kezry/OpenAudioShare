using Newtonsoft.Json;
using System;
using System.Collections.Generic;
using System.IO;

namespace AudioShare
{
    public class Settings
    {
        public class Device
        {
            public string Id { get; set; } = string.Empty;
            public AudioChannel Channel { get; set; } = AudioChannel.None;
            public Device(string id, AudioChannel channel)
            {
                Id = id;
                Channel = channel;
            }
        }
        public string AudioId { get; set; } = string.Empty;
        public List<Device> AdbDevices { get; set; } = new List<Device>();
        public List<Device> IPDevices { get; set; } = new List<Device>();
        public int SampleRate { get; set; } = 48000;
        public int Volume { get; set; } = 50;
        public bool IsUSB { get; set; } = true;
        public bool VolumeFollowSystem { get; set; } = true;
        public bool Acrylic { get; set; } = true;
        public bool AutoConnect { get; set; } = false;

        private static readonly string _loadPath;
        private static readonly Settings _settings;
        static Settings()
        {
            string roming = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            string appName = System.Reflection.Assembly.GetExecutingAssembly()?.GetName()?.Name?.ToString() ?? "AudioShare";
            string dataPath = Path.Combine(roming, appName);
            if (!Directory.Exists(dataPath)) Directory.CreateDirectory(dataPath);
            _loadPath = Path.Combine(dataPath, "audio.share.config.json");
            try
            {
                _settings = JsonConvert.DeserializeObject<Settings>(File.ReadAllText(_loadPath));
            }
            catch (Exception ex)
            {
                Logger.Error("load settings failed, using defaults: " + ex.Message);
            }
            if (_settings == null) _settings = new Settings();
        }

        private Settings() { }

        public static Settings Load()
        {
            return _settings;
        }

        public override string ToString()
        {
            try
            {

                return JsonConvert.SerializeObject(this);
            }
            catch (Exception)
            {
                return string.Empty;
            }
        }

        public void Save()
        {
            try
            {
                // Write-then-replace so a crash mid-save cannot corrupt the only config copy.
                string content = JsonConvert.SerializeObject(this);
                string tempPath = _loadPath + ".tmp";
                File.WriteAllText(tempPath, content);
                if (File.Exists(_loadPath))
                {
                    File.Replace(tempPath, _loadPath, null);
                }
                else
                {
                    File.Move(tempPath, _loadPath);
                }
            }
            catch (Exception ex)
            {
                Logger.Error("save settings error: " + ex.Message);
            }
        }
    }
}
