import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../../../shared/models/shift.dart';
import '../../../../shared/models/cash_movement.dart';
import '../../../../shared/models/shift_close_report.dart';
import '../../data/datasources/shift_datasource.dart';
import '../../../../core/utils/humanize_error.dart';
import '../../../../shared/services/transaction_journal_service.dart';

// Events
abstract class ShiftEvent extends Equatable {
  @override
  List<Object?> get props => [];
}

class ShiftLoadRequested extends ShiftEvent {
  final String outletId;
  final String kasirId;
  ShiftLoadRequested(this.outletId, this.kasirId);
  @override
  List<Object?> get props => [outletId, kasirId];
}

class ShiftManagementTargetSelected extends ShiftEvent {
  final Shift shift;
  ShiftManagementTargetSelected(this.shift);

  @override
  List<Object?> get props => [shift];
}

class ShiftOpenRequested extends ShiftEvent {
  final double openingCash;
  ShiftOpenRequested(this.openingCash);
  @override
  List<Object?> get props => [openingCash];
}

class ShiftCloseRequested extends ShiftEvent {
  final double closingCash;
  final String? notes;
  ShiftCloseRequested(this.closingCash, this.notes);
  @override
  List<Object?> get props => [closingCash, notes];
}

class ShiftCloseReportDismissed extends ShiftEvent {}

class ShiftCashMovementRequested extends ShiftEvent {
  final String type; // 'in' | 'out'
  final double amount;
  final String? note;
  final String expenseCategory;
  ShiftCashMovementRequested(
    this.type,
    this.amount,
    this.note, {
    this.expenseCategory = 'operasional',
  });
  @override
  List<Object?> get props => [type, amount, note, expenseCategory];
}

class _ShiftTimerTick extends ShiftEvent {}

// States
class ShiftState extends Equatable {
  final bool loading;
  final bool submitting;
  final String? error;
  final Shift? activeShift;
  final List<Shift> recentShifts;
  final List<CashMovement> cashMovements;
  final ShiftCloseReport? closeReport;
  final String outletId;
  final String kasirId;

  /// Penanda detak timer durasi. Tanpa field yang berubah, state hasil tick
  /// identik (Equatable) → tidak pernah di-emit → durasi live beku.
  final int tick;

  const ShiftState({
    this.loading = false,
    this.submitting = false,
    this.error,
    this.activeShift,
    this.recentShifts = const [],
    this.cashMovements = const [],
    this.closeReport,
    this.outletId = '',
    this.kasirId = '',
    this.tick = 0,
  });

  /// Kas masuk − keluar (net) untuk shift aktif.
  double get cashMovementNet =>
      cashMovements.fold(0.0, (sum, m) => sum + m.signedAmount);

  ShiftState copyWith({
    bool? loading,
    bool? submitting,
    String? error,
    Shift? activeShift,
    bool clearActive = false,
    List<Shift>? recentShifts,
    List<CashMovement>? cashMovements,
    ShiftCloseReport? closeReport,
    bool clearCloseReport = false,
    String? outletId,
    String? kasirId,
    int? tick,
  }) => ShiftState(
    loading: loading ?? this.loading,
    submitting: submitting ?? this.submitting,
    error: error,
    activeShift: clearActive ? null : activeShift ?? this.activeShift,
    recentShifts: recentShifts ?? this.recentShifts,
    cashMovements: cashMovements ?? this.cashMovements,
    closeReport: clearCloseReport ? null : closeReport ?? this.closeReport,
    outletId: outletId ?? this.outletId,
    kasirId: kasirId ?? this.kasirId,
    tick: tick ?? this.tick,
  );

  @override
  List<Object?> get props => [
    loading,
    submitting,
    error,
    activeShift,
    recentShifts,
    cashMovements,
    closeReport,
    outletId,
    kasirId,
    tick,
  ];
}

// BLoC
class ShiftBloc extends Bloc<ShiftEvent, ShiftState> {
  final ShiftDatasource datasource;
  Timer? _timer;

  ShiftBloc({required this.datasource}) : super(const ShiftState()) {
    on<ShiftLoadRequested>(_onLoad);
    on<ShiftManagementTargetSelected>(_onManagementTarget);
    on<ShiftOpenRequested>(_onOpen);
    on<ShiftCloseRequested>(_onClose);
    on<ShiftCloseReportDismissed>(
      (_, emit) => emit(state.copyWith(clearCloseReport: true)),
    );
    on<ShiftCashMovementRequested>(_onCashMovement);
    on<_ShiftTimerTick>(_onTick);
  }

  Future<void> _recordAmbiguousMutation(
    String type,
    Map<String, dynamic> payload,
    Object error,
  ) async {
    final message = error.toString().toLowerCase();
    final transport =
        error is TimeoutException ||
        message.contains('socketexception') ||
        message.contains('failed to fetch') ||
        message.contains('connection reset') ||
        message.contains('connection closed') ||
        message.contains('network is unreachable');
    if (!transport) return;
    final id = 'manual-review-$type-${DateTime.now().microsecondsSinceEpoch}';
    final journal = TransactionJournalService.instance;
    await journal.enqueue(
      id: id,
      type: 'manual_review',
      payload: {'operation': type, ...payload},
    );
    await journal.markNeedsReview(id, error);
  }

