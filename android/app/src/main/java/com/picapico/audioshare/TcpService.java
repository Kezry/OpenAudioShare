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
import java.util.Queue;
import java.util.LinkedList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class TcpService extends NotificationService {
    private static final String TAG = "AudioShareService";
    private static final String HEAD = "picapico-audio-share";
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

    // 音频同步相关字段
    private long audioDataCount = 0;
    private long baseTimestamp = 0;
    private long deviceLatency = 0; // 设备延迟（毫秒）
    private long maxLatencyOffset = 200; // 最大延迟偏移量
    private final java.util.Queue<Long> latencyHistory = new java.util.LinkedList<>(); // 延迟历史
    private static final int LATENCY_HISTORY_SIZE = 100; // 延迟历史记录数量

    // 自适应缓冲区管理相关字段
    private int currentBufferSize = 0;
    private int minBufferSize = 4096;
    private int maxBufferSize = 32768;
    private long bufferUnderrunCount = 0;
    private long bufferOverrunCount = 0;
    private final Queue<Integer> bufferUsageHistory = new java.util.LinkedList<>();
    private static final int BUFFER_USAGE_HISTORY_SIZE = 50;

    // 连接恢复相关字段
    private int disconnectCount = 0;
    private long lastDisconnectTime = 0;
    private static final int MAX_RECONNECT_ATTEMPTS = 5;
    private static final int RECONNECT_DELAY_MS = 2000;
    private boolean autoReconnectEnabled = true;
    private final Handler reconnectHandler = new Handler(Looper.getMainLooper());

    // 优化的缓冲区动态调整相关字段
    private int targetBufferSize = 0;
    private int currentBufferSizeTrend = 0; // 1=增长, -1=缩小, 0=稳定
    private static final int BUFFER_CHANGE_THRESHOLD = 3; // 连续多少次变化才调整
    private int bufferChangeCount = 0;
    private long lastBufferSizeChangeTime = 0;
    private static final long BUFFER_CHANGE_COOLDOWN_MS = 5000; // 缓冲区调整冷却时间
    @Override
    public void onCreate() {
        super.onCreate();
        mWakeLockManager = new WakeLockManager(this);
        Log.i(TAG, "Service on created");
        new Thread(this::startLocalServer).start();
        new Thread(this::startServer).start();
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
        byte[] buffer = new byte[bufferLength];
        int offset = 0;
        int bytesRead;
        while (offset < bufferLength &&
                (bytesRead = stream.read(buffer, offset, bufferLength - offset)) != -1){
            offset += bytesRead;
        }
        if(new String(buffer).equalsIgnoreCase(HEAD)){
            while ((bytesRead = stream.read(buffer, 0, 1)) != -1){
                if(bytesRead >= 1) return buffer[0];
            }
        }
        return 0;
    }

    private int readInt(InputStream stream) throws IOException {
        byte[] buffer = new byte[4];
        int offset = 0;
        int bytesRead = 0;
        while (offset < 4 &&
                (bytesRead = stream.read(buffer, offset, 4 - offset)) != -1){
            offset += bytesRead;
        }
        if(bytesRead < 0){
            throw new IOException("read stream eol.");
        }
        return parseInt(buffer);
    }

    private long readLong(InputStream stream) throws IOException {
        byte[] buffer = new byte[8];
        int offset = 0;
        int bytesRead = 0;
        while (offset < 8 &&
                (bytesRead = stream.read(buffer, offset, 8 - offset)) != -1){
            offset += bytesRead;
        }
        if(bytesRead < 0){
            throw new IOException("read stream eol.");
        }
        return bytesToLong(buffer, 0);
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
            try {
                long serverTime = readLong(stream);
                baseTimestamp = serverTime;
                deviceLatency = System.currentTimeMillis() - serverTime;
                PlayerVisualizer.updateTimeMillis();
                Log.i(TAG, "Time synced. Server: " + serverTime + ", Device latency: " + deviceLatency + "ms");
            } catch (IOException e) {
                Log.e(TAG, "Time sync error: " + e);
            }
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
        }else if(command == 5) { // MeasureLatency - 延迟测量
            try {
                int sequence = readInt(stream);
                // 立即发送响应
                if(mSocketOutputStream != null) {
                    mSocketOutputStream.write(1); // 简单确认
                    mSocketOutputStream.flush();
                }
                Log.i(TAG, "Latency measurement response sent, sequence: " + sequence);
            } catch (IOException e) {
                Log.e(TAG, "Measure latency error: " + e);
            }
        }else if(command == 6) { // SetDelay - 设置播放延迟
            try {
                int delayMs = readInt(stream);
                // 这里可以应用播放延迟设置
                // 简化处理：记录延迟值供播放时使用
                Log.i(TAG, "Playback delay set to: " + delayMs + "ms");
                // 可以将延迟值存储到SharedPreferences中
                SharedPreferences prefs = getSharedPreferences("sync_config", Context.MODE_PRIVATE);
                prefs.edit().putInt("playback_delay", delayMs).apply();
            } catch (IOException e) {
                Log.e(TAG, "Set delay error: " + e);
            }
        }else if(command == 7) { // SyncStatus - 同步状态查询
            try {
                // 返回同步状态信息
                int avgLatency = (int)(latencyHistory.isEmpty() ? 0 : calculateAverageLatency());
                int bufferSize = currentBufferSize;
                int qualityScore = getOverallQualityScore();

                Log.i(TAG, "Sync status: avgLatency=" + avgLatency + "ms, bufferSize=" + bufferSize + ", quality=" + qualityScore);

                if(mSocketOutputStream != null) {
                    mSocketOutputStream.write(qualityScore);
                    mSocketOutputStream.flush();
                }
            } catch (IOException e) {
                Log.e(TAG, "Get sync status error: " + e);
            }
        }else if(command == 8) { // ResendPacket - 重传数据包
            try {
                int sequence = readInt(stream);
                Log.w(TAG, "Received retransmit request for packet: " + sequence);

                // 简单处理：发送确认，实际应用中可能需要缓存重传
                if(mSocketOutputStream != null) {
                    mSocketOutputStream.write(1); // 确认重传请求
                    mSocketOutputStream.flush();
                }

                // 在实际应用中，这里应该重新发送指定的数据包
                // 由于音频数据是实时的，重传可能意义不大，更多是静音处理
            } catch (IOException e) {
                Log.e(TAG, "Resend packet error: " + e);
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
            int bufferSizeInBytes = AudioTrack.getMinBufferSize(sampleRate, channel, audioFormat);
            if(isLocal){
                ((LocalSocket)socket).setReceiveBufferSize(bufferSizeInBytes);
            }else {
                ((Socket)socket).setReceiveBufferSize(bufferSizeInBytes);
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
        if(getPlaying()) return;
        setPlaying(true);
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
            mAudioTrack = new AudioTrack(
                    audioAttributes.build(),
                    audioFormat,
                    bufferSizeInBytes,
                    AudioTrack.MODE_STREAM,
                    AudioManager.AUDIO_SESSION_ID_GENERATE);

            // 初始化自适应缓冲区管理
            currentBufferSize = bufferSizeInBytes;
            minBufferSize = bufferSizeInBytes / 2;
            maxBufferSize = bufferSizeInBytes * 4;
            bufferUnderrunCount = 0;
            bufferOverrunCount = 0;
            bufferUsageHistory.clear();

            // 启动网络健康监控
            monitorNetworkHealth();

            setVolume(0);
            byte[] buffer = new byte[bufferSizeInBytes];
            int dataLength;
            mAudioTrack.play();
            PlayerVisualizer.startBase(mAudioTrack.getAudioSessionId());
            Log.i(TAG, "play audio ready to read");
            outputStream.write(new byte[1]);
            outputStream.flush();
            mSocketOutputStream = outputStream;
            DataInputStream stream = new DataInputStream(inputStream);
            setWriting(false);
            byte[] finalBuffer;
            int finalDataLength;
            while (true) {
                try {
                    stream.readFully(buffer, 0, 4);
                    dataLength = parseInt(buffer);
                    if(dataLength == 0) {
                        Log.i(TAG, "play audio heartbeat");
                        continue;
                    }
                    if(dataLength > buffer.length) {
                        buffer = new byte[dataLength];
                    }
                    // 读取完整数据包（包含时间戳和音频数据）
                    stream.readFully(buffer, 0, dataLength);

                    // 解析时间戳（前8字节）
                    if(dataLength >= 8) {
                        long timestamp = bytesToLong(buffer, 0);
                        int audioDataLength = dataLength - 8;
                        // 计算延迟
                        long currentTime = System.currentTimeMillis();
                        long packetTime = timestamp;
                        long latency = currentTime - packetTime;

                        // 计算播放延迟补偿
                        long playbackDelay = calculatePlaybackDelay(latency);

                        // 每100个包打印一次延迟信息，避免日志过多
                        if(audioDataCount % 100 == 0) {
                            Log.i(TAG, "Audio packet latency: " + latency + "ms, playback delay: " + playbackDelay + "ms");
                        }
                        audioDataCount++;

                        // 检测丢包：如果延迟异常大，可能是丢包导致的
                        if(latency > maxLatencyOffset && audioDataCount > 10) {
                            if(audioDataCount % 100 == 0) {
                                Log.w(TAG, "High latency detected (possible packet loss): " + latency + "ms, using silence");
                            }
                            // 使用静音数据替代，避免播放噪音
                            finalBuffer = new byte[audioDataLength]; // 全0数据（静音）
                            finalDataLength = audioDataLength;
                        } else {
                            // 处理音频数据（跳过时间戳的8字节）
                            byte[] audioData = new byte[audioDataLength];
                            System.arraycopy(buffer, 8, audioData, 0, audioDataLength);
                            finalBuffer = audioData;
                            finalDataLength = audioDataLength;
                        }
                    } else {
                        // 兼容旧格式（没有时间戳）
                        finalBuffer = buffer;
                        finalDataLength = dataLength;
                    }
                } catch (Exception e){
                    // 读取异常，可能是连接中断
                    if(getPlaying()) {
                        Log.w(TAG, "Audio data read exception, possible packet loss: " + e);
                        // 在重连之前使用静音
                        finalBuffer = new byte[bufferSizeInBytes / 2]; // 静音数据
                        finalDataLength = finalBuffer.length;
                    } else {
                        break;
                    }
                }
                if(getWriting()) {
                    Log.w(TAG, "write audio busy");
                    continue;
                }

                if(httpServer != null && httpServer.getAudioPlayer().isPlaying()) {
                    Log.w(TAG, "write audio playing");
                    continue;
                }

                // 检查AudioTrack缓冲区状态
                int bufferSizeInFrames = mAudioTrack.getBufferSizeInFrames() / 2; // 估算
                int currentPosition = mAudioTrack.getPlaybackHeadPosition();
                int bufferLevel = (currentPosition % bufferSizeInFrames);

                // 更新缓冲区使用情况历史
                updateBufferUsageHistory(bufferLevel, bufferSizeInFrames);

                // 自适应缓冲区管理
                BufferManagementResult managementResult = manageBufferSize(bufferLevel, bufferSizeInFrames);

                if(managementResult.action == BufferAction.WAIT) {
                    try {
                        Thread.sleep(managementResult.delayMs);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                    }
                    continue;
                } else if(managementResult.action == BufferAction.UNDERRUN) {
                    bufferUnderrunCount++;
                    Log.w(TAG, "Buffer underrun detected, count: " + bufferUnderrunCount);
                } else if(managementResult.action == BufferAction.OVERRUN) {
                    bufferOverrunCount++;
                    Log.w(TAG, "Buffer overrun detected, count: " + bufferOverrunCount);
                }

                setWriting(true);
                final int finalBufferSize = bufferSizeInFrames;
                final int finalBufferLevel = bufferLevel;
                mExecutorService.execute(() -> {
                    int code = mAudioTrack.write(finalBuffer, 0, finalDataLength);

                    // 每100次写入打印一次状态信息
                    if(audioDataCount % 100 == 0) {
                        Log.i(TAG, "Audio write: " + finalDataLength + " bytes, code: " + code +
                              ", buffer level: " + finalBufferLevel + "/" + finalBufferSize);
                    }

                    mAudioTrack.flush();
                    mHandler.post(() -> setWriting(false));
                    if(code < 0) {
                        Log.e(TAG, "write audio data err: " + code);
                    }
                    int state = mAudioTrack.getPlayState();
                    if(state != AudioTrack.PLAYSTATE_PLAYING) {
                        Log.w(TAG, "write audio state: " + state);
//                        mAudioTrack.play();
                    }
                });
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

    private void stopAudio(){
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
            @Override
            public void run() {
                if (getPlaying()) {
                    try {
                        if(mSocketOutputStream != null) {
                            mSocketOutputStream.write(new byte[1]);
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
                try (DatagramSocket socket = new DatagramSocket(0)) {
                    socket.setBroadcast(true);
                    String message = HEAD + "@" + getListenPort() + "@" + getHttpPort();
                    byte[] data = message.getBytes();
                    for (int i = 58261; i < 58271; i++) {
                        socket.send(new DatagramPacket(data, data.length,
                                new InetSocketAddress(NetworkUtils.BROADCAST_ADDRESS, i)));
                    }
                    Log.i(TAG, "send broadcast " + socket.getLocalPort());
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

    private long bytesToLong(byte[] data, int offset) {
        return ((long)data[offset] & 0xFF) |
                (((long)data[offset + 1] & 0xFF) << 8) |
                (((long)data[offset + 2] & 0xFF) << 16) |
                (((long)data[offset + 3] & 0xFF) << 24) |
                (((long)data[offset + 4] & 0xFF) << 32) |
                (((long)data[offset + 5] & 0xFF) << 40) |
                (((long)data[offset + 6] & 0xFF) << 48) |
                (((long)data[offset + 7] & 0xFF) << 56);
    }

    // 计算平均延迟
    private long calculateAverageLatency() {
        if(latencyHistory.isEmpty()) return 0;
        long sum = 0;
        for(Long latency : latencyHistory) {
            sum += latency;
        }
        return sum / latencyHistory.size();
    }

    // 更新延迟历史
    private void updateLatencyHistory(long latency) {
        latencyHistory.offer(latency);
        while(latencyHistory.size() > LATENCY_HISTORY_SIZE) {
            latencyHistory.poll();
        }
    }

    // 计算需要的播放延迟
    private long calculatePlaybackDelay(long currentLatency) {
        updateLatencyHistory(currentLatency);
        long avgLatency = calculateAverageLatency();

        // 如果延迟变化较大，增加缓冲延迟
        long latencyVariance = Math.abs(currentLatency - avgLatency);
        long bufferDelay = Math.min(latencyVariance * 2, 100); // 最大100ms额外缓冲

        return avgLatency + bufferDelay;
    }

    // 自适应缓冲区管理相关类和方法
    private enum BufferAction {
        NORMAL,      // 正常播放
        WAIT,        // 需要等待
        UNDERRUN,    // 缓冲区下溢
        OVERRUN,     // 缓冲区上溢
        ADJUST       // 需要调整缓冲区大小
    }

    private static class BufferManagementResult {
        BufferAction action;
        int delayMs;

        BufferManagementResult(BufferAction action, int delayMs) {
            this.action = action;
            this.delayMs = delayMs;
        }
    }

    private void updateBufferUsageHistory(int bufferLevel, int bufferSize) {
        int usagePercentage = (bufferLevel * 100) / bufferSize;
        bufferUsageHistory.offer(usagePercentage);
        while(bufferUsageHistory.size() > BUFFER_USAGE_HISTORY_SIZE) {
            bufferUsageHistory.poll();
        }
    }

    private BufferManagementResult manageBufferSize(int bufferLevel, int bufferSize) {
        int usagePercentage = (bufferLevel * 100) / bufferSize;

        // 检查缓冲区状态
        if(usagePercentage < 10) {
            // 缓冲区接近空，可能下溢
            if(bufferUnderrunCount > 3) {
                // 多次下溢，需要增加缓冲区
                adjustBufferSize(true);
                bufferUnderrunCount = 0;
                return new BufferManagementResult(BufferAction.ADJUST, 0);
            }
            return new BufferManagementResult(BufferAction.UNDERRUN, 0);
        } else if(usagePercentage > 90) {
            // 缓冲区接近满，需要等待
            if(bufferOverrunCount > 5) {
                // 多次上溢，可以减少缓冲区
                adjustBufferSize(false);
                bufferOverrunCount = 0;
            }
            // 计算等待时间
            int waitTime = (int)((usagePercentage - 80) * 0.5); // 最多50ms
            return new BufferManagementResult(BufferAction.WAIT, waitTime);
        } else if(usagePercentage > 80) {
            // 缓冲区较满，稍微等待
            int waitTime = (int)((usagePercentage - 80) * 0.3); // 最多30ms
            return new BufferManagementResult(BufferAction.WAIT, waitTime);
        }

        // 正常范围，重置计数器
        bufferUnderrunCount = 0;
        bufferOverrunCount = 0;
        return new BufferManagementResult(BufferAction.NORMAL, 0);
    }

    private void adjustBufferSize(boolean increase) {
        // 检查冷却时间
        long currentTime = System.currentTimeMillis();
        if (currentTime - lastBufferSizeChangeTime < BUFFER_CHANGE_COOLDOWN_MS) {
            Log.d(TAG, "Buffer size change in cooldown, skipping");
            return;
        }

        // 记录变化趋势
        int newTrend = increase ? 1 : -1;
        if (newTrend == currentBufferSizeTrend) {
            bufferChangeCount++;
        } else {
            bufferChangeCount = 1;
            currentBufferSizeTrend = newTrend;
        }

        // 只有连续变化超过阈值才真正调整
        if (bufferChangeCount >= BUFFER_CHANGE_THRESHOLD) {
            int newSize = calculateOptimizedBufferSize(increase);
            applyBufferSizeChange(newSize);
            bufferChangeCount = 0;
            lastBufferSizeChangeTime = currentTime;
        } else {
            Log.d(TAG, "Buffer change trend: " + (increase ? "increasing" : "decreasing") + " (" + bufferChangeCount + "/" + BUFFER_CHANGE_THRESHOLD + ")");
        }
    }

    private int calculateOptimizedBufferSize(boolean increase) {
        if (increase) {
            // 渐进式增长，而不是翻倍
            int increaseAmount = Math.max(currentBufferSize / 4, 1024);
            return Math.min(currentBufferSize + increaseAmount, maxBufferSize);
        } else {
            // 渐进式缩小，而不是减半
            int decreaseAmount = Math.max(currentBufferSize / 8, 512);
            return Math.max(currentBufferSize - decreaseAmount, minBufferSize);
        }
    }

    private void applyBufferSizeChange(int newSize) {
        if (newSize != currentBufferSize) {
            int oldSize = currentBufferSize;
            currentBufferSize = newSize;
            targetBufferSize = newSize;

            Log.i(TAG, "Buffer size changed: " + oldSize + " -> " + newSize + " (trend: " + (currentBufferSizeTrend > 0 ? "increasing" : "decreasing") + ")");

            // 根据新缓冲区大小调整写入策略
            updateWriteStrategyForBufferSize(newSize);
        }
    }

    private void updateWriteStrategyForBufferSize(int bufferSize) {
        // 根据缓冲区大小调整写入策略
        if (bufferSize <= 8192) {
            // 小缓冲区：快速写入，低延迟
            // 使用当前的直接写入策略
        } else if (bufferSize <= 16384) {
            // 中等缓冲区：平衡策略
            // 可以添加一些小的延迟来平滑数据流
        } else {
            // 大缓冲区：保守策略，确保稳定
            // 增加预读和批量处理
        }
    }

    // 缓冲区健康状态监控
    public BufferHealthStatus getBufferHealthStatus() {
        int avgUsage = getAverageBufferUsage();
        int usageVariance = calculateBufferUsageVariance();
        long underrunRate = bufferUnderrunCount;
        long overrunRate = bufferOverrunCount;

        // 综合评估缓冲区健康状态
        if (avgUsage < 10 || underrunRate > 5) {
            return BufferHealthStatus.UNDERRUN;
        } else if (avgUsage > 90 || overrunRate > 5) {
            return BufferHealthStatus.OVERRUN;
        } else if (usageVariance > 30) {
            return BufferHealthStatus.UNSTABLE;
        } else if (avgUsage >= 40 && avgUsage <= 60 && underrunRate == 0 && overrunRate == 0) {
            return BufferHealthStatus.OPTIMAL;
        } else {
            return BufferHealthStatus.NORMAL;
        }
    }

    private int calculateBufferUsageVariance() {
        if (bufferUsageHistory.size() < 2) return 0;

        int avg = getAverageBufferUsage();
        int sum = 0;

        for (Integer usage : bufferUsageHistory) {
            sum += Math.abs(usage - avg);
        }

        return sum / bufferUsageHistory.size();
    }

    public enum BufferHealthStatus {
        UNDERRUN,   // 缓冲区下溢
        OVERRUN,    // 缓冲区上溢
        UNSTABLE,   // 使用波动大
        OPTIMAL,    // 最佳状态
        NORMAL      // 正常状态
    }

    private int getAverageBufferUsage() {
        if(bufferUsageHistory.isEmpty()) return 50;

        int sum = 0;
        for(Integer usage : bufferUsageHistory) {
            sum += usage;
        }
        return sum / bufferUsageHistory.size();
    }

    // 综合质量评分
    public int getOverallQualityScore() {
        // 基于延迟、缓冲区使用情况等计算质量评分
        long avgLatency = latencyHistory.isEmpty() ? 100 : calculateAverageLatency();
        int bufferUsage = getAverageBufferUsage();
        int underrunImpact = (int)(bufferUnderrunCount * 5);
        int overrunImpact = (int)(bufferOverrunCount * 2);

        // 延迟越低分数越高
        int latencyScore = Math.max(0, 100 - (int)(avgLatency / 2));

        // 缓冲区使用率在30-70%之间最好
        int bufferScore = 100 - Math.abs(bufferUsage - 50) * 2;

        // 综合评分
        int totalScore = (int)(latencyScore * 0.4f + bufferScore * 0.4f - underrunImpact - overrunImpact);

        return Math.max(0, Math.min(100, totalScore));
    }

    // 连接恢复相关方法
    private void handleConnectionLoss() {
        disconnectCount++;
        lastDisconnectTime = System.currentTimeMillis();

        if (autoReconnectEnabled && disconnectCount <= MAX_RECONNECT_ATTEMPTS) {
            Log.i(TAG, "Attempting to reconnect (attempt " + disconnectCount + "/" + MAX_RECONNECT_ATTEMPTS + ")");

            reconnectHandler.postDelayed(() -> {
                try {
                    // 尝试重新启动服务器
                    if(serverSocket != null && !serverSocket.isClosed()) {
                        serverSocket.close();
                    }

                    // 重新启动服务器
                    new Thread(this::startServer).start();

                    Log.i(TAG, "Reconnection attempt completed");
                } catch (Exception e) {
                    Log.e(TAG, "Reconnection failed: " + e);
                    // 如果重连失败，继续尝试
                    if(disconnectCount < MAX_RECONNECT_ATTEMPTS) {
                        handleConnectionLoss();
                    } else {
                        Log.e(TAG, "Max reconnection attempts reached, giving up");
                    }
                }
            }, RECONNECT_DELAY_MS);
        } else {
            Log.e(TAG, "Auto reconnect disabled or max attempts reached");
        }
    }

    public void enableAutoReconnect(boolean enable) {
        autoReconnectEnabled = enable;
        Log.i(TAG, "Auto reconnect " + (enable ? "enabled" : "disabled"));
    }

    public int getDisconnectCount() {
        return disconnectCount;
    }

    public long getTimeSinceLastDisconnect() {
        return lastDisconnectTime == 0 ? 0 : System.currentTimeMillis() - lastDisconnectTime;
    }

    public boolean isAutoReconnectEnabled() {
        return autoReconnectEnabled;
    }

    // 网络健康监控
    private void monitorNetworkHealth() {
        reconnectHandler.postDelayed(() -> {
            if(getPlaying() && autoReconnectEnabled) {
                try {
                    // 检查连接是否还活跃
                    if(mSocketOutputStream != null) {
                        // 发送简单的ping
                        mSocketOutputStream.write(0);
                        mSocketOutputStream.flush();
                    }
                } catch (IOException e) {
                    Log.w(TAG, "Network health check failed: " + e);
                    handleConnectionLoss();
                    return;
                }

                // 继续监控
                monitorNetworkHealth();
            }
        }, 10000); // 每10秒检查一次
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
