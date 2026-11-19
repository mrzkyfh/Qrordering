import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'kasir_shell.dart';
import '../../../../shared/services/connectivity_service.dart';
import '../../../../shared/services/order_realtime_service.dart';
import '../bloc/pos_bloc.dart';
import '../widgets/menu_item_card.dart';
import '../widgets/cart_panel.dart';
import '../widgets/stored_item_void_notice.dart';
import '../../../orders/presentation/widgets/daftar_order_button.dart';
import '../../../../shared/models/menu_item.dart';
import '../../../../shared/models/menu_extra.dart';
import '../../../../features/pos/domain/entities/selected_extra.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/widgets/app_skeleton.dart';
import '../../../../core/widgets/app_empty_state.dart';
import '../../../../core/widgets/app_error_view.dart';
import '../../../../features/auth/presentation/bloc/auth_bloc.dart';

class PosPage extends StatelessWidget {
  const PosPage({super.key});

  @override
  Widget build(BuildContext context) => const SafeArea(child: _PosView());
}

// ──────────────────────────────────────────────────────────────────────────────
// ROOT VIEW — wide: 3-col layout, narrow: mobile layout
// ──────────────────────────────────────────────────────────────────────────────

class _PosView extends StatelessWidget {
  const _PosView();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 1100) {
          return const ColoredBox(
            color: Color(0xFFF5F5F5),
            child: Row(
              children: [
                SizedBox(width: 180, child: _PosLeftSidebar()),
                Expanded(child: _MenuArea()),
                SizedBox(width: 300, child: CartPanel()),
              ],
            ),
          );
        }
        // Preserve the reference's three panels in tablet split screen.
        // A compact 900px workspace scales as one unit, including hit testing;
        // its height expands so each panel still scrolls independently.
        if (c.maxWidth >= 400) {
          final scale = c.maxWidth / 900;
          final workspaceSize = Size(900, c.maxHeight / scale);
          return FittedBox(
            key: const Key('compact-tablet-workspace'),
            fit: BoxFit.fill,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: workspaceSize.width,
              height: workspaceSize.height,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(size: workspaceSize),
                child: const Column(
                  children: [
                    _NarrowTopBar(),
                    Expanded(
                      child: Row(
                        children: [
                          SizedBox(
                            key: Key('compact-category-panel'),
                            width: 150,
                            child: ColoredBox(
                              color: Colors.white,
                              child: Column(
                                children: [
                                  Expanded(child: _CategoryNav()),
                                  _SidebarFooter(),
                                ],
                              ),
                            ),
                          ),
                          Expanded(child: _MenuGrid(compact: true)),
                          SizedBox(width: 300, child: CartPanel()),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return const Column(
          children: [
            _NarrowTopBar(),
            Expanded(child: _NarrowMenuPanel()),
            _CartBottomBar(),
          ],
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// SIDEBAR KIRI
// ──────────────────────────────────────────────────────────────────────────────

class _PosLeftSidebar extends StatelessWidget {
  const _PosLeftSidebar();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFEFEFEF), width: 0.5)),
      ),
      child: Column(
        children: [
          _SidebarHeader(),
          Expanded(child: _CategoryNav()),
          _SidebarFooter(),
        ],
      ),
    );
  }
}

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    final profile = auth is AuthAuthenticated ? auth.profile : null;
    final outletName = (profile?.outletName?.trim().isNotEmpty ?? false)
        ? profile!.outletName!.trim()
        : 'Outlet';
    final initials = outletName
        .split(' ')
        .take(2)
        .map((w) => w.isNotEmpty ? w[0].toUpperCase() : '')
        .join();

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFEFEFEF), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(
              'assets/images/ic_launcher_512.png',
              width: 38,
              height: 38,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: Color(0xFF0F766E)),
                child: Text(
                  initials,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  outletName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111111),
                  ),
                ),
                const SizedBox(height: 2),
                const _OnlineStatus(),
              ],
            ),
          ),
          GestureDetector(
            onTap: KasirShell.openMenu,
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.menu, size: 18, color: Color(0xFF888888)),
            ),
          ),
        ],
      ),
    );
  }
}

