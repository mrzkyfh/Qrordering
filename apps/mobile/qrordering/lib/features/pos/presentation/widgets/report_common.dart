import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';

/// Rentang tanggal hasil period selector. [from]/[to] format `yyyy-MM-dd`
/// (untuk kolom DATE); [fromIso]/[toIso] mencakup awal–akhir hari (untuk
/// kolom timestamp seperti voided_at/cancelled_at/start_time).
class ReportRange {
  final String from;
  final String to;
  final String label;
  const ReportRange(this.from, this.to, this.label);

  /// Batas hari LOKAL dikonversi ke instan UTC — timestamptz di DB adalah UTC,
  /// jadi '${from}T00:00Z' (tanggal lokal + Z) akan meleset 7 jam di WIB.
  String get fromIso => DateTime.parse(from).toUtc().toIso8601String();
  String get toIso => DateTime.parse(to)
      .add(const Duration(days: 1))
      .subtract(const Duration(milliseconds: 1))
      .toUtc()
      .toIso8601String();
}

String _ymd(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Hitung rentang untuk period 'harian' | 'mingguan' | 'bulanan' + offset
/// (0 = sekarang, negatif = mundur). Sama persis dengan owner_reports_page.
ReportRange computeRange(String period, int offset) {
  final now = DateTime.now();
  if (period == 'harian') {
    final d = now.subtract(Duration(days: -offset));
    final s = _ymd(d);
    return ReportRange(s, s, DateFormat('d MMM yyyy', 'id_ID').format(d));
  } else if (period == 'mingguan') {
    final weekStart = now.subtract(Duration(days: now.weekday - 1 + (-offset * 7)));
    final weekEnd = weekStart.add(const Duration(days: 6));
    return ReportRange(
      _ymd(weekStart),
      _ymd(weekEnd),
      '${DateFormat('d MMM', 'id_ID').format(weekStart)} – ${DateFormat('d MMM yyyy', 'id_ID').format(weekEnd)}',
    );
  } else {
    final d = DateTime(now.year, now.month + offset, 1);
    final lastDay = DateTime(d.year, d.month + 1, 0);
    return ReportRange(
        _ymd(d), _ymd(lastDay), DateFormat('MMMM yyyy', 'id_ID').format(d));
  }
}

/// Pemilih outlet bergaya (pill slate + chevron) untuk AppBar laporan/dashboard.
/// Menggantikan `DropdownButton` mentah agar tidak terlihat "Flutter default".
class OutletPicker extends StatelessWidget {
  final String? value;
  final List<Map<String, dynamic>> outlets;
  final String hint;
  final ValueChanged<String?> onChanged;

  const OutletPicker({
    super.key,
    required this.value,
    required this.outlets,
    required this.hint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          borderRadius: BorderRadius.circular(12),
          icon: const Padding(
            padding: EdgeInsets.only(left: 4),
            child: Icon(Icons.keyboard_arrow_down_rounded,
                size: 20, color: AppColors.textSecondary),
          ),
          hint: Text(hint,
              style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: AppColors.textPrimary)),
          style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              color: AppColors.textPrimary),
          items: outlets
              .map((o) => DropdownMenuItem<String>(
                    value: o['id'] as String,
                    child: Text(o['name'] as String),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// Bar pemilih periode (Harian/Mingguan/Bulanan) + navigasi prev/next.
class ReportPeriodBar extends StatelessWidget {
  final String period;
  final int offset;
  final String label;
  final ValueChanged<String> onPeriodChanged;
  final ValueChanged<int> onOffsetChanged;

  const ReportPeriodBar({
    super.key,
    required this.period,
    required this.offset,
    required this.label,
    required this.onPeriodChanged,
    required this.onOffsetChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                for (final p in ['harian', 'mingguan', 'bulanan'])
                  Expanded(
                    child: GestureDetector(
                      onTap: () => onPeriodChanged(p),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: period == p ? AppColors.primary : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          p[0].toUpperCase() + p.substring(1),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: period == p ? Colors.white : AppColors.textSecondary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: () => onOffsetChanged(offset - 1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                IconButton(
                  onPressed: offset < 0 ? () => onOffsetChanged(offset + 1) : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Kartu section dengan judul kapital (gaya owner panel).
class ReportSection extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final EdgeInsets padding;
  const ReportSection({
    super.key,
    required this.title,
    required this.children,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textSecondary,
                    letterSpacing: 0.8)),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Baris label–nilai dengan subtitle opsional.
class KvRow extends StatelessWidget {
  final String label;
  final String value;
  final String? subtitle;
  final Color? valueColor;
  const KvRow(this.label, this.value, {super.key, this.subtitle, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 14)),
                if (subtitle != null)
                  Text(subtitle!,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(value,
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 14, color: valueColor)),
        ],
      ),
    );
  }
}

/// Kartu statistik ringkas (label kecil + nilai besar + garis aksen bawah).
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;
  const StatTile({super.key, required this.label, required this.value, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          Container(height: 3, color: accent),
        ],
      ),
    );
  }
}

/// Empty state seragam: ikon + pesan.
class ReportEmpty extends StatelessWidget {
  final IconData icon;
  final String message;
  const ReportEmpty({super.key, this.icon = Icons.inbox_outlined, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.textDisabled),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}

/// Kartu daftar tile navigasi (ikon, label, route). Tile dinonaktifkan bila
/// [outletId] kosong; route dipush dengan `extra: outletId`.
class NavTilesCard extends StatelessWidget {
  final String outletId;
  final List<(IconData, String, String)> tiles;
  final String? disabledHint;
  const NavTilesCard({
    super.key,
    required this.outletId,
    required this.tiles,
    this.disabledHint,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = outletId.isNotEmpty;
    return Card(
      elevation: 0,
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 56),
              ListTile(
                leading: Icon(tiles[i].$1, color: AppColors.primary),
                title: Text(tiles[i].$2),
                subtitle: !enabled && disabledHint != null
                    ? Text(disabledHint!,
                        style: const TextStyle(fontSize: 11, color: AppColors.textDisabled))
                    : null,
                trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
                enabled: enabled,
                onTap: enabled ? () => context.push(tiles[i].$3, extra: outletId) : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Error state seragam: ikon + pesan + tombol coba lagi.
class ReportError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const ReportError({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 48),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Coba lagi')),
        ],
      ),
    );
  }
}
