import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/startup/startup_support.dart';

class LocalEncryptionKeyException implements Exception {
  const LocalEncryptionKeyException(this.message);

  final String message;

  @override
  String toString() => 'LocalEncryptionKeyException: $message';
}

class ProtectedLocalDataException implements Exception {
  const ProtectedLocalDataException(this.message);

  final String message;

  @override
  String toString() => 'ProtectedLocalDataException: $message';
}

/// Membuka box transaksi dengan AES-256. Kunci hanya disimpan di Keychain /
/// Android Keystore, bukan bersama file Hive yang dilindungi.
class EncryptedHiveService {
  EncryptedHiveService._();

  static const _keyName = 'time420s_hive_aes_key_v1';
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Daftar box yang dipulihkan saat startup. File asal selalu disalin ke
  /// folder karantina lebih dulu sehingga teknisi masih dapat memeriksanya.
  static final List<String> recoveryEvents = <String>[];
  static const _defaultTimeout = Duration(seconds: 12);

  static Future<HiveAesCipher> _cipher({
    Duration timeout = _defaultTimeout,
  }) async {
    try {
      var encoded = await runStartupOperation<String?>(
        category: 'SECURE_STORAGE_TIMEOUT',
        timeout: timeout,
        operation: () => _secureStorage.read(key: _keyName),
      );
      if (encoded == null) {
        encoded = base64UrlEncode(Hive.generateSecureKey());
        await runStartupOperation<void>(
          category: 'SECURE_STORAGE_TIMEOUT',
          timeout: timeout,
          operation: () => _secureStorage.write(key: _keyName, value: encoded),
        );
      }
      final key = base64Url.decode(encoded);
      if (key.length != 32) {
        throw const LocalEncryptionKeyException(
          'Panjang kunci penyimpanan lokal tidak valid',
        );
      }
      return HiveAesCipher(key);
    } on StartupTimeoutException {
      rethrow;
    } on LocalEncryptionKeyException {
      rethrow;
    } catch (error) {
      if (error is StartupTimeoutException) rethrow;
      throw LocalEncryptionKeyException(
        'Kunci penyimpanan lokal tidak dapat dibaca: $error',
      );
    }
  }

  /// Buka box terenkripsi dan pindahkan data dari box plaintext versi lama.
  /// Box lama baru dihapus setelah semua key berhasil disalin.
  static Future<void> openAndMigrate({
    required String secureName,
    required String legacyName,
    bool allowCorruptBoxReplacement = false,
    Duration timeout = _defaultTimeout,
  }) async {
    final cipher = await _cipher(timeout: timeout);
    Box<dynamic> secure;
    try {
      secure = Hive.isBoxOpen(secureName)
          ? Hive.box<dynamic>(secureName)
          : await runStartupOperation<Box<dynamic>>(
              category: 'HIVE_BOX_TIMEOUT',
              timeout: timeout,
              operation: () =>
                  Hive.openBox<dynamic>(secureName, encryptionCipher: cipher),
            );
    } catch (error) {
      if (error is StartupTimeoutException) rethrow;
      // Kerusakan satu cache tidak boleh menahan seluruh aplikasi di splash.
      // Salin file mentah untuk forensik/recovery, lalu buat box sehat baru
      // memakai kunci yang sama. Tidak ada penghapusan sebelum salinan sukses.
      if (!allowCorruptBoxReplacement) {
        await _preserveBoxFiles(secureName, error);
        throw ProtectedLocalDataException(
          'Data lokal penting $secureName tidak dapat dibuka dan telah diamankan',
        );
      }
      await _quarantineBoxFiles(secureName, error);
      secure = await runStartupOperation<Box<dynamic>>(
        category: 'HIVE_BOX_TIMEOUT',
        timeout: timeout,
        operation: () =>
            Hive.openBox<dynamic>(secureName, encryptionCipher: cipher),
      );
    }

    if (legacyName == secureName || !await Hive.boxExists(legacyName)) return;

    try {
      final legacy = Hive.isBoxOpen(legacyName)
          ? Hive.box<dynamic>(legacyName)
          : await runStartupOperation<Box<dynamic>>(
              category: 'HIVE_BOX_TIMEOUT',
              timeout: timeout,
              operation: () => Hive.openBox<dynamic>(legacyName),
            );
      for (final entry in legacy.toMap().entries) {
        if (!secure.containsKey(entry.key)) {
          await secure.put(entry.key, entry.value);
        }
      }
      await secure.flush();
      await legacy.close();
      await Hive.deleteBoxFromDisk(legacyName);
    } catch (error) {
      if (error is StartupTimeoutException) rethrow;
      // Box aman sudah dapat dipakai. Legacy yang rusak hanya dikarantina dan
      // tidak boleh menggagalkan startup versi baru.
      if (!allowCorruptBoxReplacement) {
        await _preserveBoxFiles(legacyName, error);
        throw ProtectedLocalDataException(
          'Data lokal lama $legacyName tidak dapat dimigrasikan dan dipertahankan',
        );
      }
      await _quarantineBoxFiles(legacyName, error);
    }
  }

