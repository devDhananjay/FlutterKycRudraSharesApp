import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/api/base_api.dart';
import 'package:meon_kyc/api/interceptor.dart';
import 'package:meon_kyc/services/storage_service.dart';

class ApiClient {
  static final ApiClient _instance = ApiClient._internal();
  factory ApiClient() => _instance;
  final _base = BaseAPI();

  ApiClient._internal();

  Future<http.Response> get(String path) async {
    return ApiInterceptor.request(() => _base.get(path));
  }

  Future<http.Response> post(
    String path, {
    dynamic body,
    Map<String, String>? headers,
  }) async {
    return ApiInterceptor.request(() => _base.post(path, body: body, headers: headers));
  }

  /// Sends a multipart request. [createRequest] is called each time (e.g. on retry after 401)
  /// so that a fresh request is built and the latest token from storage is used.
  /// Set [skipRefreshOn401] to true for endpoints like upload_files where 401 should not
  /// trigger token refresh (same token as other APIs is used; no retry/refresh).
  Future<http.Response> postMultipart(
    Future<http.MultipartRequest> Function() createRequest, {
    bool skipRefreshOn401 = false,
  }) async {
    Future<http.Response> send() async {
      final request = await createRequest();
      final url = request.url.toString();
      debugPrint('[API MULTIPART] Request: $url');
      debugPrint('[API MULTIPART] fields: ${request.fields}');
      final token = await StorageService.getAccessToken();
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
        final csrf = BaseAPI.csrfFromJwtAccessToken(token);
        if (csrf != null) request.headers['X-CSRF-TOKEN'] = csrf;
        final sessionId = BaseAPI.sessionIdFromJwtAccessToken(token);
        if (sessionId != null) {
          request.headers['Cookie'] = 'session_id=$sessionId';
        }
        debugPrint('[API MULTIPART] Authorization header set (token length: ${token.length})');
      } else {
        debugPrint('[API MULTIPART] WARNING: No access token in storage');
      }
      try {
        final stream = await request.send();
        final res = await http.Response.fromStream(stream);
        final bodyPreview = res.body.length > 600 ? '${res.body.substring(0, 600)}...' : res.body;
        debugPrint('[API MULTIPART] Response ${res.statusCode}: $url\n$bodyPreview');
        return res;
      } catch (e, st) {
        debugPrint('[API MULTIPART] Error: $url\n$e\n$st');
        rethrow;
      }
    }

    if (skipRefreshOn401) {
      return send().timeout(BaseAPI.requestTimeout);
    }
    return ApiInterceptor.request(send).timeout(BaseAPI.requestTimeout);
  }
}