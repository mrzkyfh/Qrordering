import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/features/orders/data/datasources/orders_datasource.dart';

void main() {
  test('sales page parser memisahkan baris, agregat, dan nama kasir', () {
    final result = salesPageResultFromPayload({
      'rows': [
        {
          'id': 'order-1',
          'outlet_id': 'outlet-1',
          'shift_id': null,
          'table_id': null,
          'order_number': '007',
          'order_type': 'dine_in',
          'status': 'paid',
          'customer_name': 'Budi',
          'subtotal': 20000,
          'discount_amount': 0,
          'tax_amount': 2000,
          'service_charge': 400,
          'total_amount': 22400,
          'net_total_amount': 20000,
          'sales_at': '2026-07-29T04:00:00Z',
          'stock_deducted': true,
          'kitchen_printed': true,
          'created_by': 'cashier-1',
          'cashier_name': 'Dino',
          'created_at': '2026-07-28T04:00:00Z',
          'updated_at': '2026-07-28T04:01:00Z',
          'restaurant_tables': {'table_number': 'A1'},
        },
      ],
      'total_transactions': 51,
      'total_sales': 1142400,
      'average_sales': 22400,
      'has_more': true,
      'days': {
        '2026-07-28': {'count': 51, 'total': 1142400},
      },
    });

    expect(result.orders, hasLength(1));
    expect(result.orders.single.orderNumber, '007');
    expect(result.orders.single.tableNumber, 'A1');
    expect(result.cashiers, {'cashier-1': 'Dino'});
    expect(result.netAmounts, {'order-1': 20000});
    expect(result.salesAt['order-1'], DateTime.parse('2026-07-29T04:00:00Z'));
    expect(result.totalTransactions, 51);
    expect(result.totalSales, 1142400);
    expect(result.averageSales, 22400);
    expect(result.hasMore, isTrue);
    expect(result.days['2026-07-28']?.count, 51);
    expect(result.days['2026-07-28']?.total, 1142400);
  });

  test('sales page parser aman untuk payload kosong', () {
    final result = salesPageResultFromPayload(null);

    expect(result.orders, isEmpty);
    expect(result.cashiers, isEmpty);
    expect(result.netAmounts, isEmpty);
    expect(result.salesAt, isEmpty);
    expect(result.days, isEmpty);
    expect(result.totalTransactions, 0);
    expect(result.totalSales, 0);
    expect(result.hasMore, isFalse);
  });
}
