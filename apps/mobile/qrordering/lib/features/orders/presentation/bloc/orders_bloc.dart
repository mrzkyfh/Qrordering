import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../../../shared/models/order.dart';
import '../../../../shared/models/enums.dart';
import '../../../../shared/services/kitchen_print.dart';
import '../../data/datasources/orders_datasource.dart';
import '../../../../core/utils/humanize_error.dart';

// Events
abstract class OrdersEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class OrdersLoadRequested extends OrdersEvent {
  final String outletId;
  OrdersLoadRequested(this.outletId);
  @override
  List<Object?> get props => [outletId];
}

class OrdersRefreshRequested extends OrdersEvent {}

class OrderStatusUpdateRequested extends OrdersEvent {
  final String orderId;
  final OrderStatus status;
  OrderStatusUpdateRequested(this.orderId, this.status);
  @override
  List<Object?> get props => [orderId, status];
}

class OrderSendToKitchenRequested extends OrdersEvent {
  final String orderId;
  final String outletId;
  final String? printedBy;
  OrderSendToKitchenRequested(this.orderId, this.outletId, {this.printedBy});
  @override
  List<Object?> get props => [orderId, outletId, printedBy];
}

class OrderVoidRequested extends OrdersEvent {
  final String orderId;
  final String? reason;
  final String approverPin;
  final String? approverId;
  OrderVoidRequested(
    this.orderId, {
    this.reason,
    required this.approverPin,
    this.approverId,
  });
  @override
  List<Object?> get props => [orderId, reason, approverPin, approverId];
}

class OrderRefundRequested extends OrdersEvent {
  final String orderId;
  final String? reason;
  final String approverPin;
  final String? approverId;
  OrderRefundRequested(
    this.orderId, {
    this.reason,
    required this.approverPin,
    this.approverId,
  });
  @override
  List<Object?> get props => [orderId, reason, approverPin, approverId];
}

class _OrdersRealtimeUpdated extends OrdersEvent {
  final String outletId;
  final List<Map<String, dynamic>> rows;

  _OrdersRealtimeUpdated(this.outletId, this.rows);

  @override
  List<Object?> get props => [outletId, rows];
}

// States
class OrdersState extends Equatable {
  final bool loading;
  final String? error;
  final List<Order> activeOrders;
  final List<Order> completedOrders;
  final String outletId;

  const OrdersState({
    this.loading = false,
    this.error,
    this.activeOrders = const [],
    this.completedOrders = const [],
    this.outletId = '',
  });

  OrdersState copyWith({
    bool? loading,
    String? error,
    List<Order>? activeOrders,
    List<Order>? completedOrders,
    String? outletId,
    bool clearError = false,
  }) => OrdersState(
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
    activeOrders: activeOrders ?? this.activeOrders,
    completedOrders: completedOrders ?? this.completedOrders,
    outletId: outletId ?? this.outletId,
  );

  @override
  List<Object?> get props => [
    loading,
    error,
    activeOrders,
    completedOrders,
    outletId,
  ];
}

// BLoC
class OrdersBloc extends Bloc<OrdersEvent, OrdersState> {
  final OrdersDatasource datasource;
  final Future<KitchenPrintResult> Function(
    String orderId,
    String outletId,
    String? printedBy,
  )
  _printKitchenOrder;
  StreamSubscription? _realtimeSub;
  Timer? _debounceTimer;
  bool _closing = false;
  int _loadEpoch = 0;

  OrdersBloc({
    required this.datasource,
    Future<KitchenPrintResult> Function(
      String orderId,
      String outletId,
      String? printedBy,
    )?
    printKitchenOrder,
  }) : _printKitchenOrder =
           printKitchenOrder ??
           ((orderId, outletId, printedBy) => printKitchenTicketsForOrder(
             orderId: orderId,
             outletId: outletId,
             trigger: KitchenTrigger.order,
             printedBy: printedBy,
             skipIfAlreadyPrinted: true,
             claimBeforePrint: true,
           )),
       super(const OrdersState()) {
    on<OrdersLoadRequested>(_onLoad);
    on<OrdersRefreshRequested>(_onRefresh);
    on<OrderStatusUpdateRequested>(_onStatusUpdate);
    on<OrderSendToKitchenRequested>(_onSendToKitchen);
    on<OrderVoidRequested>(_onVoid);
    on<OrderRefundRequested>(_onRefund);
    on<_OrdersRealtimeUpdated>(_onRealtimeUpdate);
  }

