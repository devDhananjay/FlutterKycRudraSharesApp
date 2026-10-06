import 'dart:math' as math;

import 'package:flutter/services.dart';

/// Formats up to 8 digits as `DD/MM/YYYY` while the user types.
String formatDdMmYyyyTyping(String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  final clipped = digits.length > 8 ? digits.substring(0, 8) : digits;
  final buffer = StringBuffer();
  for (var i = 0; i < clipped.length; i++) {
    if (i == 2 || i == 4) buffer.write('/');
    buffer.write(clipped[i]);
  }
  return buffer.toString();
}

/// Auto-inserts `/` after day and month while typing `DD/MM/YYYY`.
class DdMmYyyyInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final oldDigits = oldValue.text.replaceAll(RegExp(r'\D'), '');
    final newDigits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final clipped =
        newDigits.length > 8 ? newDigits.substring(0, 8) : newDigits;
    final formatted = formatDdMmYyyyTyping(clipped);

    var cursor = formatted.length;
    if (newDigits.length < oldDigits.length) {
      final rawCursor = newValue.selection.baseOffset.clamp(0, newValue.text.length);
      final digitsBeforeCursor = newValue.text
          .substring(0, rawCursor)
          .replaceAll(RegExp(r'\D'), '')
          .length;
      var pos = 0;
      var seenDigits = 0;
      while (pos < formatted.length && seenDigits < digitsBeforeCursor) {
        if (RegExp(r'\d').hasMatch(formatted[pos])) seenDigits++;
        pos++;
      }
      cursor = pos.clamp(0, formatted.length);
    }

    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }
}

/// Allows digits and `/` for manual DOB entry on the normal keyboard.
final ddMmYyyyKeyboardFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'[0-9/]')),
  DdMmYyyyInputFormatter(),
  LengthLimitingTextInputFormatter(10),
];

/// Stored value is often ISO `yyyy-MM-dd` or `MM/dd/yyyy`-style.
DateTime? parseKycDateValue(dynamic value) {
  if (value == null) return null;
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  final normalized = s.replaceAll('/', '-');
  final d = DateTime.tryParse(normalized);
  if (d != null) return DateTime(d.year, d.month, d.day);
  final m = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$').firstMatch(s);
  if (m != null) {
    final month = int.tryParse(m.group(1)!);
    final day = int.tryParse(m.group(2)!);
    final year = int.tryParse(m.group(3)!);
    if (month != null && day != null && year != null) {
      return DateTime(year, month, day);
    }
  }
  return null;
}

