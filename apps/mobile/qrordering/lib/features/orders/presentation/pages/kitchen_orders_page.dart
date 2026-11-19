import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/models/order.dart';
import '../../data/datasources/orders_datasource.dart';
import '../bloc/orders_bloc.dart';

class KitchenOrdersPage extends StatelessWidget {
  const KitchenOrdersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.read<AuthBloc>().state;
    final outletId = auth is AuthAuthenticated
        ? auth.profile.outletId ?? ''
        : '';
    return BlocProvider(
      create: (_) =>
          OrdersBloc(datasource: OrdersDatasource())
            ..add(OrdersLoadRequested(outletId)),
      child: const _KitchenOrdersView(),
    );
  }
}

class _KitchenOrdersView extends StatelessWidget {
  const _KitchenOrdersView();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F8),
      appBar: AppBar(
        title: const Text('Pesanan QR & Dapur'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: () =>
                context.read<OrdersBloc>().add(OrdersRefreshRequested()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: BlocConsumer<OrdersBloc, OrdersState>(
        listenWhen: (before, after) =>
            before.error != after.error && after.error != null,
        listener: (context, state) => ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(state.error!))),
        builder: (context, state) {
          if (state.loading && state.activeOrders.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          final orders =
              state.activeOrders
                  .where((order) => order.orderType == OrderType.selfOrder)
                  .where(
                    (order) => const {
                      OrderStatus.draft,
                      OrderStatus.confirmed,
                      OrderStatus.preparing,
                      OrderStatus.ready,
                    }.contains(order.status),
                  )
                  .toList()
                ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
          if (orders.isEmpty) {
            return RefreshIndicator(
              onRefresh: () async =>
                  context.read<OrdersBloc>().add(OrdersRefreshRequested()),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 180),
                  Icon(
                    Icons.receipt_long_outlined,
                    size: 58,
                    color: Colors.grey,
                  ),
                  SizedBox(height: 14),
                  Center(child: Text('Belum ada pesanan QR aktif')),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () async =>
                context.read<OrdersBloc>().add(OrdersRefreshRequested()),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: orders.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) => _OrderCard(order: orders[index]),
            ),
          );
        },
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});
  final Order order;

  @override
  Widget build(BuildContext context) {
    final items = order.items ?? const <OrderItem>[];
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '#${order.orderNumber} · Meja ${order.tableNumber ?? '-'}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _StatusBadge(status: order.status),
              ],
            ),
            if ((order.customerName ?? '').isNotEmpty)
              Text(
                order.customerName!,
                style: const TextStyle(color: Colors.black54),
              ),
            const Divider(height: 24),
            for (final item in items) ...[
              Text(
                '${item.quantity}× ${item.menuItem?.name ?? 'Menu'}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (item.options.isNotEmpty)
                Text(
                  item.options.map((option) => option.optionName).join(', '),
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              if ((item.notes ?? '').isNotEmpty)
                Text(
                  'Catatan: ${item.notes}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.primary,
                  ),
                ),
              const SizedBox(height: 8),
            ],
            if ((order.notes ?? '').isNotEmpty)
              Text(
                'Catatan pesanan: ${order.notes}',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: _OrderAction(order: order),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderAction extends StatelessWidget {
  const _OrderAction({required this.order});
  final Order order;

  @override
  Widget build(BuildContext context) {
    final (label, icon, nextStatus) = switch (order.status) {
      OrderStatus.draft => (
        'Konfirmasi & Kirim ke Dapur',
        Icons.check_circle_outline,
        null,
      ),
      OrderStatus.confirmed => (
        'Mulai Masak',
        Icons.soup_kitchen_outlined,
        OrderStatus.preparing,
      ),
      OrderStatus.preparing => (
        'Tandai Siap',
        Icons.done_all,
        OrderStatus.ready,
      ),
      OrderStatus.ready => (
        'Sudah Disajikan',
        Icons.room_service_outlined,
        OrderStatus.served,
      ),
      _ => ('Selesai', Icons.check, null),
    };
    return FilledButton.icon(
      onPressed: () {
        final bloc = context.read<OrdersBloc>();
        if (order.status == OrderStatus.draft) {
          final auth = context.read<AuthBloc>().state;
          bloc.add(
            OrderSendToKitchenRequested(
              order.id,
              order.outletId,
              printedBy: auth is AuthAuthenticated ? auth.profile.id : null,
            ),
          );
        } else if (nextStatus != null) {
          bloc.add(OrderStatusUpdateRequested(order.id, nextStatus));
        }
      },
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      OrderStatus.draft => Colors.orange,
      OrderStatus.confirmed => Colors.blue,
      OrderStatus.preparing => Colors.deepPurple,
      OrderStatus.ready => Colors.green,
      _ => Colors.grey,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          status.label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
