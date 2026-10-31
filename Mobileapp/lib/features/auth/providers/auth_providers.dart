import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:swastik_mobile_app/core/utils/time_utils.dart';
import 'package:swastik_mobile_app/core/services/auth_service.dart';
import 'package:swastik_mobile_app/features/auth/models/user_profile.dart';
import 'package:swastik_mobile_app/features/auth/providers/user_profiles_provider.dart';
import 'package:swastik_mobile_app/constants/api_config.dart';
import 'package:swastik_mobile_app/core/utils/device_identity.dart';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

class CurrentUserProfileNotifier extends Notifier<UserProfileModel?> {
  @override
  UserProfileModel? build() => null;

  void setProfile(UserProfileModel? profile) {
    state = profile;
  }
}

final currentUserProfileProvider = NotifierProvider<CurrentUserProfileNotifier, UserProfileModel?>(CurrentUserProfileNotifier.new);
final isStaffProvider = Provider<bool>((ref) => ref.watch(currentUserProfileProvider) != null);

enum AuthStatus { initial, loading, unverified, verified, error }

class AuthNotifier extends Notifier<AuthStatus> {
  Timer? _logoutTimer;
  Timer? _pollingTimer;
  DateTime? _localLastApprovalTime;
  http.Client? _sseClient;

  // Watchdog tolerance: require consecutive authoritative "inactive" reads
  // before logging out, so a single blip doesn't kick an active staff session.
  int _invalidReads = 0;

  // Admin realtime (SSE) reconnection state.
  Timer? _sseReconnectTimer;
  Timer? _adminPollTimer;
  bool _adminListenersActive = false;
  int _sseRetryDelayMs = 1000;

  @override
  AuthStatus build() {
    // Start verification immediately
    Future.microtask(() => verify());
    return AuthStatus.initial;
  }

  Future<void> verify() async {
    state = AuthStatus.loading;
    try {
      final authService = ref.read(authServiceProvider);
      
      // Sync authoritative server time first
      try {
        final serverTime = await authService.getServerTime();
        if (serverTime != null) {
          final localTime = DateTime.now();
          final offset = serverTime.difference(localTime);
          TimeUtils.serverOffset = offset;
          debugPrint('[AuthNotifier] Synced with server clock. Offset: ${offset.inMilliseconds} ms');
        }
      } catch (e) {
        debugPrint('[AuthNotifier] Server time sync failed, falling back to local device clock: $e');
      }

      // Step 1: Check for saved staff session
      final prefs = await SharedPreferences.getInstance();
      final savedProfileId = prefs.getString('staff_session_profile_id');
      final savedAndroidId = prefs.getString('staff_session_android_id');
      
      if (savedProfileId != null && savedAndroidId != null && savedAndroidId == DeviceIdentity.androidId) {
        debugPrint('[AuthNotifier] Found saved staff session for profile $savedProfileId. Verifying...');
        Map<String, dynamic>? sessionData;
        bool inconclusive = false;
        // Retry a couple of times so a slow/poor connection on launch doesn't
        // look like "session invalid".
        for (int attempt = 0; attempt < 2; attempt++) {
          try {
            sessionData = await authService.verifyStaffSession(DeviceIdentity.androidId);
            inconclusive = false;
            break;
          } catch (e) {
            inconclusive = true;
            debugPrint('[AuthNotifier] verify-session inconclusive (attempt ${attempt + 1}): $e');
            await Future.delayed(Duration(milliseconds: 800 * (attempt + 1)));
          }
        }

        if (sessionData != null && sessionData['profile'] != null) {
          final profile = UserProfileModel.fromJson(
            Map<String, dynamic>.from(sessionData['profile']),
          );
          debugPrint('[AuthNotifier] Staff session restored for ${profile.name}');
          loginAsStaff(profile);
          return;
        }

        if (inconclusive) {
          // Could not reach the server. Do NOT discard the session — keep it so
          // the next launch (or the Resume button once the profile list loads)
          // can restore it without a new admin approval.
          debugPrint('[AuthNotifier] Server unreachable; keeping saved staff session for later.');
        } else {
          // Server explicitly said the session is no longer valid → safe to clear.
          debugPrint('[AuthNotifier] Saved staff session is no longer valid. Clearing...');
          await _clearSavedSession();
        }
      }

      // Step 2: Try admin device verification
      final isVerified = await authService.verifyDevice();
      state = isVerified ? AuthStatus.verified : AuthStatus.unverified;
      debugPrint('[AuthNotifier] Verification result: $state');
      
      if (isVerified) {
        _startAdminSseListener();
      }
    } catch (e) {
      debugPrint('[AuthNotifier] Verification FAILED with error: $e');
      state = AuthStatus.error;
    }
  }

