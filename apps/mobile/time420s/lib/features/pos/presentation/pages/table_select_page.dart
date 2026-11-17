import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../bloc/pos_bloc.dart';
import '../../../orders/data/datasources/orders_datasource.dart';
import '../../../../shared/models/restaurant_table.dart';
import '../../../../shared/models/enums.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../features/auth/presentation/bloc/auth_bloc.dart';

class TableSelectPage extends StatefulWidget {
  const TableSelectPage({super.key});
  @override
  State<TableSelectPage> createState() => _TableSelectPageState();
}

class _TableSelectPageState extends State<TableSelectPage> {
  List<RestaurantTable> _tables = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  Future<void> _loadTables() async {
    final authState = context.read<AuthBloc>().state;
    if (authState is! AuthAuthenticated) return;
    final outletId = authState.profile.outletId ?? '';
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await OrdersDatasource().fetchTables(outletId);
      if (!mounted) return;
      final tables =
          (data as List).map((e) => RestaurantTable.fromJson(e)).toList()
            // Urut natural: "2" sebelum "10" (server order by string salah urut).
            ..sort((a, b) => _naturalCompare(a.tableNumber, b.tableNumber));
      setState(() {
        _tables = tables;
        _loading = false;
      });
    } catch (_) {
      // Tanpa ini, kegagalan jaringan membuat _loading selamanya true →
      // spinner ngegantung tanpa jalan keluar. Tampilkan pesan + tombol ulang.
      if (mounted) {
        setState(() {
          _loading = false;
          _error =
              'Data meja belum tersimpan. Sambungkan internet sekali lalu coba lagi.';
        });
      }
    }
  }

  /// Bandingkan nomor meja secara natural: angka diurut numerik, sisanya teks.
  /// Mis. "1","2","10","A1","A2","A10" — bukan "1","10","2".
  int _naturalCompare(String a, String b) {
    final numA = int.tryParse(a);
    final numB = int.tryParse(b);
    if (numA != null && numB != null) return numA.compareTo(numB);
    if (numA != null) return -1; // angka murni sebelum yang ada huruf
    if (numB != null) return 1;
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pilih Meja')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wifi_off, size: 40, color: Colors.grey),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _loadTables,
                    child: const Text('Coba Lagi'),
                  ),
                ],
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 1,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: _tables.length,
              itemBuilder: (context, i) {
                final table = _tables[i];
                final isOccupied = table.status == TableStatus.occupied;
                return _TableCard(
                  table: table,
                  onTap: isOccupied
                      ? null
                      : () {
                          context.read<PosBloc>().add(
                            PosTableSelected(table.id, table.tableNumber),
                          );
                          context.pop();
                        },
                );
              },
            ),
    );
  }
}

class _TableCard extends StatelessWidget {
  final RestaurantTable table;
  final VoidCallback? onTap;
  const _TableCard({required this.table, this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = switch (table.status) {
      TableStatus.available => AppColors.tableAvailable,
      TableStatus.occupied => AppColors.tableOccupied,
      TableStatus.reserved => AppColors.tableReserved,
      TableStatus.dirty => AppColors.tableDirty,
    };

    final label = switch (table.status) {
      TableStatus.available => 'Tersedia',
      TableStatus.occupied => 'Terisi',
      TableStatus.reserved => 'Reservasi',
      TableStatus.dirty => 'Kotor',
    };

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: onTap != null
              ? color.withValues(alpha: 0.1)
              : Colors.grey.withValues(alpha: 0.05),
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.table_restaurant, color: color, size: 28),
            const SizedBox(height: 4),
            Text(
              table.tableNumber,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: onTap != null
                    ? AppColors.textPrimary
                    : AppColors.textDisabled,
              ),
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
