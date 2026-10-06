import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:meon_kyc/api/base_api.dart';
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/services/storage_service.dart';

class ApiInterceptor {
  static bool _isRefreshing = false;
  static bool? _lastRefreshSucceeded;
  static final List<void Function()> _onRefreshComplete = [];

  static Future<http.Response> request(
    Future<http.Response> Function() fn,
  ) async {
    var response = await fn();
    debugPrint('[ApiInterceptor] Response status: ${response.statusCode}');

    // Only 401 means auth/session — never treat validation 422 as session expiry.
    if (response.statusCode != 401) {
      return response;
    }

    debugPrint('[ApiInterceptor] 401 — attempting token refresh');

    if (_isRefreshing) {
      debugPrint('[ApiInterceptor] Refresh already in progress — waiting');
      await _waitForRefresh();
      if (_lastRefreshSucceeded == true) {
        debugPrint('[ApiInterceptor] Refresh succeeded — retrying waiter request');
        return fn();
      }
      debugPrint(
        '[ApiInterceptor] Refresh failed for waiter — returning original 401',
      );
      return response;
    }

    _isRefreshing = true;
    _lastRefreshSucceeded = null;
    try {
      final refreshed = await _refreshTokenWithRetry();
      _lastRefreshSucceeded = refreshed;
      if (refreshed) {
        debugPrint(
          '[ApiInterceptor] Refresh success — retrying original request',
        );
        response = await fn();
        debugPrint(
          '[ApiInterceptor] Retry response status: ${response.statusCode}',
        );
        if (response.statusCode == 401) {
          debugPrint(
            '[ApiInterceptor] Still 401 after refresh — clearing auth tokens',
          );
          await StorageService.clearAuthTokens();
          Fluttertoast.showToast(
            msg: 'Session expired. Please sign in again.',
            gravity: ToastGravity.TOP,
          );
        }
      } else {
        debugPrint('[ApiInterceptor] Refresh failed — clearing auth tokens');
        await StorageService.clearAuthTokens();
        Fluttertoast.showToast(
          msg: 'Session expired. Please sign in again.',
          gravity: ToastGravity.TOP,
        );
      }
    } catch (e, st) {
      debugPrint('[ApiInterceptor] Refresh exception: $e\n$st');
      _lastRefreshSucceeded = false;
      await StorageService.clearAuthTokens();
      Fluttertoast.showToast(
        msg: 'Session expired. Please sign in again.',
        gravity: ToastGravity.TOP,
      );
    } finally {
      _isRefreshing = false;
      for (final cb in List<void Function()>.from(_onRefreshComplete)) {
        cb();
      }
      _onRefreshComplete.clear();
    }
    return response;
  }

  static Future<void> _waitForRefresh() async {
    final c = Completer<void>();
    _onRefreshComplete.add(() {
      if (!c.isCompleted) c.complete();
    });
    return c.future;
  }

  /// One quick retry on network blips before giving up.
  static Future<bool> _refreshTokenWithRetry() async {
    final first = await _refreshToken();
    if (first) return true;
    debugPrint('[ApiInterceptor] Refresh failed once — retrying after 400ms');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return _refreshToken();
  }

  static Future<bool> _refreshToken() async {
    final refreshToken = await StorageService.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      debugPrint(
        '[ApiInterceptor] No refresh token in storage — cannot refresh',
      );
      return false;
    }

    final url = '${EnvConfig.baseUrl}/api/user/refresh';
    debugPrint('[ApiInterceptor] Calling refresh API: $url');
    try {
      final res = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $refreshToken',
            },
          )
          .timeout(BaseAPI.requestTimeout);

      debugPrint('[ApiInterceptor] Refresh API response: ${res.statusCode}');
      if (res.statusCode != 200 && res.statusCode != 201) {
        debugPrint(
          '[ApiInterceptor] Refresh failed: ${res.body.length > 200 ? '${res.body.substring(0, 200)}...' : res.body}',
        );
        return false;
      }

      Map<String, dynamic>? data;
      try {
        data = jsonDecode(res.body) as Map<String, dynamic>?;
      } catch (e) {
        debugPrint('[ApiInterceptor] Refresh response parse error: $e');
        return false;
      }

      final accessToken =
          data?['access_token'] as String? ?? data?['token'] as String?;
      final newRefresh =
          data?['refresh_token'] as String? ?? data?['refresh'] as String?;

      if (accessToken != null && accessToken.isNotEmpty) {
        await StorageService.setAccessToken(accessToken);
        if (newRefresh != null && newRefresh.isNotEmpty) {
          await StorageService.setRefreshToken(newRefresh);
        }
        debugPrint('[ApiInterceptor] New access token stored successfully');
        return true;
      }
      debugPrint('[ApiInterceptor] Refresh response missing access_token/token');
      return false;
    } catch (e, st) {
      debugPrint('[ApiInterceptor] Refresh network/error: $e\n$st');
      return false;
    }
  }
}