  void _startAdminSseListener() {
    _adminListenersActive = true;
    _sseReconnectTimer?.cancel();
    _sseRetryDelayMs = 1000;
    _connectSse();
    _startAdminPollFallback();
  }

  void _connectSse() {
    if (!_adminListenersActive) return;
    _sseClient?.close();
    _sseClient = http.Client();

    final request = http.Request('GET', Uri.parse('${ApiConfig.baseUrl}/api/events'));

    _sseClient!.send(request).then((response) {
      // Connected: reset backoff and immediately refetch to catch anything that
      // changed while we were disconnected.
      _sseRetryDelayMs = 1000;
      debugPrint('[AuthNotifier] SSE connected.');
      ref.read(userProfilesNotifierProvider.notifier).fetchProfiles();

      response.stream.transform(utf8.decoder).listen((data) {
        if (data.contains('profiles_updated')) {
          debugPrint('[AuthNotifier] SSE received profiles_updated. Fetching profiles...');
          ref.read(userProfilesNotifierProvider.notifier).fetchProfiles();
        }
      }, onError: (err) {
        debugPrint('[AuthNotifier] SSE Error: $err');
        _scheduleSseReconnect();
      }, onDone: () {
        debugPrint('[AuthNotifier] SSE connection closed.');
        _scheduleSseReconnect();
      }, cancelOnError: true);
    }).catchError((err) {
      debugPrint('[AuthNotifier] SSE connection failed: $err');
      _scheduleSseReconnect();
    });
  }

  void _scheduleSseReconnect() {
    if (!_adminListenersActive) return;
    _sseClient?.close();
    _sseReconnectTimer?.cancel();
    final delay = Duration(milliseconds: _sseRetryDelayMs);
    debugPrint('[AuthNotifier] Reconnecting SSE in ${delay.inMilliseconds}ms');
    _sseReconnectTimer = Timer(delay, _connectSse);
    // Exponential backoff, capped at 30s.
    _sseRetryDelayMs = (_sseRetryDelayMs * 2).clamp(1000, 30000).toInt();
  }