  /// Secure storage dapat terpotong setelah update/restore OS. Dalam kondisi
  /// itu seluruh box terenkripsi lama memang tak dapat dibuka dengan aman.
  /// Karantina semuanya sebelum mengganti kunci supaya aplikasi tetap boot dan
  /// berkas asli tidak hilang seperti saat uninstall.
  static Future<void> recoverInvalidKey({
    required Iterable<String> recoverableBoxNames,
    required Iterable<String> protectedBoxNames,
    Duration timeout = _defaultTimeout,
  }) async {
    final protectedExisting = <String>[];
    for (final name in protectedBoxNames) {
      if (await Hive.boxExists(name)) {
        await _preserveBoxFiles(
          name,
          const LocalEncryptionKeyException('Kunci lokal rusak atau hilang'),
        );
        protectedExisting.add(name);
      }
    }
    if (protectedExisting.isNotEmpty) {
      throw ProtectedLocalDataException(
        'Kunci penyimpanan data transaksi tidak tersedia; file dipertahankan',
      );
    }

    for (final name in recoverableBoxNames) {
      if (Hive.isBoxOpen(name)) await Hive.box<dynamic>(name).close();
      if (await Hive.boxExists(name)) {
        await _quarantineBoxFiles(
          name,
          const LocalEncryptionKeyException('Kunci lokal rusak atau hilang'),
        );
      }
    }
    await runStartupOperation<void>(
      category: 'SECURE_STORAGE_TIMEOUT',
      timeout: timeout,
      operation: () => _secureStorage.delete(key: _keyName),
    );
    await _cipher(timeout: timeout);
  }

  /// Preferensi non-finansial juga dapat rusak ketika proses mati saat menulis.
  /// Pulihkan box kosong setelah salinan mentah diamankan.
  static Future<Box<dynamic>> openRecoverablePlainBox(
    String name, {
    Duration timeout = _defaultTimeout,
  }) async {
    try {
      return Hive.isBoxOpen(name)
          ? Hive.box<dynamic>(name)
          : await runStartupOperation<Box<dynamic>>(
              category: 'HIVE_BOX_TIMEOUT',
              timeout: timeout,
              operation: () => Hive.openBox<dynamic>(name),
            );
    } catch (error) {
      if (error is StartupTimeoutException) rethrow;
      await _quarantineBoxFiles(name, error);
      return runStartupOperation<Box<dynamic>>(
        category: 'HIVE_BOX_TIMEOUT',
        timeout: timeout,
        operation: () => Hive.openBox<dynamic>(name),
      );
    }
  }

  static Future<void> _preserveBoxFiles(String boxName, Object reason) =>
      _copyBoxFiles(boxName, reason, deleteOriginal: false);

  static Future<void> _quarantineBoxFiles(String boxName, Object reason) async {
    await _copyBoxFiles(boxName, reason, deleteOriginal: true);
  }

  static Future<void> _copyBoxFiles(
    String boxName,
    Object reason, {
    required bool deleteOriginal,
  }) async {
    final root = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9A-Za-z]'),
      '_',
    );
    final separator = Platform.pathSeparator;
    final recoveryDir = Directory(
      '${root.path}${separator}time420s_recovery$separator${stamp}_$boxName',
    );
    await recoveryDir.create(recursive: true);

    var copied = false;
    for (final extension in const ['hive', 'hivec']) {
      final source = File('${root.path}$separator$boxName.$extension');
      if (!await source.exists()) continue;
      await source.copy('${recoveryDir.path}$separator$boxName.$extension');
      copied = true;
    }
    await File('${recoveryDir.path}${separator}reason.txt').writeAsString(
      '${DateTime.now().toUtc().toIso8601String()}\n$reason\n',
      flush: true,
    );

    // Jika Hive mengatakan box ada tetapi tidak ada file yang berhasil
    // disalin, jangan ambil risiko menghapus data yang lokasinya tak diketahui.
    if (await Hive.boxExists(boxName) && !copied) {
      throw StateError('File $boxName gagal diamankan sebelum pemulihan');
    }
    if (deleteOriginal) await Hive.deleteBoxFromDisk(boxName);
    recoveryEvents.add('$boxName → ${recoveryDir.path}');
  }
}
