import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'core/config/app_config.dart';
import 'features/settings/data/app_settings.dart';
import 'shared/services/backend_route_resolver.dart';
import 'shared/services/connectivity_service.dart';
import 'shared/services/offline_queue_service.dart';
import 'shared/services/sync_service.dart';
import 'shared/services/error_log_service.dart';
import 'shared/services/encrypted_hive_service.dart';
import 'shared/services/transaction_journal_service.dart';
import 'features/pos/data/datasources/pos_datasource.dart';
import 'features/pos/data/services/held_order_service.dart';
import 'core/widgets/startup_gate.dart';
import 'core/startup/startup_support.dart';

const _encryptedBoxPairs = <({String secure, String legacy})>[
  (
    secure: PosDatasource.menuCacheBoxName,
    legacy: PosDatasource.legacyMenuCacheBoxName,
  ),
  (
    secure: OfflineQueueService.boxName,
    legacy: OfflineQueueService.legacyBoxName,
  ),
  (
    secure: OfflineQueueService.deadBoxName,
    legacy: OfflineQueueService.legacyDeadBoxName,
  ),
  (secure: HeldOrderService.boxName, legacy: HeldOrderService.legacyBoxName),
  (
    secure: TransactionJournalService.boxName,
    legacy: TransactionJournalService.legacyBoxName,
  ),
];

bool _runtimeServicesStarted = false;

const _pluginStartupTimeout = Duration(seconds: 10);
const _boxStartupTimeout = Duration(seconds: 12);
const _supabaseStartupTimeout = Duration(seconds: 15);

void main() {
  // Global error handler: tangkap error sinkron (framework) & async (zona) agar
  // tidak hilang diam-diam. Titik tunggal ini siap disambung ke crash reporting
  // (mis. Sentry) nanti tanpa mengubah struktur.
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();

      // Android 15+ memaksakan edge-to-edge untuk target SDK modern dan Android
      // 16 tidak lagi mengizinkan opt-out. Aktifkan juga pada Android lama agar
      // perilakunya konsisten; inset aman ditangani di root App.
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));

      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        debugPrint(
          'FLUTTER ERROR: ${details.exceptionAsString()}\n${details.stack}',
        );
        ErrorLogService.report(details.exception, details.stack);
      };

      PlatformDispatcher.instance.onError = (error, stack) {
        debugPrint('PLATFORM ERROR: $error\n$stack');
        unawaited(ErrorLogService.report(error, stack));
        return true;
      };

      // UI dibuat SEBELUM membaca disk/jaringan. Jika bootstrap gagal, kasir
      // melihat layar retry alih-alih splash beku yang mendorong reinstall.
      runApp(
        StartupGate(
          initialize: _bootstrapApplication,
          readyBuilder: (_) => const App(),
          onFailure: (error, stack) => StartupDiagnostics.recordFailure(
            error,
            stack,
            appBuild: AppConfig.appBuild,
          ),
        ),
      );
    },
    (error, stack) {
      debugPrint('UNCAUGHT ERROR: $error\n$stack');
      ErrorLogService.report(error, stack);
    },
  );
}

