import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swastik_mobile_app/constants/api_config.dart';
import 'package:swastik_mobile_app/features/ledger/providers/transaction_providers.dart';
import 'package:swastik_mobile_app/features/parties/providers/party_providers.dart';

/// Keeps the dashboard data (transactions, daily closing balances, party
/// balances) live across every device by listening to the backend's
/// Server-Sent Events stream (`/api/events`).
///
/// When any device creates/edits/deletes a transaction or party, the server
/// pushes an event and every other device refetches within a single network
/// round-trip — instead of waiting for the streams' (up to 12s) polling cycle.
/// An exponential-backoff reconnect and a 45s poll fallback keep it robust on
/// poor mobile connections, mirroring the admin profile SSE listener in
/// `AuthNotifier`.
class RealtimeSyncNotifier extends Notifier<void> {
  http.Client? _client;
  Timer? _reconnectTimer;
  Timer? _pollTimer;
  bool _active = false;
  int _retryDelayMs = 1000;
  DateTime _lastRefreshTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPartiesRefreshTime = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void build() {
    ref.onDispose(stop);
  }

  /// Begin listening. Idempotent — safe to call more than once.
  void start() {
    if (_active) return;
    _active = true;
    _retryDelayMs = 1000;
    _connect();
    _startPollFallback();
  }

  /// Force a fresh connection — used when the app resumes from the background,
  /// where the OS may have silently killed the socket while we were away.
  void reconnect() {
    if (!_active) {
      start();
      return;
    }
    _reconnectTimer?.cancel();
    _connect();
  }

  void stop() {
    _active = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _client?.close();
    _client = null;
  }

  void _connect() {
    if (!_active) return;
    _client?.close();
    _client = http.Client();

    final request =
        http.Request('GET', Uri.parse('${ApiConfig.baseUrl}/api/events'));

    _client!.send(request).then((response) {
      // Connected: reset backoff and immediately refetch to catch anything that
      // changed while we were disconnected.
      _retryDelayMs = 1000;
      debugPrint('[RealtimeSync] SSE connected.');
      _refreshDashboard();

      response.stream.transform(utf8.decoder).listen((data) {
        if (data.contains('transactions_updated')) {
          debugPrint('[RealtimeSync] transactions_updated received.');
          _refreshDashboard();
        } else if (data.contains('parties_updated')) {
          debugPrint('[RealtimeSync] parties_updated received.');
          final now = DateTime.now();
          if (now.difference(_lastPartiesRefreshTime).inMilliseconds >= 1500) {
            _lastPartiesRefreshTime = now;
            ref.invalidate(partiesStreamProvider);
          }
        }
      }, onError: (err) {
        debugPrint('[RealtimeSync] SSE error: $err');
        _scheduleReconnect();
      }, onDone: () {
        debugPrint('[RealtimeSync] SSE connection closed.');
        _scheduleReconnect();
      }, cancelOnError: true);
    }).catchError((err) {
      debugPrint('[RealtimeSync] SSE connection failed: $err');
      _scheduleReconnect();
    });
  }

  void _scheduleReconnect() {
    if (!_active) return;
    _client?.close();
    _reconnectTimer?.cancel();
    final delay = Duration(milliseconds: _retryDelayMs);
    debugPrint('[RealtimeSync] Reconnecting SSE in ${delay.inMilliseconds}ms');
    _reconnectTimer = Timer(delay, _connect);
    // Exponential backoff, capped at 30s.
    _retryDelayMs = (_retryDelayMs * 2).clamp(1000, 30000).toInt();
  }

  void _startPollFallback() {
    _pollTimer?.cancel();
    // Safety net: even if SSE is dead on a poor connection, guarantee the
    // dashboard never goes permanently stale.
    _pollTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      _refreshDashboard();
    });
  }

  void _refreshDashboard() {
    final now = DateTime.now();
    // Coalesce / debounce rapid bursts from SSE and reconnect:
    // If a refresh was already dispatched in the last 1500ms, skip duplicate storm.
    if (now.difference(_lastRefreshTime).inMilliseconds < 1500) {
      debugPrint('[RealtimeSync] Skipping duplicate refresh (coalesced within 1500ms).');
      return;
    }
    _lastRefreshTime = now;

    // A transaction affects the ledger, the day's closing balances, and the
    // involved party's running balance — refresh all three. Home reads
    // `asyncValue.value`, which Riverpod preserves across an invalidate, so the
    // UI updates in place with no loading flicker.
    ref.invalidate(dailyBalancesStreamProvider);
    ref.invalidate(partiesStreamProvider);
    ref.invalidate(statementTransactionsProvider);
    // Home's table + summary totals are in-place providers (not invalidated, to
    // preserve filter/paging and avoid flicker) — refresh them so a transaction
    // made on another device shows up on this device's home immediately.
    ref.read(homeTransactionsProvider.notifier).refresh();
    ref.read(transactionSummaryProvider.notifier).refresh();
  }
}

final realtimeSyncProvider =
    NotifierProvider<RealtimeSyncNotifier, void>(RealtimeSyncNotifier.new);
