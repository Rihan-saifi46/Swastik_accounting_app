import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swastik_mobile_app/core/models/transaction_model.dart';
import 'package:swastik_mobile_app/core/services/transaction_service.dart';
import 'package:swastik_mobile_app/core/utils/constants.dart';
import 'package:swastik_mobile_app/core/utils/time_utils.dart';

import 'package:swastik_mobile_app/core/models/daily_closing_balance_model.dart';
import 'package:swastik_mobile_app/core/models/txn_summary_model.dart';
import 'package:swastik_mobile_app/features/auth/providers/auth_providers.dart';
import 'package:swastik_mobile_app/features/parties/providers/party_providers.dart';

final transactionServiceProvider = Provider<TransactionService>((ref) => TransactionService(ref));

final transactionsStreamProvider = StreamProvider<List<TransactionModel>>((ref) {
  return ref.watch(transactionServiceProvider).transactionsStream(AppConstants.centralDbId);
});

final partyTransactionsStreamProvider = StreamProvider.autoDispose.family<List<TransactionModel>, String>((ref, partyId) {
  return ref.watch(transactionServiceProvider).partyTransactionsStream(AppConstants.centralDbId, partyId);
});

final dailyBalancesStreamProvider = StreamProvider.autoDispose<List<DailyClosingBalanceModel>>((ref) {
  return ref.watch(transactionServiceProvider).dailyBalancesStream();
});

/// Date-scoped transaction provider for Statement screens to avoid downloading
/// the entire multi-year transaction history when a specific date window is selected.
final statementTransactionsProvider = FutureProvider.autoDispose.family<List<TransactionModel>, String>((ref, dateFilter) async {
  DateTime? from;
  DateTime? to;
  final now = TimeUtils.now;
  if (dateFilter == 'Today') {
    from = DateTime(now.year, now.month, now.day, 0, 0, 0);
    to = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
  } else if (dateFilter == 'This Week') {
    final weekAgo = now.subtract(const Duration(days: 7));
    from = DateTime(weekAgo.year, weekAgo.month, weekAgo.day, 0, 0, 0);
    to = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
  } else if (dateFilter == 'This Month') {
    from = DateTime(now.year, now.month, 1, 0, 0, 0);
    to = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
  }
  return ref.watch(transactionServiceProvider).fetchTransactions(from: from, to: to);
});

/// Just the latest closing-balance row (current running totals) for the home
/// summary cards — avoids downloading the full day-by-day history.
final latestDailyBalanceProvider = StreamProvider<DailyClosingBalanceModel?>((ref) {
  return ref.watch(transactionServiceProvider).latestDailyBalanceStream();
});

// ─────────────────────────────────────────────────────────────────────────
// Home summary totals — server-side aggregated + optimistic.
//
// The home cards (Total Cash / Online / Gold / Diamond) used to be summed on
// the device from the ENTIRE transactions collection, re-downloaded every 12s.
// This notifier instead polls the tiny `/transactions/summary` endpoint (four
// numbers) and lets a mutation push an instant [applyDelta] so the cards update
// the moment an entry is saved — the next poll/refresh reconciles authoritatively.
// ─────────────────────────────────────────────────────────────────────────
class TxnSummaryNotifier extends Notifier<AsyncValue<TxnSummary>> {
  Timer? _timer;

  @override
  AsyncValue<TxnSummary> build() {
    ref.onDispose(() => _timer?.cancel());
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 12), (_) => _poll());
    _poll(); // fetch immediately on first build
    return const AsyncValue.loading();
  }

  TransactionService get _svc => ref.read(transactionServiceProvider);

  Future<void> _poll() async {
    try {
      state = AsyncData(await _svc.fetchSummary());
    } catch (e, st) {
      // Keep showing the last good totals; only surface an error before we've
      // ever had a value. The next tick retries.
      if (state is! AsyncData) state = AsyncError(e, st);
    }
  }

  /// Pull-to-refresh and post-mutation authoritative refetch.
  Future<void> refresh() => _poll();

  /// Instant optimistic adjustment applied the moment an entry is created /
  /// edited / deleted, before the server round-trip returns. Reconciled by the
  /// next [_poll] / [refresh], which overwrites (not adds to) the totals.
  void applyDelta(TxnSummary delta) {
    final current = state.value ?? TxnSummary.zero;
    state = AsyncData(current + delta);
  }
}

final transactionSummaryProvider =
    NotifierProvider<TxnSummaryNotifier, AsyncValue<TxnSummary>>(
  TxnSummaryNotifier.new,
);

// ─────────────────────────────────────────────────────────────────────────
// Home transactions table — server-side filtered + batched loading.
//
// Instead of downloading the entire transactions collection every poll and
// filtering on the device, the home table asks the server for exactly the
// window it needs:
//   • a date filter (Today / Week / Month / Custom) → bounded `from`/`to` fetch
//   • the "All" filter → batches of [pageSize], with `loadMore()` for the next
// This is what collapses the startup payload from "whole history" to one batch.
// ─────────────────────────────────────────────────────────────────────────