  Future<void> _onCashMovement(
    ShiftCashMovementRequested event,
    Emitter<ShiftState> emit,
  ) async {
    final active = state.activeShift;
    if (active == null) return;
    emit(state.copyWith(submitting: true));
    try {
      await datasource.addCashMovement(
        shiftId: active.id,
        outletId: state.outletId,
        type: event.type,
        amount: event.amount,
        note: event.note,
        expenseCategory: event.expenseCategory,
      );
      final movements = await datasource.fetchCashMovements(active.id);
      emit(state.copyWith(submitting: false, cashMovements: movements));
    } catch (e) {
      await _recordAmbiguousMutation('cash_movement', {
        'shiftId': active.id,
        'outletId': state.outletId,
        'type': event.type,
        'amount': event.amount,
        'note': event.note,
      }, e);
      emit(state.copyWith(submitting: false, error: humanizeError(e)));
    }
  }

  Future<void> _onLoad(
    ShiftLoadRequested event,
    Emitter<ShiftState> emit,
  ) async {
    emit(
      state.copyWith(
        loading: true,
        outletId: event.outletId,
        kasirId: event.kasirId,
      ),
    );
    await _fetchAll(event.outletId, event.kasirId, emit);
    _startTimer();
  }

  Future<void> _onManagementTarget(
    ShiftManagementTargetSelected event,
    Emitter<ShiftState> emit,
  ) async {
    emit(
      state.copyWith(
        loading: true,
        activeShift: event.shift,
        outletId: event.shift.outletId,
        kasirId: event.shift.kasirId,
        cashMovements: const [],
      ),
    );
    try {
      final movements = await datasource.fetchCashMovements(event.shift.id);
      emit(
        state.copyWith(
          loading: false,
          activeShift: event.shift,
          cashMovements: movements,
        ),
      );
    } catch (error) {
      emit(
        state.copyWith(
          loading: false,
          activeShift: event.shift,
          cashMovements: const [],
          error: humanizeError(error),
        ),
      );
    }
  }

  Future<void> _onTick(_ShiftTimerTick event, Emitter<ShiftState> emit) async {
    // Naikkan tick agar state benar-benar berbeda → UI durasi live ter-rebuild.
    emit(state.copyWith(tick: state.tick + 1));
  }

  Future<void> _onOpen(
    ShiftOpenRequested event,
    Emitter<ShiftState> emit,
  ) async {
    emit(state.copyWith(submitting: true));
    try {
      final shift = await datasource.openShift(
        state.outletId,
        state.kasirId,
        event.openingCash,
      );
      emit(state.copyWith(submitting: false, activeShift: shift));
      _startTimer();
    } on ActiveShiftExistsException catch (e) {
      emit(
        state.copyWith(
          submitting: false,
          activeShift: e.shift,
          error: e.message,
        ),
      );
      _startTimer();
    } catch (e) {
      await _recordAmbiguousMutation('shift_open', {
        'outletId': state.outletId,
        'kasirId': state.kasirId,
        'openingCash': event.openingCash,
      }, e);
      emit(state.copyWith(submitting: false, error: humanizeError(e)));
    }
  }

  Future<void> _onClose(
    ShiftCloseRequested event,
    Emitter<ShiftState> emit,
  ) async {
    final active = state.activeShift;
    if (active == null) return;
    emit(state.copyWith(submitting: true));
    try {
      // expected_cash & cash_difference dihitung SERVER (RPC close_shift).
      // Dulu dihitung di sini lalu dikirim untuk ditulis apa adanya — angka
      // rekonsiliasi laci ditentukan aplikasi, dan rumusnya jadi salinan kedua
      // yang sudah terlanjur berbeda dari RPC yang dipakai owner-panel.
      // calculateExpectedCash tetap ada untuk PRATINJAU di layar tutup shift.
      final report = await datasource.closeShift(
        shiftId: active.id,
        closingCash: event.closingCash,
        notes: event.notes,
      );
      _timer?.cancel();
      // Tutup shift sudah sah ketika RPC mengembalikan laporan. Kosongkan shift
      // aktif SEBELUM memuat ulang riwayat, agar gangguan jaringan saat refresh
      // tidak membuat kasir melihat shift lama lalu mencoba menutupnya lagi.
      emit(
        state.copyWith(
          submitting: false,
          clearActive: true,
          closeReport: report,
          cashMovements: const [],
        ),
      );
      await _fetchAll(state.outletId, state.kasirId, emit);
    } catch (e) {
      await _recordAmbiguousMutation('shift_close', {
        'shiftId': active.id,
        'closingCash': event.closingCash,
        'notes': event.notes,
      }, e);
      emit(state.copyWith(submitting: false, error: humanizeError(e)));
    }
  }

  Future<void> _fetchAll(
    String outletId,
    String kasirId,
    Emitter<ShiftState> emit,
  ) async {
    try {
      final results = await Future.wait([
        datasource.fetchActiveShift(outletId, kasirId),
        datasource.fetchRecentShifts(outletId, kasirId),
      ]);
      final active = results[0] as Shift?;
      emit(
        state.copyWith(
          loading: false,
          activeShift: active,
          clearActive: active == null,
          recentShifts: results[1] as List<Shift>,
          // Kasir hanya memerlukan data shift untuk buka/tutup. Cash movement
          // dimuat khusus melalui ShiftManagementTargetSelected.
          cashMovements: const [],
        ),
      );
    } catch (e) {
      emit(state.copyWith(loading: false, error: humanizeError(e)));
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (state.activeShift != null) {
      _timer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => add(_ShiftTimerTick()),
      );
    }
  }

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