  Future<void> _onLoad(
    OrdersLoadRequested event,
    Emitter<OrdersState> emit,
  ) async {
    final epoch = ++_loadEpoch;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    final previous = _realtimeSub;
    _realtimeSub = null;
    await previous?.cancel();
    if (!_canContinue(emit) || epoch != _loadEpoch) return;

    emit(
      state.copyWith(
        loading: true,
        outletId: event.outletId,
        activeOrders: const [],
        completedOrders: const [],
        clearError: true,
      ),
    );
    await _fetchAll(event.outletId, emit, expectedEpoch: epoch);
    if (!_isCurrent(event.outletId, epoch, emit)) return;
    await _subscribeRealtime(event.outletId, epoch);
  }

  Future<void> _onRefresh(
    OrdersRefreshRequested event,
    Emitter<OrdersState> emit,
  ) async {
    await _fetchAll(state.outletId, emit);
  }

  Future<void> _onRealtimeUpdate(
    _OrdersRealtimeUpdated event,
    Emitter<OrdersState> emit,
  ) async {
    if (event.outletId != state.outletId) return;
    final impact = _realtimeImpact(event.rows);
    if (impact == _RealtimeImpact.none) return;
    if (impact == _RealtimeImpact.activeOnly) {
      await _fetchActiveOnly(state.outletId, emit);
      return;
    }
    await _fetchAll(state.outletId, emit);
  }

  Future<void> _onStatusUpdate(
    OrderStatusUpdateRequested event,
    Emitter<OrdersState> emit,
  ) async {
    try {
      await datasource.updateOrderStatus(event.orderId, event.status);
      await _fetchAll(state.outletId, emit);
    } catch (e) {
      if (_canContinue(emit)) {
        emit(state.copyWith(error: humanizeError(e)));
      }
    }
  }

  Future<void> _onSendToKitchen(
    OrderSendToKitchenRequested event,
    Emitter<OrdersState> emit,
  ) async {
    try {
      // Status harus berhasil disimpan sebelum tiket dibuat. Dengan urutan ini,
      // dapur tidak menerima tiket dari pesanan yang gagal dikonfirmasi.
      await datasource.updateOrderStatus(event.orderId, OrderStatus.confirmed);
      final printResult = await _printKitchenOrder(
        event.orderId,
        event.outletId,
        event.printedBy,
      );
      await _fetchAll(state.outletId, emit);
      if (printResult.wasSkipped && _canContinue(emit)) {
        emit(
          state.copyWith(
            error:
                printResult.skippedReason ??
                'Tiket dapur belum berhasil diproses',
          ),
        );
      }
    } catch (e) {
      if (_canContinue(emit)) {
        emit(state.copyWith(error: humanizeError(e)));
      }
    }
  }

  Future<void> _onVoid(
    OrderVoidRequested event,
    Emitter<OrdersState> emit,
  ) async {
    try {
      await datasource.voidOrder(
        event.orderId,
        reason: event.reason,
        approverPin: event.approverPin,
        approverId: event.approverId,
      );
      await _fetchAll(state.outletId, emit);
    } catch (e) {
      if (_canContinue(emit)) {
        emit(state.copyWith(error: humanizeError(e)));
      }
    }
  }

  Future<void> _onRefund(
    OrderRefundRequested event,
    Emitter<OrdersState> emit,
  ) async {
    try {
      await datasource.refundOrder(
        event.orderId,
        reason: event.reason,
        approverPin: event.approverPin,
        approverId: event.approverId,
      );
      await _fetchAll(state.outletId, emit);
    } catch (e) {
      if (_canContinue(emit)) {
        emit(state.copyWith(error: humanizeError(e)));
      }
    }
  }