/// Describes what the home table should request from the server.
/// A date range (padded by the caller; the UI trims the exact days) or, when
/// [all] is true, the full collection loaded in batches.
class HomeTxnQuery {
  final DateTime? from;
  final DateTime? to;
  final bool all;

  const HomeTxnQuery({this.from, this.to, this.all = false});

  @override
  bool operator ==(Object other) =>
      other is HomeTxnQuery &&
      other.from == from &&
      other.to == to &&
      other.all == all;

  @override
  int get hashCode => Object.hash(from, to, all);
}

/// The current window the home table is showing, plus paging flags.
class HomeTxnState {
  final List<TransactionModel> items;
  final bool isLoading; // first load for the current query
  final bool isLoadingMore; // a loadMore() batch is in flight
  final bool hasMore; // another "All" batch is available
  final Object? error;

  const HomeTxnState({
    this.items = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.error,
  });

  HomeTxnState copyWith({
    List<TransactionModel>? items,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    Object? error,
    bool clearError = false,
  }) {
    return HomeTxnState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class HomeTransactionsNotifier extends Notifier<HomeTxnState> {
  static const int pageSize = 15;

  int _skip = 0;
  Timer? _timer;
  // Null until the UI pushes the first filter (via [setQuery]); the notifier
  // stays in its loading state and fetches nothing until then, so we never
  // accidentally download the whole collection before the filter is known.
  HomeTxnQuery? _query;

  @override
  HomeTxnState build() {
    ref.onDispose(() => _timer?.cancel());
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => _refreshInPlace(),
    );
    return const HomeTxnState(isLoading: true);
  }

  TransactionService get _svc => ref.read(transactionServiceProvider);

  /// Called by the UI whenever the selected filter changes. Refetches the first
  /// window for the new query; a no-op when the query is unchanged.
  Future<void> setQuery(HomeTxnQuery query) async {
    if (query == _query) return;
    _query = query;
    _skip = 0;
    await _reload();
  }

  Future<List<TransactionModel>> _fetch({required int skip}) {
    final q = _query!;
    return _svc.fetchTransactions(
      from: q.all ? null : q.from,
      to: q.all ? null : q.to,
      limit: q.all ? pageSize : null,
      skip: q.all ? skip : null,
    );
  }

  Future<void> _reload() async {
    if (_query == null) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final list = await _fetch(skip: 0);
      _skip = list.length;
      state = HomeTxnState(
        items: list,
        isLoading: false,
        hasMore: _query!.all && list.length >= pageSize,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e);
    }
  }

  /// Loads the next batch (only meaningful for the "All" filter).
  Future<void> loadMore() async {
    final q = _query;
    if (q == null || !q.all || state.isLoadingMore || !state.hasMore) return;
    state = state.copyWith(isLoadingMore: true);
    try {
      final more = await _fetch(skip: _skip);
      final combined = [...state.items, ...more];
      _skip = combined.length;
      state = state.copyWith(
        items: combined,
        isLoadingMore: false,
        hasMore: more.length >= pageSize,
      );
    } catch (_) {
      state = state.copyWith(isLoadingMore: false);
    }
  }

  /// Pull-to-refresh: reload the current window from scratch.
  Future<void> refresh() => _reload();

  bool _inWindow(TransactionModel tx) {
    final q = _query;
    if (q == null) return false;
    if (q.all) return true;
    if (q.from != null && tx.date.isBefore(q.from!)) return false;
    if (q.to != null && tx.date.isAfter(q.to!)) return false;
    return true;
  }

  /// Instantly show a freshly created entry at the top of the visible window
  /// (if it falls inside the current filter) without waiting for the poll/refresh.
  void addOptimistic(TransactionModel tx) {
    if (!_inWindow(tx)) return;
    if (state.items.any((t) => t.id == tx.id && tx.id.isNotEmpty)) return;
    final items = [tx, ...state.items]..sort((a, b) => b.date.compareTo(a.date));
    state = state.copyWith(items: items);
  }

  /// Instantly reflect an edited entry in the visible window.
  void replaceOptimistic(TransactionModel tx) {
    if (!state.items.any((t) => t.id == tx.id)) {
      addOptimistic(tx);
      return;
    }
    final items = state.items
        .map((t) => t.id == tx.id ? tx : t)
        .where(_inWindow)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    state = state.copyWith(items: items);
  }

  /// Instantly drop a deleted entry from the visible window.
  void removeOptimistic(String id) {
    if (id.isEmpty) return;
    state = state.copyWith(
      items: state.items.where((t) => t.id != id).toList(),
    );
  }

  /// Silent poll refresh — re-fetch the currently visible window (including all
  /// already-loaded "All" batches) without disturbing scroll or paging.
  Future<void> _refreshInPlace() async {
    final q = _query;
    if (q == null) return;
    try {
      final list = await _svc.fetchTransactions(
        from: q.all ? null : q.from,
        to: q.all ? null : q.to,
        limit: q.all ? (_skip == 0 ? pageSize : _skip) : null,
        skip: q.all ? 0 : null,
      );
      if (q.all) _skip = list.length;
      state = state.copyWith(items: list, isLoading: false, clearError: true);
    } catch (_) {
      // Keep showing the last good window; the next tick retries.
    }
  }
}

