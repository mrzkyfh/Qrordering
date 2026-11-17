import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// Notifikasi in-app terpusat — overlay top-center bergaya kartu gelap
/// (judul + subjudul + tombol close), slide+fade masuk, auto-dismiss 3 detik.
class AppToast {
  const AppToast._();

  static OverlayEntry? _current;
  static VoidCallback? _removeCurrent;

  static void success(BuildContext context, String message, {String? title}) =>
      _show(context, _ToastKind.success, title ?? 'Berhasil', message);

  static void error(BuildContext context, String message, {String? title}) =>
      _show(context, _ToastKind.error, title ?? 'Gagal', message);

  static void info(BuildContext context, String message, {String? title}) =>
      _show(context, _ToastKind.info, title ?? 'Info', message);

  static void _show(
    BuildContext context,
    _ToastKind kind,
    String title,
    String message,
  ) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    // Hanya satu toast aktif — tutup yang lama.
    _removeCurrent?.call();

    late OverlayEntry entry;
    var removed = false;
    void removeEntry() {
      // Timer, tombol close, toast pengganti, dan dispose route dapat tiba pada
      // frame yang sama. OverlayEntry.remove() tidak boleh dipanggil dua kali.
      if (removed) return;
      removed = true;
      if (_current == entry) {
        _current = null;
        _removeCurrent = null;
      }
      if (entry.mounted) entry.remove();
    }

    entry = OverlayEntry(
      builder: (_) => _ToastCard(
        kind: kind,
        title: title,
        message: message,
        onClose: removeEntry,
      ),
    );
    _current = entry;
    _removeCurrent = removeEntry;
    overlay.insert(entry);
  }
}

enum _ToastKind { success, error, info }

class _ToastCard extends StatefulWidget {
  final _ToastKind kind;
  final String title;
  final String message;
  final VoidCallback onClose;

  const _ToastCard({
    required this.kind,
    required this.title,
    required this.message,
    required this.onClose,
  });

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _timer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 200),
    )..forward();
    _timer = Timer(const Duration(seconds: 3), _dismiss);
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _timer?.cancel();
    if (mounted) {
      try {
        await _ctrl.reverse();
      } on TickerCanceled {
        // Toast diganti/route ditutup ketika animasi reverse masih berjalan.
      }
    }
    widget.onClose();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  ({Color bg, IconData icon}) get _style => switch (widget.kind) {
    _ToastKind.success => (
      bg: const Color(0xFF1D9E75),
      icon: Icons.check_rounded,
    ),
    _ToastKind.error => (bg: AppColors.error, icon: Icons.close_rounded),
    _ToastKind.info => (bg: AppColors.primary, icon: Icons.info_outline),
  };

  @override
  Widget build(BuildContext context) {
    final s = _style;
    final curve = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    return Positioned(
      top: MediaQuery.of(context).padding.top + 16,
      left: 0,
      right: 0,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -1),
          end: Offset.zero,
        ).animate(curve),
        child: FadeTransition(
          opacity: curve,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF111111),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: s.bg,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(s.icon, size: 16, color: Colors.white),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                widget.title,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                widget.message,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.white.withValues(alpha: 0.6),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        GestureDetector(
                          onTap: _dismiss,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              size: 14,
                              color: Colors.white.withValues(alpha: 0.4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
