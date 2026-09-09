package com.picapico.audioshare;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

public class BootReceiver extends BroadcastReceiver {
    private static final String TAG = "AudioShareBootReceiver";
    @Override
    public void onReceive(Context context, Intent intent) {
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) {
            Intent serviceIntent = new Intent(context, TcpService.class);
            try {
                // Android 15 additionally restricts mediaPlayback foreground
                // services from BOOT_COMPLETED; failures are logged, not fatal.
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent);
                } else {
                    context.startService(serviceIntent);
                }
                Log.i(TAG, "start audio share at boot completed");
            } catch (Exception e) {
                Log.e(TAG, "start service at boot failed: " + e);
            }
        }
    }
}