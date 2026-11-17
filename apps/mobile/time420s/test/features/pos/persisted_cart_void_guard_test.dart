import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:time420s/features/pos/data/datasources/pos_datasource.dart';
import 'package:time420s/features/pos/data/services/held_order_service.dart';
import 'package:time420s/features/pos/domain/entities/cart_item.dart';
import 'package:time420s/features/pos/presentation/bloc/pos_bloc.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/menu_item.dart';

class _Datasource extends Mock implements PosDatasource {}

const menu = MenuItem(
  id: 'menu',
  outletId: 'outlet',
  name: 'Kebab',
  price: 25000,
  isAvailable: true,
  isActive: true,
  isFeatured: false,
  sortOrder: 0,
);
const saved = CartItem(
  id: 'saved',
  menuItem: menu,
  quantity: 2,
  persistedQuantity: 2,
  persistedOrderItemId: 'order-item-1',
);

void main() {
  for (final online in [false, true]) {
    blocTest<PosBloc, PosState>(
      'recalling ${online ? "online" : "draft"} records persisted quantities',
      build: () => PosBloc(datasource: _Datasource()),
      act: (bloc) => bloc.add(
        PosCartLoaded(
          const [CartItem(id: 'saved', menuItem: menu, quantity: 2)],
          editingOrderId: online ? null : 'draft',
          replaceOrderId: online ? 'online' : null,
        ),
      ),
      expect: () => [
        isA<PosState>().having(
          (s) => s.cart.single.persistedQuantity,
          'saved quantity',
          2,
        ),
      ],
    );
  }
  for (final event in <PosEvent>[
    PosItemRemoved('saved'),
    PosQuantityChanged('saved', -1),
    PosQuantityChanged('saved', -999),
    PosCartRemovalRequested(),
    PosItemAdded(menu, quantity: -1),
  ]) {
    blocTest<PosBloc, PosState>(
      'saved items reject ${event.runtimeType} without void',
      build: () => PosBloc(datasource: _Datasource()),
      seed: () => const PosState(cart: [saved], replaceOrderId: 'online'),
      act: (bloc) => bloc.add(event),
      expect: () => <PosState>[],
      verify: (bloc) => expect(bloc.state.cart.single.quantity, 2),
    );
  }
  blocTest<PosBloc, PosState>(
    'new units added to a persisted row can be removed down to its baseline',
    build: () => PosBloc(datasource: _Datasource()),
    seed: () =>
        PosState(cart: [saved.copyWith(quantity: 3)], editingOrderId: 'draft'),
    act: (bloc) => bloc.add(PosQuantityChanged('saved', -1)),
    expect: () => [
      isA<PosState>()
          .having((s) => s.cart.single.quantity, 'quantity', 2)
          .having((s) => s.cart.single.persistedQuantity, 'baseline', 2),
    ],
  );
  blocTest<PosBloc, PosState>(
    'full server void removes the stale row and leaves edit mode',
    build: () => PosBloc(datasource: _Datasource()),
    seed: () => const PosState(cart: [saved], replaceOrderId: 'order-1'),
    act: (bloc) => bloc.add(
      PosPersistedItemsVoided('order-1', const {}, orderVoided: true),
    ),
    expect: () => [
      isA<PosState>()
          .having((state) => state.cart, 'cart', isEmpty)
          .having((state) => state.replaceOrderId, 'edit mode', isNull),
    ],
  );
  blocTest<PosBloc, PosState>(
    'voiding an order also removes unsaved additions tied to that dead order',
    build: () => PosBloc(datasource: _Datasource()),
    seed: () => const PosState(
      cart: [CartItem(id: 'new', menuItem: menu, quantity: 1)],
      appendOrderId: 'order-1',
    ),
    act: (bloc) => bloc.add(
      PosPersistedItemsVoided('order-1', const {}, orderVoided: true),
    ),
    expect: () => [
      isA<PosState>()
          .having((state) => state.cart, 'cart', isEmpty)
          .having((state) => state.appendOrderId, 'append mode', isNull),
    ],
  );
  blocTest<PosBloc, PosState>(
    'partial server void updates saved baseline and keeps unsaved additions',
    build: () => PosBloc(datasource: _Datasource()),
    seed: () => PosState(
      cart: [saved.copyWith(quantity: 3)],
      editingOrderId: 'order-1',
    ),
    act: (bloc) =>
        bloc.add(PosPersistedItemsVoided('order-1', const {'order-item-1': 1})),
    expect: () => [
      isA<PosState>()
          .having((state) => state.cart.single.quantity, 'quantity', 2)
          .having(
            (state) => state.cart.single.persistedQuantity,
            'saved baseline',
            1,
          ),
    ],
  );
  blocTest<PosBloc, PosState>(
    'unsaved additions to an existing order remain removable',
    build: () => PosBloc(datasource: _Datasource()),
    seed: () => const PosState(
      cart: [CartItem(id: 'new', menuItem: menu, quantity: 1)],
      appendOrderId: 'order',
    ),
    act: (bloc) => bloc.add(PosItemRemoved('new')),
    expect: () => [isA<PosState>().having((s) => s.cart, 'cart', isEmpty)],
  );
  blocTest<PosBloc, PosState>(
    'a cart of unsaved items can still be cleared',
    build: () => PosBloc(datasource: _Datasource()),
    seed: () => const PosState(
      cart: [CartItem(id: 'new', menuItem: menu, quantity: 1)],
    ),
    act: (bloc) => bloc.add(PosCartRemovalRequested()),
    expect: () => [isA<PosState>().having((s) => s.cart, 'cart', isEmpty)],
  );
  test(
    'holding cannot turn persisted items into unprotected local items',
    () async {
      await expectLater(
        HeldOrderService.save(
          outletId: 'outlet',
          items: const [saved],
          orderType: OrderType.dineIn,
        ),
        throwsStateError,
      );
    },
  );
}
