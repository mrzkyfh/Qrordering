import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/features/orders/presentation/pages/order_list_page.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/models/order.dart';

Order _order({
  OrderType type = OrderType.selfOrder,
  OrderStatus status = OrderStatus.confirmed,
  List<Payment>? payments,
}) {
  final now = DateTime(2026, 7, 26);
  return Order(
    id: 'order-1',
    outletId: 'outlet-1',
    orderNumber: 'ON-001',
    orderType: type,
    status: status,
    subtotal: 20000,
    discountAmount: 0,
    taxAmount: 2000,
    serviceCharge: 0,
    totalAmount: 22000,
    stockDeducted: true,
    createdAt: now,
    updatedAt: now,
    payments: payments,
  );
}

void main() {
  test('online confirmed tanpa pembayaran dapat diedit', () {
    expect(canEditOnlineOrder(_order()), isTrue);
  });

  test('online draft tanpa pembayaran dapat diedit pada order yang sama', () {
    expect(canEditOnlineOrder(_order(status: OrderStatus.draft)), isTrue);
  });

  test('online yang sudah masuk dapur tidak dapat diedit penuh', () {
    expect(canEditOnlineOrder(_order(status: OrderStatus.preparing)), isFalse);
  });

  test('online yang sudah menerima pembayaran tidak dapat diedit', () {
    expect(
      canEditOnlineOrder(
        _order(
          payments: [
            Payment(
              id: 'pay-1',
              orderId: 'order-1',
              outletId: 'outlet-1',
              method: PaymentMethod.qris,
              amount: 10000,
              paidAt: DateTime(2026, 7, 26),
            ),
          ],
        ),
      ),
      isFalse,
    );
  });

  test('order kasir biasa tidak memakai alur edit online', () {
    expect(canEditOnlineOrder(_order(type: OrderType.dineIn)), isFalse);
  });
}
