package com.picapico.audioshare;

import android.annotation.SuppressLint;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Binder;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.core.content.ContextCompat;

import com.phicomm.speaker.player.light.PlayerVisualizer;
import com.picapico.audioshare.musiche.player.AudioPlayer;
import com.picapico.audioshare.musiche.HttpServer;
import com.picapico.audioshare.musiche.notification.NotificationService;

import java.io.Closeable;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.Timer;
import java.util.TimerTask;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class TcpService extends NotificationService {
    private static final String TAG = "AudioShareService";
    private static final String HEAD = "picapico-audio-share";
    private static final String DISCOVER_PROBE = HEAD + "-find";
    private static final int DISCOVERY_PORT = 58270;
    public  static final String CHANNEL_ID = "com.picapico.audio_share";
    public static int NOTIFICATION_ID = 1;
    private final IBinder binder = new TcpBinder();
    private MessageListener mListener;
    private LocalServerSocket localServerSocket = null;
    private ServerSocket serverSocket = null;
    private AudioManager mAudioManager = null;
    private AudioTrack mAudioTrack = null;
    private OutputStream mSocketOutputStream = null;
    private int maxAudioVolume = 15;

    private boolean isWriting = false;
    private WakeLockManager mWakeLockManager;
    private final ExecutorService mExecutorService = Executors.newSingleThreadExecutor();
    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private HttpServer httpServer;
    private SharedPreferences mSharedPreferences;
    private volatile int playbackDelayMs = 0;
    private volatile int appliedDelayMs = 0;
    private volatile int pendingDelayChange = 0;
    private volatile long lastDataTimeMs = 0;
    private int mSampleRate = 44100;
    private int mBytesPerFrame = 4;
    private static final int RESEED_GAP_MS = 1500;
    private final byte[] _readHeadBuf = new byte[20];
    private final byte[] _readIntBuf = new byte[4];
    private static final byte[] _heartBeatByte = new byte[1];

    public int getPlaybackDelay() {
        return playbackDelayMs;
    }

    private void setPlaybackDelay(int delayMs, boolean applyNow) {
        int clamped = Math.max(0, Math.min(delayMs, 500));
        int oldDelay = playbackDelayMs;
        playbackDelayMs = clamped;
        if (applyNow && getPlaying() && clamped != appliedDelayMs) {
            Log.i(TAG, "Playback delay " + oldDelay + "ms -> " + clamped + "ms, applying now");
            pendingDelayChange = clamped - appliedDelayMs;
        }else {
            // Stored only; takes effect when the next track reseeds the backlog,
            // so playback is never interrupted by background RTT measurements.
            Log.i(TAG, "Playback delay target " + clamped + "ms (was " + oldDelay + "ms), applied on next track");
        }
    }
    @Override
    public void onCreate() {
        super.onCreate();
        mWakeLockManager = new WakeLockManager(this);
        Log.i(TAG, "Service on created");
        new Thread(this::startLocalServer).start();
        new Thread(this::startServer).start();
        new Thread(this::startDiscoveryListener).start();
        mSharedPreferences = getSharedPreferences("app", Context.MODE_PRIVATE);
        if(mSharedPreferences.getBoolean("http-server", true)){
            this.startHttpServer();
        }
        this.startBroadcastTimer();
    }
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Log.i(TAG, "Service on start command");
        return START_STICKY;
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        super.onTaskRemoved(rootIntent);
        Log.i(TAG, "Service on task removed");
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        stopForeground(true);
        stopAudio();
        Log.i(TAG, "Service on destroy");
        try {
            if(localServerSocket != null){
                localServerSocket.close();
                localServerSocket = null;
            }
        } catch (IOException e) {
            Log.e(TAG, "close local server error: " + e);
        }
        try {
            if(serverSocket != null){
                serverSocket.close();
                serverSocket = null;
            }
        } catch (IOException e) {
            Log.e(TAG, "close tcp server error: " + e);
        }
        if(httpServer != null) httpServer.stop();
    }

    private byte readHead(InputStream stream) throws IOException {
        int bufferLength = HEAD.length();
        int offset = 0;
        int bytesRead;
        while (offset < bufferLength &&
                (bytesRead = stream.read(_readHeadBuf, offset, bufferLength - offset)) != -1){
            offset += bytesRead;
        }
        if(new String(_readHeadBuf, 0, bufferLength).equalsIgnoreCase(HEAD)){
            while ((bytesRead = stream.read(_readHeadBuf, 0, 1)) != -1){
                if(bytesRead >= 1) return _readHeadBuf[0];
            }
        }
        return 0;
    }

    private int readInt(InputStream stream) throws IOException {
        int offset = 0;
        int bytesRead = 0;
        while (offset < 4 &&
                (bytesRead = stream.read(_readIntBuf, offset, 4 - offset)) != -1){
            offset += bytesRead;
        }
        if(bytesRead < 0){
            throw new IOException("read stream eol.");
        }
        return parseInt(_readIntBuf);
    }

    private int lastPCVolume = 1;
    private void processControlStream(byte command, InputStream stream) {
        if(command == 2){
            try {
                int volume = readInt(stream);
                lastPCVolume = maxAudioVolume * volume / 100;
                setVolume(lastPCVolume);
            } catch (IOException e) {
                Log.e(TAG, "read volume error: " + e);
            }
        }else if(command == 3) {
            PlayerVisualizer.updateTimeMillis();
        }else if(command == 4) {
            if(getPlaying() && getPlayerCloser() != null){
                try {
                    getPlayerCloser().close();
                } catch (IOException ignored) {
                }
                setPlayerCloser(null);
                for (int i = 0; i < 10; i++) {
                    if(!getPlaying()) break;
                    try {
                        Thread.sleep(50);
                    } catch (InterruptedException ignored) {
                    }
                }
            }
        }else if(command == 5) {
            // MeasureLatency - no payload, ack is automatic via socket lifecycle
        }else if(command == 6) {
            try {
                int delayMs = readInt(stream);
                boolean applyNow = stream.read() == 1;
                setPlaybackDelay(delayMs, applyNow);
            } catch (IOException e) {
                Log.e(TAG, "read delay error: " + e);
            }
        }
    }

    private void setVolume(int volume) {
        mHandler.post(() -> {
            try {
                Log.i(TAG, "set music volume " + volume);
                mAudioManager.setStreamVolume(
                        AudioManager.STREAM_MUSIC,
                        volume,
                        AudioManager.FLAG_SHOW_UI);
            } catch (Exception ignored){
            }
        });
    }

    private void processSocketClient(Closeable socket) throws IOException {
        InputStream stream;
        OutputStream outputStream;
        boolean isLocal = false;
        if (socket instanceof LocalSocket){
            stream = ((LocalSocket)socket).getInputStream();
            outputStream = ((LocalSocket)socket).getOutputStream();
            isLocal = true;
        }else if (socket instanceof Socket){
            stream = ((Socket)socket).getInputStream();
            outputStream = ((Socket)socket).getOutputStream();
        }else {
            return;
        }
        byte command = readHead(stream);
        Log.i(TAG, "client connected: " + command);
        if(command == 1 && !getPlaying()){
            int sampleRate = readInt(stream);
            int channel = readInt(stream);
            int audioFormat = AudioFormat.ENCODING_PCM_16BIT;
            int channelCount = (channel == AudioFormat.CHANNEL_OUT_STEREO) ? 2 : 1;
            mSampleRate = sampleRate;
            mBytesPerFrame = channelCount * 2; // 16-bit = 2 bytes per sample
            int bufferSizeInBytes = AudioTrack.getMinBufferSize(sampleRate, channel, audioFormat);
            int recvBufSize = Math.max(bufferSizeInBytes * 4, 65536);
            if(isLocal){
                ((LocalSocket)socket).setReceiveBufferSize(recvBufSize);
            }else {
                ((Socket)socket).setReceiveBufferSize(recvBufSize);
            }
            new Thread(() -> playAudio(
                    sampleRate,
                    channel,
                    audioFormat,
                    bufferSizeInBytes,
                    socket,
                    stream,
                    outputStream
            )).start();
        }else {
            processControlStream(command, stream);
            socket.close();
        }
    }

    private void startLocalServer(){
        Log.i(TAG, "prepare start local server");
        try {
            localServerSocket = new LocalServerSocket(HEAD);
            while (localServerSocket != null){
                LocalSocket clientSocket = null;
                try {
                    clientSocket = localServerSocket.accept();
                    Log.i(TAG, "local server client accept");
                    processSocketClient(clientSocket);
                } catch (Exception e) {
                    if(clientSocket != null){
                        try {
                            clientSocket.close();
                        } catch (Exception ignored) {
                        }
                    }
                    Log.e(TAG, "process local client error: " + e);
                    e.printStackTrace();
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "start local server error: " + e);
        } finally {
            try {
                if(localServerSocket != null) {
                    localServerSocket.close();
                }
            } catch (IOException e) {
                Log.e(TAG, "close local server error: " + e);
            }
        }
    }
    private void startHttpServer(){
        if(httpServer != null) return;
        Log.i(TAG, "prepare http start server");
        int port = NetworkUtils.getFreePort(Build.MANUFACTURER.equalsIgnoreCase("phicomm") ? 8090 : 8080);
        this.setHttpPort(port);
        httpServer = new HttpServer(getApplicationContext(), port).start();
        httpServer.getAudioPlayer().setMediaMetaChangedListener(new AudioPlayer.OnMediaMetaChangedListener() {
            @Override
            public void onMediaMetaChanged(boolean playing, int position) {
                setMetaData(playing, position);
            }

            @Override
            public void onMediaMetaChanged(String title, String artist, String album, String artwork, boolean lover, boolean playing, int position, int duration) {
                setMetaData(title, artist, album, artwork, lover, playing, position, duration);
            }
        });
        this.setMediaSessionCallback(httpServer.getAudioPlayer().getNotificationCallback());
        httpServer.setSharedPreferences(getSharedPreferences("config", Context.MODE_PRIVATE));
        httpServer.setAssetManager(getAssets());
        httpServer.setVersionName(mVersionName);
    }
    private void startDiscoveryListener(){
        try {
            DatagramSocket socket = new DatagramSocket(DISCOVERY_PORT);
            socket.setBroadcast(true);
            byte[] buffer = new byte[64];
            while (!socket.isClosed()) {
                try {
                    DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                    socket.receive(packet);
                    String message = new String(packet.getData(), 0, packet.getLength()).trim();
                    if (DISCOVER_PROBE.equals(message)) {
                        String reply = HEAD + "@" + getListenPort() + "@" + getHttpPort();
                        byte[] data = reply.getBytes();
                        socket.send(new DatagramPacket(data, data.length, packet.getAddress(), packet.getPort()));
                        Log.i(TAG, "replied discovery probe to " + packet.getAddress().getHostAddress());
                    }
                } catch (Exception e) {
                    Log.e(TAG, "discovery receive error: " + e);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "start discovery listener error: " + e);
        }
    }

    private void startServer(){
        Log.i(TAG, "prepare tcp start server");
        try {
            int port = NetworkUtils.getFreePort();
            serverSocket = new ServerSocket(port);
            if(mListener != null){
                mListener.onMessage();
            }
            setListenPort(port);
            while (serverSocket != null && !serverSocket.isClosed()){
                Socket clientSocket = null;
                try {
                    clientSocket = serverSocket.accept();
                    clientSocket.setTcpNoDelay(true);
                    processSocketClient(clientSocket);
                } catch (Exception e) {
                    if(clientSocket != null){
                        try {
                            clientSocket.close();
                        } catch (Exception ignored) {
                        }
                    }
                    Log.e(TAG, "accept tcp server error: " + e);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "start tcp server error: " + e);
        } finally {
            try {
                if(serverSocket != null) {
                    serverSocket.close();
                }
            } catch (IOException e) {
                Log.e(TAG, "close tcp server error: " + e);
            }
        }
    }

    private boolean isPlaying = false;
    private Closeable playerCloser = null;

    private synchronized void setPlaying(boolean playing) {
        isPlaying = playing;
    }

    /** Atomically claims playback; two concurrent connections must not both play. */
    public synchronized boolean tryStartPlaying() {
        if (isPlaying) return false;
        isPlaying = true;
        return true;
    }

    private synchronized void setPlayerCloser(Closeable closer) {
        playerCloser = closer;
    }

    private synchronized Closeable getPlayerCloser() {
        return playerCloser;
    }

    public synchronized boolean getPlaying() {
        return isPlaying;
    }

    private int listenPort = 8088;

    private synchronized void setListenPort(int listenPort) {
        this.listenPort = listenPort;
    }

    public synchronized int getListenPort() {
        return listenPort;
    }

    private int httpPort = 8088;
    private String mVersionName="";

    private synchronized void setHttpPort(int httpPort) {
        this.httpPort = httpPort;
    }

    public synchronized int getHttpPort() {
        return httpPort;
    }

    public synchronized boolean getHttpRunning() {
        return mSharedPreferences.getBoolean("http-server", true) && httpServer != null;
    }

    @SuppressLint("ApplySharedPref")
    public synchronized void setHttpRunning(boolean running) {
        if(running) {
            mSharedPreferences.edit().putBoolean("http-server", true).apply();
            startHttpServer();
        }else {
            String message = getResources().getString(R.string.musiche_closed) + ", " + getResources().getString(R.string.effective_after_restart);
            Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
            final Intent intent = getPackageManager().getLaunchIntentForPackage(getPackageName());
            if(intent != null){
                startActivity(intent);
            }
            mSharedPreferences.edit().putBoolean("http-server", false).commit();
            android.os.Process.killProcess(android.os.Process.myPid());
        }
        if(mListener != null){
            mListener.onMessage();
        }
    }

    public void setMessageListener(MessageListener listener){
        mListener = listener;
    }

    public void setAudioManager(AudioManager audioManager){
        mAudioManager = audioManager;
        maxAudioVolume = mAudioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        if(httpServer != null) httpServer.setAudioManager(audioManager);
    }
    public void setVersionName(String versionName){
        mVersionName = versionName;
        if(httpServer != null) httpServer.setVersionName(versionName);
    }

    private void playAudio(int sampleRateInHz, int channelConfig, int audioEncoding, int bufferSizeInBytes, Closeable closer, InputStream inputStream, OutputStream outputStream){
        if(!tryStartPlaying()) return;
        setPlayerCloser(closer);
        if(mListener != null){
            mListener.onMessage();
        }
        try {
            initNotification();
            mWakeLockManager.acquireWakeLock();
            AudioFormat audioFormat = new AudioFormat.Builder()
                    .setChannelMask(channelConfig)
                    .setEncoding(audioEncoding)
                    .setSampleRate(sampleRateInHz)
                    .build();
            AudioAttributes.Builder audioAttributes = new AudioAttributes.Builder()
                    .setLegacyStreamType(AudioManager.STREAM_MUSIC)
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                audioAttributes.setFlags(AudioAttributes.FLAG_LOW_LATENCY);
            }
            if(httpServer != null) httpServer.getAudioPlayer().pause();
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    mAudioTrack = new AudioTrack.Builder()
                            .setAudioAttributes(audioAttributes.build())
                            .setAudioFormat(audioFormat)
                            .setBufferSizeInBytes(bufferSizeInBytes)
                            .setTransferMode(AudioTrack.MODE_STREAM)
                            .setSessionId(AudioManager.AUDIO_SESSION_ID_GENERATE)
                            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                            .build();
                } else {
                    mAudioTrack = new AudioTrack(
                            audioAttributes.build(),
                            audioFormat,
                            bufferSizeInBytes,
                            AudioTrack.MODE_STREAM,
                            AudioManager.AUDIO_SESSION_ID_GENERATE);
                }
            } catch (Exception e) {
                Log.w(TAG, "Low latency AudioTrack failed, falling back: " + e);
                mAudioTrack = new AudioTrack(
                        audioAttributes.build(),
                        audioFormat,
                        bufferSizeInBytes,
                        AudioTrack.MODE_STREAM,
                        AudioManager.AUDIO_SESSION_ID_GENERATE);
            }
            setVolume(0);
            byte[] buffer = new byte[bufferSizeInBytes];
            int dataLength;
            mAudioTrack.play();
            PlayerVisualizer.startBase(mAudioTrack.getAudioSessionId());
            Log.i(TAG, "play audio ready to read");
            outputStream.write(_heartBeatByte);
            outputStream.flush();
            mSocketOutputStream = outputStream;
            if(playbackDelayMs > 0) {
                try { Thread.sleep(playbackDelayMs); } catch (InterruptedException ignored) {}
            }
            appliedDelayMs = playbackDelayMs;
            lastDataTimeMs = SystemClock.elapsedRealtime();
            DataInputStream stream = new DataInputStream(inputStream);
            while (true) {
                try {
                    stream.readFully(buffer, 0, 4);
                    dataLength = parseInt(buffer);
                    if(dataLength == 0) {
                        continue;
                    }
                    if(dataLength > buffer.length) {
                        if (dataLength > bufferSizeInBytes * 4) {
                            Log.w(TAG, "Skipping oversized packet: " + dataLength + " bytes");
                            stream.skipBytes(dataLength);
                            continue;
                        }
                        buffer = new byte[dataLength];
                    }
                    stream.readFully(buffer, 0, dataLength);
                } catch (Exception e){
                    break;
                }

                long now = SystemClock.elapsedRealtime();
                boolean afterGap = now - lastDataTimeMs > RESEED_GAP_MS;
                lastDataTimeMs = now;

                if (afterGap && mAudioTrack != null) {
                    // A silence gap means the delay backlog has drained; flush any
                    // stale audio and rebuild it so this track starts aligned with
                    // the other devices (arrival + configured delay).
                    Log.i(TAG, "Audio resumed after gap, reseeding delay " + playbackDelayMs + "ms");
                    try {
                        mAudioTrack.pause();
                        mAudioTrack.flush();
                        mAudioTrack.play();
                    } catch (Exception e) {
                        Log.e(TAG, "Reseed flush error: " + e);
                    }
                    if(playbackDelayMs > 0) {
                        try { Thread.sleep(playbackDelayMs); } catch (InterruptedException ignored) {}
                    }
                    appliedDelayMs = playbackDelayMs;
                }

                if (pendingDelayChange != 0) {
                    int change = pendingDelayChange;
                    pendingDelayChange = 0;
                    applyDelayChange(change, stream);
                    appliedDelayMs = playbackDelayMs;
                }

                if(httpServer != null && httpServer.getAudioPlayer().isPlaying()) {
                    continue;
                }
                int written = mAudioTrack.write(buffer, 0, dataLength);
                if(written < 0) {
                    Log.e(TAG, "AudioTrack write error: " + written);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "play audio error: " + e);
        } finally {
            PlayerVisualizer.stopBase();
            try {
                inputStream.close();
            } catch (Exception e) {
                Log.e(TAG, "stop stream error: " + e);
            }
            try {
                closer.close();
            } catch (Exception e) {
                Log.e(TAG, "close audio socket error: " + e);
            }
            stopAudio();
            stopSocketOutputStream();
            stopForeground(true);
            mWakeLockManager.releaseWakeLock();
            setPlaying(false);
            if(mListener != null){
                mListener.onMessage();
            }
            Log.i(TAG, "play audio ended");
        }
    }

    private void applyDelayChange(int changeMs, InputStream stream) {
        Log.i(TAG, "Applying delay change: " + changeMs + "ms");
        if (changeMs > 0) {
            // Increase: pause playback for the delta so the backlog grows into it.
            try {
                if (mAudioTrack != null) mAudioTrack.pause();
                Thread.sleep(changeMs);
                if (mAudioTrack != null) mAudioTrack.play();
            } catch (InterruptedException ignored) {
                try {
                    if (mAudioTrack != null) mAudioTrack.play();
                } catch (Exception ignored2) {
                }
            } catch (Exception e) {
                Log.e(TAG, "Delay increase error: " + e);
            }
        }else {
            // Decrease: discard exactly the delta worth of audio from the stream,
            // so playback moves ahead without dropping the whole buffer.
            long skipTotal = (long) -changeMs * mSampleRate * mBytesPerFrame / 1000;
            try {
                long skipped = 0;
                byte[] scratch = new byte[4096];
                while (skipped < skipTotal) {
                    int n = stream.read(scratch, 0, (int) Math.min(scratch.length, skipTotal - skipped));
                    if (n < 0) break;
                    skipped += n;
                }
                Log.i(TAG, "Skipped " + skipped + " bytes to reduce delay by " + -changeMs + "ms");
            } catch (Exception e) {
                Log.e(TAG, "Delay decrease error: " + e);
            }
        }
    }

    private void stopAudio(){
        pendingDelayChange = 0;
        appliedDelayMs = 0;
        lastDataTimeMs = 0;
        try {
            if(mAudioTrack != null) {
                mAudioTrack.pause();
                mAudioTrack.stop();
                mAudioTrack.flush();
                mAudioTrack.release();
                mAudioTrack = null;
            }
        } catch (Exception e) {
            Log.e(TAG, "stop audio error: " + e);
        }
    }

    private void stopSocketOutputStream(){
        try {
            if(mSocketOutputStream != null) {
                mSocketOutputStream.flush();
                mSocketOutputStream.close();
                mSocketOutputStream = null;
            }
        } catch (Exception e) {
            Log.e(TAG, "stop output stream error: " + e);
        }
    }
    private void createNotificationChannel(){
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
            NotificationChannel serviceChannel = new NotificationChannel(
                    CHANNEL_ID,
                    getResources().getString(R.string.app_name),
                    NotificationManager.IMPORTANCE_LOW
            );
            serviceChannel.enableLights(false);
            serviceChannel.enableVibration(false);
            NotificationManager manager = getSystemService(NotificationManager.class);
            if(manager != null) manager.createNotificationChannel(serviceChannel);
        }
    }
    private void initNotification(){
        createNotificationChannel();
        int flag = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flag = PendingIntent.FLAG_IMMUTABLE;
        }
        Intent infoIntent = new Intent(this, BootReceiver.class);
        PendingIntent pendingInfo = PendingIntent.getActivity(this, 0, infoIntent, flag);
        Notification mNotification = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentIntent(pendingInfo)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setContentTitle(getResources().getString(R.string.app_name))
                .setContentText(getResources().getString(R.string.app_name))
                .build();
        if(ContextCompat.checkSelfPermission(
                this, android.Manifest.permission.WAKE_LOCK) ==
                PackageManager.PERMISSION_GRANTED) {
            startForeground(NOTIFICATION_ID, mNotification);
        }
    }
    private synchronized void setWriting(boolean writing) {
        isWriting = writing;
    }

    public synchronized boolean getWriting() {
        return isWriting;
    }

    private void startBroadcastTimer(){
        Timer timer = new Timer();
        timer.schedule(new TimerTask() {
            private DatagramSocket broadcastSocket;
            @Override
            public void run() {
                if (getPlaying()) {
                    try {
                        if(mSocketOutputStream != null) {
                            mSocketOutputStream.write(_heartBeatByte);
                            Log.i(TAG, "send heartbeat");
                            if(lastPCVolume > 0 && mAudioManager.getStreamVolume(AudioManager.STREAM_MUSIC) == 0){
                                setVolume(lastPCVolume);
                            }
                        }
                    } catch (IOException e) {
                        Log.e(TAG, "send heartbeat err: " + e);
                    }
                    return;
                }
                try {
                    if (broadcastSocket == null || broadcastSocket.isClosed()) {
                        broadcastSocket = new DatagramSocket(0);
                        broadcastSocket.setBroadcast(true);
                    }
                    String message = HEAD + "@" + getListenPort() + "@" + getHttpPort();
                    byte[] data = message.getBytes();
                    for (int i = 58261; i < 58271; i++) {
                        broadcastSocket.send(new DatagramPacket(data, data.length,
                                new InetSocketAddress(NetworkUtils.BROADCAST_ADDRESS, i)));
                    }
                    Log.i(TAG, "send broadcast " + broadcastSocket.getLocalPort());
                } catch (Exception e) {
                    Log.e(TAG, "send broadcast error ", e);
                }
            }
        }, 0, 1000L * 10);
    }

    private int parseInt(@NonNull byte[] data) {
        return (data[0] & 0xFF) |
                ((data[1] & 0xFF) << 8) |
                ((data[2] & 0xFF) << 16) |
                ((data[3] & 0xFF) << 24);
    }

    public class TcpBinder extends Binder {
        TcpService getService() {
            return TcpService.this;
        }
    }

    public interface MessageListener {
        void onMessage();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        Log.i(TAG, "Service on bind");
        return binder;
    }
}
