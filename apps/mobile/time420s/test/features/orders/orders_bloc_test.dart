import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:time420s/features/orders/data/datasources/orders_datasource.dart';
import 'package:time420s/features/orders/presentation/bloc/orders_bloc.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/order.dart';
import 'package:time420s/shared/services/kitchen_print.dart';

class MockOrdersDatasource extends Mock implements OrdersDatasource {}

Order _makeOrder({
  String id = 'order-1',
  String outletId = 'outlet-1',
  String orderNumber = 'ORD-001',
  OrderStatus status = OrderStatus.confirmed,
  double totalAmount = 50000,
  DateTime? createdAt,
  DateTime? updatedAt,
}) => Order(
  id: id,
  outletId: outletId,
  orderNumber: orderNumber,
  orderType: OrderType.dineIn,
  status: status,
  subtotal: totalAmount,
  discountAmount: 0,
  taxAmount: 0,
  serviceCharge: 0,
  totalAmount: totalAmount,
  stockDeducted: true,
  createdAt: createdAt ?? DateTime(2026, 5, 27),
  updatedAt: updatedAt ?? createdAt ?? DateTime(2026, 5, 27),
);

Map<String, dynamic> _realtimeRow(Order order) => {
  'id': order.id,
  'outlet_id': order.outletId,
  'status': order.status.value,
  'created_at': order.createdAt.toUtc().toIso8601String(),
  'updated_at': order.updatedAt.toUtc().toIso8601String(),
};

