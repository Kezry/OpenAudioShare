package com.picapico.audioshare.musiche;

import android.util.Log;

import com.picapico.audioshare.NetworkUtils;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.util.List;

public class BroadcastReceiver {
    private static final String TAG = "AudioShareBCReceiver";
    private static final String HEAD = "picapico-audio-share";
    public interface OnRemoteServerReceivedListener {
        void OnRemoteServerReceived(String hostname, String port);
    }
    private OnRemoteServerReceivedListener remoteServerReceivedListener = null;

    public void setRemoteServerReceivedListener(OnRemoteServerReceivedListener listener){
        remoteServerReceivedListener = listener;
    }
    private final Object socketLock = new Object();
    private DatagramSocket socket = null;
    private boolean started = false;
    private boolean ignoreError = false;
    private final String localAddresses;

    public BroadcastReceiver(){
        localAddresses = getIPV4();
    }

    public void start(){
        synchronized (socketLock) {
            if(started) return;
            started = true;
        }
        new Thread(this::startReceiveBroadcast).start();
    }

    private void startReceiveBroadcast(){
        DatagramSocket local = null;
        for (int port = 58261; port < 58271; port++) {
            try{
                local = new DatagramSocket(port);
                local.setBroadcast(true);
                break;
            }catch (Exception ignore){
                local = null;
            }
        }
        if(local == null) {
            Log.w(TAG, "cannot listen udp");
            synchronized (socketLock) {
                started = false;
            }
            return;
        }
        synchronized (socketLock) {
            socket = local;
        }
        byte[] buffer = new byte[128];
        DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
        try{
            while (true) {
                local.receive(packet);
                if(remoteServerReceivedListener == null) continue;
                InetAddress packageAddress = packet.getAddress();
                // Exact token match: "-1.2.3.4-" must not match "21.2.3.4".
                if(packageAddress == null || packageAddress.getHostAddress() == null
                        || localAddresses.contains("-" + packageAddress.getHostAddress() + "-")){
                    continue;
                }
                String[] messages = new String(packet.getData(), 0, packet.getLength()).split("@");
                if(messages.length < 3 || !messages[0].startsWith(HEAD)) continue;
                remoteServerReceivedListener.OnRemoteServerReceived(packet.getAddress().getHostAddress(), messages[2]);
            }
        }catch (Exception e){
            if(!ignoreError) Log.e(TAG, "cannot receive udp: " + e.getMessage());
        }
        stop();
        ignoreError = false;
    }

    public void stop(){
        ignoreError = true;
        DatagramSocket current;
        synchronized (socketLock) {
            current = socket;
            socket = null;
            started = false;
        }
        if(current != null){
            try {
                current.close();
            } catch (Exception ignore) { }
        }
    }

    private String getIPV4(){
        StringBuilder addressesSB = new StringBuilder();
        List<InetAddress> allAddresses = NetworkUtils.getAllInetAddress();
        for (int i = 0; i < allAddresses.size();i++) {
            if(allAddresses.get(i) instanceof Inet4Address){
                addressesSB.append("-").append(allAddresses.get(i).getHostAddress()).append("-");
            }
        }
        return addressesSB.toString();
    }
}
