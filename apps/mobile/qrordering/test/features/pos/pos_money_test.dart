import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/features/pos/presentation/bloc/pos_bloc.dart';
import 'package:qrordering/features/pos/domain/entities/cart_item.dart';
import 'package:qrordering/shared/models/menu_item.dart';
import 'package:qrordering/shared/models/enums.dart';
import 'package:qrordering/shared/services/tax_calculator.dart';

MenuItem _item({double price = 10000}) => MenuItem(
  id: 'i1',
  outletId: 'o1',
  name: 'Kopi',
  price: price,
  isAvailable: true,
  isActive: true,
  isFeatured: false,
  sortOrder: 0,
);

CartItem _cart({double price = 10000, int qty = 1}) => CartItem(
  id: 'c1',
  menuItem: _item(price: price),
  quantity: qty,
  selectedExtras: const [],
);

void main() {
  group('PosState perhitungan uang', () {
    test('subtotal = harga × qty', () {
      final s = const PosState().copyWith(cart: [_cart(price: 10000, qty: 3)]);
      expect(s.subtotal, 30000);
    });

    test('pajak 10% dibulatkan, service 5%', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 25000, qty: 1)],
        taxPercent: 10,
        taxActive: true,
        serviceChargePercent: 5,
      );
      expect(s.subtotal, 25000);
      expect(s.taxAmount, 2500); // 25000 * 10%
      expect(s.serviceCharge, 1250); // 25000 * 5%
      // total = (25000 − 0 − 0) + 2500 + 1250
      expect(s.total, 28750);
    });

    test('pembulatan outlet diterapkan ke total POS', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 28750)],
        taxPercent: 0,
        taxActive: false,
        rounding: 1000,
      );
      expect(s.unroundedTotal, 28750);
      expect(s.total, 29000);
    });

    test('pajak sesudah diskon memakai basis bersih', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 100000)],
        discountAmount: 20000,
        taxPercent: 10,
        taxActive: true,
        taxCalculation: 'after_discount',
      );
      expect(s.taxAmount, 8000);
      expect(s.total, 88000);
    });

    test('pajak dengan tipe order terbatas tidak aktif di tipe lain', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 100000)],
        orderType: OrderType.takeaway,
        taxPercent: 10,
        taxActive: true,
        taxOrderTypes: {'dine_in'},
      );
      expect(s.taxAmount, 0);
      expect(s.total, 100000);
    });

    test('pajak nonaktif → taxAmount 0', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 20000)],
        taxPercent: 10,
        taxActive: false,
      );
      expect(s.taxAmount, 0);
      expect(s.total, 20000);
    });

    test('beberapa pajak aktif dijumlahkan pada POS', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 100000)],
        taxRules: const [
          TaxRule(id: 'ppn', percent: 10),
          TaxRule(id: 'daerah', percent: 2),
        ],
      );
      expect(s.taxAmount, 12000);
      expect(s.total, 112000);
    });

    test(
      'pajak inclusive + exclusive dinormalisasi sebagai tambahan total',
      () {
        final s = const PosState().copyWith(
          cart: [_cart(price: 100000)],
          taxRules: const [
            TaxRule(id: 'ppn', percent: 10, inclusive: true),
            TaxRule(id: 'daerah', percent: 2),
          ],
        );
        expect(s.taxAmount, 11091);
        expect(s.taxInclusiveForOrder, isFalse);
        expect(s.total, 111091);
      },
    );

    test('diskon + loyalty dikurangi sebelum pajak/service ditambah', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 100000, qty: 1)],
        discountAmount: 15000,
        loyaltyDiscount: 5000,
        taxPercent: 10,
        taxActive: true,
        serviceChargePercent: 0,
      );
      // base = 100000 − 15000 − 5000 = 80000; pajak = 100000*10% = 10000
      // total = 80000 + 10000 = 90000
      expect(s.total, 90000);
    });

    test('diskon melebihi subtotal → base di-clamp 0, tidak negatif', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 10000, qty: 1)],
        discountAmount: 50000,
        taxPercent: 0,
        taxActive: false,
        serviceChargePercent: 0,
      );
      expect(s.total, 0);
    });

    // ── Harga sudah termasuk pajak ────────────────────────────────────────────
    // Setelan ini lama dihormati STRUK ("Harga Sudah Termasuk PPN senilai X")
    // tapi diabaikan perhitungan → pajak tetap ditambahkan di atas harga.
    // Pelanggan tertagih dobel sementara struknya bilang sudah termasuk.

    test('termasuk pajak: pajak DIPISAHKAN dari harga, bukan ditambahkan', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 110000, qty: 1)],
        taxPercent: 10,
        taxActive: true,
        taxInclusive: true,
      );
      // 110.000 sudah memuat PPN 10% → harga dasar 100.000, pajak 10.000.
      expect(s.taxAmount, 10000, reason: 'komponen pajak di dalam harga');
      expect(
        s.total,
        110000,
        reason: 'total = harga tertera; pajak TIDAK ditambahkan lagi',
      );
    });

    test('termasuk pajak: service tetap ditambahkan di atas', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 110000, qty: 1)],
        taxPercent: 10,
        taxActive: true,
        taxInclusive: true,
        serviceChargePercent: 5,
      );
      expect(s.serviceCharge, 5500);
      expect(
        s.total,
        115500,
        reason: '110.000 + service 5.500, tanpa pajak lagi',
      );
    });

    test(
      'termasuk pajak: diskon mengurangi harga yang sudah bermuatan pajak',
      () {
        final s = const PosState().copyWith(
          cart: [_cart(price: 110000, qty: 1)],
          discountAmount: 10000,
          taxPercent: 10,
          taxActive: true,
          taxInclusive: true,
        );
        expect(s.total, 100000);
      },
    );

    test('termasuk pajak + pajak nonaktif → tak ada komponen pajak', () {
      final s = const PosState().copyWith(
        cart: [_cart(price: 110000, qty: 1)],
        taxPercent: 10,
        taxActive: false,
        taxInclusive: true,
      );
      expect(s.taxAmount, 0);
      expect(s.total, 110000);
    });

    test('inklusif vs eksklusif pada harga sama → total HARUS berbeda', () {
      final cart = [_cart(price: 110000, qty: 1)];
      final incl = const PosState().copyWith(
        cart: cart,
        taxPercent: 10,
        taxActive: true,
        taxInclusive: true,
      );
      final excl = const PosState().copyWith(
        cart: cart,
        taxPercent: 10,
        taxActive: true,
        taxInclusive: false,
      );

      expect(incl.total, 110000);
      expect(excl.total, 121000);
      expect(
        incl.total,
        lessThan(excl.total),
        reason: 'kalau sama, artinya toggle-nya tidak berpengaruh — bug lama',
      );
    });

    test('keranjang kosong → semua 0', () {
      const s = PosState();
      expect(s.subtotal, 0);
      expect(s.taxAmount, 0);
      expect(s.total, 0);
    });
  });
}
