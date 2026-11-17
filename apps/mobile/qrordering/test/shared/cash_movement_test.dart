import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/shared/models/cash_movement.dart';
import 'package:qrordering/features/pos/presentation/bloc/shift_bloc.dart';

CashMovement _mv(String type, double amount) => CashMovement(
      id: 'm-$type-$amount',
      shiftId: 's1',
      outletId: 'o1',
      type: type,
      amount: amount,
      createdAt: DateTime(2026, 7, 5, 10),
    );

void main() {
  group('CashMovement', () {
    test('kas masuk → signedAmount positif', () {
      expect(_mv('in', 50000).signedAmount, 50000);
      expect(_mv('in', 50000).isIn, true);
    });

    test('kas keluar → signedAmount negatif', () {
      expect(_mv('out', 30000).signedAmount, -30000);
      expect(_mv('out', 30000).isIn, false);
    });
  });

  group('ShiftState.cashMovementNet', () {
    test('kosong → 0', () {
      expect(const ShiftState().cashMovementNet, 0);
    });

    test('net = masuk − keluar', () {
      final state = const ShiftState().copyWith(cashMovements: [
        _mv('in', 100000),
        _mv('out', 30000),
        _mv('in', 20000),
        _mv('out', 5000),
      ]);
      // 100000 + 20000 − 30000 − 5000 = 85000
      expect(state.cashMovementNet, 85000);
    });

    test('hanya kas keluar → net negatif', () {
      final state = const ShiftState().copyWith(cashMovements: [
        _mv('out', 40000),
        _mv('out', 10000),
      ]);
      expect(state.cashMovementNet, -50000);
    });
  });
}
