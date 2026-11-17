package com.time420s.pos

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val ENGINE_ID = "time420s_main_engine"
    }

    private val channelName = "time420s/bluetooth"

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
        super.onCreate(savedInstanceState)
    }

    /**
     * Pakai kembali engine yang dipertahankan foreground service. Tanpa ini,
     * FlutterActivity membuat engine baru dan listener realtime yang lama
     * hilang ketika Activity dihancurkan di background.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(ENGINE_ID)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put(ENGINE_ID, flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Tampilkan prompt sistem "Izinkan app menyalakan Bluetooth?".
                    // Butuh izin BLUETOOTH_CONNECT (Android 12+) sudah granted.
                    "requestEnable" -> {
                        if (
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                            ContextCompat.checkSelfPermission(
                                this,
                                Manifest.permission.BLUETOOTH_CONNECT
                            ) != PackageManager.PERMISSION_GRANTED
                        ) {
                            result.error(
                                "BLUETOOTH_PERMISSION_REQUIRED",
                                "Izin perangkat terdekat belum diberikan.",
                                null
                            )
                            return@setMethodCallHandler
                        }
                        try {
                            startActivity(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ENABLE_FAILED", e.message, null)
                        }
                    }

                    // Mulai foreground service penjaga proses (agar notifikasi &
                    // auto-cetak pesanan online tetap jalan saat app diminimize).
                    "startKeepAlive" -> {
                        try {
                            val intent = Intent(this, KeepAliveService::class.java)
                                .setAction(KeepAliveService.ACTION_START)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("KEEPALIVE_START_FAILED", e.message, null)
                        }
                    }

                    "stopKeepAlive" -> {
                        try {
                            val stopped = stopService(
                                Intent(this, KeepAliveService::class.java)
                            )
                            result.success(stopped)
                        } catch (e: Exception) {
                            result.error("KEEPALIVE_STOP_FAILED", e.message, null)
                        }
                    }

                    // True bila app sudah dikecualikan dari optimasi baterai.
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }

                    // Buka daftar optimasi baterai agar pengguna dapat memilih
                    // manual. Tidak memakai ACTION_REQUEST_* karena permintaan
                    // pengecualian langsung dibatasi kebijakan Google Play.
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (pm.isIgnoringBatteryOptimizations(packageName)) {
                                result.success(true)
                            } else {
                                startActivity(
                                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                                )
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.error("BATTERY_REQ_FAILED", e.message, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
