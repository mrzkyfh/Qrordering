package com.example.bluetooth_print_plus.bluetooth_print_plus;

import static android.bluetooth.BluetoothDevice.DEVICE_TYPE_LE;

import android.annotation.SuppressLint;
import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import com.example.bluetooth_print_plus.bluetooth_print_plus.payload.BPPState;
import com.example.bluetooth_print_plus.bluetooth_print_plus.payload.Printer;
import com.example.bluetooth_print_plus.bluetooth_print_plus.payload.ThreadPoolManager;
import com.gprinter.bean.PrinterDevices;
import com.gprinter.io.PortManager;
import com.gprinter.utils.CallbackListener;
import com.gprinter.utils.Command;
import com.gprinter.utils.LogUtils;
import com.gprinter.utils.ConnMethod;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.*;
import io.flutter.plugin.common.EventChannel.EventSink;
import io.flutter.plugin.common.EventChannel.StreamHandler;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener;
import pub.devrel.easypermissions.EasyPermissions;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.Objects;

/**
 * BluetoothPrintPlusPlugin
 *
 * @author amoLink
 */
public class BluetoothPrintPlusPlugin
        implements FlutterPlugin, ActivityAware, MethodCallHandler, RequestPermissionsResultListener {
  private static final String TAG = "BluetoothPrintPlusPlugin";
  private static final int REQUEST_LOCATION_PERMISSIONS = 1452;
  private final Object initializationLock = new Object();
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  private Context context;
  private Activity activity;
  private Result pendingResult;
  private boolean discoveryReceiverRegistered;
  private boolean stateReceiverRegistered;
  public PortManager portManager = null;
  private BluetoothAdapter mBluetoothAdapter;

  private FlutterPluginBinding pluginBinding;
  private ActivityPluginBinding activityBinding;
  private MethodChannel channel;
  private EventSink sink;
  private MethodChannel tscChannel;
  private MethodChannel cpclChannel;
  private MethodChannel escChannel;
  private EventChannel stateChannel;
  private final TscCommandPlugin tscCommandPlugin = new TscCommandPlugin();
  private final CpclCommandPlugin cpclCommandPlugin = new CpclCommandPlugin();
  private final EscCommandPlugin escCommandPlugin = new EscCommandPlugin();

  public BluetoothPrintPlusPlugin() {}

  @Override
  public void onAttachedToEngine(FlutterPluginBinding binding) {
    pluginBinding = binding;
    setupEngine(
        binding.getBinaryMessenger(),
        binding.getApplicationContext());
  }

  @Override
  public void onDetachedFromEngine(FlutterPluginBinding binding) {
    tearDownActivity();
    tearDownEngine();
    pluginBinding = null;
  }

  @Override
  public void onAttachedToActivity(ActivityPluginBinding binding) {
    activityBinding = binding;
    activity = binding.getActivity();
    activityBinding.addRequestPermissionsResultListener(this);
  }

  @Override
  public void onDetachedFromActivity() {
    tearDownActivity();
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    onDetachedFromActivity();
  }

  @Override
  public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) {
    onAttachedToActivity(binding);
  }

  private void setupEngine(
          final BinaryMessenger messenger,
          final Context applicationContext
  ) {
    synchronized (initializationLock) {
      LogUtils.i(TAG, "setup");
      this.context = applicationContext;
      channel = new MethodChannel(messenger, "bluetooth_print_plus/methods");
      channel.setMethodCallHandler(this);
      // tsc Channel
      tscChannel = new MethodChannel(messenger, "bluetooth_print_plus_tsc");
      tscCommandPlugin.setUpChannel(tscChannel);
      // cpcl Channel
      cpclChannel = new MethodChannel(messenger, "bluetooth_print_plus_cpcl");
      cpclCommandPlugin.setUpChannel(cpclChannel);
      // esc Channel
      escChannel = new MethodChannel(messenger, "bluetooth_print_plus_esc");
      escCommandPlugin.setUpChannel(escChannel);
      // state Channel
      stateChannel = new EventChannel(messenger, "bluetooth_print_plus/state");
      stateChannel.setStreamHandler(stateHandler);
      mBluetoothAdapter = BluetoothAdapter.getDefaultAdapter();

      initBroadcast();
    }
  }

  private void tearDownActivity() {
    if (pendingResult != null) {
      pendingResult.error(
          "activity_unavailable",
          "Bluetooth permission request was cancelled because the Activity detached",
          null);
      pendingResult = null;
    }
    activity = null;
    if (activityBinding != null) {
      activityBinding.removeRequestPermissionsResultListener(this);
    }
    activityBinding = null;
  }

  private void tearDownEngine() {
    LogUtils.i(TAG, "teardown");
    if (context != null && discoveryReceiverRegistered) {
      try {
        context.unregisterReceiver(mFindBlueToothReceiver);
      } catch (IllegalArgumentException ignored) {
      }
      discoveryReceiverRegistered = false;
    }
    if (context != null && stateReceiverRegistered) {
      try {
        context.unregisterReceiver(mBluetoothStateReceiver);
      } catch (IllegalArgumentException ignored) {
      }
      stateReceiverRegistered = false;
    }
    sink = null;
    if (channel != null) {
      channel.setMethodCallHandler(null);
    }
    if (stateChannel != null) {
      stateChannel.setStreamHandler(null);
    }
    if (tscChannel != null) {
      tscChannel.setMethodCallHandler(null);
    }
    if (cpclChannel != null) {
      cpclChannel.setMethodCallHandler(null);
    }
    if (escChannel != null) {
      escChannel.setMethodCallHandler(null);
    }
    context = null;
    channel = null;
    stateChannel = null;
    tscChannel = null;
    cpclChannel = null;
    escChannel = null;
    mBluetoothAdapter = null;
  }

  @Override
  public void onMethodCall(MethodCall call, Result result) {
    if (mBluetoothAdapter == null && !"isAvailable".equals(call.method)) {
      result.error("bluetooth_unavailable", "the device does not have bluetooth", null);
      return;
    }
    switch (call.method) {
      case "state":
        state(result);
        break;
      case "startScan":
        startScan(result);
        break;
      case "stopScan":
        stopScan();
        result.success(null);
        break;
      case "connect":
        Map<String, Object> args = call.arguments();
        if (args == null || !(args.get("address") instanceof String)) {
          result.error("invalid_argument", "argument 'address' not found", null);
          return;
        }
        final String address = (String) args.get("address");
        stopScan();
        connect(address);
        result.success(null);
        break;
      case "disconnect":
        Printer.close();
        result.success(null);
        break;
      case "write":
        byte[] bytes = call.argument("data");
        if (bytes == null || bytes.length == 0) {
          result.error("invalid_argument", "argument 'data' is empty", null);
          return;
        }
        try {
          result.success(write(bytes));
        } catch (Exception e) {
          result.error("write_failed", e.getMessage(), null);
        }
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private void initBroadcast() {
    try {
      IntentFilter filter = new IntentFilter();
      filter.addAction(BluetoothDevice.ACTION_FOUND);
      filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED);
      context.registerReceiver(mFindBlueToothReceiver, filter);
      discoveryReceiverRegistered = true;
    } catch (Exception ignored) {
      discoveryReceiverRegistered = false;
    }
  }

  @SuppressLint("MissingPermission")
  private final BroadcastReceiver mFindBlueToothReceiver = new BroadcastReceiver() {
    @Override
    public void onReceive(Context context, Intent intent) {
      String action = intent.getAction();
      if (BluetoothDevice.ACTION_FOUND.equals(action)) {
        // Izin dapat dicabut ketika discovery sedang berjalan. Jangan sentuh
        // metadata BluetoothDevice lagi bila itu terjadi karena Android 12+
        // akan melempar SecurityException dari callback receiver ini.
        if (!hasScanPermissions()) return;
        BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
        if (device == null || device.getName() == null) return;
        if (device.getType() == DEVICE_TYPE_LE) return;
        int rssi = Objects.requireNonNull(intent.getExtras()).getShort(BluetoothDevice.EXTRA_RSSI);
        LogUtils.i(TAG, "\nBlueToothName: " + device.getName() + "\nMacAddress: " + device.getAddress() + "\nrssi: " + rssi);
        invokeMethodUIThread(device);
      }
    }
  };

  private void state(Result result) {
    try {
      result.success(
          mBluetoothAdapter.isEnabled()
              ? BPPState.BlueOn.getValue()
              : BPPState.BlueOff.getValue());
    } catch (SecurityException e) {
      result.error("no_permissions", "Bluetooth connect permission is required", null);
    }
  }

  private void startScan(Result result) {
    LogUtils.i(TAG, "start scan...");
    try {
      String[] perms = requiredScanPermissions();

      if (EasyPermissions.hasPermissions(this.context, perms)) {
        startScan();
        result.success(null);
      } else {
        if (this.activity == null) {
          result.error("activity_unavailable", "Bluetooth scan requires an attached Activity", null);
          return;
        }
        if (pendingResult != null) {
          result.error("permission_in_progress", "Bluetooth permission request already in progress", null);
          return;
        }
        pendingResult = result;
        EasyPermissions.requestPermissions(
                this.activity,
                "Bluetooth permission is required to find printers",
                REQUEST_LOCATION_PERMISSIONS,
                perms);
      }
    } catch (Exception e) {
      pendingResult = null;
      result.error("startScan", e.getMessage(), e);
    }
  }

  private String[] requiredScanPermissions() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      // Android 12+: Nearby devices menggantikan izin lokasi untuk scan.
      return new String[] {
          Manifest.permission.BLUETOOTH_CONNECT,
          Manifest.permission.BLUETOOTH_SCAN,
      };
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      // Android 6–11 masih mensyaratkan lokasi untuk discovery Bluetooth.
      return new String[] {
          Manifest.permission.BLUETOOTH,
          Manifest.permission.BLUETOOTH_ADMIN,
          Manifest.permission.ACCESS_FINE_LOCATION,
      };
    }
    return new String[] {
        Manifest.permission.BLUETOOTH,
        Manifest.permission.BLUETOOTH_ADMIN,
    };
  }

  private boolean hasScanPermissions() {
    Context currentContext = context;
    return currentContext != null
        && EasyPermissions.hasPermissions(currentContext, requiredScanPermissions());
  }

  @SuppressLint("MissingPermission")
  private void invokeMethodUIThread(BluetoothDevice device) {
    if (!hasScanPermissions()) return;
    final Map<String, Object> ret = new HashMap<>();
    ret.put("address", device.getAddress());
    ret.put("name", device.getName());
    ret.put("type", device.getType());
    mainHandler.post(() -> {
      MethodChannel currentChannel = channel;
      if (currentChannel != null) {
        currentChannel.invokeMethod("ScanResult", ret);
      }
    });
  }

  @SuppressLint("MissingPermission")
  private void startScan() throws IllegalStateException, SecurityException {
    if (!hasScanPermissions()) {
      throw new SecurityException("Bluetooth scan permission is required");
    }
    if (!mBluetoothAdapter.startDiscovery()) {
      throw new IllegalStateException("Bluetooth discovery could not be started");
    }
  }

  private void stopScan() {
    try {
      if (mBluetoothAdapter != null) {
        mBluetoothAdapter.cancelDiscovery();
      }
    } catch (SecurityException ignored) {
    }
  }

  public void connect(final String mac) {
    final Context appContext = context;
    if (appContext == null) return;
    ThreadPoolManager.getInstance().addTask(new Runnable() {
      @Override
      public void run() {
        if (portManager != null) {
          portManager.closePort();
          try {
            Thread.sleep(500);
          } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return;
          }
        }
        if (mac != null) {
          PrinterDevices blueTooth = new PrinterDevices.Build()
                  .setContext(appContext)
                  .setConnMethod(ConnMethod.BLUETOOTH)
                  .setMacAddress(mac)
                  .setCommand(Command.ESC)
                  .setCallbackListener(new CallbackListener() {
                    @Override
                    public void onConnecting() { }

                    @Override
                    public void onCheckCommand() { }

                    @Override
                    public void onSuccess(PrinterDevices printerDevices) {
                      // LogUtils.d(TAG, "onSuccess");
                      // Autoprint dapat berjalan sebelum Dart selesai memasang
                      // EventChannel. Jangan crash proses aplikasi bila sink
                      // belum siap / Activity baru saja dilepas.
                      emitConnectionState(BPPState.DeviceConnected);
                    }

                    @Override
                    public void onReceive(byte[] data) {
                      if (data == null) return;
                      // LogUtils.d(TAG, "Received Data: " + Arrays.toString(data));
                      mainHandler.post(() -> {
                        MethodChannel currentChannel = channel;
                        if (currentChannel != null) {
                          currentChannel.invokeMethod("ReceivedData", data);
                        }
                      });
                    }

                    @Override
                    public void onFailure() { }

                    @Override
                    public void onDisconnect() {
                      // LogUtils.d(TAG, "onDisconnect");
                      emitConnectionState(BPPState.DeviceDisconnected);
                    }
                  })
                  .build();
          Printer.connect(blueTooth);
        }
      }
    });
  }

  private void emitConnectionState(BPPState state) {
    mainHandler.post(() -> {
      EventSink currentSink = sink;
      if (currentSink != null) {
        currentSink.success(state.getValue());
      }
    });
  }

  private boolean write(byte[] data) throws IOException {
    if (Printer.getPortManager() == null) {
      throw new IOException("Printer is not connected");
    }
    boolean result = Printer.getPortManager().writeDataImmediately(data);
    LogUtils.d(TAG, result ? "发送成功": "发送失败");
    return result;
  }

  @Override
  public boolean onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
    LogUtils.d(TAG, "onRequestPermissionsResult");
    if (requestCode == REQUEST_LOCATION_PERMISSIONS) {
      Result result = pendingResult;
      pendingResult = null;
      if (result == null) return true;

      try {
        if (this.context != null
            && EasyPermissions.hasPermissions(this.context, permissions)) {
          startScan();
          result.success(null);
        } else {
          result.error("no_permissions", "Bluetooth scan permission was denied", null);
        }
      } catch (Exception e) {
        result.error("startScan", e.getMessage(), null);
      }
      return true;
    }
    return false;
  }

  private final BroadcastReceiver mBluetoothStateReceiver = new BroadcastReceiver() {
    @Override
    public void onReceive(Context context, Intent intent) {
      if (!BluetoothAdapter.ACTION_STATE_CHANGED.equals(intent.getAction())) return;
      int blueState = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, 0);
      EventSink currentSink = sink;
      if (currentSink == null) return;
      if (blueState == BluetoothAdapter.STATE_ON) {
        currentSink.success(BPPState.BlueOn.getValue());
      } else if (blueState == BluetoothAdapter.STATE_OFF) {
        currentSink.success(BPPState.BlueOff.getValue());
      }
    }
  };

  private final StreamHandler stateHandler = new StreamHandler() {
    @Override
    public void onListen(Object o, EventSink eventSink) {
      sink = eventSink;
      if (context == null || stateReceiverRegistered) return;
      IntentFilter filter = new IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED);
      try {
        context.registerReceiver(mBluetoothStateReceiver, filter);
        stateReceiverRegistered = true;
      } catch (Exception e) {
        eventSink.error("receiver_failed", e.getMessage(), null);
      }
    }

    @Override
    public void onCancel(Object o) {
      sink = null;
      if (context != null && stateReceiverRegistered) {
        try {
          context.unregisterReceiver(mBluetoothStateReceiver);
        } catch (IllegalArgumentException ignored) {
        }
        stateReceiverRegistered = false;
      }
    }
  };
}
