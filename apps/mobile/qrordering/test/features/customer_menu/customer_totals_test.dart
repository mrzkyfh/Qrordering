import 'package:flutter_test/flutter_test.dart';
import 'package:qrordering/features/customer_menu/presentation/pages/customer_menu_page.dart';
import 'package:qrordering/shared/services/tax_calculator.dart';

/// Regression: harga yang DIKUTIP ke pelanggan di menu QR harus sama persis
/// dengan yang DIHITUNG & DISIMPAN server (create_self_order, migration 114).
///
/// Layar ini pernah membaca kunci setelan yang tidak pernah ditulis siapa pun
/// (`tax_rate`/`service_rate`) sehingga selalu jatuh ke 11%/5% hardcoded —
/// sementara server memakai setelan asli outlet. Pelanggan melihat satu harga,
/// ordernya tersimpan dengan harga lain, di SETIAP transaksi QR.
void main() {
  group('nomor member self-order', () {
    test('kosong menjadi null dan input berformat tetap diterima', () {
      expect(selfOrderMemberPhoneOrNull('   '), isNull);
      expect(
        selfOrderMemberPhoneOrNull(' +62 812-3456-789 '),
        '+62 812-3456-789',
      );
      expect(isValidSelfOrderMemberPhone('+62 812-3456-789'), isTrue);
    });

    test('menolak jumlah digit yang tidak masuk akal', () {
      expect(isValidSelfOrderMemberPhone(null), isTrue);
      expect(isValidSelfOrderMemberPhone('1234567'), isFalse);
      expect(isValidSelfOrderMemberPhone('12345678901234567'), isFalse);
    });
  });

  group('selfOrderWithinSchedule', () {
    test('jadwal siang menerima order di dalam jam', () {
      expect(
        selfOrderWithinSchedule({
          'self_order_schedule_enabled': true,
          'self_order_open_time': '10:00',
          'self_order_close_time': '22:00',
        }, DateTime(2026, 7, 18, 12)),
        isTrue,
      );
      expect(
        selfOrderWithinSchedule({
          'self_order_schedule_enabled': true,
          'self_order_open_time': '10:00',
          'self_order_close_time': '22:00',
        }, DateTime(2026, 7, 18, 22)),
        isFalse,
      );
    });

    test('jadwal melewati tengah malam tetap dihitung benar', () {
      const settings = {
        'self_order_schedule_enabled': true,
        'self_order_open_time': '22:00',
        'self_order_close_time': '02:00',
      };
      expect(
        selfOrderWithinSchedule(settings, DateTime(2026, 7, 18, 23)),
        isTrue,
      );
      expect(
        selfOrderWithinSchedule(settings, DateTime(2026, 7, 19, 1)),
        isTrue,
      );
      expect(
        selfOrderWithinSchedule(settings, DateTime(2026, 7, 18, 12)),
        isFalse,
      );
    });
  });

  group('CustomerCartTotals — cermin create_self_order', () {
    test('eksklusif: pajak & service ditambahkan di atas subtotal', () {
      final t = CustomerCartTotals.compute(
        subtotal: 100000,
        taxPercent: 10,
        servicePercent: 2,
        taxInclusive: false,
      );
      expect(t.tax, 10000);
      expect(t.service, 2000);
      expect(t.total, 112000);
    });

    test('outlet tanpa pajak → TIDAK ada pajak yang dikutip', () {
      // Dulu ini mengutip 11% ke pelanggan walau outlet tak memungut pajak.
      final t = CustomerCartTotals.compute(
        subtotal: 100000,
        taxPercent: 0,
        servicePercent: 0,
        taxInclusive: false,
      );
      expect(t.tax, 0);
      expect(t.service, 0);
      expect(t.total, 100000);
    });

    test('inklusif: pajak dipisahkan dari harga, bukan ditambahkan', () {
      final t = CustomerCartTotals.compute(
        subtotal: 110000,
        taxPercent: 10,
        servicePercent: 0,
        taxInclusive: true,
      );
      expect(t.tax, 10000, reason: 'komponen pajak DI DALAM harga');
      expect(t.total, 110000, reason: 'total = harga tertera, tanpa tambahan');
    });

    test('inklusif: service tetap ditambahkan di atas', () {
      final t = CustomerCartTotals.compute(
        subtotal: 110000,
        taxPercent: 10,
        servicePercent: 5,
        taxInclusive: true,
      );
      expect(t.service, 5500);
      expect(t.total, 115500);
    });

    test('inklusif vs eksklusif pada harga sama → total HARUS berbeda', () {
      final incl = CustomerCartTotals.compute(
        subtotal: 110000,
        taxPercent: 10,
        servicePercent: 0,
        taxInclusive: true,
      );
      final excl = CustomerCartTotals.compute(
        subtotal: 110000,
        taxPercent: 10,
        servicePercent: 0,
        taxInclusive: false,
      );

      expect(incl.total, 110000);
      expect(excl.total, 121000);
      expect(
        incl.total,
        lessThan(excl.total),
        reason: 'kalau sama, toggle inklusif tidak berpengaruh — bug lama',
      );
    });

    test('pembulatan mengikuti round() server, bukan dibiarkan pecahan', () {
      // 33.333 × 10% = 3.333,3 → server: round() = 3.333
      final t = CustomerCartTotals.compute(
        subtotal: 33333,
        taxPercent: 10,
        servicePercent: 0,
        taxInclusive: false,
      );
      expect(t.tax, 3333);
      expect(t.total, 36666);
    });

    test('pembulatan outlet diterapkan setelah komponen dihitung', () {
      final t = CustomerCartTotals.compute(
        subtotal: 28750,
        taxPercent: 0,
        servicePercent: 0,
        taxInclusive: false,
        rounding: 1000,
      );
      expect(t.total, 29000);
    });

    test('beberapa pajak aktif dijumlahkan pada self-order', () {
      final t = CustomerCartTotals.compute(
        subtotal: 100000,
        taxPercent: 0,
        servicePercent: 0,
        taxInclusive: false,
        taxRules: const [
          TaxRule(id: 'ppn', percent: 10),
          TaxRule(id: 'daerah', percent: 2),
        ],
      );
      expect(t.tax, 12000);
      expect(t.total, 112000);
    });

    test('keranjang kosong → semua nol', () {
      final t = CustomerCartTotals.compute(
        subtotal: 0,
        taxPercent: 10,
        servicePercent: 5,
        taxInclusive: false,
      );
      expect(t.tax, 0);
      expect(t.service, 0);
      expect(t.total, 0);
    });

    test(
      'angka pelanggan identik dengan tarif nyata outlet produksi (10% + 2%)',
      () {
        // Setelan asli outlet: tax_percent=10, service=2. Dulu layar ini
        // mengutip 11%+5% → Rp 116.000, server menyimpan Rp 112.000.
        final t = CustomerCartTotals.compute(
          subtotal: 100000,
          taxPercent: 10,
          servicePercent: 2,
          taxInclusive: false,
        );
        expect(t.total, 112000, reason: 'bukan 116000 seperti bug lama');
      },
    );
  });
}
