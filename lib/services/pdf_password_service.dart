import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/api/kyc_api.dart';

enum PdfPasswordCheckStatus {
  notEncrypted,
  encrypted,
  corrupted,
  error,
}

class PdfPasswordCheckResult {
  final PdfPasswordCheckStatus status;
  final String message;

  const PdfPasswordCheckResult({
    required this.status,
    this.message = '',
  });
}

class PdfPasswordVerifyResult {
  final bool success;
  final String message;

  const PdfPasswordVerifyResult({
    required this.success,
    this.message = '',
  });
}

/// Global helpers for PDF password-protection check / verify (web JS parity).
class PdfPasswordService {
  static const int _maxTransientRetries = 3;

  static bool isPdfFile(File file) {
    final path = file.path.toLowerCase();
    return path.endsWith('.pdf');
  }

  static bool _isTransientStatus(int statusCode) =>
      statusCode == 403 ||
      statusCode == 429 ||
      statusCode == 502 ||
      statusCode == 503;

  static bool _looksLikeTransientHtml(String body) {
    final t = body.toLowerCase();
    return t.contains('processing your journey') ||
        t.contains('syncing your progress') ||
        t.contains('<!doctype html');
  }

  static Future<http.Response> _checkWithRetry({
    required File file,
    required String workflowKey,
    String? urlCompany,
  }) async {
    http.Response? last;
    for (var attempt = 1; attempt <= _maxTransientRetries; attempt++) {
      last = await KycAPI.pdfPasswordCheck(
        urlCompany ?? '',
        workflowKey,
        {'financial': file},
      );
      debugPrint(
        '[PdfPassword] check attempt=$attempt/$_maxTransientRetries '
        'status=${last.statusCode}',
      );
      if (!_isTransientStatus(last.statusCode)) return last;
      if (attempt < _maxTransientRetries) {
        final wait = Duration(seconds: attempt + 1);
        debugPrint(
          '[PdfPassword] transient ${last.statusCode} — retry in ${wait.inSeconds}s',
        );
        await Future.delayed(wait);
      }
    }
    return last!;
  }

  static PdfPasswordCheckResult _parseCheckResponse(http.Response res) {
    debugPrint(
      '[PdfPassword] check status=${res.statusCode} body=${res.body.length > 400 ? '${res.body.substring(0, 400)}...' : res.body}',
    );

    if (res.statusCode < 200 || res.statusCode >= 300) {
      final transient = _isTransientStatus(res.statusCode) ||
          _looksLikeTransientHtml(res.body);
      return PdfPasswordCheckResult(
        status: PdfPasswordCheckStatus.error,
        message: transient
            ? 'Server is busy verifying the PDF. Please try uploading again in a moment.'
            : 'Could not check PDF password protection. Please try again.',
      );
    }

    try {
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        // 2xx but not JSON — treat as not encrypted (web else-branch).
        return const PdfPasswordCheckResult(
          status: PdfPasswordCheckStatus.notEncrypted,
        );
      }

      final data = decoded['data'] == true;
      final info = decoded['info']?.toString().toLowerCase() ?? '';
      final msg = decoded['msg']?.toString() ?? '';

      if (data && info == 'corrupted') {
        return PdfPasswordCheckResult(
          status: PdfPasswordCheckStatus.corrupted,
          message: msg.isNotEmpty
              ? msg
              : 'Your file is corrupted. Please upload a valid file.',
        );
      }
      if (data && info == 'encrypted') {
        return PdfPasswordCheckResult(
          status: PdfPasswordCheckStatus.encrypted,
          message: msg,
        );
      }
      return const PdfPasswordCheckResult(
        status: PdfPasswordCheckStatus.notEncrypted,
      );
    } catch (_) {
      // HTML/non-JSON 2xx — not encrypted.
      return const PdfPasswordCheckResult(
        status: PdfPasswordCheckStatus.notEncrypted,
      );
    }
  }

  static Future<PdfPasswordCheckResult> checkEncrypted({
    required File file,
    required String workflowKey,
    String? urlCompany,
  }) async {
    try {
      final res = await _checkWithRetry(
        file: file,
        workflowKey: workflowKey,
        urlCompany: urlCompany,
      );
      return _parseCheckResponse(res);
    } catch (e, st) {
      debugPrint('[PdfPassword] check exception: $e\n$st');
      return const PdfPasswordCheckResult(
        status: PdfPasswordCheckStatus.error,
        message: 'Could not check PDF password protection. Please try again.',
      );
    }
  }

  static Future<PdfPasswordVerifyResult> verifyPassword({
    required File file,
    required String password,
    required String workflowKey,
  }) async {
    try {
      http.Response? last;
      for (var attempt = 1; attempt <= _maxTransientRetries; attempt++) {
        last = await KycAPI.verifyPdfPassword(
          password,
          workflowKey,
          {'financial': file},
        );
        debugPrint(
          '[PdfPassword] verify attempt=$attempt/$_maxTransientRetries '
          'status=${last.statusCode}',
        );
        if (!_isTransientStatus(last.statusCode)) break;
        if (attempt < _maxTransientRetries) {
          await Future.delayed(Duration(seconds: attempt + 1));
        }
      }
      final res = last!;
      debugPrint(
        '[PdfPassword] verify status=${res.statusCode} body=${res.body.length > 400 ? '${res.body.substring(0, 400)}...' : res.body}',
      );

      if (res.statusCode < 200 || res.statusCode >= 300) {
        return PdfPasswordVerifyResult(
          success: false,
          message: _isTransientStatus(res.statusCode)
              ? 'Server is busy. Please try verifying again in a moment.'
              : 'Password verification failed. Please try again.',
        );
      }

      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        return const PdfPasswordVerifyResult(success: true);
      }

      if (decoded['success'] == false || decoded['data'] == false) {
        final msg = decoded['msg']?.toString() ??
            decoded['message']?.toString() ??
            'Incorrect password. Please try again.';
        return PdfPasswordVerifyResult(success: false, message: msg);
      }

      final info = decoded['info']?.toString().toLowerCase() ?? '';
      if (info == 'encrypted' && decoded['data'] == true) {
        return PdfPasswordVerifyResult(
          success: false,
          message: decoded['msg']?.toString() ??
              'Incorrect password. Please try again.',
        );
      }

      return const PdfPasswordVerifyResult(success: true);
    } catch (e, st) {
      debugPrint('[PdfPassword] verify exception: $e\n$st');
      return const PdfPasswordVerifyResult(
        success: false,
        message: 'Password verification failed. Please try again.',
      );
    }
  }
}