  Future<void> _fetchAll(
    String outletId,
    Emitter<OrdersState> emit, {
    int? expectedEpoch,
  }) async {
    try {
      final results = await Future.wait([
        datasource.fetchActiveOrders(outletId),
        datasource.fetchCompletedOrders(outletId),
      ]);
      if (_isCurrent(outletId, expectedEpoch, emit)) {
        emit(
          state.copyWith(
            loading: false,
            activeOrders: results[0],
            completedOrders: results[1]
                .where((order) => order.status != OrderStatus.void_)
                .toList(),
            clearError: true,
          ),
        );
      }
    } catch (e) {
      if (_isCurrent(outletId, expectedEpoch, emit)) {
        emit(state.copyWith(loading: false, error: humanizeError(e)));
      }
    }
  }

  Future<void> _fetchActiveOnly(
    String outletId,
    Emitter<OrdersState> emit,
  ) async {
    try {
      final active = await datasource.fetchActiveOrders(outletId);
      if (_isCurrent(outletId, null, emit)) {
        emit(state.copyWith(activeOrders: active, clearError: true));
      }
    } catch (e) {
      if (_canContinue(emit)) {
        emit(state.copyWith(error: humanizeError(e)));
      }
    }
  }

  _RealtimeImpact _realtimeImpact(List<Map<String, dynamic>> rows) {
    final known = <String, Order>{
      for (final order in state.activeOrders) order.id: order,
      for (final order in state.completedOrders) order.id: order,
    };
    var impact = _RealtimeImpact.none;
    for (final row in rows) {
      final id = row['id'] as String?;
      final status = row['status'] as String?;
      if (id == null || status == null) continue;

      final current = known[id];
      final isActive = _activeRealtimeStatuses.contains(status);
      final isCompletedToday =
          _completedRealtimeStatuses.contains(status) &&
          _isToday(row['created_at']);

      // Snapshot bersama juga berisi histori terbaru. Baris lama yang memang
      // tidak ada pada layar Daftar Order tidak perlu memicu query.
      if (current == null && !isActive && !isCompletedToday) continue;

      final updatedAt = DateTime.tryParse(row['updated_at'] as String? ?? '');
      final unchanged =
          current != null &&
          current.status.value == status &&
          updatedAt != null &&
          current.updatedAt.toUtc() == updatedAt.toUtc();
      if (unchanged) continue;

      // Order final perlu memuat kedua daftar: hapus dari aktif dan tambahkan
      // ke selesai. Perubahan order aktif cukup mengambil daftar aktif saja.
      if (!isActive || isCompletedToday) return _RealtimeImpact.all;
      impact = _RealtimeImpact.activeOnly;
    }
    return impact;
  }

  bool _isToday(Object? rawDate) {
    final parsed = DateTime.tryParse(rawDate as String? ?? '')?.toLocal();
    if (parsed == null) return false;
    final now = DateTime.now();
    return parsed.year == now.year &&
        parsed.month == now.month &&
        parsed.day == now.day;
  }

  bool _canContinue(Emitter<OrdersState> emit) =>
      !_closing && !isClosed && !emit.isDone;

  bool _isCurrent(
    String outletId,
    int? expectedEpoch,
    Emitter<OrdersState> emit,
  ) =>
      _canContinue(emit) &&
      state.outletId == outletId &&
      (expectedEpoch == null || expectedEpoch == _loadEpoch);

  Future<void> _subscribeRealtime(String outletId, int epoch) async {
    final previous = _realtimeSub;
    _realtimeSub = null;
    await previous?.cancel();
    if (_closing || isClosed || epoch != _loadEpoch) return;

    _realtimeSub = datasource.watchOrders(outletId).listen((rows) {
      if (_closing ||
          isClosed ||
          epoch != _loadEpoch ||
          state.outletId != outletId) {
        return;
      }
      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 500), () {
        if (_closing ||
            isClosed ||
            epoch != _loadEpoch ||
            state.outletId != outletId) {
          return;
        }
        add(_OrdersRealtimeUpdated(outletId, rows));
      });
    });
  }

  @override
  Future<void> close() async {
    _closing = true;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    final realtimeSub = _realtimeSub;
    _realtimeSub = null;
    await realtimeSub?.cancel();
    await super.close();
  }
}

enum _RealtimeImpact { none, activeOnly, all }

const _activeRealtimeStatuses = {
  'draft',
  'confirmed',
  'preparing',
  'ready',
  'served',
};

const _completedRealtimeStatuses = {'paid', 'cancelled'};