class _OnlineStatus extends StatelessWidget {
  const _OnlineStatus();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityService.instance.online,
      builder: (context, online, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: online ? const Color(0xFF4ADE80) : AppColors.error,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              online ? 'Online' : 'Offline',
              style: TextStyle(
                fontSize: 10,
                color: online ? const Color(0xFF888888) : AppColors.error,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CategoryNav extends StatelessWidget {
  const _CategoryNav();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PosBloc, PosState>(
      builder: (context, state) {
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 10),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                'KATEGORI',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFFBBBBBB),
                  letterSpacing: 0.5,
                ),
              ),
            ),
            _CategoryVTile(
              label: 'Semua',
              selected: state.selectedCategoryId == null,
              onTap: () =>
                  context.read<PosBloc>().add(PosCategorySelected(null)),
            ),
            ...state.sortedCategories.map(
              (cat) => _CategoryVTile(
                label: cat.name,
                selected: state.selectedCategoryId == cat.id,
                onTap: () =>
                    context.read<PosBloc>().add(PosCategorySelected(cat.id)),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SidebarFooter extends StatelessWidget {
  const _SidebarFooter();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    final profile = auth is AuthAuthenticated ? auth.profile : null;
    final kasirName = profile?.fullName ?? 'Kasir';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEFEFEF), width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'KASIR AKTIF',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w500,
              color: Color(0xFFBBBBBB),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            kasirName,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Color(0xFF111111),
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// MENU AREA (Expanded)
// ──────────────────────────────────────────────────────────────────────────────

class _MenuArea extends StatelessWidget {
  const _MenuArea();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        _MenuTopbar(),
        Expanded(child: _MenuGrid()),
      ],
    );
  }
}

class _MenuTopbar extends StatelessWidget {
  const _MenuTopbar();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    final outletId = auth is AuthAuthenticated
        ? (auth.profile.outletId ?? '')
        : '';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(color: Color(0xFFEFEFEF), width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _SearchBar(
              onChanged: (q) =>
                  context.read<PosBloc>().add(PosSearchChanged(q)),
            ),
          ),
          const SizedBox(width: 10),
          _OrderListButton(outletId: outletId),
        ],
      ),
    );
  }
}

// Tombol "Daftar Order" dengan badge aktif order (realtime Supabase)
class _OrderListButton extends StatefulWidget {
  final String outletId;
  const _OrderListButton({required this.outletId});

  @override
  State<_OrderListButton> createState() => _OrderListButtonState();
}