void main() {
  late MockOrdersDatasource datasource;

  setUpAll(() {
    registerFallbackValue(OrderStatus.served);
  });

  setUp(() {
    datasource = MockOrdersDatasource();
  });

  // ─── Initial State ────────────────────────────────────────────────────────

  group('Initial State', () {
    test('activeOrders dan completedOrders kosong; loading=false', () {
      final bloc = OrdersBloc(datasource: datasource);
      expect(bloc.state.activeOrders, isEmpty);
      expect(bloc.state.completedOrders, isEmpty);
      expect(bloc.state.loading, false);
      bloc.close();
    });
  });

  // ─── OrdersLoadRequested ──────────────────────────────────────────────────

  group('OrdersLoadRequested', () {
    blocTest<OrdersBloc, OrdersState>(
      'berhasil load: emit loading → activeOrders dan completedOrders terisi',
      build: () {
        when(() => datasource.fetchActiveOrders('outlet-1')).thenAnswer(
          (_) async => [
            _makeOrder(id: 'o1', status: OrderStatus.confirmed),
            _makeOrder(id: 'o2', status: OrderStatus.preparing),
          ],
        );
        when(() => datasource.fetchCompletedOrders('outlet-1')).thenAnswer(
          (_) async => [_makeOrder(id: 'o3', status: OrderStatus.paid)],
        );
        when(
          () => datasource.watchOrders('outlet-1'),
        ).thenAnswer((_) => const Stream.empty());
        return OrdersBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(OrdersLoadRequested('outlet-1')),
      expect: () => [
        isA<OrdersState>().having((s) => s.loading, 'loading', true),
        isA<OrdersState>()
            .having((s) => s.loading, 'loading', false)
            .having((s) => s.activeOrders.length, 'active', 2)
            .having((s) => s.completedOrders.length, 'completed', 1),
      ],
    );

    blocTest<OrdersBloc, OrdersState>(
      'gagal load: emit error',
      build: () {
        when(
          () => datasource.fetchActiveOrders(any()),
        ).thenThrow(Exception('timeout'));
        when(
          () => datasource.fetchCompletedOrders(any()),
        ).thenThrow(Exception('timeout'));
        when(
          () => datasource.watchOrders(any()),
        ).thenAnswer((_) => const Stream.empty());
        return OrdersBloc(datasource: datasource);
      },
      act: (bloc) => bloc.add(OrdersLoadRequested('outlet-1')),
      expect: () => [
        isA<OrdersState>().having((s) => s.loading, 'loading', true),
        isA<OrdersState>()
            .having((s) => s.loading, 'loading', false)
            .having((s) => s.error, 'error', isNotNull),
      ],
    );

    test(
      'load yang selesai setelah close tidak memasang subscription realtime',
      () async {
        final active = Completer<List<Order>>();
        final completed = Completer<List<Order>>();
        when(
          () => datasource.fetchActiveOrders('outlet-1'),
        ).thenAnswer((_) => active.future);
        when(
          () => datasource.fetchCompletedOrders('outlet-1'),
        ).thenAnswer((_) => completed.future);
        when(
          () => datasource.watchOrders('outlet-1'),
        ).thenAnswer((_) => const Stream.empty());

        final bloc = OrdersBloc(datasource: datasource);
        bloc.add(OrdersLoadRequested('outlet-1'));
        await bloc.stream.firstWhere((state) => state.loading);

        // Reproduksi produksi: kasir meninggalkan halaman saat fetch awal
        // belum selesai. close() berjalan sebelum Future.wait melanjutkan.
        final closeFuture = bloc.close();
        active.complete([_makeOrder()]);
        completed.complete([]);
        await closeFuture;
        await Future<void>.delayed(Duration.zero);

        verifyNever(() => datasource.watchOrders(any()));
        expect(bloc.isClosed, isTrue);
      },
    );

    test('hasil outlet lama tidak menimpa outlet yang baru dipilih', () async {
      final oldActive = Completer<List<Order>>();
      final oldCompleted = Completer<List<Order>>();
      when(
        () => datasource.fetchActiveOrders('outlet-1'),
      ).thenAnswer((_) => oldActive.future);
      when(
        () => datasource.fetchCompletedOrders('outlet-1'),
      ).thenAnswer((_) => oldCompleted.future);
      when(() => datasource.fetchActiveOrders('outlet-2')).thenAnswer(
        (_) async => [_makeOrder(id: 'new-order', outletId: 'outlet-2')],
      );
      when(
        () => datasource.fetchCompletedOrders('outlet-2'),
      ).thenAnswer((_) async => []);
      when(
        () => datasource.watchOrders('outlet-2'),
      ).thenAnswer((_) => const Stream.empty());

      final bloc = OrdersBloc(datasource: datasource);
      addTearDown(bloc.close);
      bloc.add(OrdersLoadRequested('outlet-1'));
      await bloc.stream.firstWhere(
        (state) => state.loading && state.outletId == 'outlet-1',
      );

      bloc.add(OrdersLoadRequested('outlet-2'));
      await bloc.stream.firstWhere(
        (state) =>
            !state.loading &&
            state.outletId == 'outlet-2' &&
            state.activeOrders.single.id == 'new-order',
      );

      oldActive.complete([_makeOrder(id: 'stale-order')]);
      oldCompleted.complete([]);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(bloc.state.outletId, 'outlet-2');
      expect(bloc.state.activeOrders.single.id, 'new-order');
      verifyNever(() => datasource.watchOrders('outlet-1'));
    });
  });

  // ─── OrdersRefreshRequested ───────────────────────────────────────────────

  group('OrdersRefreshRequested', () {
    blocTest<OrdersBloc, OrdersState>(
      'refresh mengambil ulang data dengan outletId yang sama',
      build: () {
        when(
          () => datasource.fetchActiveOrders('outlet-1'),
        ).thenAnswer((_) async => [_makeOrder()]);
        when(
          () => datasource.fetchCompletedOrders('outlet-1'),
        ).thenAnswer((_) async => []);
        when(
          () => datasource.watchOrders('outlet-1'),
        ).thenAnswer((_) => const Stream.empty());
        return OrdersBloc(datasource: datasource);
      },
      seed: () => const OrdersState(outletId: 'outlet-1'),
      act: (bloc) => bloc.add(OrdersRefreshRequested()),
      expect: () => [
        isA<OrdersState>().having((s) => s.activeOrders.length, 'active', 1),
      ],
    );
  });

  group('Realtime hemat query', () {
    test(
      'snapshot sama tidak reload dan order aktif baru hanya fetch daftar aktif',
      () async {
        final realtime = StreamController<List<Map<String, dynamic>>>();
        final firstOrder = _makeOrder(id: 'order-1');
        final secondOrder = _makeOrder(id: 'order-2');
        var activeCalls = 0;
        var completedCalls = 0;
        when(() => datasource.fetchActiveOrders('outlet-1')).thenAnswer((
          _,
        ) async {
          activeCalls++;
          return activeCalls == 1 ? [firstOrder] : [firstOrder, secondOrder];
        });
        when(() => datasource.fetchCompletedOrders('outlet-1')).thenAnswer((
          _,
        ) async {
          completedCalls++;
          return [];
        });
        when(
          () => datasource.watchOrders('outlet-1'),
        ).thenAnswer((_) => realtime.stream);

        final bloc = OrdersBloc(datasource: datasource);
        try {
          bloc.add(OrdersLoadRequested('outlet-1'));
          await bloc.stream.firstWhere(
            (state) => !state.loading && state.activeOrders.length == 1,
          );

          realtime.add([_realtimeRow(firstOrder)]);
          await Future<void>.delayed(const Duration(milliseconds: 650));
          expect(activeCalls, 1, reason: 'snapshot identik tidak boleh reload');
          expect(completedCalls, 1);

          realtime.add([_realtimeRow(firstOrder), _realtimeRow(secondOrder)]);
          await bloc.stream
              .firstWhere((state) => state.activeOrders.length == 2)
              .timeout(const Duration(seconds: 2));

          expect(activeCalls, 2);
          expect(
            completedCalls,
            1,
            reason: 'order aktif baru tidak perlu mengambil transaksi selesai',
          );
        } finally {
          await bloc.close();
          await realtime.close();
        }
      },
    );
  });

  // ─── OrderStatusUpdateRequested ───────────────────────────────────────────

  group('OrderStatusUpdateRequested', () {
    blocTest<OrdersBloc, OrdersState>(
      'update status berhasil: updateOrderStatus dipanggil + reload',
      build: () {
        when(
          () => datasource.updateOrderStatus('order-1', OrderStatus.served),
        ).thenAnswer((_) async {});
        when(() => datasource.fetchActiveOrders('outlet-1')).thenAnswer(
          (_) async => [_makeOrder(id: 'order-1', status: OrderStatus.served)],
        );
        when(
          () => datasource.fetchCompletedOrders('outlet-1'),
        ).thenAnswer((_) async => []);
        when(
          () => datasource.watchOrders(any()),
        ).thenAnswer((_) => const Stream.empty());
        return OrdersBloc(datasource: datasource);
      },
      seed: () => const OrdersState(outletId: 'outlet-1'),
      act: (bloc) =>
          bloc.add(OrderStatusUpdateRequested('order-1', OrderStatus.served)),
      expect: () => [
        isA<OrdersState>().having(
          (s) => s.activeOrders.first.status,
          'status',
          OrderStatus.served,
        ),
      ],
      verify: (_) {
        verify(
          () => datasource.updateOrderStatus('order-1', OrderStatus.served),
        ).called(1);
      },
    );

    blocTest<OrdersBloc, OrdersState>(
      'update status gagal: emit error',
      build: () {
        when(
          () => datasource.updateOrderStatus(any(), any()),
        ).thenThrow(Exception('DB error'));
        when(
          () => datasource.watchOrders(any()),
        ).thenAnswer((_) => const Stream.empty());
        return OrdersBloc(datasource: datasource);
      },
      seed: () => const OrdersState(outletId: 'outlet-1'),
      act: (bloc) =>
          bloc.add(OrderStatusUpdateRequested('order-1', OrderStatus.served)),
      expect: () => [
        isA<OrdersState>().having((s) => s.error, 'error', isNotNull),
      ],
    );
  });

  group('OrderSendToKitchenRequested', () {
    test(
      'menyimpan status dahulu lalu mencetak tiket dapur otomatis',
      () async {
        final sequence = <String>[];
        when(
          () => datasource.updateOrderStatus('order-1', OrderStatus.confirmed),
        ).thenAnswer((_) async => sequence.add('status'));
        when(() => datasource.fetchActiveOrders('outlet-1')).thenAnswer(
          (_) async => [
            _makeOrder(id: 'order-1', status: OrderStatus.confirmed),
          ],
        );
        when(
          () => datasource.fetchCompletedOrders('outlet-1'),
        ).thenAnswer((_) async => []);
        when(
          () => datasource.watchOrders('outlet-1'),
        ).thenAnswer((_) => const Stream.empty());

        final bloc = OrdersBloc(
          datasource: datasource,
          printKitchenOrder: (orderId, outletId, printedBy) async {
            sequence.add('print:$orderId:$outletId:${printedBy ?? '-'}');
            return const KitchenPrintResult(printed: 1);
          },
        );
        addTearDown(bloc.close);

        bloc.add(OrdersLoadRequested('outlet-1'));
        await bloc.stream.firstWhere((state) => state.activeOrders.isNotEmpty);
        sequence.clear();

        bloc.add(
          OrderSendToKitchenRequested(
            'order-1',
            'outlet-1',
            printedBy: 'Dino M',
          ),
        );
        for (var attempt = 0; attempt < 100 && sequence.length < 2; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }

        expect(
          sequence,
          ['status', 'print:order-1:outlet-1:Dino M'],
          reason: 'Tiket tidak boleh dicetak sebelum status berhasil disimpan',
        );
        verify(
          () => datasource.updateOrderStatus('order-1', OrderStatus.confirmed),
        ).called(1);
      },
    );
  });

  // ─── OrderVoidRequested ───────────────────────────────────────────────────

  group('OrderVoidRequested', () {
    blocTest<OrdersBloc, OrdersState>(
      'void order berhasil: order hilang dari Daftar Order',
      build: () {
        when(
          () => datasource.voidOrder(
            'order-1',
            approverPin: any(named: 'approverPin'),
          ),
        ).thenAnswer((_) async => 'Manajer');
        when(
          () => datasource.fetchActiveOrders('outlet-1'),
        ).thenAnswer((_) async => []);
        when(() => datasource.fetchCompletedOrders('outlet-1')).thenAnswer(
          (_) async => [_makeOrder(id: 'order-1', status: OrderStatus.void_)],
        );
        when(
          () => datasource.watchOrders(any()),
        ).thenAnswer((_) => const Stream.empty());
        return OrdersBloc(datasource: datasource);
      },
      seed: () => const OrdersState(outletId: 'outlet-1'),
      act: (bloc) =>
          bloc.add(OrderVoidRequested('order-1', approverPin: '1234')),
      // Hasil refresh sama-sama kosong sehingga Equatable tidak memancarkan
      // state duplikat; yang penting order void tidak masuk completed.
      expect: () => <OrdersState>[],
      verify: (_) {
        verify(
          () => datasource.voidOrder(
            'order-1',
            approverPin: any(named: 'approverPin'),
          ),
        ).called(1);
      },
    );

    blocTest<OrdersBloc, OrdersState>(
      'void order gagal: emit error',
      build: () {
        when(
          () => datasource.voidOrder(
            any(),
            approverPin: any(named: 'approverPin'),
          ),
        ).thenThrow(Exception('unauthorized'));
        when(
          () => datasource.watchOrders(any()),
        ).thenAnswer((_) => const Stream.empty());
        return OrdersBloc(datasource: datasource);
      },
      seed: () => const OrdersState(outletId: 'outlet-1'),
      act: (bloc) =>
          bloc.add(OrderVoidRequested('order-1', approverPin: '0000')),
      expect: () => [
        isA<OrdersState>().having((s) => s.error, 'error', isNotNull),
      ],
    );
  });

  // ─── OrderRefundRequested ─────────────────────────────────────────────────

  group('OrderRefundRequested', () {
    blocTest<OrdersBloc, OrdersState>(
      'refund order berhasil: refundOrder dipanggil + order pindah ke completed (cancelled)',
      build: () {
        when(
          () => datasource.refundOrder(
            'order-1',
            reason: 'salah pesan',
            approverPin: any(named: 'approverPin'),
          ),
        ).thenAnswer((_) async => 'Manajer');
        when(
          () => datasource.fetchActiveOrders('outlet-1'),
        ).thenAnswer((_) async => []);
        when(() => datasource.fetchCompletedOrders('outlet-1')).thenAnswer(
          (_) async => [
            _makeOrder(id: 'order-1', status: OrderStatus.cancelled),
          ],
        );
        when(
          () => datasource.watchOrders(any()),
        ).thenAnswer((_) => const Stream.empty());
        return OrdersBloc(datasource: datasource);
      },
      seed: () => const OrdersState(outletId: 'outlet-1'),
      act: (bloc) => bloc.add(
        OrderRefundRequested(
          'order-1',
          reason: 'salah pesan',
          approverPin: '1234',
        ),
      ),
      expect: () => [
        isA<OrdersState>()
            .having((s) => s.activeOrders, 'active', isEmpty)
            .having(
              (s) => s.completedOrders.first.status,
              'status',
              OrderStatus.cancelled,
            ),
      ],
      verify: (_) {
        verify(
          () => datasource.refundOrder(
            'order-1',
            reason: 'salah pesan',
            approverPin: any(named: 'approverPin'),
          ),
        ).called(1);
      },
    );

    blocTest<OrdersBloc, OrdersState>(
      'refund order gagal: emit error',
      build: () {
        when(
          () => datasource.refundOrder(
            any(),
            reason: any(named: 'reason'),
            approverPin: any(named: 'approverPin'),
          ),
        ).thenThrow(Exception('unauthorized'));
        when(
          () => datasource.watchOrders(any()),
        ).thenAnswer((_) => const Stream.empty());
        return OrdersBloc(datasource: datasource);
      },
      seed: () => const OrdersState(outletId: 'outlet-1'),
      act: (bloc) =>
          bloc.add(OrderRefundRequested('order-1', approverPin: '0000')),
      expect: () => [
        isA<OrdersState>().having((s) => s.error, 'error', isNotNull),
      ],
    );
  });

  // ─── Order Model ──────────────────────────────────────────────────────────

  group('Order.isActive', () {
    test('status confirmed → isActive true', () {
      expect(_makeOrder(status: OrderStatus.confirmed).isActive, true);
    });

    test('status preparing → isActive true', () {
      expect(_makeOrder(status: OrderStatus.preparing).isActive, true);
    });

    test('status paid → isActive false', () {
      expect(_makeOrder(status: OrderStatus.paid).isActive, false);
    });

    test('status cancelled → isActive false', () {
      expect(_makeOrder(status: OrderStatus.cancelled).isActive, false);
    });

    test('status void → isActive false', () {
      expect(_makeOrder(status: OrderStatus.void_).isActive, false);
    });
  });
}
