import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/currency_formatter.dart';
import '../services/notification_service.dart';

/// Overlay yang tampil di atas semua page saat order self-order baru masuk.
/// Banner bertahan (tidak auto-dismiss) dan nada dering berulang sampai kasir
/// membuka pesanan (tap) atau menutup banner — sesuai permintaan agar suara
/// tidak berhenti sebelum pesanan dibuka.
class NewOrderBannerHost extends StatefulWidget {
  final Widget child;
  const NewOrderBannerHost({super.key, required this.child});

  @override
  State<NewOrderBannerHost> createState() => _NewOrderBannerHostState();
}

class _NewOrderBannerHostState extends State<NewOrderBannerHost> {
  StreamSubscription<NewOrderEvent>? _sub;
  NewOrderEvent? _current;

  @override
  void initState() {
    super.initState();
    _sub = NotificationService().events.listen(_onNewOrder);
  }

  void _onNewOrder(NewOrderEvent event) {
    // Banner sengaja TIDAK auto-dismiss: biarkan tampil selama nada dering
    // berbunyi, sampai kasir membuka atau menutup pesanan.
    setState(() => _current = event);
  }

  void _dismiss() {
    // Setiap penutupan banner = tanda pesanan sudah diperhatikan → matikan
    // nada dering yang berulang.
    NotificationService().stopAlertSound();
    if (!mounted) return;
    setState(() => _current = null);
  }

  void _openOrders() {
    _dismiss();
    final router = GoRouter.maybeOf(context);
    router?.go('/orders');
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final event = _current;
    return Stack(
      children: [
        widget.child,
        if (event != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: _BannerCard(
                event: event,
                onTap: _openOrders,
                onClose: _dismiss,
              ),
            ),
          ),
      ],
    );
  }
}

class _BannerCard extends StatelessWidget {
  final NewOrderEvent event;
  final VoidCallback onTap;
  final VoidCallback onClose;
  const _BannerCard({
    required this.event,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: AppColors.primary,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.notifications_active,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Pesanan Baru #${event.orderNumber}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Total ${CurrencyFormatter.format(event.totalAmount)} — tap untuk proses',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 20),
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
