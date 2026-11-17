import 'package:hive_flutter/hive_flutter.dart';

/// Preferensi lokal (per-perangkat) untuk section OPERASIONAL di Pengaturan.
/// Disimpan di Hive box 'app_settings' (dibuka di main.dart).
class AppSettings {
  AppSettings._();

  static const boxName = 'app_settings';
  static const _kSoundNotif = 'sound_notif'; // suara notifikasi pesanan

  static Box get _box => Hive.box(boxName);

  // ── Suara notifikasi pesanan (default: aktif) ──────────────────────────────
  static bool get soundNotifEnabled =>
      _box.get(_kSoundNotif, defaultValue: true) as bool;
  static Future<void> setSoundNotif(bool v) => _box.put(_kSoundNotif, v);
}