/// If [value] parses as a calendar date, returns **`dd/MM/yyyy`** (e.g. for kyc-post JSON).
String? tryFormatKycDateValueAsDdMmYyyy(dynamic value) {
  final d = parseKycDateValue(value);
  if (d == null) return null;
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

/// Parses slash dates as **day/month/year** (matches PAN step UI `dd/MM/yyyy`).
DateTime? parseKycDateValueAsDdMmYyyy(dynamic value) {
  if (value == null) return null;
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  final iso = DateTime.tryParse(s.replaceAll('/', '-'));
  if (iso != null) return DateTime(iso.year, iso.month, iso.day);
  final m = RegExp(r'^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$').firstMatch(s);
  if (m == null) return null;
  final day = int.tryParse(m.group(1)!);
  final month = int.tryParse(m.group(2)!);
  final year = int.tryParse(m.group(3)!);
  if (day == null || month == null || year == null) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime(year, month, day);
}

/// PAN verify step (`pan10`) — exact web/curl body: trim, uppercase name/PAN, ISO DOB.
bool isPanVerifyKycPostStep(String? position, String pathSegment) {
  final p = (position ?? '').toLowerCase();
  final path = pathSegment.toLowerCase();
  if (p == 'detailspan' || path.startsWith('detailspan')) return false;
  // Document upload step — must not run PAN verify body logic (drops file from payload).
  if (p == 'pan_upload' || path.startsWith('pan_upload')) return false;
  return p == 'pan' || path.startsWith('pan');
}

/// PAN capture step (`detailspan`) before verify/KRA.
bool isDetailspanKycStep(String? position, String? pageLabel) {
  final p = (position ?? '').toLowerCase();
  final l = (pageLabel ?? '').toLowerCase();
  return p == 'detailspan' ||
      l == 'detailspan' ||
      p.startsWith('detailspan') ||
      l.startsWith('detailspan');
}

/// PAN / DOB inputs on `detailspan` must stay blank for the user — do not
/// merge get-context dropoff `field.value` into the form or UI.
bool isDetailspanUserEntryField(String? fieldName) {
  final n = (fieldName ?? '').toLowerCase().trim();
  return n == 'pan_number' ||
      n == 'temp_pan_no' ||
      n == 'pan_no' ||
      n == 'pan_dob_for_match' ||
      n == 'pan_dob' ||
      n == 'dob' ||
      n == 'date_of_birth';
}

const String kDetailspanPanDuplicateUserMessage =
    'This PAN is already registered. Please use a different PAN';

bool isPanNumberAlreadyExistsApiMessage(String? raw) {
  if (raw == null || raw.trim().isEmpty) return false;
  final lower = raw.toLowerCase().trim();
  return lower.contains('pan number already exist') ||
      lower.contains('pan already exist');
}

String? detailspanPanDuplicateFriendlyMessage(String? apiMsg) {
  if (!isPanNumberAlreadyExistsApiMessage(apiMsg)) return null;
  return kDetailspanPanDuplicateUserMessage;
}

/// HTTP 200 + `success: false` when PAN was already saved on this journey.
bool isPanNumberAlreadyExistsResponse(Map<String, dynamic>? body) {
  if (body == null) return false;
  return isPanNumberAlreadyExistsApiMessage(
    (body['msg'] ?? body['message'])?.toString(),
  );
}

/// Same PAN already on file for this user (user-details) — safe to advance like web.
bool panNumberMatchesUserDetails(
  Map<String, dynamic> submissionData,
  Map<String, dynamic>? userDetailsData,
) {
  if (userDetailsData == null) return false;
  final submitted =
      (submissionData['pan_number'] ?? '').toString().trim().toUpperCase();
  if (submitted.isEmpty) return false;
  for (final key in ['pan_number', 'temp_pan_no']) {
    final stored = userDetailsData[key]?.toString().trim().toUpperCase() ?? '';
    if (stored.isNotEmpty && stored == submitted) return true;
  }
  return false;
}

/// Builds `kyc-post-v2` body for PAN verify (`pan10`) only.
Map<String, dynamic> buildPanVerifyKycPostBody(Map<String, dynamic> data) {
  final name = (data['name'] ?? '').toString().trim().toUpperCase();
  final pan = (data['pan_number'] ?? '').toString().trim().toUpperCase();
  final dob = tryFormatKycPanDobForMatchApi(data['pan_dob_for_match']) ??
      (data['pan_dob_for_match']?.toString().trim() ?? '');

  final out = <String, dynamic>{};
  if (name.isNotEmpty) out['name'] = name;
  if (dob.isNotEmpty) out['pan_dob_for_match'] = dob;
  if (pan.isNotEmpty) out['pan_number'] = pan;
  return out;
}

/// PAN verify `kyc-post-v2` (`pan10`): API expects **`yyyy-MM-dd`** (e.g. `2005-11-05`).
/// UI stays `dd/MM/yyyy`; only the POST body uses this ISO format.
String? tryFormatKycPanDobForMatchApi(dynamic value) {
  final s = value?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  final DateTime? d;
  if (RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(s)) {
    d = parseKycDateValue(value);
  } else {
    d = parseKycDateValueAsDdMmYyyy(value) ?? parseKycDateValue(value);
  }
  if (d == null) return null;
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

DateTime _subtractYearsFromDate(DateTime from, int years) {
  if (years <= 0) return from;
  final targetYear = from.year - years;
  final dim = DateTime(targetYear, from.month + 1, 0).day;
  final day = math.min(from.day, dim);
  return DateTime(targetYear, from.month, day);
}

/// API-driven DOB picker bounds, e.g. `maxDateType: year`, `maxDateValue: -18` (min age 18),
/// `minDateType: year`, `minDateValue: 100` (max age 100).
/// Returns `null` when no usable date constraints are present.
({DateTime first, DateTime last})? kycDobPickerBoundsFromField(
  Map<dynamic, dynamic> field, {
  DateTime? today,
}) {
  final now = today ?? DateTime.now();
  final todayDate = DateTime(now.year, now.month, now.day);

  final minType = field['minDateType']?.toString().toLowerCase().trim();
  final minRaw = field['minDateValue']?.toString().trim();
  final maxType = field['maxDateType']?.toString().toLowerCase().trim();
  final maxRaw = field['maxDateValue']?.toString().trim();

  final hasMin = minType != null &&
      minType.isNotEmpty &&
      minRaw != null &&
      minRaw.isNotEmpty;
  final hasMax = maxType != null &&
      maxType.isNotEmpty &&
      maxRaw != null &&
      maxRaw.isNotEmpty;

  if (!hasMin && !hasMax) return null;

  var first = DateTime(1900, 1, 1);
  var last = todayDate;

  if (hasMin && minType == 'year') {
    final y = int.tryParse(minRaw ?? '');
    if (y != null && y > 0) {
      first = _subtractYearsFromDate(todayDate, y);
    }
  }

  if (hasMax && maxType == 'year') {
    final raw = maxRaw ?? '';
    final y = int.tryParse(raw.replaceAll('+', ''));
    if (y != null && y != 0) {
      final years = y.abs();
      last = _subtractYearsFromDate(todayDate, years);
    }
  }

  if (first.isAfter(last)) {
    final t = first;
    first = last;
    last = t;
  }
  return (first: first, last: last);
}

/// `null` if valid or empty (caller handles required separately).
String? validateDobAgainstFieldBounds(
  Map<dynamic, dynamic> field,
  dynamic value,
) {
  final bounds = kycDobPickerBoundsFromField(field);
  if (bounds == null) return null;

  final d = parseKycDateValue(value);
  if (d == null) return null;

  final dob = DateTime(d.year, d.month, d.day);
  if (dob.isBefore(bounds.first) || dob.isAfter(bounds.last)) {
    return 'Date of birth must be between ${_formatShort(bounds.first)} and '
        '${_formatShort(bounds.last)}.';
  }
  return null;
}

String _formatShort(DateTime d) {
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}
