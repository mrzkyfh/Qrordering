import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../shared/services/order_realtime_service.dart';

/// Tombol Daftar Order + badge jumlah order aktif (live realtime) — "notif order
/// masuk". 34×34, radius 8, merah brand, ikon nota putih.
class DaftarOrderButton extends StatefulWidget {
  final String outletId;
  const DaftarOrderButton({super.key, required this.outletId});

  @override
  State<DaftarOrderButton> createState() => _DaftarOrderButtonState();
}

class _DaftarOrderButtonState extends State<DaftarOrderButton> {
  static const _active = {'draft', 'confirmed', 'preparing', 'ready', 'served'};

  // Dibuat sekali; sumbernya dibagi dengan notifikasi dan halaman order.
  Stream<List<Map<String, dynamic>>>? _stream;

  @override
  void initState() {
    super.initState();
    if (widget.outletId.isNotEmpty) {
      _stream = OrderRealtimeService.instance.watch(widget.outletId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        final count = (snap.data ?? const [])
            .where((r) => _active.contains(r['status']))
            .length;
        return GestureDetector(
          onTap: () => context.go('/kasir/orders'),
          behavior: HitTestBehavior.opaque,
          child: Tooltip(
            message: 'Daftar Order',
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE24B4A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.receipt_long,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                if (count > 0)
                  Positioned(
                    top: -5,
                    right: -5,
                    child: Container(
                      width: 16,
                      height: 16,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFF111111),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: Text(
                        count > 9 ? '9+' : '$count',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
