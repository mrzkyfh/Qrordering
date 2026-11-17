package com.qrordering.pos

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Foreground service penjaga proses. Tujuannya BUKAN menjalankan logika di sini,
 * melainkan menahan proses aplikasi tetap hidup & berprioritas tinggi saat UI
 * diminimize — sehingga isolate Flutter utama (listener realtime Supabase +
 * koneksi printer Bluetooth) tetap berjalan dan bisa menerima/mencetak pesanan
 * online dari QR meja. Menampilkan notifikasi permanen "POS aktif".
 */
class KeepAliveService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private var tickChannel: MethodChannel? = null
    private val backgroundTick = object : Runnable {
        override fun run() {
            tickChannel?.invokeMethod("backgroundTick", null)
            handler.postDelayed(this, 10_000L)
        }
    }

    companion object {
        const val CHANNEL_ID = "pos_keep_alive"
        const val NOTIF_ID = 42111
        const val ACTION_START = "com.qrordering.pos.KEEP_ALIVE_START"
        const val ACTION_STOP = "com.qrordering.pos.KEEP_ALIVE_STOP"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        // Promosikan secepat mungkin; membangun FlutterEngine bisa memerlukan
        // beberapa detik dan Android mewajibkan startForeground segera setelah
        // startForegroundService dipanggil.
        try {
            startForegroundInternal()
        } catch (e: SecurityException) {
            stopSelf()
            return
        }
        val engine = ensureFlutterRuntime()
        tickChannel = MethodChannel(
            engine.dartExecutor.binaryMessenger,
            "qrordering/keep_alive_events"
        )
        // Flutter/Supabase WebSocket dapat ditahan OEM ketika Activity pause.
        // Platform message native ini tetap membangunkan isolate; sisi Dart
        // lalu mengecek order terbaru sebagai fallback realtime.
        handler.postDelayed(backgroundTick, 5_000L)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            startForegroundInternal()
        } catch (e: SecurityException) {
            // Android 14+ memvalidasi permission foreground-service ketika
            // startForeground() dipanggil. Jangan biarkan konfigurasi izin
            // OEM/manifest yang tidak sesuai menjatuhkan seluruh aplikasi.
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // START_STICKY: bila proses sempat dibersihkan sistem, layanan dibuat
        // ulang → aplikasi kembali siap menerima pesanan.
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(backgroundTick)
        tickChannel = null
        super.onDestroy()
    }

    private fun startForegroundInternal() {
        createChannel()

        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val notification: Notification = builder
            .setContentTitle("QrOrdering POS aktif")
            .setContentText("Siap menerima pesanan online dari meja")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    /**
     * Foreground service native saja tidak menjaga Dart isolate milik
     * FlutterActivity. Simpan engine di cache agar listener Supabase dan
     * autoprint tetap hidup setelah Activity dilepas. Jika Android pernah
     * membunuh proses lalu me-restart START_STICKY service, bangun engine
     * headless baru dan jalankan main() untuk memulihkan session/listener.
     */
    private fun ensureFlutterRuntime(): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(MainActivity.ENGINE_ID)?.let { return it }

        val engine = FlutterEngine(applicationContext)
        cache.put(MainActivity.ENGINE_ID, engine)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault()
        )
        return engine
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Status POS",
                    // LOW: tanpa suara/getar — hanya penanda proses berjalan.
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "Menjaga aplikasi tetap menerima pesanan online"
                    setShowBadge(false)
                }
                mgr.createNotificationChannel(channel)
            }
        }
    }
}
