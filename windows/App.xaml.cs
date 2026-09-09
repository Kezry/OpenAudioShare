using System;
using System.IO.Pipes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;

namespace AudioShare
{
    /// <summary>
    /// Interaction logic for App.xaml
    /// </summary>
    public partial class App : Application
    {
        System.Threading.Mutex procMutex;
        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);
            DispatcherUnhandledException += OnDispatcherUnhandledException;
            AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;
            TaskScheduler.UnobservedTaskException += OnUnobservedTaskException;
            procMutex = new System.Threading.Mutex(true, "_AUDIO_SHARE_MUTEX", out var result);
            if (!result)
            {
                try
                {
                    using (var clientStream = new NamedPipeClientStream(".", "_AUDIO_SHARE_PIPE", PipeDirection.InOut, PipeOptions.None))
                    {
                        clientStream.Connect(2000);
                    }
                }
                catch (Exception)
                {
                }
                Current.Shutdown();
                Environment.Exit(0);
                return;
            }
            MainWindow = new MainWindow();
            MainWindow.Show();
        }

        private void OnDispatcherUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
        {
            Logger.Error("Unhandled UI exception: ", e.Exception);
            e.Handled = true;
        }

        private void OnUnhandledException(object sender, UnhandledExceptionEventArgs e)
        {
            Logger.Error("Unhandled exception: ", e.ExceptionObject);
        }

        private void OnUnobservedTaskException(object sender, UnobservedTaskExceptionEventArgs e)
        {
            Logger.Error("Unobserved task exception: ", e.Exception);
            e.SetObserved();
        }

        protected override void OnExit(ExitEventArgs e)
        {
            base.OnExit(e);
            try
            {
                procMutex?.ReleaseMutex();
            }
            catch (Exception)
            {
            }
        }
    }
}
