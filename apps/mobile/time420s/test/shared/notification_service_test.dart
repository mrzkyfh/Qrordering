import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/shared/services/kitchen_print.dart';
import 'package:time420s/shared/services/notification_service.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const audioGlobalChannel = MethodChannel('xyz.luan/audioplayers.global');
  const audioPlayerChannel = MethodChannel('xyz.luan/audioplayers');

  test(
    'izin notifikasi ditunda sampai Activity resumed dan tidak diulang',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioGlobalChannel, (_) async => null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioPlayerChannel, (_) async => null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'initialize' ||
                call.method == 'requestNotificationsPermission') {
              return true;
            }
            return null;
          });

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await NotificationService().init();

      expect(calls, isNot(contains('requestNotificationsPermission')));

      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((method) => method == 'requestNotificationsPermission'),
        hasLength(1),
      );

      // Resume kedua tidak boleh memunculkan prompt izin lagi dalam proses sama.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(
        calls.where((method) => method == 'requestNotificationsPermission'),
        hasLength(1),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioGlobalChannel, null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(audioPlayerChannel, null);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test('poll hanya mengambil overlap terbaru maksimal 10 menit', () {
    final now = DateTime.utc(2026, 7, 23, 10);

    expect(
      notificationPollCutoff(now, now.subtract(const Duration(minutes: 2))),
      now.subtract(const Duration(minutes: 2, seconds: 30)),
    );
    expect(
      notificationPollCutoff(now, now.subtract(const Duration(hours: 1))),
      now.subtract(const Duration(minutes: 10)),
    );
  });

  test('recovery tiket pending tidak dipotong batas usia 10 menit', () {
    final now = DateTime.utc(2026, 10, 2, 10);

    expect(
      notificationEventCutoff(
        now,
        now.subtract(const Duration(days: 2)),
        recoverAllPending: true,
      ),
      DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect(
      notificationEventCutoff(
        now,
        now.subtract(const Duration(days: 2)),
        recoverAllPending: false,
      ),
      now.subtract(const Duration(minutes: 10)),
    );
  });

  test('poll background melambat saat realtime sehat atau request gagal', () {
    expect(
      orderBackgroundPollDelay(
        realtimeHealthy: true,
        requestFailed: false,
        previous: const Duration(seconds: 30),
      ),
      const Duration(minutes: 2),
    );
    expect(
      orderBackgroundPollDelay(
        realtimeHealthy: false,
        requestFailed: false,
        previous: const Duration(seconds: 60),
      ),
      const Duration(seconds: 30),
    );
    expect(
      orderBackgroundPollDelay(
        realtimeHealthy: false,
        requestFailed: true,
        previous: const Duration(seconds: 60),
      ),
      const Duration(seconds: 120),
    );
  });

  test('recovery tiket dapur tidak memindai server berulang saat resume', () {
    final now = DateTime.utc(2026, 10, 3, 8);
    expect(pendingKitchenRecoveryIsDue(null, now), isTrue);
    expect(
      pendingKitchenRecoveryIsDue(
        now.subtract(const Duration(minutes: 1, seconds: 59)),
        now,
      ),
      isFalse,
    );
    expect(
      pendingKitchenRecoveryIsDue(
        now.subtract(const Duration(minutes: 2)),
        now,
      ),
      isTrue,
    );
  });

  test('printer dapur yang memang belum dikonfigurasi tidak diretry', () {
    expect(
      kitchenPrintNeedsRecovery(
        const KitchenPrintResult(
          skippedReason: 'Belum ada printer Dapur yang aktif',
        ),
      ),
      isFalse,
    );
    expect(
      kitchenPrintNeedsRecovery(
        const KitchenPrintResult(
          skippedReason: 'Data pesanan belum tersedia untuk dicetak',
        ),
      ),
      isTrue,
    );
  });
}
