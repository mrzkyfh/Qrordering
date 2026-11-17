import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/shared/models/order.dart';

Map<String, dynamic> _json({String? notes, String? tableNumber}) => {
  'id': 'order-1',
  'outlet_id': 'outlet-1',
  'order_number': '001',
  'order_type': 'self_order',
  'status': 'confirmed',
  'customer_name': 'Pelanggan QR',
  'notes': notes,
  'subtotal': 20000,
  'discount_amount': 0,
  'tax_amount': 2000,
  'service_charge': 400,
  'total_amount': 22400,
  'stock_deducted': false,
  'created_at': '2026-08-13T10:00:00.000Z',
  'updated_at': '2026-08-13T10:00:00.000Z',
  if (tableNumber != null) 'restaurant_tables': {'table_number': tableNumber},
};

void main() {
  test('membaca mode bawa pulang dari catatan order QR', () {
    final order = Order.fromJson(
      _json(
        notes: 'Jenis layanan: Bawa Pulang\nCatatan pelanggan: cepat',
        tableNumber: 'A1',
      ),
    );

    expect(order.customerServiceMode, 'pickup');
    expect(order.customerServiceLabel, 'Bawa Pulang');
    expect(order.operationalOrderTypeLabel, 'QR - Bawa Pulang');
    expect(order.shouldDisplayTable, false);
    expect(order.customerOrderNote, 'Catatan pelanggan: cepat');
  });

  test('membaca mode makan di tempat beserta nomor meja', () {
    final order = Order.fromJson(
      _json(
        notes: 'Jenis layanan: Makan di Tempat (Meja A1)',
        tableNumber: 'A1',
      ),
    );

    expect(order.customerServiceMode, 'dine_in');
    expect(order.customerServiceLabel, 'Makan di Tempat · Meja A1');
    expect(order.operationalOrderTypeLabel, 'QR - Makan di Tempat');
    expect(order.shouldDisplayTable, true);
    expect(order.customerOrderNote, isNull);
  });

  test('tidak menafsirkan catatan bebas sebagai mode layanan', () {
    final order = Order.fromJson(_json(notes: 'Bungkus saus terpisah'));

    expect(order.customerServiceMode, isNull);
    expect(order.customerServiceLabel, isNull);
    expect(order.operationalOrderTypeLabel, 'Order QR');
    expect(order.customerOrderNote, 'Bungkus saus terpisah');
  });
}
