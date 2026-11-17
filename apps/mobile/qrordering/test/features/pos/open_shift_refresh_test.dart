import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qrordering/features/pos/data/datasources/pos_datasource.dart';

/// Regression reconnect: daftar shift dari server wajib mengganti cache lama.
/// Jalur offline/cache-only sendiri diuji di till_cache_test dan
/// payment_flow_test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HttpServer server;
  late List<Map<String, dynamic>> serverShifts;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('open_shift_refresh_test');
    Hive.init(tmp.path);
    await Hive.openBox(PosDatasource.menuCacheBoxName);
    await Hive.box(PosDatasource.menuCacheBoxName).clear();

    serverShifts = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final response = request.response..headers.contentType = ContentType.json;
      if (request.uri.path == '/rest/v1/shifts') {
        response.write(jsonEncode(serverShifts));
      } else {
        response.write('[]');
      }
      await response.close();
    });
    await Supabase.initialize(
      url: 'http://127.0.0.1:${server.port}',
      anonKey: 'test-anon-key',
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  tearDown(() async {
    await Supabase.instance.dispose();
    await server.close(force: true);
    await Hive.deleteFromDisk();
    await tmp.delete(recursive: true);
  });

  test('reconnect menimpa shift kasir lama dengan hasil server', () async {
    await Hive.box(PosDatasource.menuCacheBoxName).put(
      'open_shifts_outlet-1',
      jsonEncode([
        {
          'id': 'shift-lama',
          'kasir_id': 'kasir-1',
          'start_time': '2026-07-28T08:00:00.000Z',
        },
      ]),
    );
    serverShifts = [
      {
        'id': 'shift-aktif',
        'kasir_id': 'kasir-1',
        'start_time': '2026-07-30T08:00:00.000Z',
        'profiles': {'full_name': 'Andi'},
      },
    ];

    final open = await PosDatasource().fetchOpenShifts('outlet-1');

    expect(open.single['id'], 'shift-aktif');
    expect(open.single['verified_at'], isNotNull);
    expect(
      PosDatasource().cachedOwnShiftId('outlet-1', 'kasir-1'),
      'shift-aktif',
    );
    expect(
      PosDatasource().cachedShiftSnapshot('outlet-1', 'shift-lama'),
      isNull,
    );
  });

  test('server tanpa shift aktif membersihkan cache lama', () async {
    await Hive.box(PosDatasource.menuCacheBoxName).put(
      'open_shifts_outlet-1',
      jsonEncode([
        {'id': 'shift-lama', 'kasir_id': 'kasir-1'},
      ]),
    );
    serverShifts = [];

    final open = await PosDatasource().fetchOpenShifts('outlet-1');

    expect(open, isEmpty);
    expect(PosDatasource().cachedOpenShifts('outlet-1'), isEmpty);
  });
}
