/// Maps raw API / gateway bodies to short, user-friendly copy.
String friendlyApiErrorMessage(
  String? raw, {
  int? statusCode,
}) {
  if (raw == null || raw.trim().isEmpty) {
    return _defaultForStatus(statusCode);
  }

  final text = raw.trim();
  final lower = text.toLowerCase();

  if (lower.contains('<!doctype') ||
      lower.contains('<html') ||
      lower.contains('<body')) {
    return _defaultForStatus(statusCode);
  }

  if (lower.contains('502') || lower.contains('bad gateway')) {
    return 'Our servers are temporarily unavailable. Please wait a moment and tap Try Again.';
  }
  if (lower.contains('503') || lower.contains('service unavailable')) {
    return 'The service is temporarily busy. Please try again in a little while.';
  }
  if (lower.contains('504') || lower.contains('gateway timeout')) {
    return 'The request took too long. Please check your connection and try again.';
  }
  if (lower.contains('internal server error') || statusCode == 500) {
    return 'Something went wrong on our end. Please tap Try Again.';
  }

  if (_isTechnicalBackendToken(lower)) {
    return 'We couldn\'t load this step right now. Please tap Try Again.';
  }

  if (text.length > 280 || (text.startsWith('{') && text.endsWith('}'))) {
    return _defaultForStatus(statusCode);
  }

  if (_looksLikeUserFacingMessage(text)) {
    return text;
  }

  return _defaultForStatus(statusCode);
}

bool _isTechnicalBackendToken(String lower) {
  if (lower.startsWith('from ')) return true;
  if (lower.contains('render_time_diverge')) return true;
  if (lower.contains('traceback')) return true;
  if (RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(lower)) return true;
  return false;
}

bool _looksLikeUserFacingMessage(String text) {
  if (text.contains('<') || text.contains('>')) return false;
  if (_isTechnicalBackendToken(text.toLowerCase())) return false;
  if (text.length < 8) return false;
  return text.contains(' ') || text.contains('.');
}

String _defaultForStatus(int? statusCode) {
  switch (statusCode) {
    case 502:
      return 'Our servers are temporarily unavailable. Please wait a moment and tap Try Again.';
    case 503:
      return 'The service is temporarily busy. Please try again in a little while.';
    case 504:
      return 'The request took too long. Please check your connection and try again.';
    case 500:
    case 501:
      return 'Something went wrong on our end. Please tap Try Again.';
    case 401:
    case 403:
      return 'Your session may have expired. Please refresh or sign in again.';
    default:
      return 'Something went wrong. Please check your connection and tap Try Again.';
  }
}

/// Backend get-context / process error when uploaded PDF is still locked.
bool isPdfDocumentEncryptedError(String? raw) {
  if (raw == null || raw.trim().isEmpty) return false;
  final lower = raw.toLowerCase();
  return lower.contains('document closed or encrypted') ||
      lower.contains('closed or encrypted');
}

const String kPdfDocumentEncryptedUserMessage =
    'This PDF is password protected or could not be opened. Please upload again and enter the correct password.';

/// get-context / KRA PAN validation failed — keep user on PAN step to retry.
bool isInvalidPanContextError(String? raw) {
  if (raw == null || raw.trim().isEmpty) return false;
  final lower = raw.toLowerCase();
  return lower.contains('invalid pan') ||
      lower.contains('weberr-999') ||
      lower.contains('getpanstatus') ||
      lower.contains('kra_fetch_failed') ||
      (lower.contains('pan') &&
          (lower.contains('format') ||
              lower.contains('invalid') ||
              lower.contains('not valid')));
}

String invalidPanUserFacingMessage(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return 'Invalid PAN. Please enter a valid PAN and try again.';
  }
  final lower = raw.toLowerCase();
  if (lower.contains('invalid pan') || lower.contains('weberr-999')) {
    // Prefer short API msg when present (e.g. "WEBERR-999: Invalid PAN format").
    final trimmed = raw.trim();
    if (trimmed.length <= 120 && !trimmed.startsWith('{')) {
      return trimmed.contains('Invalid PAN') || trimmed.contains('invalid pan')
          ? (trimmed.toLowerCase().contains('format')
              ? 'Invalid PAN format. Please enter a valid PAN.'
              : trimmed)
          : 'Invalid PAN format. Please enter a valid PAN.';
    }
    return 'Invalid PAN format. Please enter a valid PAN.';
  }
  return friendlyApiErrorMessage(raw);
}