Future<void> _bootstrapApplication() async {
  StartupDiagnostics.begin();
  StartupDiagnostics.phase('environment');
  await initializeDateFormatting('id_ID', null);
  if (!dotenv.isInitialized) await dotenv.load(fileName: '.env');
  await AppConfig.init(); // build number runtime (gerbang versi & error log)
  StartupDiagnostics.phase('hive_init');
  await runStartupOperation<void>(
    category: 'HIVE_INIT_TIMEOUT',
    timeout: _pluginStartupTimeout,
    operation: Hive.initFlutter,
  );

  StartupDiagnostics.phase('hive_boxes');
  try {
    await _openEncryptedBoxes();
  } on LocalEncryptionKeyException {
    // Kunci rusak berarti seluruh file AES lama tidak bisa dibaca. Amankan
    // semuanya sebelum membuat kunci baru; jangan meniru reinstall yang
    // menghapus satu-satunya salinan transaksi lokal.
    await EncryptedHiveService.recoverInvalidKey(
      recoverableBoxNames: const [PosDatasource.menuCacheBoxName],
      protectedBoxNames: _encryptedBoxPairs.skip(1).map((pair) => pair.secure),
      timeout: _boxStartupTimeout,
    );
    await _openEncryptedBoxes();
  }
  await EncryptedHiveService.openRecoverablePlainBox(
    AppSettings.boxName,
    timeout: _boxStartupTimeout,
  );

  // Saat startup benar-benar offline, gunakan jalur yang TERAKHIR terbukti
  // sehat. Jangan menebak gateway: tebakan itu dapat mengunci aplikasi pada
  // gateway yang sedang mati walaupun direct kemudian pulih.
  StartupDiagnostics.phase('shared_preferences');
  final routePrefs = await runStartupOperation<SharedPreferences>(
    category: 'SHARED_PREFS_TIMEOUT',
    timeout: _pluginStartupTimeout,
    operation: SharedPreferences.getInstance,
  );
  StartupDiagnostics.phase('session_validation');
  await _discardCorruptSupabaseSession(routePrefs);
  const preferFallbackKey = 'backend_last_reachable_was_fallback';
  StartupDiagnostics.phase('backend_probe');
  final backendRoute = await BackendRouteResolver.resolve(
    primaryUrl: AppConfig.supabaseUrl,
    fallbackUrl: AppConfig.supabaseFallbackUrl,
    anonKey: AppConfig.supabaseAnonKey,
    lastReachableWasFallback: routePrefs.getBool(preferFallbackKey) ?? false,
  );
  if (backendRoute.kind != BackendRouteKind.unavailable) {
    await routePrefs.setBool(
      preferFallbackKey,
      backendRoute.kind == BackendRouteKind.fallback,
    );
  }
  AppConfig.activateSupabaseUrl(backendRoute.url);

  StartupDiagnostics.phase('supabase');
  await runStartupOperation<void>(
    category: 'SUPABASE_INIT_TIMEOUT',
    timeout: _supabaseStartupTimeout,
    operation: () => Supabase.initialize(
      url: AppConfig.activeSupabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
      realtimeClientOptions: const RealtimeClientOptions(eventsPerSecond: 10),
      authOptions: FlutterAuthClientOptions(
        localStorage: SharedPreferencesLocalStorage(
          persistSessionKey: AppConfig.supabaseSessionKey,
        ),
      ),
    ),
  );

  if (!_runtimeServicesStarted) {
    // Konektivitas + sinkronisasi transaksi offline.
    StartupDiagnostics.phase('connectivity');
    await runStartupOperation<void>(
      category: 'CONNECTIVITY_INIT_TIMEOUT',
      timeout: _pluginStartupTimeout,
      operation: ConnectivityService.instance.init,
    );
    StartupDiagnostics.phase('services');
    OfflineQueueService.instance.init();
    TransactionJournalService.instance.init();
    SyncService.instance.start();
    _runtimeServicesStarted = true;
  }
  StartupDiagnostics.phase('auth_restore');
}

Future<void> _openEncryptedBoxes() async {
  for (final pair in _encryptedBoxPairs) {
    await EncryptedHiveService.openAndMigrate(
      secureName: pair.secure,
      legacyName: pair.legacy,
      allowCorruptBoxReplacement: pair.secure == PosDatasource.menuCacheBoxName,
      timeout: _boxStartupTimeout,
    );
  }
}

/// Satu string sesi yang terpotong cukup untuk membuat restore auth melempar
/// sebelum aplikasi terbuka. Hanya sesi Supabase yang dibuang; kredensial akun
/// cabang di secure storage dan seluruh transaksi Hive tetap dipertahankan.
Future<void> _discardCorruptSupabaseSession(
  SharedPreferences preferences,
) async {
  final key = AppConfig.supabaseSessionKey;
  final raw = preferences.getString(key);
  if (raw == null) return;
  if (isStoredSupabaseSessionValid(raw)) return;
  await preferences.remove(key);
}

@visibleForTesting
bool isStoredSupabaseSessionValid(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map &&
        decoded['access_token'] is String &&
        (decoded['access_token'] as String).isNotEmpty;
  } catch (_) {
    return false;
  }
}

SupabaseClient get supabase => Supabase.instance.client;
