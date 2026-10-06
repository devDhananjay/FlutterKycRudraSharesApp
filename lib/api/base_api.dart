import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/services/storage_service.dart';

class BaseAPI {
  static final BaseAPI _instance = BaseAPI._internal();
  factory BaseAPI() => _instance;

  BaseAPI._internal();

  /// Default timeout for KYC API calls (`get-context`, `kyc-post-v2`, etc.).
  static const Duration requestTimeout = Duration(seconds: 600);

  String get _baseUrl => EnvConfig.baseUrl;

  /// Reads [csrf] from JWT payload when present (e.g. Flask-JWT-Extended).
  /// Used by [ApiClient] multipart requests; same header as JSON calls.
  static String? csrfFromJwtAccessToken(String token) => _csrfFromAccessToken(token);

  static Map<String, dynamic>? _jwtPayloadMap(String token) {
    final firstDot = token.indexOf('.');
    final secondDot = token.indexOf('.', firstDot + 1);
    if (firstDot <= 0 || secondDot <= firstDot) return null;
    final segment = token.substring(firstDot + 1, secondDot);
    final pad = (4 - (segment.length % 4)) % 4;
    final padded = segment + ('=' * pad);
    try {
      final jsonStr = utf8.decode(base64Url.decode(padded));
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  static String? _csrfFromAccessToken(String token) {
    final csrf = _jwtPayloadMap(token)?['csrf'];
    if (csrf == null) return null;
    final s = csrf.toString();
    return s.isEmpty ? null : s;
  }

  /// Flask session cookie — web/curl send `session_id=...`; match on mobile JSON calls.
  static String? sessionIdFromJwtAccessToken(String token) {
    final sid = _jwtPayloadMap(token)?['session_id'];
    if (sid == null) return null;
    final s = sid.toString().trim();
    return s.isEmpty ? null : s;
  }

  static void _applyBearerAndCsrf(Map<String, String> headers, String? token) {
    if (token == null || token.isEmpty) return;
    headers['Authorization'] = 'Bearer $token';
    final csrf = _csrfFromAccessToken(token);
    if (csrf != null) headers['X-CSRF-TOKEN'] = csrf;
    final sessionId = sessionIdFromJwtAccessToken(token);
    if (sessionId != null) {
      final existing = headers['Cookie']?.trim();
      final sessionCookie = 'session_id=$sessionId';
      headers['Cookie'] =
          existing == null || existing.isEmpty ? sessionCookie : '$existing; $sessionCookie';
    }
  }

  static void _log(String tag, String message, [String? extra]) {
    debugPrint('[API $tag] $message${extra != null ? '\n$extra' : ''}');
  }

  static String _truncate(String s, [int max = 600]) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}... (${s.length} chars)';
  }

  Future<http.Response> get(String path, {Map<String, String>? headers}) async {
    final url = '$_baseUrl$path';
    _log('GET', 'Request: $url');
    final token = await StorageService.getAccessToken();
    debugPrint('[API] Token: $token');
    final h = {...?headers, 'Content-Type': 'application/json'};
    _applyBearerAndCsrf(h, token);
    try {
      final res = await http
          .get(Uri.parse(url), headers: h)
          .timeout(requestTimeout);
      _log('GET', 'Response ${res.statusCode}: $url', _truncate(res.body));
      return res;
    } catch (e, st) {
      _log('GET', 'Error: $url', '$e\n$st');
      rethrow;
    }
  }

  Future<http.Response> post(
    String path, {
    dynamic body,
    Map<String, String>? headers,
  }) async {
    final url = '$_baseUrl$path';
    final bodyStr = body == null
        ? null
        : body is Map || body is List
            ? jsonEncode(body)
            : body.toString();
    _log('POST', 'Request: $url', 'body: ${_truncate(bodyStr ?? '{}')}');
    final token = await StorageService.getAccessToken();
    debugPrint('[API] Token: $token');
    final h = Map<String, String>.from(headers ?? {});
    if (!h.containsKey('Content-Type')) {
      h['Content-Type'] = 'application/json';
    }
    _applyBearerAndCsrf(h, token);
    try {
      final res = await http
          .post(
            Uri.parse(url),
            headers: h,
            body: bodyStr ?? '{}',
          )
          .timeout(requestTimeout);
      _log(
        'POST',
        'Response ${res.statusCode}: $path',
        _truncate(res.body),
      );
      
      // Extract and log Position from get-context API response
      if (res.statusCode == 200) {
        try {
          final responseData = json.decode(res.body);
          if (responseData is Map && responseData.containsKey('context')) {
            final context = responseData['context'];
            if (context is Map && context.containsKey('position')) {
              final position = context['position'];
              debugPrint('[API] Position extracted: $position');
            }
          }
        } catch (_) {
          // Ignore for responses without context (like IFSC API)
        }
      }

      return res;
    } catch (e, st) {
      _log('POST', 'Error: $url', '$e\n$st');
      rethrow;
    }
  }
}
