import 'package:flutter_test/flutter_test.dart';
import 'package:time420s/shared/models/enums.dart';
import 'package:time420s/shared/services/supabase_service.dart';

void main() {
  group('clockInProfileFromPayload', () {
    test('membentuk profil langsung dari respons clock-in', () {
      final profile = clockInProfileFromPayload({
        'refresh_token': 'tidak-dipakai-oleh-parser',
        'profile': {
          'id': 'staff-1',
          'outlet_id': 'outlet-1',
          'full_name': 'Budi Kasir',
          'role': 'kasir',
          'is_active': true,
          'can_refund': true,
          'created_at': '2026-07-24T10:00:00Z',
          'updated_at': '2026-07-24T11:00:00Z',
        },
      }, staffId: 'staff-1');

      expect(profile.id, 'staff-1');
      expect(profile.outletId, 'outlet-1');
      expect(profile.fullName, 'Budi Kasir');
      expect(profile.role, UserRole.kasir);
      expect(profile.canRefund, isTrue);
    });

    test('respons tanpa status aktif ditolak secara fail-closed', () {
      final profile = clockInProfileFromPayload({
        'profile': {
          'id': 'staff-1',
          'outlet_id': 'outlet-1',
          'full_name': 'Budi Kasir',
          'role': 'kasir',
        },
      }, staffId: 'staff-1');

      expect(profile.isActive, isFalse);
      expect(profile.canRefund, isFalse);
    });

    test('menolak profil yang bukan milik staf yang dipilih', () {
      expect(
        () => clockInProfileFromPayload({
          'profile': {
            'id': 'staff-lain',
            'full_name': 'Staf Lain',
            'role': 'kasir',
          },
        }, staffId: 'staff-1'),
        throwsException,
      );
    });

    test('meneruskan pesan error server tanpa memerlukan profil', () {
      expect(
        () => clockInProfileFromPayload({
          'error': 'PIN salah',
        }, staffId: 'staff-1'),
        throwsA(
          predicate<Object>((error) => error.toString().contains('PIN salah')),
        ),
      );
    });
  });
}