class _OrderListButtonState extends State<_OrderListButton> {
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
    if (widget.outletId.isEmpty) return _btn(context, 0);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _stream,
      builder: (context, snap) {
        final count = (snap.data ?? [])
            .where((r) => _active.contains(r['status']))
            .length;
        return _btn(context, count);
      },
    );
  }

  Widget _btn(BuildContext context, int count) {
    return GestureDetector(
      onTap: () => context.go('/kasir/orders'),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E5E5), width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.receipt_long_outlined,
              size: 16,
              color: Color(0xFF555555),
            ),
            const SizedBox(width: 6),
            const Text(
              'Daftar Order',
              style: TextStyle(fontSize: 12, color: Color(0xFF555555)),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFF0F766E),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MenuGrid extends StatelessWidget {
  final bool compact;
  const _MenuGrid({this.compact = false});

  void _onItemTap(BuildContext context, MenuItem item) {
    // Selalu buka modal agar tiap produk bisa atur qty + catatan (+ varian/extra).
    _showAddonModal(context, item);
  }

  Future<void> _showAddonModal(BuildContext context, MenuItem item) async {
    final bloc = context.read<PosBloc>();
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<_AddonResult>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: _AddonModal(item: item),
        ),
      ),
    );
    if (result == null) return;
    bloc.add(
      PosItemAdded(
        item,
        variant: result.variant,
        selectedExtras: result.extras,
        quantity: result.qty,
        notes: result.notes,
        overriddenPrice: result.overriddenPrice,
      ),
    );
    messenger.showSnackBar(
      SnackBar(
        content: const Text(
          'Item ditambahkan ke pesanan',
          style: TextStyle(color: Colors.white, fontSize: 12),
        ),
        backgroundColor: const Color(0xFF111111),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PosBloc, PosState>(
      builder: (context, state) {
        if (state.menuLoading) return const MenuGridSkeleton();
        if (state.menuError != null) {
          return AppErrorView(
            message: state.menuError!,
            onRetry: () {
              final a = context.read<AuthBloc>().state;
              final outletId = a is AuthAuthenticated
                  ? a.profile.outletId ?? ''
                  : '';
              context.read<PosBloc>().add(PosMenuLoadRequested(outletId));
            },
          );
        }
        if (state.filteredMenu.isEmpty) {
          return const AppEmptyState(
            icon: Icons.restaurant_menu,
            title: 'Tidak ada menu',
            subtitle: 'Coba ubah kategori atau kata kunci pencarian',
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) => GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: compact
                  ? 3
                  : ((constraints.maxWidth - 14) / 170).floor().clamp(1, 6),
              mainAxisExtent:
                  (compact ? 140 : 230) +
                  (MediaQuery.textScalerOf(context).scale(13) - 13).clamp(
                        0,
                        30,
                      ) *
                      5,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemCount: state.filteredMenu.length,
            itemBuilder: (context, i) {
              final item = state.filteredMenu[i];
              final qty = state.cart
                  .where((ci) => ci.menuItem.id == item.id)
                  .fold<int>(0, (sum, ci) => sum + ci.quantity);
              final cartEntries = state.cart.where(
                (ci) => ci.menuItem.id == item.id,
              );
              final cartEntry = cartEntries.isEmpty ? null : cartEntries.first;
              return MenuItemCard(
                    compact: compact,
                    item: item,
                    quantity: qty,
                    onTap: () => _onItemTap(context, item),
                    // Tombol + wajib melewati modal yang sama dengan klik kartu.
                    // Menambah langsung melewati variant/extra wajib dan baru
                    // ditolak server ketika transaksi offline disinkronkan.
                    onAdd: () => _onItemTap(context, item),
                    onRemove: () {
                      if (cartEntry == null) return;
                      if (cartEntry.requiresVoidToDecrease) {
                        showStoredItemVoidNotice(context);
                        return;
                      }
                      if (cartEntry.quantity <= 1) {
                        context.read<PosBloc>().add(
                          PosItemRemoved(cartEntry.id),
                        );
                      } else {
                        context.read<PosBloc>().add(
                          PosQuantityChanged(cartEntry.id, -1),
                        );
                      }
                    },
                  )
                  .animate()
                  .fadeIn(duration: 220.ms, delay: (30 * (i % 12)).ms)
                  .slideY(begin: 0.06, end: 0, curve: Curves.easeOut);
            },
          ),
        );
      },
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// COMPACT / MOBILE LAYOUT
// ──────────────────────────────────────────────────────────────────────────────

class _CartBottomBar extends StatelessWidget {
  const _CartBottomBar();

  void _openCart(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.9,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: context.read<PosBloc>()),
              BlocProvider.value(value: context.read<AuthBloc>()),
            ],
            child: const SafeArea(child: CartPanel()),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<PosBloc, PosState>(
      builder: (context, s) {
        if (s.cart.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: EdgeInsets.fromLTRB(
            16,
            10,
            16,
            MediaQuery.of(context).padding.bottom + 10,
          ),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${s.itemCount} item',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        CurrencyFormatter.format(s.total),
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _openCart(context),
                icon: const Icon(Icons.shopping_cart_rounded, size: 18),
                label: const Text('Lihat Pesanan'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NarrowTopBar extends StatelessWidget {
  const _NarrowTopBar();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthBloc>().state;
    final profile = auth is AuthAuthenticated ? auth.profile : null;
    final branch = (profile?.outletName?.trim().isNotEmpty ?? false)
        ? profile!.outletName!.trim()
        : 'Outlet';
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked = constraints.maxWidth < 580;
          final search = _SearchBar(
            onChanged: (q) => context.read<PosBloc>().add(PosSearchChanged(q)),
          );
          final header = Row(
            children: [
              IconButton(
                icon: const Icon(Icons.menu, color: AppColors.textPrimary),
                tooltip: 'Menu',
                onPressed: KasirShell.openMenu,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      branch,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const _OnlineStatus(),
                  ],
                ),
              ),
              if (!stacked) ...[
                const SizedBox(width: 12),
                Expanded(flex: 2, child: search),
              ],
              const SizedBox(width: 8),
              DaftarOrderButton(outletId: profile?.outletId ?? ''),
            ],
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [header, if (stacked) search],
          );
        },
      ),
    );
  }
}

