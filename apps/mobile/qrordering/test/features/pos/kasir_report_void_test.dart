import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:qrordering/features/pos/data/datasources/kasir_report_datasource.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'laporan void memakai nilai historis item setelah total order menjadi 0',
    () async {
      HttpOverrides.global = null;
      SharedPreferences.setMockInitialValues({});
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final path = request.uri.path;
        request.response.headers.contentType = ContentType.json;
        if (path.endsWith('/report_void_summary')) {
          request.response.write(
            jsonEncode([
              {'total_orders': 1, 'total_rows': 1, 'total_amount': 39500},
            ]),
          );
        } else if (path.endsWith('/report_void_details')) {
          request.response.write(
            jsonEncode([
              {
                'row_id': 'item:void-1',
                'order_id': 'order-1',
                'order_number': '003',
                'status_at': '2026-09-25T18:50:00Z',
                'order_at': '2026-09-25T18:46:00Z',
                'kasir_name': 'Dino M',
                'otorisasi_name': 'Dino M',
                'product_name': 'Beef Cheese With Egg',
                'quantity': 1,
                'subtotal': 39500,
                'order_type': 'dine_in',
                'order_total': 39500,
              },
            ]),
          );
        } else {
          request.response.write('[]');
        }
        await request.response.close();
      });

      await Supabase.initialize(
        url: 'http://127.0.0.1:${server.port}',
        anonKey: 'test-anon-key',
        authOptions: const FlutterAuthClientOptions(
          localStorage: EmptyLocalStorage(),
        ),
      );
      addTearDown(() async {
        await Supabase.instance.dispose();
        await server.close(force: true);
      });

      final report = await KasirReportDatasource().fetchVoidReport(
        'outlet-1',
        '2026-09-25T00:00:00Z',
        '2026-09-25T23:59:59Z',
      );

      expect(report.total, 39500);
      expect(report.orders.single['void_amount'], 39500);
      expect(report.orders.single['product_name'], 'Beef Cheese With Egg');
    },
  );
}
