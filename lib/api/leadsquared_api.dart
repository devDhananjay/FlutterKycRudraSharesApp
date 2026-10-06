import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/config/env_config.dart';

/// Meon LeadSquared proxy — called before SSO on app load.
class LeadSquaredAPI {
  static const int _requestTimeoutSeconds = 120;

  static const String _utmSource = 'App';
  static const String _utmMedium = 'App';
  static const String _utmCampaign = 'In_app_kyc';
  static const String _commSource = 'In_app_kyc';
  static const String _sourceContent = 'App';

  static List<Map<String, String>> _buildPayloadAttributes({
    required String mobileNumber,
    String firstName = '',
    String ageGroup = '',
  }) {
    return [
      {'Attribute': 'SearchBy', 'Value': 'Phone'},
      {'Attribute': 'Phone', 'Value': mobileNumber},
      {'Attribute': 'FirstName', 'Value': firstName},
      {'Attribute': 'mx_Lead_Age_Group', 'Value': ageGroup},
      {'Attribute': 'Source', 'Value': _utmSource},
      {'Attribute': 'mx_UTMSource', 'Value': _utmSource},
      {'Attribute': 'SourceMedium', 'Value': _utmMedium},
      {'Attribute': 'SourceCampaign', 'Value': _utmCampaign},
      {'Attribute': 'mx_CommSource', 'Value': _commSource},
      {'Attribute': 'mx_Ad_Group', 'Value': ''},
      {'Attribute': 'SourceContent', 'Value': _sourceContent},
    ];
  }

  /// SSO `additional_info` keys (different naming than LeadSquared Attribute list).
  static Map<String, String> buildSsoAdditionalInfo({
    required String mobileNumber,
    String firstName = '',
    String ageGroup = '',
  }) {
    return <String, String>{
      'Phone': mobileNumber,
      'firstname': firstName,
      'age_group': ageGroup,
      'source': _utmSource,
      'mx_utmsource': _utmSource,
      'source_medium': _utmMedium,
      'source_campaign': _utmCampaign,
      'mx_comsource': _commSource,
      'mx_adgroup': '',
      'sourcecontent': _sourceContent,
    };
  }

  static String? _extractLeadId(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final data = decoded['data'];
      if (data is! Map) return null;
      final message = data['Message'];
      if (message is! Map) return null;
      final id = message['RelatedId']?.toString().trim();
      return id == null || id.isEmpty ? null : id;
    } catch (_) {
      return null;
    }
  }

  static bool _isSuccessResponse(int statusCode, String body) {
    if (statusCode < 200 || statusCode >= 300) return false;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return true;
      if (decoded['success'] == true) return true;
      final data = decoded['data'];
      if (data is Map && data['Status']?.toString().toLowerCase() == 'success') {
        return true;
      }
      if (decoded['status_code'] == 200) return true;
    } catch (_) {
      return true;
    }
    return false;
  }

  /// Captures lead and returns `data.Message.RelatedId` for SSO `additional_info.kyc_lead`.
  static Future<String?> captureLead({
    required String mobileNumber,
    String firstName = '',
    String ageGroup = '',
  }) async {
    final url = EnvConfig.leadSquaredCaptureUrl;
    final body = <String, dynamic>{
      'payload': _buildPayloadAttributes(
        mobileNumber: mobileNumber,
        firstName: firstName,
        ageGroup: ageGroup,
      ),
      'timeout': _requestTimeoutSeconds,
    };
    final encodedBody = jsonEncode(body);

    debugPrint('[LeadSquared] POST $url');
    debugPrint('[LeadSquared] payload: $encodedBody');

    try {
      final res = await http
          .post(
            Uri.parse(url),
            headers: const {'Content-Type': 'application/json'},
            body: encodedBody,
          )
          .timeout(const Duration(seconds: _requestTimeoutSeconds));

      debugPrint('[LeadSquared] response status=${res.statusCode}');
      debugPrint('[LeadSquared] response: ${res.body}');

      if (!_isSuccessResponse(res.statusCode, res.body)) {
        return null;
      }

      final leadId = _extractLeadId(res.body);
      debugPrint('[LeadSquared] lead captured RelatedId=$leadId');
      return leadId;
    } catch (e, st) {
      debugPrint('[LeadSquared] exception: $e\n$st');
      return null;
    }
  }
}
