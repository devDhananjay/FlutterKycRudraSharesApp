import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/api/api_client.dart';
import 'package:meon_kyc/config/env_config.dart';

class KycAPI {
  static final _client = ApiClient();
  static final _baseUrl = EnvConfig.baseUrl;

  static Future<http.Response> submitKyc(
    String urlCompany,
    String urlWorkflowName,
    dynamic dataToSend,
    Map<String, String> headers,
  ) async {
    return _client.post(
      '/api/get-user/$urlCompany/$urlWorkflowName',
      body: dataToSend is Map ? dataToSend : (dataToSend is String ? jsonDecode(dataToSend) : dataToSend),
      headers: headers,
    );
  }

  /// Backend proxy → review/edit step for a field; on success client refreshes via get-context.
  static Future<http.Response> reviewEditPage(
    String company,
    String workflowName,
    String currentField,
  ) {
    final c = Uri.encodeComponent(company);
    final w = Uri.encodeComponent(workflowName);
    final f = Uri.encodeComponent(currentField);
    return _client.get('/api_review_edit_page/$c/$w/$f');
  }

  static Future<http.Response> submitKycV2(
    String urlCompany,
    String urlWorkflowName,
    String position,
    String index,
    dynamic dataToSend,
    Map<String, String> headers,
  ) async {
    return _client.post(
      '/api/kyc-post-v2/$urlCompany/$urlWorkflowName/$position$index',
      body: dataToSend is Map ? dataToSend : jsonDecode(dataToSend.toString()),
      headers: headers,
    );
  }

  static Future<http.Response> pdfPasswordCheck(
    String urlCompany,
    String workflowKey,
    Map<String, dynamic> dataToSend,
  ) async {
    // Match web: /pdfPassCheck/{workflow_Key} (raw key, not double-encoded).
    final uri = Uri.parse('$_baseUrl/pdfPassCheck/$workflowKey');
    return _client.postMultipart(
      () async {
        final request = http.MultipartRequest('POST', uri);
        final financial = dataToSend['financial'];
        if (financial is File) {
          request.files.add(await http.MultipartFile.fromPath(
            'financial',
            financial.path,
          ));
        }
        return request;
      },
      skipRefreshOn401: true,
    );
  }

  static Future<http.Response> verifyPdfPassword(
    String pdfPassword,
    String workflowKey,
    Map<String, dynamic> dataToSend,
  ) async {
    final encodedPassword = Uri.encodeComponent(pdfPassword);
    final uri =
        Uri.parse('$_baseUrl/verifyPdfPassword/$encodedPassword/$workflowKey');
    return _client.postMultipart(
      () async {
        final request = http.MultipartRequest('POST', uri);
        final financial = dataToSend['financial'];
        if (financial is File) {
          request.files.add(await http.MultipartFile.fromPath(
            'financial',
            financial.path,
          ));
        }
        return request;
      },
      skipRefreshOn401: true,
    );
  }

  static Future<http.Response> getUserDetails() async {
    return _client.post('/api/user-details', body: {});
  }

  static Future<http.Response> positionUpdate(String position) async {
    return _client.post('/api/position-update', body: {'position': position});
  }

  static Future<http.Response> getStepperWorkflow(String company, String workflowId) async {
    // Admin stepper workflow API (used only for step labels)
    // Backend route (from curl): /kycadmin_getWorkflow/{workflowName}/{workflowId}
    // "company" arg here is actually workflowName (e.g. bp_flow)
    return _client.post('/kycadmin_getWorkflow/$company/$workflowId', body: {});
  }
}
