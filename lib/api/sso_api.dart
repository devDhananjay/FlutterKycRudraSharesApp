import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/api/base_api.dart';
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/api/leadsquared_api.dart';

class SsoTokenResult {
  final String accessToken;
  final String refreshToken;

  const SsoTokenResult({
    required this.accessToken,
    required this.refreshToken,
  });
}

class SsoAPI {
  static String get _ssoBaseUrl => EnvConfig.baseUrl;
  static const String _ssoRoutePath = '/get_sso_route';

  static const List<String> _containerKeys = [
    'data',
    'result',
    'payload',
    'session',
    'auth',
  ];

  static const List<String> _accessTokenKeys = [
    'access_token',
    'token',
  ];

  static const List<String> _refreshTokenKeys = [
    'refresh_token',
    'refresh',
  ];

  static String? _extractStringFromMap(
    Map<String, dynamic> map,
    List<String> keys,
  ) {
    for (final k in keys) {
      final v = map[k];
      if (v == null) continue;
      final s = v.toString();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  static String? _extractToken(Map<String, dynamic> root, List<String> tokenKeys) {
    // First pass: direct keys at the root.
    final direct = _extractStringFromMap(root, tokenKeys);
    if (direct != null) return direct;

    // Second pass: recursive search through nested objects/arrays.
    return _extractTokenRecursive(root, tokenKeys);
  }

  static String? _extractTokenRecursive(
    dynamic node,
    List<String> tokenKeys,
  ) {
    if (node is Map<String, dynamic>) {
      final direct = _extractStringFromMap(node, tokenKeys);
      if (direct != null) return direct;

      for (final v in node.values) {
        final found = _extractTokenRecursive(v, tokenKeys);
        if (found != null) return found;
      }
      return null;
    }

    if (node is List) {
      for (final item in node) {
        final found = _extractTokenRecursive(item, tokenKeys);
        if (found != null) return found;
      }
      return null;
    }

    return null;
  }

  static Future<SsoTokenResult?> getSsoRouteTokens({
    required String company,
    required String workflowName,
    required String mobileNumber,
    required String email,
    String firstName = '',
    String ageGroup = '',
    String? kycLeadId,
  }) async {
    final url = '$_ssoBaseUrl$_ssoRoutePath';
    final leadSquaredAdditionalInfo = LeadSquaredAPI.buildSsoAdditionalInfo(
      mobileNumber: mobileNumber,
      firstName: firstName,
      ageGroup: ageGroup,
    );

    final body = <String, dynamic>{
      'company': company,
      'workflowName': workflowName,
      'generate_access_token': true,
      'skip_reverification': true,
      'secret_key': EnvConfig.ssoSecretKey,
      'notification': false,
      'unique_keys': <String, dynamic>{
        'mobile_number': mobileNumber,
        // Keep exact key name from provided curl.
        'select_dependancy': 'Self',
      },
      'additional_info': <String, dynamic>{
        'email': email,
        ...leadSquaredAdditionalInfo,
        if (kycLeadId != null && kycLeadId.isNotEmpty) 'kyc_lead': kycLeadId,
      },
      'temp_data': <String, dynamic>{
        'is_sso': 'yes',
      },
    };

    debugPrint('[SSO] Calling get_sso_route for $company / $workflowName');
    debugPrint(
      '[SSO] additional_info payload: ${jsonEncode(body['additional_info'])}',
    );
    debugPrint('[SSO] Request payload: ${jsonEncode(body)}');

    try {
      final res = await http
          .post(
            Uri.parse(url),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(BaseAPI.requestTimeout);

      debugPrint('[SSO] get_sso_route response status=${res.statusCode}');

      if (res.statusCode < 200 || res.statusCode >= 300) {
        debugPrint(
          '[SSO] get_sso_route failed: ${res.body.length > 600 ? res.body.substring(0, 600) + "..." : res.body}',
        );
        return null;
      }

      final decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) {
        debugPrint('[SSO] Unexpected response shape: ${decoded.runtimeType}');
        return null;
      }

      debugPrint(
        '[SSO] get_sso_route response decoded keys: ${decoded.keys.toList()}',
      );

      final accessToken = _extractToken(decoded, _accessTokenKeys);
      final refreshToken = _extractToken(decoded, _refreshTokenKeys);

      if (accessToken == null || refreshToken == null) {
        debugPrint(
          '[SSO] Tokens missing. accessToken=${accessToken != null} refreshToken=${refreshToken != null}',
        );
        return null;
      }

      debugPrint(
        '[SSO] Tokens extracted. accessTokenLen=${accessToken.length} refreshTokenLen=${refreshToken.length}',
      );

      return SsoTokenResult(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );
    } catch (e, st) {
      debugPrint('[SSO] Exception in getSsoRouteTokens: $e\n$st');
      return null;
    }
  }
}

