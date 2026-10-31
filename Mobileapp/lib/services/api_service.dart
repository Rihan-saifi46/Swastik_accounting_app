import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:swastik_mobile_app/constants/api_config.dart';
import 'package:swastik_mobile_app/core/utils/device_identity.dart';
import 'package:swastik_mobile_app/features/auth/providers/auth_providers.dart';

/// A centralised HTTP service that wraps every backend endpoint.
///
/// Usage:
/// ```dart
/// final api = ApiService();
/// final parties = await api.getParties();
/// ```
class ApiService {
  final Ref? _ref;
  ApiService([this._ref]);

  final String _base = ApiConfig.baseUrl;
  static const _timeout = Duration(seconds: 15);

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

  // ──────────────────────────────────────────────────────────────────────
  //  Health
  // ──────────────────────────────────────────────────────────────────────

  /// GET /api/health — check backend & database status.
  Future<Map<String, dynamic>> getHealth() async {
    final res = await http.get(Uri.parse('$_base/api/health')).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ──────────────────────────────────────────────────────────────────────
  //  Verification
  // ──────────────────────────────────────────────────────────────────────

  /// POST /api/verify — verify a device by Android ID, brand, and model.
  Future<Map<String, dynamic>> verifyDevice({
    required String androidId,
    required String brand,
    required String model,
  }) async {
    final res = await http.post(
      Uri.parse('$_base/api/verify'),
      headers: _getHeaders(),
      body: jsonEncode({
        'androidId': androidId,
        'brand': brand,
        'model': model,
      }),
    ).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ──────────────────────────────────────────────────────────────────────
  //  Parties
  // ──────────────────────────────────────────────────────────────────────

  /// GET /api/parties — fetch all parties.
  Future<List<dynamic>> getParties() async {
    final res = await http.get(Uri.parse('$_base/api/parties'), headers: _getHeaders()).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// POST /api/parties — create a new party.
  Future<Map<String, dynamic>> createParty(Map<String, dynamic> body) async {
    final res = await http.post(
      Uri.parse('$_base/api/parties'),
      headers: _getHeaders(),
      body: jsonEncode(body),
    ).timeout(_timeout);
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw ApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// PUT /api/parties/:id — update an existing party.
  Future<Map<String, dynamic>> updateParty(
    String id,
    Map<String, dynamic> body,
  ) async {
    final res = await http.put(
      Uri.parse('$_base/api/parties/$id'),
      headers: _getHeaders(),
      body: jsonEncode(body),
    ).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// DELETE /api/parties/:id — delete a party.
  Future<Map<String, dynamic>> deleteParty(String id) async {
    final res = await http.delete(Uri.parse('$_base/api/parties/$id'), headers: _getHeaders()).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ──────────────────────────────────────────────────────────────────────
  //  Transactions
  // ──────────────────────────────────────────────────────────────────────

  /// GET /api/transactions — fetch all transactions.
  Future<List<dynamic>> getTransactions() async {
    final res = await http.get(Uri.parse('$_base/api/transactions'), headers: _getHeaders()).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// POST /api/transactions — create a new transaction.
  Future<Map<String, dynamic>> createTransaction(
    Map<String, dynamic> body,
  ) async {
    final res = await http.post(
      Uri.parse('$_base/api/transactions'),
      headers: _getHeaders(),
      body: jsonEncode(body),
    ).timeout(_timeout);
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw ApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// PUT /api/transactions/:id — update an existing transaction.
  /// PATCH /api/transactions/:id/date — update ONLY the transaction date.
  Future<Map<String, dynamic>> updateTransactionDate(
    String id,
    DateTime newDate,
  ) async {
    final res = await http.patch(
      Uri.parse('$_base/api/transactions/$id/date'),
      headers: _getHeaders(),
      body: jsonEncode({'date': newDate.toUtc().toIso8601String()}),
    ).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateTransaction(
    String id,
    Map<String, dynamic> body,
  ) async {
    final res = await http.put(
      Uri.parse('$_base/api/transactions/$id'),
      headers: _getHeaders(),
      body: jsonEncode(body),
    ).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// DELETE /api/transactions/:id — delete a transaction.
  Future<Map<String, dynamic>> deleteTransaction(String id) async {
    final res = await http.delete(Uri.parse('$_base/api/transactions/$id'), headers: _getHeaders()).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ──────────────────────────────────────────────────────────────────────
  //  Reminders
  // ──────────────────────────────────────────────────────────────────────

  /// GET /api/reminders — fetch all reminders.
  Future<List<dynamic>> getReminders() async {
    final res = await http.get(Uri.parse('$_base/api/reminders'), headers: _getHeaders()).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// POST /api/reminders — create a new reminder.
  Future<Map<String, dynamic>> createReminder(
    Map<String, dynamic> body,
  ) async {
    final res = await http.post(
      Uri.parse('$_base/api/reminders'),
      headers: _getHeaders(),
      body: jsonEncode(body),
    ).timeout(_timeout);
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw ApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// PUT /api/reminders/:id — update an existing reminder.
  Future<Map<String, dynamic>> updateReminder(
    String id,
    Map<String, dynamic> body,
  ) async {
    final res = await http.put(
      Uri.parse('$_base/api/reminders/$id'),
      headers: _getHeaders(),
      body: jsonEncode(body),
    ).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// DELETE /api/reminders/:id — delete a reminder.
  Future<Map<String, dynamic>> deleteReminder(String id) async {
    final res = await http.delete(Uri.parse('$_base/api/reminders/$id'), headers: _getHeaders()).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ──────────────────────────────────────────────────────────────────────
  //  User Profiles
  // ──────────────────────────────────────────────────────────────────────

  /// GET /api/user-profiles — fetch all user profiles.
  Future<List<dynamic>> getUserProfiles() async {
    final res = await http.get(Uri.parse('$_base/api/user-profiles'), headers: _getHeaders()).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// POST /api/user-profiles — create a new user profile.
  Future<Map<String, dynamic>> createUserProfile(Map<String, dynamic> body) async {
    final res = await http.post(
      Uri.parse('$_base/api/user-profiles'),
      headers: _getHeaders(),
      body: jsonEncode(body),
    ).timeout(_timeout);
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw ApiException(res.statusCode, res.body);
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// POST /api/user-profiles/:id/request-access — send access request.
  Future<Map<String, dynamic>> requestProfileAccess(
    String id,
    Map<String, dynamic> requestBody,
  ) async {
    final res = await http.post(
      Uri.parse('$_base/api/user-profiles/$id/request-access'),
      headers: _getHeaders(),
      body: jsonEncode(requestBody),
    ).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// POST /api/user-profiles/:id/approve — approve access request.
  Future<Map<String, dynamic>> approveProfileAccess(String id) async {
    final res = await http.post(
      Uri.parse('$_base/api/user-profiles/$id/approve'),
      headers: _getHeaders(),
    ).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// POST /api/user-profiles/:id/decline — decline access request.
  Future<Map<String, dynamic>> declineProfileAccess(String id) async {
    final res = await http.post(
      Uri.parse('$_base/api/user-profiles/$id/decline'),
      headers: _getHeaders(),
    ).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// POST /api/user-profiles/verify-session — verify saved staff session
  Future<Map<String, dynamic>> verifyStaffSession(String androidId) async {
    final res = await http.post(
      Uri.parse('$_base/api/user-profiles/verify-session'),
      headers: _getHeaders(),
      body: jsonEncode({'androidId': androidId}),
    ).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ──────────────────────────────────────────────────────────────────────
  //  Daily Balances
  // ──────────────────────────────────────────────────────────────────────

  /// GET /api/daily-balances — fetch all saved daily closing balances.
  Future<List<dynamic>> getDailyBalances() async {
    final res = await http.get(Uri.parse('$_base/api/daily-balances'), headers: _getHeaders()).timeout(_timeout);
    _assertOk(res);
    return jsonDecode(res.body) as List<dynamic>;
  }

  // ──────────────────────────────────────────────────────────────────────
  //  Helpers
  // ──────────────────────────────────────────────────────────────────────

  void _assertOk(http.Response res) {
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(res.statusCode, res.body);
    }
  }
}

/// Custom exception thrown when the backend returns a non-success status code.
class ApiException implements Exception {
  final int statusCode;
  final String responseBody;

  const ApiException(this.statusCode, this.responseBody);

  @override
  String toString() =>
      'ApiException(statusCode: $statusCode, body: $responseBody)';
}
