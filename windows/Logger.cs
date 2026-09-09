using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

namespace AudioShare
{
    public class Logger
    {
        public enum LogLevel
        {
            Error,
            Warning,
            Info,
            Debug
        }

        private const long MaxLogBytes = 5 * 1024 * 1024;
        private static readonly object _logLock = new object();
        private static readonly string _logDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AudioShare", "logs");
        private static string _logDate = string.Empty;
        private static string _logPath = string.Empty;

        private static string Now => DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff");

        private static void Log(LogLevel logLevel = LogLevel.Info, params object[] message)
        {
            string line = $"[{Now}][{logLevel.ToString().ToUpper()}] {string.Join(" ", message)}";
#if DEBUG
            try
            {
                var stacktrace = new StackTrace(skipFrames: 2, fNeedFileInfo: true);
                var frame = stacktrace.GetFrame(0);
                string stack = "";
                if (frame != null)
                {
                    stack = $"{Path.GetFileName(frame.GetFileName())}:{frame.GetFileLineNumber()}:{frame.GetMethod()?.Name}";
                }
                Trace.WriteLine($"[{Now}]{stack} {string.Join(" ", message)}", logLevel.ToString());
            }
            catch (Exception)
            {
            }
#endif
            WriteFile(line);
        }

        private static void WriteFile(string line)
        {
            if (!Monitor.TryEnter(_logLock)) return;
            try
            {
                string date = DateTime.Now.ToString("yyyyMMdd");
                if (_logPath == string.Empty || date != _logDate)
                {
                    _logDate = date;
                    _logPath = Path.Combine(_logDirectory, $"audioshare-{date}.log");
                }
                if (!Directory.Exists(_logDirectory))
                {
                    Directory.CreateDirectory(_logDirectory);
                }
                var info = new FileInfo(_logPath);
                // Drop the oldest of the previous logs once the current one grows too large.
                if (info.Exists && info.Length > MaxLogBytes)
                {
                    foreach (string old in Directory.GetFiles(_logDirectory, "audioshare-*.log"))
                    {
                        try { File.Delete(old); } catch (Exception) { }
                    }
                }
                File.AppendAllText(_logPath, line + Environment.NewLine, Encoding.UTF8);
            }
            catch (Exception)
            {
                // Logging must never take the app down.
            }
            finally
            {
                Monitor.Exit(_logLock);
            }
        }

        public static void Info(params object[] message)
        {
            Log(LogLevel.Info, message);
        }

        public static void Warning(params object[] message)
        {
            Log(LogLevel.Warning, message);
        }

        public static void Error(params object[] message)
        {
            Log(LogLevel.Error, message);
        }

        public static void Debug(params object[] message)
        {
            Log(LogLevel.Debug, message);
        }
    }
}