class _NarrowMenuPanel extends StatelessWidget {
  const _NarrowMenuPanel();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        BlocBuilder<PosBloc, PosState>(
          builder: (context, state) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('Semua'),
                  selected: state.selectedCategoryId == null,
                  onSelected: (_) =>
                      context.read<PosBloc>().add(PosCategorySelected(null)),
                ),
                ...state.sortedCategories.map(
                  (category) => Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoiceChip(
                      label: Text(category.name),
                      selected: state.selectedCategoryId == category.id,
                      onSelected: (_) => context.read<PosBloc>().add(
                        PosCategorySelected(category.id),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const Expanded(child: _MenuGrid()),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ──────────────────────────────────────────────────────────────────────────────

class _SearchBar extends StatefulWidget {
  final ValueChanged<String> onChanged;
  const _SearchBar({required this.onChanged});

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: TextField(
        controller: _ctrl,
        onChanged: widget.onChanged,
        style: const TextStyle(fontSize: 12, color: Color(0xFF111111)),
        decoration: InputDecoration(
          hintText: 'Cari menu...',
          hintStyle: const TextStyle(color: Color(0xFFCCCCCC), fontSize: 12),
          prefixIcon: const Icon(
            Icons.search,
            size: 16,
            color: Color(0xFFBBBBBB),
          ),
          suffixIcon: _ctrl.text.isNotEmpty
              ? GestureDetector(
                  onTap: () {
                    _ctrl.clear();
                    widget.onChanged('');
                    setState(() {});
                  },
                  child: const Icon(
                    Icons.close,
                    size: 14,
                    color: Color(0xFFBBBBBB),
                  ),
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
        onTap: () => setState(() {}),
      ),
    );
  }
}

class _CategoryVTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryVTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF5F5) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color: selected ? const Color(0xFF0F766E) : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: selected ? const Color(0xFF0F766E) : const Color(0xFF666666),
            fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
            fontSize: 11,
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// MODAL ADDON (varian + extras + qty)
// ──────────────────────────────────────────────────────────────────────────────

class _AddonResult {
  final MenuItemVariant? variant;
  final List<SelectedExtra> extras;
  final int qty;
  final String? notes;
  final double? overriddenPrice;
  const _AddonResult(
    this.variant,
    this.extras,
    this.qty,
    this.notes,
    this.overriddenPrice,
  );
}

class _AddonModal extends StatefulWidget {
  final MenuItem item;
  const _AddonModal({required this.item});

  @override
  State<_AddonModal> createState() => _AddonModalState();
}

class _AddonModalState extends State<_AddonModal> {
  MenuItemVariant? _variant;
  final Map<String, Set<String>> _selections = {};
  int _qty = 1;
  final _notesCtrl = TextEditingController();
  late final TextEditingController _priceCtrl;

  @override
  void initState() {
    super.initState();
    _priceCtrl = TextEditingController(
      text: widget.item.price.round().toString(),
    );
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  List<MenuItemVariant> get _variants => widget.item.variants ?? const [];
  List<MenuExtra> get _extras => widget.item.extras ?? const [];

  double get _addonTotal {
    double t = _variant?.priceAddition ?? 0;
    for (final extra in _extras) {
      for (final id in _selections[extra.id] ?? const <String>{}) {
        t += extra.options.firstWhere((o) => o.id == id).price;
      }
    }
    return t;
  }

  double? get _overriddenPrice {
    if (!widget.item.allowPriceOverride) return null;
    return double.tryParse(_priceCtrl.text);
  }

  double get _basePrice => _overriddenPrice ?? widget.item.price;

  double? get _priceOverrideForCart {
    if (!widget.item.allowPriceOverride || _overriddenPrice == null) {
      return null;
    }
    return (_overriddenPrice! - widget.item.price).abs() > 0.01
        ? _overriddenPrice
        : null;
  }

  double get _total => (_basePrice + _addonTotal) * _qty;

  bool get _valid {
    if (widget.item.allowPriceOverride &&
        (_overriddenPrice == null || _overriddenPrice! <= 0)) {
      return false;
    }
    if (_variants.isNotEmpty && _variant == null) return false;
    for (final extra in _extras) {
      if (extra.isRequired && (_selections[extra.id]?.isEmpty ?? true)) {
        return false;
      }
    }
    return true;
  }

  void _toggleExtra(MenuExtra extra, String optId) {
    setState(() {
      final set = _selections.putIfAbsent(extra.id, () => {});
      if (extra.isSingleSelect) {
        set
          ..clear()
          ..add(optId);
      } else {
        set.contains(optId) ? set.remove(optId) : set.add(optId);
      }
    });
  }

  void _confirm() {
    final extras = <SelectedExtra>[];
    for (final extra in _extras) {
      for (final id in _selections[extra.id] ?? const <String>{}) {
        final opt = extra.options.firstWhere((o) => o.id == id);
        extras.add(
          SelectedExtra(
            menuExtraId: extra.id,
            menuExtraOptionId: opt.id,
            extraName: extra.name,
            optionName: opt.name,
            price: opt.price,
          ),
        );
      }
    }
    final note = _notesCtrl.text.trim();
    Navigator.pop(
      context,
      _AddonResult(
        _variant,
        extras,
        _qty,
        note.isEmpty ? null : note,
        _priceOverrideForCart,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _header(),
        Flexible(child: _body()),
        _footer(),
      ],
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFF0F0F0), width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.item.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111111),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${CurrencyFormatter.format(widget.item.price)} · Pilih tambahan',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF999999),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFF5F5F5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(
                Icons.close,
                size: 14,
                color: Color(0xFF888888),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final sections = <Widget>[];
    if (widget.item.allowPriceOverride) {
      sections.add(
        _section(
          label: 'Harga Jual',
          required: true,
          children: [
            TextField(
              key: const ValueKey('priceOverrideField'),
              controller: _priceCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixText: 'Rp ',
                hintText: 'Masukkan harga jual',
                helperText:
                    'Harga katalog ${CurrencyFormatter.format(widget.item.price)}',
                isDense: true,
                filled: true,
                fillColor: const Color(0xFFF5F5F5),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (_variants.isNotEmpty) {
      sections.add(
        _section(
          label: 'Varian',
          required: true,
          children: _variants
              .map(
                (v) => _AddonOption(
                  selected: _variant == v,
                  isCheckbox: false,
                  name: v.name,
                  price: v.priceAddition,
                  onTap: () => setState(() => _variant = v),
                ),
              )
              .toList(),
        ),
      );
    }
    for (final extra in _extras) {
      final set = _selections[extra.id] ?? const <String>{};
      sections.add(
        _section(
          label: extra.name,
          required: extra.isRequired,
          children: extra.options
              .map(
                (opt) => _AddonOption(
                  selected: set.contains(opt.id),
                  isCheckbox: !extra.isSingleSelect,
                  name: opt.name,
                  price: opt.price,
                  onTap: () => _toggleExtra(extra, opt.id),
                ),
              )
              .toList(),
        ),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.55,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int i = 0; i < sections.length; i++) ...[
              if (i > 0) const SizedBox(height: 14),
              sections[i],
            ],
            if (sections.isNotEmpty) const SizedBox(height: 14),
            const _SectionLabel(label: 'Catatan', required: false),
            const SizedBox(height: 8),
            TextField(
              controller: _notesCtrl,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'mis. tanpa gula, es dipisah…',
                hintStyle: const TextStyle(color: Color(0xFFAAAAAA)),
                isDense: true,
                filled: true,
                fillColor: const Color(0xFFF5F5F5),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section({
    required String label,
    required bool required,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(label: label, required: required),
        const SizedBox(height: 6),
        ...children,
      ],
    );
  }

  Widget _footer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF0F0F0), width: 0.5)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Text(
                'Jumlah',
                style: TextStyle(fontSize: 12, color: Color(0xFF666666)),
              ),
              const Spacer(),
              _qtyBtn(
                Icons.remove,
                _qty > 1 ? () => setState(() => _qty--) : null,
              ),
              Container(
                constraints: const BoxConstraints(minWidth: 20),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '$_qty',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF111111),
                  ),
                ),
              ),
              _qtyBtn(
                Icons.add,
                _qty < 99 ? () => setState(() => _qty++) : null,
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: Material(
              color: _valid ? const Color(0xFF0F766E) : const Color(0xFFD0D0D0),
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: _valid ? _confirm : null,
                borderRadius: BorderRadius.circular(8),
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Tambah ke Pesanan',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '· ${CurrencyFormatter.format(_total)}',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _qtyBtn(IconData icon, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 16, color: const Color(0xFF333333)),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final bool required;
  const _SectionLabel({required this.label, required this.required});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: Color(0xFFBBBBBB),
              letterSpacing: 0.6,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Text(
            required ? '*wajib pilih' : '(opsional)',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w400,
              color: required
                  ? const Color(0xFF0F766E)
                  : const Color(0xFFBBBBBB),
            ),
          ),
        ),
      ],
    );
  }
}

class _AddonOption extends StatelessWidget {
  final bool selected;
  final bool isCheckbox;
  final String name;
  final double price;
  final VoidCallback onTap;

  const _AddonOption({
    required this.selected,
    required this.isCheckbox,
    required this.name,
    required this.price,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFFFF5F5) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xFF0F766E) : const Color(0xFFEFEFEF),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            isCheckbox ? _checkbox() : _radio(),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  color: selected
                      ? const Color(0xFF111111)
                      : const Color(0xFF333333),
                ),
              ),
            ),
            const SizedBox(width: 8),
            price > 0
                ? Text(
                    '+${CurrencyFormatter.format(price)}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF0F766E),
                    ),
                  )
                : const Text(
                    'Gratis',
                    style: TextStyle(fontSize: 11, color: Color(0xFFBBBBBB)),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _radio() {
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? const Color(0xFF0F766E) : const Color(0xFFD0D0D0),
          width: 2,
        ),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: Color(0xFF0F766E),
                  shape: BoxShape.circle,
                ),
              ),
            )
          : null,
    );
  }

  Widget _checkbox() {
    return Container(
      width: 16,
      height: 16,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF0F766E) : Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: selected ? const Color(0xFF0F766E) : const Color(0xFFD0D0D0),
          width: 2,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, size: 10, color: Colors.white)
          : null,
    );
  }
}
