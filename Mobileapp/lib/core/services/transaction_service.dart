import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/transaction_model.dart';
import '../models/daily_closing_balance_model.dart';
import '../models/txn_summary_model.dart';
import 'package:swastik_mobile_app/core/utils/device_identity.dart';
import 'package:swastik_mobile_app/features/auth/providers/auth_providers.dart';
import 'package:swastik_mobile_app/core/utils/constants.dart';

class TransactionService {
  final Ref? _ref;
  TransactionService([this._ref]);

  final String baseUrl = AppConstants.baseUrl;

  Map<String, String> _getHeaders() {
    final headers = {
      'Content-Type': 'application/json',
      'x-android-id': DeviceIdentity.androidId,
      'x-device-brand': DeviceIdentity.brand,
      'x-device-model': DeviceIdentity.model,
    };
    if (_ref != null) {
      final staffProfile = _ref.read(currentUserProfileProvider);
      if (staffProfile != null) {
        headers['x-staff-id'] = staffProfile.id;
      }
    }
    return headers;
  }

  /// Creates the transaction and returns the persisted model (with its
  /// server-assigned `_id`) so callers can optimistically drop the row into the
  /// visible list without waiting for the next poll.
  Future<TransactionModel> createTransaction(TransactionModel transaction) async {
    // The server applies the party-balance impact atomically ($inc) when the
    // transaction is created, so the client only needs to POST the transaction.
    final response = await http.post(
      Uri.parse('$baseUrl/transactions'),
      headers: _getHeaders(),
      body: jsonEncode(transaction.toMap()),
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to create transaction');
    }
    final map = jsonDecode(response.body) as Map<String, dynamic>;
    return TransactionModel.fromMap(map['_id']?.toString() ?? '', map);
  }

