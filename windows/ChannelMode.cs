using System.Collections.Generic;

namespace AudioShare
{
    public enum ChannelMode
    {
        Stereo = 0,
        Ch21 = 1,
        Ch51 = 2,
        Ch71 = 3
    }

    public static class ChannelModeMap
    {
        // The mode is chosen by the user first; capture and per-speaker channel
        // menus then follow it, so every offered channel exists in the capture.

        public static string Name(ChannelMode mode)
        {
            switch (mode)
            {
                case ChannelMode.Ch21: return "2.1声道";
                case ChannelMode.Ch51: return "5.1声道";
                case ChannelMode.Ch71: return "7.1声道";
                default: return "立体声";
            }
        }

        public static string Hint(ChannelMode mode)
        {
            switch (mode)
            {
                case ChannelMode.Ch21: return "左、右、重低音";
                case ChannelMode.Ch51: return "左/右、中置、重低音、后置左/右";
                case ChannelMode.Ch71: return "左/右、中置、重低音、环绕左/右、后置左/右";
                default: return "左、右";
            }
        }

        public static int CaptureChannels(ChannelMode mode)
        {
            switch (mode)
            {
                case ChannelMode.Ch51:
                case ChannelMode.Ch21: return 6;
                case ChannelMode.Ch71: return 8;
                default: return 2;
            }
        }

        public static int CaptureMask(ChannelMode mode)
        {
            switch (mode)
            {
                case ChannelMode.Ch51:
                // 2.1 captures the standard 5.1 layout (FL FR FC LFE BL BR);
                // the non-standard 3-channel FL FR LFE mask is not one the audio
                // engine reliably accepts, and only L/R/LFE are offered anyway.
                case ChannelMode.Ch21: return 0x3F;
                case ChannelMode.Ch71: return 0x63F;
                default: return 0x3;
            }
        }

        public static AudioChannel[] SpeakerChannels(ChannelMode mode)
        {
            switch (mode)
            {
                case ChannelMode.Ch21:
                    return new[] { AudioChannel.Left, AudioChannel.Right, AudioChannel.Lfe };
                case ChannelMode.Ch51:
                    return new[] { AudioChannel.Left, AudioChannel.Right, AudioChannel.Center,
                        AudioChannel.Lfe, AudioChannel.BackLeft, AudioChannel.BackRight };
                case ChannelMode.Ch71:
                    return new[] { AudioChannel.Left, AudioChannel.Right, AudioChannel.Center,
                        AudioChannel.Lfe, AudioChannel.SideLeft, AudioChannel.SideRight,
                        AudioChannel.BackLeft, AudioChannel.BackRight };
                default:
                    return new[] { AudioChannel.Left, AudioChannel.Right };
            }
        }

        public static bool IsValid(ChannelMode mode, AudioChannel channel)
        {
            if (channel == AudioChannel.None || channel == AudioChannel.Stereo) return true;
            return ((IList<AudioChannel>)SpeakerChannels(mode)).Contains(channel);
        }
    }
}