  // Safety net: even if SSE is dead on a poor connection, refresh the admin's
  // profile/request list on a slow timer so it never goes permanently stale.
  void _startAdminPollFallback() {
    _adminPollTimer?.cancel();
    _adminPollTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      ref.read(userProfilesNotifierProvider.notifier).fetchProfiles();
    });
  }

  void _stopAdminListeners() {
    _adminListenersActive = false;
    _sseReconnectTimer?.cancel();
    _sseReconnectTimer = null;
    _adminPollTimer?.cancel();
    _adminPollTimer = null;
    _sseClient?.close();
  }

  void loginAsStaff(UserProfileModel profile) {
    ref.read(currentUserProfileProvider.notifier).setProfile(profile);
    state = AuthStatus.verified;
    _localLastApprovalTime = profile.lastApprovalTime;

    // Save session to SharedPreferences for persistence across app restarts
    _saveSession(profile);

    _logoutTimer?.cancel();
    _pollingTimer?.cancel();
    _stopAdminListeners();
    _invalidReads = 0;

    if (profile.expiresAt != null) {
      // Use server-synced time so a skewed device clock can't expire early/late.
      final diff = profile.expiresAt!.difference(TimeUtils.now);
      if (diff.isNegative) {
        logoutLocal();
        return;
      } else {
        _logoutTimer = Timer(diff, () {
          logoutLocal();
        });
      }
    }

    // Start polling the backend for session status via targeted verify-session
    // (avoids fetching all profiles and causing UI rebuilds on userProfilesNotifierProvider)
    _pollingTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      try {
        final sessionData = await ref.read(authServiceProvider).verifyStaffSession(DeviceIdentity.androidId);
        if (sessionData == null) {
          // Authoritative "inactive" response from server
          _invalidReads++;
          if (_invalidReads >= 2) {
            debugPrint('[AuthNotifier] Session invalidated remotely (confirmed). Logging out.');
            logoutLocal();
          }
        } else {
          _invalidReads = 0;
          final profileData = sessionData['profile'];
          if (profileData != null && profileData['lastApprovalTime'] != null && _localLastApprovalTime != null) {
            final remoteApproval = DateTime.tryParse(profileData['lastApprovalTime'].toString());
            if (remoteApproval != null && remoteApproval.isAfter(_localLastApprovalTime!)) {
              debugPrint('[AuthNotifier] New device approved. Logging out old device.');
              logoutLocal();
            }
          }
        }
      } catch (e) {
        // Inconclusive network error / blip: do not increment _invalidReads
        debugPrint('[AuthNotifier] Staff session check inconclusive: $e');
      }
    });
  }

  Future<bool> logout() async {
    final profile = ref.read(currentUserProfileProvider);
    if (profile == null) {
      logoutLocal();
      return true;
    }

    try {
      final result = await InternetAddress.lookup('google.com');
      if (result.isEmpty || result[0].rawAddress.isEmpty) {
        throw Exception('Offline');
      }
    } on SocketException catch (_) {
      debugPrint('[AuthNotifier] Offline, cannot logout.');
      return false; // Offline
    }

    // Online, call API
    try {
      final success = await ref.read(authServiceProvider).deauthorizeDevice(profile.id);
      if (success) {
        logoutLocal();
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[AuthNotifier] API error during logout: $e');
      return false;
    }
  }

  void logoutLocal() {
    _logoutTimer?.cancel();
    _pollingTimer?.cancel();
    _stopAdminListeners();
    _invalidReads = 0;
    ref.read(currentUserProfileProvider.notifier).setProfile(null);
    _clearSavedSession();
    state = AuthStatus.unverified;
  }

  Future<void> _saveSession(UserProfileModel profile) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('staff_session_profile_id', profile.id);
      await prefs.setString('staff_session_android_id', DeviceIdentity.androidId);
      if (profile.lastApprovalTime != null) {
        await prefs.setString('staff_session_last_approval', profile.lastApprovalTime!.toIso8601String());
      }
      debugPrint('[AuthNotifier] Staff session saved to SharedPreferences');
    } catch (e) {
      debugPrint('[AuthNotifier] Error saving session: $e');
    }
  }

  Future<void> _clearSavedSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('staff_session_profile_id');
      await prefs.remove('staff_session_android_id');
      await prefs.remove('staff_session_last_approval');
      debugPrint('[AuthNotifier] Saved staff session cleared');
    } catch (e) {
      debugPrint('[AuthNotifier] Error clearing session: $e');
    }
  }
}

final authStateProvider = NotifierProvider<AuthNotifier, AuthStatus>(AuthNotifier.new);

class DevicesNotifier extends AsyncNotifier<List<Map<String, dynamic>>> {
  @override
  Future<List<Map<String, dynamic>>> build() async {
    try {
      final devices = await ref.read(authServiceProvider).getDevices();
      return devices;
    } catch (e) {
      debugPrint('[DevicesNotifier] Error fetching devices: $e');
      return [];
    }
  }

  Future<bool> deauthorizeDevice(String id) async {
    try {
      final success = await ref.read(authServiceProvider).deauthorizeDevice(id);
      if (success) {
        final list = state.value;
        if (list != null) {
          state = AsyncValue.data(list.where((device) => device['id'].toString() != id).toList());
        }
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[DevicesNotifier] Error deauthorizing device $id: $e');
      return false;
    }
  }
}

final devicesProvider = AsyncNotifierProvider.autoDispose<DevicesNotifier, List<Map<String, dynamic>>>(DevicesNotifier.new);