  /// Fetches just the four running totals for the home summary cards — a tiny
  /// aggregation on the server instead of downloading the whole collection to
  /// sum them on the device. Optional [from]/[to] scopes the totals to a window.
  Future<TxnSummary> fetchSummary({DateTime? from, DateTime? to}) async {
    final params = <String, String>{};
    if (from != null) params['from'] = from.toUtc().toIso8601String();
    if (to != null) params['to'] = to.toUtc().toIso8601String();

    final uri = Uri.parse('$baseUrl/transactions/summary')
        .replace(queryParameters: params.isEmpty ? null : params);

    final res = await http
        .get(uri, headers: _getHeaders())
        .timeout(const Duration(seconds: 10));

    if (res.statusCode != 200) {
      throw Exception('Failed to load summary (${res.statusCode})');
    }
    return TxnSummary.fromMap(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<void> deleteTransaction(TransactionModel transaction) async {
    // The server reverses the party-balance impact atomically ($inc) when the
    // transaction is deleted, so the client only needs to DELETE it.
    final response = await http.delete(
      Uri.parse('$baseUrl/transactions/${transaction.id}'),
      headers: _getHeaders(),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to delete transaction');
    }
  }

  Future<void> updateTransaction(TransactionModel oldTx, TransactionModel newTx) async {
    // The server reverses the old impact and applies the new one atomically
    // ($inc) when the transaction is updated, so the client only needs to PUT it.
    final response = await http.put(
      Uri.parse('$baseUrl/transactions/${newTx.id}'),
      headers: _getHeaders(),
      body: jsonEncode(newTx.toMap()),
    ).timeout(const Duration(seconds: 30));

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to update transaction');
    }
  }

  /// Fetches a filtered / paginated batch of transactions from the server.
  ///
  /// Every argument is optional. With no arguments this returns the full
  /// collection (newest first), matching the legacy behaviour. Providing
  /// [from]/[to] scopes to a date window, [partyId] to one party, and
  /// [limit]/[skip] pulls a single batch for infinite-scroll style loading.
  ///
  /// Dates are serialised exactly like [TransactionModel.toMap] (UTC ISO of the
  /// app's internal time space) so the bounds line up with the stored `date`
  /// field regardless of the device timezone.
  Future<List<TransactionModel>> fetchTransactions({
    String? partyId,
    DateTime? from,
    DateTime? to,
    int? limit,
    int? skip,
  }) async {
    final params = <String, String>{};
    if (partyId != null && partyId.isNotEmpty) params['partyId'] = partyId;
    if (from != null) params['from'] = from.toUtc().toIso8601String();
    if (to != null) params['to'] = to.toUtc().toIso8601String();
    if (limit != null) params['limit'] = '$limit';
    if (skip != null) params['skip'] = '$skip';

    final uri = Uri.parse('$baseUrl/transactions')
        .replace(queryParameters: params.isEmpty ? null : params);

    final res = await http
        .get(uri, headers: _getHeaders())
        .timeout(const Duration(seconds: 15));

    if (res.statusCode != 200) {
      throw Exception('Failed to load transactions (${res.statusCode})');
    }
    final List data = jsonDecode(res.body);
    final list = data
        .map((e) =>
            TransactionModel.fromMap(e['_id'], e as Map<String, dynamic>))
        .toList();
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  Stream<List<TransactionModel>> transactionsStream(String userId) {
    late StreamController<List<TransactionModel>> controller;
    Timer? timer;

    Future<void> poll() async {
      try {
        final res = await http.get(
          Uri.parse('$baseUrl/transactions'),
          headers: _getHeaders(),
        ).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200 && !controller.isClosed) {
          final List data = jsonDecode(res.body);
          final list = data.map((e) => TransactionModel.fromMap(e['_id'], e as Map<String, dynamic>)).toList();
          list.sort((a, b) => b.date.compareTo(a.date));
          controller.add(list);
        }
      } catch (_) {
        // Keep the polling stream alive; the next cycle will retry.
      }
    }

    controller = StreamController<List<TransactionModel>>(
      onListen: () {
        poll();
        timer = Timer.periodic(const Duration(seconds: 12), (_) => poll());
      },
      onCancel: () {
        timer?.cancel();
        controller.close();
      },
    );

    return controller.stream;
  }

  Stream<List<TransactionModel>> partyTransactionsStream(String userId, String partyId) {
    // Filter by partyId on the server (uses the {partyId, date} index) instead of
    // downloading every transaction and filtering on the device each cycle.
    late StreamController<List<TransactionModel>> controller;
    Timer? timer;

    Future<void> poll() async {
      try {
        final list = await fetchTransactions(partyId: partyId);
        if (!controller.isClosed) {
          controller.add(list);
        }
      } catch (_) {
        // Keep the polling stream alive; the next cycle will retry.
      }
    }

    controller = StreamController<List<TransactionModel>>(
      onListen: () {
        poll();
        timer = Timer.periodic(const Duration(seconds: 12), (_) => poll());
      },
      onCancel: () {
        timer?.cancel();
        controller.close();
      },
    );

    return controller.stream;
  }

  /// Polls just the latest closing-balance row (current running totals) for the
  /// home summary cards — a single tiny document instead of the whole history.
  Stream<DailyClosingBalanceModel?> latestDailyBalanceStream() {
    late StreamController<DailyClosingBalanceModel?> controller;
    Timer? timer;

    Future<void> poll() async {
      try {
        final res = await http
            .get(
              Uri.parse('$baseUrl/daily-balances/latest'),
              headers: _getHeaders(),
            )
            .timeout(const Duration(seconds: 10));
        if (res.statusCode == 200 && !controller.isClosed) {
          final dynamic data = jsonDecode(res.body);
          controller.add(data == null
              ? null
              : DailyClosingBalanceModel.fromMap(data as Map<String, dynamic>));
        }
      } catch (_) {
        // Keep the polling stream alive; the next cycle will retry.
      }
    }

    controller = StreamController<DailyClosingBalanceModel?>(
      onListen: () {
        poll();
        timer = Timer.periodic(const Duration(seconds: 12), (_) => poll());
      },
      onCancel: () {
        timer?.cancel();
        controller.close();
      },
    );

    return controller.stream;
  }

  Stream<List<DailyClosingBalanceModel>> dailyBalancesStream() {
    late StreamController<List<DailyClosingBalanceModel>> controller;
    Timer? timer;

    Future<void> poll() async {
      try {
        final res = await http.get(
          Uri.parse('$baseUrl/daily-balances'),
          headers: _getHeaders(),
        ).timeout(const Duration(seconds: 10));
        if (res.statusCode == 200 && !controller.isClosed) {
          final List data = jsonDecode(res.body);
          final list = data.map((e) => DailyClosingBalanceModel.fromMap(e as Map<String, dynamic>)).toList();
          controller.add(list);
        }
      } catch (_) {
        // Keep the polling stream alive; the next cycle will retry.
      }
    }

    controller = StreamController<List<DailyClosingBalanceModel>>(
      onListen: () {
        poll();
        timer = Timer.periodic(const Duration(seconds: 12), (_) => poll());
      },
      onCancel: () {
        timer?.cancel();
        controller.close();
      },
    );

    return controller.stream;
  }
}
