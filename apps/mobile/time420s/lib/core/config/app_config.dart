import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppConfig {
  AppConfig._();

  static String _activeSupabaseUrl = '';

  /// Build number aplikasi — dibaca OTOMATIS dari build (pubspec `version:
  /// x.y.z+N`) saat [init]. Dulu konstanta manual yang harus di-bump tiap
  /// rilis; sekali lupa, gerbang paksa-update (`app_config.min_build_android`)
  /// dan kolom build di error_logs jadi bohong. Nilai 0 = belum ter-init.
  static int appBuild = 103;

  /// Panggil sekali di main() sebelum runApp.
  static Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      appBuild = int.tryParse(info.buildNumber) ?? 0;
    } catch (e) {
      debugPrint('AppConfig.init: gagal baca build number: $e');
    }
  }

  /// Nilai hasil kompilasi (`--dart-define-from-file`) selalu diprioritaskan
  /// untuk release. `dotenv` tetap menjadi fallback agar workflow development
  /// lama (`flutter run`) tidak rusak.
  static String get supabaseUrl {
    const compiled = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
    return compiled.isNotEmpty ? compiled : dotenv.env['SUPABASE_URL'] ?? '';
  }

  static String get supabaseAnonKey {
    const compiled = String.fromEnvironment(
      'SUPABASE_ANON_KEY',
      defaultValue: '',
    );
    return compiled.isNotEmpty
        ? compiled
        : dotenv.env['SUPABASE_ANON_KEY'] ?? '';
  }

  /// Jalur cadangan publik milik Time420s. Nilai ini bukan kunci rahasia dan
  /// dapat diganti saat build bila alamat gateway berpindah.
  static String get supabaseFallbackUrl {
    const compiled = String.fromEnvironment(
      'SUPABASE_FALLBACK_URL',
      defaultValue: '',
    );
    final fromFile = dotenv.env['SUPABASE_FALLBACK_URL'] ?? '';
    final configured = compiled.isNotEmpty
        ? compiled
        : fromFile.isNotEmpty
        ? fromFile
        : 'https://api.time420s.my.id';
    return _normalizeUrl(configured);
  }

  /// URL yang benar-benar dipilih saat aplikasi mulai. Jalur langsung tetap
  /// diprioritaskan; gateway hanya dipakai jika Supabase tidak dapat dijangkau.
  static String get activeSupabaseUrl => _activeSupabaseUrl.isNotEmpty
      ? _activeSupabaseUrl
      : _normalizeUrl(supabaseUrl);

  static bool get usingFallback =>
      supabaseFallbackUrl.isNotEmpty &&
      activeSupabaseUrl == supabaseFallbackUrl;

  static void activateSupabaseUrl(String url) {
    _activeSupabaseUrl = _normalizeUrl(url);
  }

  /// Arahkan aset Supabase Storage ke jalur backend yang sedang aktif.
  ///
  /// Saat jaringan outlet memblokir host Supabase, API berpindah ke gateway
  /// tetapi `menu_items.image_url` tetap berisi URL host utama. Request gambar
  /// dari CachedNetworkImage tidak memakai SupabaseClient, jadi tanpa rewrite
  /// ini menu berhasil dimuat sementara seluruh fotonya gagal.
  static String resolveBackendAssetUrl(
    String value, {
    String? primaryUrl,
    String? activeUrl,
    String? fallbackUrl,
  }) {
    final candidates = resolveBackendAssetUrls(
      value,
      primaryUrl: primaryUrl,
      activeUrl: activeUrl,
      // Fungsi singular mempertahankan perilaku lama: hanya selesaikan URL ke
      // jalur aktif. Daftar failover hanya dibuat lewat versi plural.
      fallbackUrl: fallbackUrl ?? activeUrl,
    );
    return candidates.isEmpty ? value.trim() : candidates.first;
  }

  /// Daftar URL aset berdasarkan prioritas jaringan. Jalur aktif dicoba lebih
  /// dulu, lalu gateway, lalu host asli. Ini diperlukan karena pada beberapa
  /// perangkat API Supabase dapat diakses tetapi request Storage gagal.
  static List<String> resolveBackendAssetUrls(
    String value, {
    String? primaryUrl,
    String? activeUrl,
    String? fallbackUrl,
  }) {
    final raw = value.trim();
    if (raw.isEmpty) return const [];

    final primary = Uri.tryParse(_normalizeUrl(primaryUrl ?? supabaseUrl));
    final active = Uri.tryParse(_normalizeUrl(activeUrl ?? activeSupabaseUrl));
    final source = Uri.tryParse(raw);
    if (primary == null || active == null || source == null) return [raw];
    if (!source.hasScheme || source.host.isEmpty) return [raw];
    if (source.host != primary.host ||
        !source.path.startsWith('/storage/v1/')) {
      return [raw];
    }

    final fallback = Uri.tryParse(
      _normalizeUrl(fallbackUrl ?? supabaseFallbackUrl),
    );

    final candidates = <String>[];
    void addCandidate(Uri? base) {
      if (base == null || !base.hasScheme || base.host.isEmpty) return;
      final basePath = base.path == '/'
          ? ''
          : base.path.replaceFirst(RegExp(r'/+$'), '');
      final candidate = base
          .replace(
            path: '$basePath${source.path}',
            query: source.hasQuery ? source.query : null,
            fragment: source.hasFragment ? source.fragment : null,
          )
          .toString();
      if (!candidates.contains(candidate)) candidates.add(candidate);
    }

    addCandidate(active);
    addCandidate(fallback);
    if (!candidates.contains(raw)) candidates.add(raw);
    return candidates;
  }

  /// Pertahankan nama penyimpanan sesi lama walaupun aplikasi berpindah ke
  /// gateway, sehingga kasir tidak diminta login ulang hanya karena rute ganti.
  static String get supabaseSessionKey {
    final host = Uri.tryParse(supabaseUrl)?.host ?? '';
    final project = host.split('.').first;
    return 'sb-$project-auth-token';
  }

  static String _normalizeUrl(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');
}
