import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manages tokens and cookies equivalent to js-cookie in React
class StorageService {
  static const _storage = FlutterSecureStorage();
  // Process-lifetime SSO switch:
  // - true by default (fresh app start -> allow SSO)
  // - set false on explicit logout (skip SSO; use normal get-workflow/get-user flow)
  // - resets to true automatically when app process restarts.
  static bool _ssoAutoLoginEnabled = true;

  static const _keyAccessToken = 'access_token';
  static const _keyRefreshToken = 'refresh_token';
  static const _keyAuthSuccess = 'auth_success';
  static const _keyMessage = 'message';
  static const _keyUserStep = 'userStep';
  static const _keyUserData = 'user_data';
  static const _keyHasRunBefore = 'has_run_before';

  /// iOS Keychain (and some Android Keystore setups) entries survive app
  /// uninstall/reinstall, unlike SharedPreferences. Call this once at app
  /// startup, before any other secure-storage read, to detect a genuine
  /// fresh install via a SharedPreferences flag (which IS cleared on
  /// uninstall) and wipe stale secure-storage data left over from a
  /// previous install.
  static Future<void> resetOnFreshInstall() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_keyHasRunBefore) != true) {
      await _storage.deleteAll();
      await prefs.setBool(_keyHasRunBefore, true);
    }
  }

  static Future<String?> getAccessToken() async {
    return _storage.read(key: _keyAccessToken);
  }

  static Future<void> setAccessToken(String token) async {
    await _storage.write(key: _keyAccessToken, value: token);
  }

  static Future<String?> getRefreshToken() async {
    return _storage.read(key: _keyRefreshToken);
  }

  static Future<void> setRefreshToken(String token) async {
    await _storage.write(key: _keyRefreshToken, value: token);
  }

  static Future<void> setAuthSuccess(String value) async {
    await _storage.write(key: _keyAuthSuccess, value: value);
  }

  static Future<void> setMessage(String msg) async {
    await _storage.write(key: _keyMessage, value: msg);
  }

  static Future<void> setUserStep(String step) async {
    await _storage.write(key: _keyUserStep, value: step);
  }

  static Future<void> setUserData(String data) async {
    await _storage.write(key: _keyUserData, value: data);
  }

  static Future<void> clearAll() async {
    await _storage.deleteAll();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
  }

  static Future<void> clearAuthTokens() async {
    await _storage.delete(key: _keyAccessToken);
    await _storage.delete(key: _keyRefreshToken);
    await _storage.delete(key: _keyAuthSuccess);
  }

  static Future<bool> hasAccessToken() async {
    final token = await getAccessToken();
    return token != null && token.isNotEmpty;
  }

  static bool get ssoAutoLoginEnabled => _ssoAutoLoginEnabled;

  static void setSsoAutoLoginEnabled(bool enabled) {
    _ssoAutoLoginEnabled = enabled;
  }
}