final homeTransactionsProvider =
    NotifierProvider<HomeTransactionsNotifier, HomeTxnState>(
  HomeTransactionsNotifier.new,
);


class TransactionState {
  final bool isLoading;
  final String? error;
  final bool isSuccess;

  const TransactionState({
    this.isLoading = false,
    this.error,
    this.isSuccess = false,
  });

  TransactionState copyWith({
    bool? isLoading,
    String? error,
    bool? isSuccess,
    bool clearError = false,
  }) {
    return TransactionState(
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      isSuccess: isSuccess ?? this.isSuccess,
    );
  }
}

class TransactionNotifier extends Notifier<TransactionState> {
  @override
  TransactionState build() => const TransactionState();

  TransactionService get _transactionService => ref.read(transactionServiceProvider);

  /// Forces the dashboard streams to refetch immediately after a mutation so
  /// the Home/Ledger screens reflect the change without waiting for the next
  /// (up to 12s) poll cycle. Home reads `asyncValue.value`, which Riverpod
  /// preserves across the invalidate, so the list updates in place with no
  /// loading flicker.
  void _refreshDashboardStreams() {
    ref.invalidate(transactionsStreamProvider);
    ref.invalidate(dailyBalancesStreamProvider);
    ref.invalidate(latestDailyBalanceProvider);
    ref.invalidate(partiesStreamProvider);
    ref.invalidate(statementTransactionsProvider);
    // Home's table + summary cards use in-place providers — refresh them without
    // invalidating (which would drop the active filter/paging state, or the
    // optimistic totals we just applied). Each refetch reconciles authoritatively.
    ref.read(homeTransactionsProvider.notifier).refresh();
    ref.read(transactionSummaryProvider.notifier).refresh();
  }

  Future<bool> createTransaction({
    required String partyId,
    required String partyName,
    required String partyPhone,
    required TransactionType type,
    required PaymentMode paymentMode,
    required double cashAmount,
    required String metalType,
    required double metalWeight,
    required String metalPurity,
    required String notes,
    required DateTime date,
  }) async {


    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final now = TimeUtils.now;
      final transaction = TransactionModel(
        id: '', 
        partyId: partyId,
        partyName: partyName,
        partyPhone: partyPhone,
        type: type,
        paymentMode: paymentMode,
        cashAmount: cashAmount,
        metalType: metalType,
        metalWeight: metalWeight,
        metalPurity: metalPurity,
        notes: notes,
        date: date,
        createdAt: now,
        createdBy: ref.read(currentUserProfileProvider)?.name ?? 'Admin',
      );

      final saved = await _transactionService.createTransaction(transaction);
      // Optimistic: show the new row + updated totals instantly, before the
      // authoritative refresh below lands.
      ref.read(homeTransactionsProvider.notifier).addOptimistic(saved);
      ref
          .read(transactionSummaryProvider.notifier)
          .applyDelta(TxnSummary.deltaOf(saved));
      _refreshDashboardStreams();
      state = state.copyWith(isLoading: false, isSuccess: true);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<bool> updateTransaction({
    required TransactionModel oldTx,
    required TransactionModel newTx,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final updatedTx = newTx;
      final finalTx = TransactionModel(
        id: updatedTx.id,
        partyId: updatedTx.partyId,
        partyName: updatedTx.partyName,
        partyPhone: updatedTx.partyPhone,
        type: updatedTx.type,
        paymentMode: updatedTx.paymentMode,
        cashAmount: updatedTx.cashAmount,
        metalType: updatedTx.metalType,
        metalWeight: updatedTx.metalWeight,
        metalPurity: updatedTx.metalPurity,
        notes: updatedTx.notes,
        date: updatedTx.date,
        createdAt: updatedTx.createdAt,
        createdBy: updatedTx.createdBy,
        updatedBy: ref.read(currentUserProfileProvider)?.name ?? 'Admin',
        updatedAt: TimeUtils.now,
      );

      await _transactionService.updateTransaction(oldTx, finalTx);
      // Optimistic: swap old→new impact on the totals and the visible row instantly.
      ref.read(homeTransactionsProvider.notifier).replaceOptimistic(finalTx);
      ref
          .read(transactionSummaryProvider.notifier)
          .applyDelta(TxnSummary.deltaOf(finalTx) - TxnSummary.deltaOf(oldTx));
      _refreshDashboardStreams();
      state = state.copyWith(isLoading: false, isSuccess: true);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }

  Future<bool> deleteTransaction(TransactionModel transaction) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _transactionService.deleteTransaction(transaction);
      // Optimistic: remove the row + back out its impact on the totals instantly.
      ref.read(homeTransactionsProvider.notifier).removeOptimistic(transaction.id);
      ref
          .read(transactionSummaryProvider.notifier)
          .applyDelta(TxnSummary.zero - TxnSummary.deltaOf(transaction));
      _refreshDashboardStreams();
      state = state.copyWith(isLoading: false, isSuccess: true);
      return true;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return false;
    }
  }
}

final transactionNotifierProvider = NotifierProvider<TransactionNotifier, TransactionState>(TransactionNotifier.new);
