import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/shared/models/enums.dart';

void main() {
  group('UserRoleX', () {
    test('value string sesuai untuk semua role', () {
      expect(UserRole.owner.value, 'owner');
      expect(UserRole.admin.value, 'admin');
      expect(UserRole.manajer.value, 'manajer');
      expect(UserRole.kasir.value, 'kasir');
      expect(UserRole.pelanggan.value, 'pelanggan');
    });

    test('admin dan manajer memiliki akses administrasi outlet yang sama', () {
      expect(UserRole.owner.hasAdminAccess, isTrue);
      expect(UserRole.admin.hasAdminAccess, isTrue);
      expect(UserRole.manajer.hasAdminAccess, isTrue);
      expect(UserRole.kasir.hasAdminAccess, isFalse);
      expect(UserRole.pelanggan.hasAdminAccess, isFalse);
    });

    test('fromString mengembalikan role yang benar', () {
      expect(UserRoleX.fromString('owner'), UserRole.owner);
      expect(UserRoleX.fromString('admin'), UserRole.admin);
      expect(UserRoleX.fromString('manajer'), UserRole.manajer);
      expect(UserRoleX.fromString('kasir'), UserRole.kasir);
    });

    test('fromString dengan nilai tidak dikenal fallback ke kasir', () {
      expect(UserRoleX.fromString('unknown'), UserRole.kasir);
    });

  });

  group('OrderStatusX', () {
    test('value string sesuai untuk semua status', () {
      expect(OrderStatus.draft.value, 'draft');
      expect(OrderStatus.confirmed.value, 'confirmed');
      expect(OrderStatus.preparing.value, 'preparing');
      expect(OrderStatus.ready.value, 'ready');
      expect(OrderStatus.served.value, 'served');
      expect(OrderStatus.paid.value, 'paid');
      expect(OrderStatus.cancelled.value, 'cancelled');
      expect(OrderStatus.void_.value, 'void');
    });

    test('label Bahasa Indonesia sesuai', () {
      expect(OrderStatus.confirmed.label, 'Dikonfirmasi');
      expect(OrderStatus.preparing.label, 'Dimasak');
      expect(OrderStatus.ready.label, 'Siap');
      expect(OrderStatus.paid.label, 'Lunas');
      expect(OrderStatus.void_.label, 'Void');
    });

    test('fromString mengembalikan status yang benar', () {
      expect(OrderStatusX.fromString('confirmed'), OrderStatus.confirmed);
      expect(OrderStatusX.fromString('preparing'), OrderStatus.preparing);
      expect(OrderStatusX.fromString('paid'), OrderStatus.paid);
      expect(OrderStatusX.fromString('void'), OrderStatus.void_);
    });

    test('fromString dengan nilai tidak dikenal fallback ke draft', () {
      expect(OrderStatusX.fromString('invalid'), OrderStatus.draft);
    });
  });

  group('PaymentMethodX', () {
    test('value string sesuai', () {
      expect(PaymentMethod.cash.value, 'cash');
      expect(PaymentMethod.qris.value, 'qris');
      expect(PaymentMethod.debit.value, 'debit');
      expect(PaymentMethod.credit.value, 'credit');
      expect(PaymentMethod.ewallet.value, 'ewallet');
      expect(PaymentMethod.transfer.value, 'transfer');
    });

    test('label Bahasa Indonesia sesuai', () {
      expect(PaymentMethod.cash.label, 'Tunai');
      expect(PaymentMethod.qris.label, 'QRIS');
      expect(PaymentMethod.ewallet.label, 'E-Wallet');
    });

    test('fromString fallback ke cash jika tidak dikenal', () {
      expect(PaymentMethodX.fromString('bitcoin'), PaymentMethod.cash);
    });
  });

  group('OrderTypeX', () {
    test('value string sesuai', () {
      expect(OrderType.dineIn.value, 'dine_in');
      expect(OrderType.takeaway.value, 'takeaway');
      expect(OrderType.selfOrder.value, 'self_order');
    });

    test('fromString mengembalikan tipe yang benar', () {
      expect(OrderTypeX.fromString('dine_in'), OrderType.dineIn);
      expect(OrderTypeX.fromString('takeaway'), OrderType.takeaway);
      expect(OrderTypeX.fromString('self_order'), OrderType.selfOrder);
    });

    test('fromString fallback ke dineIn jika tidak dikenal', () {
      expect(OrderTypeX.fromString('unknown'), OrderType.dineIn);
    });
  });

  group('TableStatusX', () {
    test('value string sesuai', () {
      expect(TableStatus.available.value, 'available');
      expect(TableStatus.occupied.value, 'occupied');
      expect(TableStatus.reserved.value, 'reserved');
      expect(TableStatus.dirty.value, 'dirty');
    });

    test('fromString fallback ke available jika tidak dikenal', () {
      expect(TableStatusX.fromString('unknown'), TableStatus.available);
    });
  });
}
