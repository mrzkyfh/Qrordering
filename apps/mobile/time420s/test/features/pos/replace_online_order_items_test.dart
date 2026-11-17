import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:time420s/features/pos/data/datasources/pos_datasource.dart';
import 'package:time420s/features/pos/domain/entities/cart_item.dart';
import 'package:time420s/features/pos/domain/entities/selected_extra.dart';
import 'package:time420s/shared/models/menu_item.dart';

class _FakePostgrest {
  final requests = <({String path, Object? body})>[];
  late final HttpServer _server;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      requests.add((
        path: request.uri.path,
        body: raw.isEmpty ? null : jsonDecode(raw),
      ));
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'order_id': 'order-online-1',
          'order_number': 'ON-001',
          'items': [],
          'subtotal': 29000,
          'total_amount': 32480,
        }),
      );
      await request.response.close();
    });
  }

  Map<String, dynamic> rpcBody(String rpc) =>
      (requests
                  .singleWhere((request) => request.path == '/rest/v1/rpc/$rpc')
                  .body
              as Map)
          .cast<String, dynamic>();

  Future<void> stop() => _server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakePostgrest api;
  late PosDatasource datasource;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    api = _FakePostgrest();
    await api.start();
    await Supabase.initialize(
      url: api.url,
      anonKey: 'test-anon-key',
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );
    datasource = PosDatasource();
  });

  tearDown(() async {
    await Supabase.instance.dispose();
    await api.stop();
  });

  test(
    'edit online mengirim identitas order, item, catatan, dan ekstra lengkap',
    () async {
      const menu = MenuItem(
        id: 'menu-kebab',
        outletId: 'outlet-1',
        name: 'Kebab',
        price: 12000,
        isAvailable: true,
        isActive: true,
        isFeatured: false,
        sortOrder: 0,
      );
      const extra = SelectedExtra(
        menuExtraId: 'extra-saus',
        menuExtraOptionId: 'option-pedas',
        extraName: 'Saus',
        optionName: 'Pedas',
        price: 2500,
      );

      await datasource.replaceOnlineOrderItems(
        orderId: 'order-online-1',
        customerName: '  Budi  ',
        items: const [
          CartItem(
            id: 'cart-1',
            menuItem: menu,
            quantity: 2,
            notes: 'Tanpa bawang',
            selectedExtras: [extra],
          ),
        ],
      );

      expect(api.rpcBody('replace_online_order_items'), {
        'p_order_id': 'order-online-1',
        'p_items': [
          {
            'menu_item_id': 'menu-kebab',
            'quantity': 2,
            'unit_price': 14500,
            'notes': 'Tanpa bawang',
            'extras': [
              {'menu_extra_option_id': 'option-pedas'},
            ],
          },
        ],
        'p_customer_name': 'Budi',
      });
    },
  );

  test(
    'edit online menolak keranjang kosong sebelum memanggil server',
    () async {
      await expectLater(
        datasource.replaceOnlineOrderItems(
          orderId: 'order-online-1',
          items: const [],
        ),
        throwsArgumentError,
      );

      expect(
        api.requests.where(
          (request) =>
              request.path == '/rest/v1/rpc/replace_online_order_items',
        ),
        isEmpty,
      );
    },
  );
}
