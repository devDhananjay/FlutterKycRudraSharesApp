import 'package:flutter/foundation.dart';

int _calculateAge(DateTime dob) {
  final today = DateTime.now();
  var age = today.year - dob.year;
  final m = today.month - dob.month;
  if (m < 0 || (m == 0 && today.day < dob.day)) age--;
  return age;
}

bool _parseDate(dynamic v) {
  if (v == null) return false;
  final d = DateTime.tryParse(v.toString());
  return d != null;
}

int? _tryAge(dynamic fieldValue) {
  if (fieldValue == null) return null;
  final d = DateTime.tryParse(fieldValue.toString());
  if (d == null) return null;
  return _calculateAge(d);
}

final Map<String, bool Function(dynamic, dynamic)> _conditionOperators = {
  'equals': (a, b) {
    // Case-insensitive comparison for Yes/No values (nominee conditions)
    final aStr = a.toString().trim().toLowerCase();
    final bStr = b.toString().trim().toLowerCase();
    return aStr == bStr;
  },
  'contains': (a, b) {
    if (a is List) return a.contains(b);
    // Handle checkbox boolean values (true/false) matching against string 'true'/'false'
    if (a is bool) {
      final bStr = b.toString().trim().toLowerCase();
      return (a && bStr == 'true') || (!a && bStr == 'false');
    }
    final aStr = a.toString().trim().toLowerCase();
    final bStr = b.toString().trim().toLowerCase();
    return aStr.contains(bStr);
  },
  'notEquals': (a, b) {
    final aStr = a.toString().trim().toLowerCase();
    final bStr = b.toString().trim().toLowerCase();
    return aStr != bStr;
  },
  'notequals': (a, b) {
    // Alias for notEquals (JSON uses lowercase variant)
    final aStr = a.toString().trim().toLowerCase();
    final bStr = b.toString().trim().toLowerCase();
    return aStr != bStr;
  },
  'greaterthan': (a, b) {
    if (b == null || b.toString().isEmpty) return false;
    final age = _tryAge(a);
    if (age != null) return age >= (int.tryParse(b.toString()) ?? 0);
    return (double.tryParse(a?.toString() ?? '') ?? 0) >
        (double.tryParse(b.toString()) ?? 0);
  },
  'lessthan': (a, b) {
    if (b == null || b.toString().isEmpty) return false;
    final age = _tryAge(a);
    if (age != null) return age < (int.tryParse(b.toString()) ?? 0);
    return (double.tryParse(a?.toString() ?? '') ?? 0) <
        (double.tryParse(b.toString()) ?? 0);
  },
  'in': (a, b) {
    final list = b is List ? b : b.toString().split(',');
    return list.map((e) => e.toString()).contains(a.toString());
  },
};

typedef FieldVisibility = Map<String, bool>;
typedef FieldEditable = Map<String, bool>;
typedef FormDataMap = Map<String, dynamic>;

class ConditionalFlowState {
  final FieldVisibility fieldVisibility = {};
  final FormDataMap formData;
  final Map<String, String> fieldErrors = {};
  final Map<String, bool> fieldRequirements = {};
  final FieldEditable fieldEditable = {};

  ConditionalFlowState({FormDataMap? formData})
      : formData = Map<String, dynamic>.from(formData ?? {});
}

List<Map<String, dynamic>> getConditionsForField(
  List<dynamic>? conditionalFlow,
  String fieldName,
) {
  if (conditionalFlow == null) return [];
  return conditionalFlow
      .where((c) => c is Map && (c['field'] ?? '') == fieldName)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
}

/// Nominee address fields controlled by each "same as my address" checkbox.
const Map<String, List<String>> kNomineeSameAsAddressGroups = {
  'nominee1_same_as_my_address': [
    'nominee1_add1',
    'nominee1_add2',
    'nominee_1_city',
    'nominee1_state',
    'nominee1_country',
    'nominee1_pincode',
  ],
  'nominee2_same_as_my_address': [
    'nominee2_add1',
    'nominee2_add2',
    'nominee_2_city',
    'nominee2_state',
    'nominee2_country',
    'nominee2_pincode',
  ],
  'nominee3_same_as_my_address': [
    'nominee3_add1',
    'nominee3_add2',
    'nominee3_city',
    'nominee3_state',
    'nominee3_country',
    'nominee3_pincode',
  ],
  'nominee4_same_as_my_address': [
    'nominee4_add1',
    'nominee4_add2',
    'nominee_4_city',
    'nominee4_state',
    'nominee4_country',
    'nominee4_pincode',
  ],
  'nominee5_same_as_my_address': [
    'nominee5_add1',
    'nominee5_add2',
    'nominee_5_city',
    'nominee5_state',
    'nominee5_country',
    'nominee5_pincode',
  ],
  'nominee6_same_as_my_address': [
    'nominee6_add1',
    'nominee6_add2',
    'nominee6_city',
    'nominee_6_city',
    'nominee6_state',
    'nominee6_country',
    'nominee6_pincode',
  ],
  'nominee7_same_as_my_address': [
    'nominee7_add1',
    'nominee_7_city',
    'nominee7_state',
    'nominee7_country',
    'nominee7_pincode',
  ],
  'nominee8_same_as_my_address': [
    'nominee8_add1',
    'nominee_8_city',
    'nominee8_state',
    'nominee8_country',
    'nominee8_pincode',
  ],
  'nominee9_same_as_my_address': [
    'nominee9_add1',
    'nominee9_city',
    'nominee9_state',
    'nominee9_country',
    'nominee9_pincode',
  ],
  'nominee10_same_as_my_address': [
    'nominee10_add1',
    'nominee_10_city',
    'nominee10_state',
    'nominee10_country',
    'nominee10_pincode',
  ],
};

const Map<String, int> _kNomineeWordSlotsForAddress = {
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
};

/// Nominee slot from field name (digits + word forms like nominee_ten).
int? _nomineeSlotFromFieldNameForAddress(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('guardian')) return null;
  final compact = lower.replaceAll('_', '');
  final m = RegExp(r'nominee(\d+)').firstMatch(compact);
  if (m != null) return int.tryParse(m.group(1)!);
  for (final e in _kNomineeWordSlotsForAddress.entries) {
    if (compact.contains('nominee${e.key}')) return e.value;
  }
  return null;
}

bool _isNomineeAddressDataFieldName(String name) {
  final n = name.toLowerCase();
  if (n.contains('same_as_my_address')) return false;
  if (n.contains('guardian')) return false;
  if (RegExp(r'nominee\d+_(mobile|email|name|relation|dob)').hasMatch(n)) {
    return false;
  }
  if (RegExp(r'nominee_\d+_(mobile|email|name|relation|dob)').hasMatch(n)) {
    return false;
  }
  if (n.contains('percentage') ||
      n.contains('proof_type') ||
      n.contains('upload') ||
      (n.contains('pan') && !n.contains('pincode')) ||
      n.contains('aadhar') ||
      n.contains('aadhaar')) {
    return false;
  }
  return n.contains('_add') ||
      n.contains('city') ||
      n.contains('state') ||
      n.contains('country') ||
      n.contains('pincode');
}

/// Step fields + static map — covers additional nominee slots from API.
Map<String, List<String>> resolveNomineeSameAsAddressGroups(
  List<dynamic>? fields,
) {
  final groups = Map<String, List<String>>.from(kNomineeSameAsAddressGroups);
  if (fields == null) return groups;

  for (final f in fields) {
    if (f is! Map) continue;
    final checkbox = f['name']?.toString();
    if (checkbox == null || !checkbox.contains('same_as_my_address')) continue;
    if (groups.containsKey(checkbox)) continue;

    final slot = _nomineeSlotFromFieldNameForAddress(checkbox);
    if (slot == null) continue;

    final targets = <String>[];
    for (final f2 in fields) {
      if (f2 is! Map) continue;
      final n = f2['name']?.toString() ?? '';
      final type = (f2['type']?.toString() ?? '').toLowerCase();
      if (type == 'button' || type == 'hidden' || type == 'file') continue;
      if (_nomineeSlotFromFieldNameForAddress(n) != slot) continue;
      if (!_isNomineeAddressDataFieldName(n)) continue;
      targets.add(n);
    }
    if (targets.isNotEmpty) groups[checkbox] = targets;
  }
  return groups;
}

bool isNomineeSameAsMyAddressCheckbox(String? fieldName) {
  return fieldName != null && fieldName.contains('same_as_my_address');
}

bool isNomineeAddressTargetField(String? fieldName) {
  if (fieldName == null) return false;
  for (final targets in kNomineeSameAsAddressGroups.values) {
    if (targets.contains(fieldName)) return true;
  }
  if (fieldName.contains('nominee') &&
      (fieldName.contains('_add') ||
          fieldName.contains('city') ||
          fieldName.contains('state') ||
          fieldName.contains('country') ||
          fieldName.contains('pincode'))) {
    return true;
  }
  return false;
}

bool isCheckboxCheckedValue(dynamic value) {
  if (value == true) return true;
  final s = value?.toString().trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

/// Dropdown / radio placeholders from API (`value: "Select"`) — not real answers.
bool isApiFieldPlaceholderValue(dynamic value) {
  if (value == null) return true;
  if (value is bool) return false;
  // Source mappings (`[{label, value}]`) are never displayable answers.
  if (value is List || value is Map) return true;
  final s = value.toString().trim().toLowerCase();
  if (s.isEmpty) return true;
  if (s == 'select' ||
      s == '--select--' ||
      s == '-select-' ||
      s == 'choose' ||
      s == 'choose...' ||
      s == 'please select') {
    return true;
  }
  if (s.startsWith('--') && s.endsWith('--')) return true;
  return false;
}

/// True when [s] is an API prepopulate *source key* (e.g. `reverse_ifsc`,
/// `mobile_number`), not a user-facing value.
bool looksLikePrepopulateSourceKey(String s) {
  final t = _stripFieldKeyPrefix(s);
  if (t.isEmpty) return false;
  final lower = t.toLowerCase();
  // List/Map dumps that leaked into text controllers.
  if (lower.startsWith('[{') ||
      lower.startsWith('{label:') ||
      lower.contains('reverse_')) {
    return true;
  }
  if (lower.startsWith('reverse')) return true;
  if (looksLikeAddressFieldKey(t)) return true;
  const bareSourceKeys = {
    'name',
    'email',
    'mobile',
    'phone',
    'pan',
    'dob',
    'gender',
    'mobile_number',
  };
  return bareSourceKeys.contains(lower);
}

/// Prefer API `value` (dropoff), then a *literal* `prepopulateValue`, then
/// `defaultValue`.
///
/// `prepopulateValue` is usually a source-field reference (`"mobile_number"` or
/// `[{label: reverse_ifsc, value: reverse_ifsc}]`), not text to show in the UI.
/// Those are skipped so empty bank fields stay blank instead of showing key names.
dynamic resolveApiFieldSeedValue(Map field) {
  final v = field['value'];
  if (v is bool) return v;
  if (!isApiFieldPlaceholderValue(v)) {
    if (v is String && looksLikePrepopulateSourceKey(v)) {
      // fall through — API echoed a source key into `value`
    } else {
      return v;
    }
  }

  final pv = field['prepopulateValue'];
  if (pv is bool) return pv;
  // Only accept a plain string that is a real literal, not a source key / mapping.
  if (pv is String &&
      !isApiFieldPlaceholderValue(pv) &&
      !looksLikePrepopulateSourceKey(pv)) {
    return pv;
  }

  final dv = field['defaultValue'];
  if (dv is bool) return dv;
  if (!isApiFieldPlaceholderValue(dv)) return dv;
  return null;
}

Map<String, String> _emptyUserAddressMap() => {
      'add1': '',
      'add2': '',
      'city': '',
      'state': '',
      'country': '',
      'pincode': '',
    };

Map<String, String> _cachedUserAddress = {};

/// API pre-fills these nominee fields with the applicant address (old on-load behaviour).
const Map<String, String> kNomineePrefillToAddressComponent = {
  'nominee1_add1': 'add1',
  'nominee1_add2': 'add2',
  'nominee_1_city': 'city',
  'nominee1_state': 'state',
  'nominee1_country': 'country',
  'nominee1_pincode': 'pincode',
};

const Map<String, List<String>> _userAddressAliases = {
  'add1': [
    'add1',
    'address_line1',
    'address_line_1',
    'address1',
    'addr_line1',
    'kra_add_line1',
    'kraaddress',
    'kra_address',
    'correspondence_add1',
    'corr_add1',
    'perm_add1',
    'permanent_add1',
    'current_add1',
    'communication_add1',
    'residence_add1',
    'residential_address',
    'address',
    'user_address',
    'permanent_address',
    'correspondence_address',
  ],
  'add2': [
    'add2',
    'address_line2',
    'address_line_2',
    'address2',
    'addr_line2',
    'kra_add_line2',
    'correspondence_add2',
    'corr_add2',
    'perm_add2',
    'permanent_add2',
    'current_add2',
  ],
  'city': [
    'city',
    'kra_city',
    'aadhar_dist',
    'aadhar_city',
    'user_city',
    'perm_city',
    'permanent_city',
    'correspondence_city',
    'corr_city',
    'current_city',
    'residence_city',
  ],
  'state': [
    'state',
    'kra_state',
    'user_state',
    'perm_state',
    'permanent_state',
    'correspondence_state',
    'current_state',
  ],
  'country': [
    'country',
    'kra_country',
    'aadhar_country',
    'user_country',
    'perm_country',
    'permanent_country',
    'correspondence_country',
  ],
  'pincode': [
    'pincode',
    'kra_pincode',
    'kra_pin_code',
    'pin_code',
    'zip',
    'zipcode',
    'postal_code',
    'perm_pincode',
    'permanent_pincode',
    'correspondence_pincode',
  ],
};

/// Radio / radioButton / select — Yes/No style choice fields from workflow API.
bool isKycChoiceFieldType(String? type) {
  final t = (type ?? '').toLowerCase().trim();
  return t == 'radio' || t == 'radiobutton' || t == 'select';
}

Map<String, String> _mergeAddressMaps(
  Map<String, String> base,
  Map<String, String> overlay,
) {
  final out = Map<String, String>.from(base);
  for (final e in overlay.entries) {
    if (e.value.trim().isNotEmpty) out[e.key] = e.value.trim();
  }
  return out;
}

bool _isExcludedAddressSourceKey(String key) {
  final k = key.toLowerCase();
  if (k.contains('nominee') || k.contains('guardian')) return true;
  if (k.contains('bank_') || k.startsWith('bank')) return true;
  if (k.contains('otp') || k.contains('stamp') || k.contains('proof')) {
    return true;
  }
  return false;
}

void _assignAddressComponent(
  Map<String, String> result,
  String fieldName,
  String value,
) {
  if (value.trim().isEmpty || _isExcludedAddressSourceKey(fieldName)) return;
  final k = fieldName.toLowerCase();

  if (result['add1']!.isEmpty &&
      (k == 'add1' ||
          k.endsWith('_add1') ||
          k.contains('address_line_1') ||
          k.contains('address_line1') ||
          (k.contains('address') &&
              !k.contains('2') &&
              !k.contains('email')))) {
    result['add1'] = value.trim();
    return;
  }
  if (result['add2']!.isEmpty &&
      (k == 'add2' ||
          k.endsWith('_add2') ||
          k.contains('address_line_2') ||
          k.contains('address_line2'))) {
    result['add2'] = value.trim();
    return;
  }
  if (result['city']!.isEmpty &&
      (k == 'city' || (k.endsWith('_city') && !k.contains('nominee')))) {
    result['city'] = value.trim();
    return;
  }
  if (result['state']!.isEmpty &&
      (k == 'state' || (k.endsWith('_state') && !k.contains('nominee')))) {
    result['state'] = value.trim();
    return;
  }
  if (result['country']!.isEmpty &&
      (k == 'country' || (k.endsWith('_country') && !k.contains('nominee')))) {
    result['country'] = value.trim();
    return;
  }
  if (result['pincode']!.isEmpty &&
      (k == 'pincode' ||
          k.contains('pincode') ||
          k.contains('pin_code') ||
          k.contains('zipcode') ||
          k.contains('postal'))) {
    result['pincode'] = value.trim();
  }
}

/// Reads the same address the API used to pre-fill nominee1 fields on page load.
Map<String, String> extractUserAddressFromNomineePrefill({
  required Map<String, dynamic> formData,
  List<dynamic>? stepFields,
}) {
  final result = _emptyUserAddressMap();
  for (final entry in kNomineePrefillToAddressComponent.entries) {
    final fromForm = formData[entry.key]?.toString().trim();
    if (fromForm != null && fromForm.isNotEmpty) {
      result[entry.value] = fromForm;
    }
  }
  if (stepFields != null) {
    for (final f in stepFields) {
      if (f is! Map) continue;
      final name = f['name']?.toString();
      final component = name != null ? kNomineePrefillToAddressComponent[name] : null;
      if (component == null) continue;
      final val = f['value']?.toString().trim();
      if (val != null && val.isNotEmpty) {
        result[component] = val;
      }
    }
  }
  return result;
}

Map<String, String> resolveUserAddressFromFormData(Map<String, dynamic> formData) {
  var result = _emptyUserAddressMap();
  for (final component in _userAddressAliases.keys) {
    for (final alias in _userAddressAliases[component]!) {
      if (_isExcludedAddressSourceKey(alias)) continue;
      final v = formData[alias];
      if (v != null && v.toString().trim().isNotEmpty) {
        result[component] = v.toString().trim();
        break;
      }
    }
  }
  for (final e in formData.entries) {
    _assignAddressComponent(result, e.key.toString(), e.value?.toString() ?? '');
  }
  return result;
}

Map<String, String> resolveAddressFromFieldDefinitions(List<dynamic> fields) {
  final result = _emptyUserAddressMap();
  for (final f in fields) {
    if (f is! Map) continue;
    final name = f['name']?.toString() ?? '';
    final val = f['value']?.toString().trim() ?? '';
    if (val.isEmpty) continue;
    final nomineeComponent = kNomineePrefillToAddressComponent[name];
    if (nomineeComponent != null) {
      result[nomineeComponent] = val;
    } else {
      _assignAddressComponent(result, name, val);
    }
  }
  return result;
}

void _deepScanAddressInto(Map<String, String> result, dynamic node, [int depth = 0]) {
  if (depth > 15 || node == null) return;
  if (node is Map) {
    for (final e in node.entries) {
      final key = e.key.toString();
      final val = e.value;
      if (val is! Map && val is! List) {
        final str = val?.toString() ?? '';
        final nomineeComponent = kNomineePrefillToAddressComponent[key];
        if (nomineeComponent != null && str.trim().isNotEmpty) {
          if (result[nomineeComponent]!.isEmpty) {
            result[nomineeComponent] = str.trim();
          }
        } else {
          _assignAddressComponent(result, key, str);
        }
      } else {
        _deepScanAddressInto(result, val, depth + 1);
      }
    }
  } else if (node is List) {
    for (final item in node) {
      _deepScanAddressInto(result, item, depth + 1);
    }
  }
}

/// Cache applicant address from form + get-context for nominee copy.
void refreshUserAddressCache({
  required Map<String, dynamic> formData,
  dynamic fieldsWithAuth,
  List<dynamic>? stepFields,
}) {
  // Priority 1: nominee1 API prefill (same source as old on-load address display).
  var merged = extractUserAddressFromNomineePrefill(
    formData: formData,
    stepFields: stepFields,
  );
  merged = _mergeAddressMaps(merged, resolveUserAddressFromFormData(formData));
  if (stepFields != null) {
    merged = _mergeAddressMaps(
      merged,
      resolveAddressFromFieldDefinitions(stepFields),
    );
  }
  if (fieldsWithAuth != null) {
    final scanned = _emptyUserAddressMap();
    _deepScanAddressInto(scanned, fieldsWithAuth);
    merged = _mergeAddressMaps(merged, scanned);
  }
  if (merged.values.any((v) => v.isNotEmpty)) {
    _cachedUserAddress = merged;
    debugPrint('[ConditionalForm] User address cache updated: $_cachedUserAddress');
  }
}

void clearUserAddressCache() => _cachedUserAddress = _emptyUserAddressMap();

Map<String, String> getUserAddressForNomineeCopy(Map<String, dynamic> formData) {
  if (_cachedUserAddress.values.any((v) => v.isNotEmpty)) {
    return Map<String, String>.from(_cachedUserAddress);
  }
  return resolveUserAddressFromFormData(formData);
}

String _stripFieldKeyPrefix(String key) =>
    key.trim().replaceFirst(RegExp(r'^\$'), '');

/// True when [s] looks like a field key (e.g. aadhar_address), not real address text.
/// Single-word values like "Pilibhit" or "India" are real city/country names, not keys.
bool looksLikeAddressFieldKey(String s) {
  final t = _stripFieldKeyPrefix(s);
  if (t.isEmpty) return true;
  if (t.contains(' ')) return false;
  final lower = t.toLowerCase();
  const bareComponentKeys = {
    'add1',
    'add2',
    'city',
    'state',
    'country',
    'pincode',
    'address',
    'dist',
    'district',
  };
  if (bareComponentKeys.contains(lower)) return true;
  if (t.contains('_')) return true;
  if (lower.startsWith('aadhar') ||
      lower.startsWith('nominee') ||
      lower.startsWith('guardian') ||
      lower.startsWith('perm_') ||
      lower.startsWith('corr_')) {
    return true;
  }
  return false;
}

const Map<String, String> _kAadharKeyByAddressComponent = {
  'add1': 'aadhar_address',
  'add2': 'aadhar_address',
  'city': 'aadhar_dist',
  'state': 'aadhar_state',
  'country': 'aadhar_country',
  'pincode': 'aadhar_pincode',
};

/// When API omits `prepopulateValue` (e.g. nominee10_*), use same aadhar sources as nominee7.
String? defaultAadharSourceKeyForNomineeAddressField(String targetFieldName) {
  final component = _getNomineeAddressSourceField(targetFieldName);
  if (component == null) return null;
  return _kAadharKeyByAddressComponent[component];
}

/// Resolve a stored value or field-key placeholder to real address text.
String lookupAddressValueByFieldKey(
  String key,
  Map<String, String> index,
  Map<String, dynamic> formData,
) {
  final k = _stripFieldKeyPrefix(key);
  if (k.isEmpty) return '';
  for (final candidate in [k, '\$$k']) {
    final fromIndex = index[candidate];
    if (fromIndex != null &&
        fromIndex.isNotEmpty &&
        !looksLikeAddressFieldKey(fromIndex)) {
      return fromIndex;
    }
    final fromForm = formData[candidate]?.toString().trim();
    if (fromForm != null &&
        fromForm.isNotEmpty &&
        !looksLikeAddressFieldKey(fromForm)) {
      return fromForm;
    }
  }
  return '';
}

String _resolveStoredAddressValue(
  String raw,
  Map<String, String> index,
  Map<String, dynamic> formData,
) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  if (looksLikeAddressFieldKey(trimmed)) {
    return lookupAddressValueByFieldKey(trimmed, index, formData);
  }
  return trimmed;
}

/// Turn cached `$aadhar_*` placeholders into real address lines for same-as copy.
Map<String, String> resolveUserAddressMapForNomineeCopy({
  required Map<String, String> raw,
  required Map<String, String> index,
  required Map<String, dynamic> formData,
}) {
  final out = _emptyUserAddressMap();
  for (final component in _kAadharKeyByAddressComponent.keys) {
    var v = _resolveStoredAddressValue(raw[component] ?? '', index, formData);
    if (v.isEmpty) {
      final aadharKey = _kAadharKeyByAddressComponent[component];
      if (aadharKey != null) {
        v = lookupAddressValueByFieldKey(aadharKey, index, formData);
      }
    }
    if (v.isNotEmpty) out[component] = v;
  }
  if (out.values.every((v) => v.isEmpty)) {
    return _mergeAddressMaps(out, resolveUserAddressFromFormData(formData));
  }
  return out;
}

/// Copy from another nominee slot on this step (e.g. nominee7_add1 → nominee10_add1).
String? copyFromFilledNomineeAddressField({
  required String targetFieldName,
  required Map<String, dynamic> formData,
}) {
  final component = _getNomineeAddressSourceField(targetFieldName);
  if (component == null) return null;
  for (final e in formData.entries) {
    final name = e.key.toString();
    if (name == targetFieldName) continue;
    if (_getNomineeAddressSourceField(name) != component) continue;
    final v = e.value?.toString().trim() ?? '';
    if (v.isNotEmpty && !looksLikeAddressFieldKey(v)) return v;
  }
  return null;
}

/// Parses API `prepopulateValue` → source field name (e.g. aadhar_address).
String? parsePrepopulateSourceFieldName(dynamic prepopulateValue) {
  if (prepopulateValue == null) return null;
  if (prepopulateValue is String) {
    final s = prepopulateValue.trim();
    if (s.isEmpty || s.toLowerCase() == 'select') return null;
    return _stripFieldKeyPrefix(s);
  }
  if (prepopulateValue is List && prepopulateValue.isNotEmpty) {
    final first = prepopulateValue.first;
    if (first is Map) {
      final v = first['value']?.toString() ?? first['label']?.toString();
      if (v != null && v.trim().isNotEmpty) {
        return _stripFieldKeyPrefix(v);
      }
    }
  }
  return null;
}

/// Index field name → value from formData, step fields, and full get-context payload.
Map<String, String> buildFieldValueIndex({
  required Map<String, dynamic> formData,
  List<dynamic>? stepFields,
  dynamic fieldsWithAuth,
}) {
  final index = <String, String>{};

  void put(String? name, dynamic value) {
    if (name == null) return;
    final v = value?.toString().trim() ?? '';
    if (v.isEmpty || looksLikeAddressFieldKey(v)) return;
    index[name] = v;
  }

  for (final e in formData.entries) {
    put(e.key.toString(), e.value);
  }

  if (stepFields != null) {
    for (final f in stepFields) {
      if (f is! Map) continue;
      put(f['name']?.toString(), f['value']);
    }
  }

  void walk(dynamic node, [int depth = 0]) {
    if (depth > 20 || node == null) return;
    if (node is Map) {
      if (node.containsKey('name') && node.containsKey('value')) {
        put(node['name']?.toString(), node['value']);
      }
      for (final v in node.values) {
        walk(v, depth + 1);
      }
    } else if (node is List) {
      for (final item in node) {
        walk(item, depth + 1);
      }
    }
  }

  walk(fieldsWithAuth);
  return index;
}

/// Resolves one nominee field using API `value` then `prepopulateValue` source lookup.
String resolveNomineeTargetAddressValue({
  required String targetFieldName,
  required Map<String, dynamic> formData,
  List<dynamic>? stepFields,
  dynamic fieldsWithAuth,
}) {
  Map<dynamic, dynamic>? fieldDef;
  if (stepFields != null) {
    for (final f in stepFields) {
      if (f is Map && f['name']?.toString() == targetFieldName) {
        fieldDef = f;
        break;
      }
    }
  }

  final index = buildFieldValueIndex(
    formData: formData,
    stepFields: stepFields,
    fieldsWithAuth: fieldsWithAuth,
  );

  if (fieldDef != null) {
    final ownValue = fieldDef['value']?.toString().trim() ?? '';
    if (ownValue.isNotEmpty && !looksLikeAddressFieldKey(ownValue)) {
      return ownValue;
    }

    var sourceKey = parsePrepopulateSourceFieldName(fieldDef['prepopulateValue']);
    sourceKey ??= defaultAadharSourceKeyForNomineeAddressField(targetFieldName);
    if (sourceKey != null) {
      final resolved = lookupAddressValueByFieldKey(sourceKey, index, formData);
      if (resolved.isNotEmpty) return resolved;
    }
  }

  return copyFromFilledNomineeAddressField(
        targetFieldName: targetFieldName,
        formData: formData,
      ) ??
      '';
}

/// Fill or clear nominee address using each field's API prepopulateValue mapping.
void syncNomineeAddressFromSameAsCheckbox(
  Map<String, dynamic> formData,
  String checkboxName,
  dynamic checkboxValue, {
  List<dynamic>? stepFields,
  dynamic fieldsWithAuth,
}) {
  final targets =
      resolveNomineeSameAsAddressGroups(stepFields)[checkboxName];
  if (targets == null) return;

  if (isCheckboxCheckedValue(checkboxValue)) {
    refreshUserAddressCache(
      formData: formData,
      fieldsWithAuth: fieldsWithAuth,
      stepFields: stepFields,
    );
    final index = buildFieldValueIndex(
      formData: formData,
      stepFields: stepFields,
      fieldsWithAuth: fieldsWithAuth,
    );
    final userAddr = resolveUserAddressMapForNomineeCopy(
      raw: getUserAddressForNomineeCopy(formData),
      index: index,
      formData: formData,
    );
    for (final target in targets) {
      var val = '';
      final component = _getNomineeAddressSourceField(target);
      if (component != null) {
        val = userAddr[component]?.trim() ?? '';
      }
      if (val.isEmpty) {
        val = resolveNomineeTargetAddressValue(
          targetFieldName: target,
          formData: formData,
          stepFields: stepFields,
          fieldsWithAuth: fieldsWithAuth,
        );
      }
      if (val.isEmpty) {
        val = copyFromFilledNomineeAddressField(
              targetFieldName: target,
              formData: formData,
            ) ??
            '';
      }
      formData[target] = val;
      debugPrint('[ConditionalForm] Same-as fill $target <- "$val"');
    }
  } else {
    for (final target in targets) {
      formData[target] = '';
    }
  }
}

/// On load: keep nominee address only when that nominee's checkbox is checked.
void clearNomineeAddressesWhenUnchecked(
  Map<String, dynamic> formData, {
  List<dynamic>? stepFields,
}) {
  final groups = resolveNomineeSameAsAddressGroups(stepFields);
  for (final entry in groups.entries) {
    if (!isCheckboxCheckedValue(formData[entry.key])) {
      for (final field in entry.value) {
        formData[field] = '';
      }
    }
  }
}

/// Maps nominee address fields to user's address fields for prePopulate
String? _getNomineeAddressSourceField(String nomineeField) {
  // Map nominee1_add1 -> add1, address_line1, current_add1, etc.
  if (nomineeField.endsWith('_add1')) return 'add1';
  if (nomineeField.endsWith('_add2')) return 'add2';
  if (nomineeField.endsWith('_city') ||
      RegExp(r'nominee_\d+_city').hasMatch(nomineeField)) {
    return 'city';
  }
  if (nomineeField.endsWith('_state')) return 'state';
  if (nomineeField.endsWith('_country')) return 'country';
  if (nomineeField.endsWith('_pincode')) return 'pincode';
  return null;
}

/// Gets address value from formData, trying multiple field name variants
String _getAddressValue(Map<String, dynamic> formData, String baseField) {
  // Try exact match first
  if (formData[baseField] != null && formData[baseField].toString().trim().isNotEmpty) {
    return formData[baseField].toString();
  }
  // Try common variants
  final variants = [
    baseField,
    'current_$baseField',
    'permanent_$baseField',
    '${baseField}_line1', // for add1
    'address_$baseField',
  ];
  for (final variant in variants) {
    final val = formData[variant];
    if (val != null && val.toString().trim().isNotEmpty) {
      return val.toString();
    }
  }
  return '';
}

ConditionalFlowState evaluateConditionalFlowForField(
  List<dynamic>? conditionalFlow,
  Map<String, dynamic> formData,
  String changedFieldName,
) {
  final state = ConditionalFlowState(
    formData: Map.from(formData),
  );

  final conditions = getConditionsForField(conditionalFlow, changedFieldName);

  for (final condition in conditions) {
    final fieldValue = formData[condition['field']];
    var inputValue = condition['inputValue'];
    final operator = condition['operator'] ?? 'equals';
    
    // For age-based conditions (DOB fields), use dateValue ONLY if inputValue is empty
    final dateType = condition['dateType'];
    final dateValue = condition['dateValue'];
    if (dateType != null && dateValue != null && 
        (inputValue == null || inputValue.toString().trim().isEmpty)) {
      inputValue = dateValue;
      debugPrint('[ConditionalForm] Age condition: field=${condition['field']}, operator=$operator, dateValue=$dateValue');
    }
    
    final opFn = _conditionOperators[operator];
    if (opFn == null) continue;
    
    final matches = opFn(fieldValue, inputValue);
    if (!matches) continue;
    
    debugPrint('[ConditionalForm] ✅ Condition matched: ${condition['field']} $operator $inputValue');

    final thenList = condition['then'];
    if (thenList is! List) continue;

    for (final action in thenList) {
      if (action is! Map) continue;
      final actionType = action['action']?.toString();
      final selected = action['selectedoption']?.toString();
      if (selected == null || selected.isEmpty) continue;

      switch (actionType) {
        case 'hide':
          state.fieldVisibility[selected] = false;
          debugPrint('[ConditionalForm] 🔒 Hide: $selected');
          break;
        case 'show':
          state.fieldVisibility[selected] = true;
          debugPrint('[ConditionalForm] 👁️ Show: $selected');
          break;
        case 'empty':
          state.formData[selected] = '';
          break;
        case 'prePopulate':
          var prePopValue = action['value']?.toString() ?? '';
          final triggerField = condition['field']?.toString() ?? '';
          // Copy user address only for "same as my address" checkbox rules.
          if (prePopValue.isEmpty &&
              triggerField.contains('same_as_my_address')) {
            final sourceField = _getNomineeAddressSourceField(selected);
            if (sourceField != null) {
              prePopValue = _getAddressValue(formData, sourceField);
            }
          }
          state.formData[selected] = prePopValue;
          break;
        case 'true':
          state.formData[selected] = true;
          break;
        case 'false':
          state.formData[selected] = false;
          break;
        case 'enable':
          final enableVal = action['enable'];
          state.fieldEditable[selected] = enableVal == true || enableVal == 1;
          break;
        case 'disable':
          state.fieldEditable[selected] = true;
          break;
      }
    }
  }

  return state;
}

List<String> getWatchedFields(List<dynamic>? conditionalFlow) {
  if (conditionalFlow == null) return [];
  final set = <String>{};
  for (final c in conditionalFlow) {
    if (c is Map && c['field'] != null) set.add(c['field'].toString());
  }
  return set.toList();
}

bool _jsonTruthy(dynamic v) {
  if (v == true) return true;
  if (v == false || v == null) return false;
  if (v is num) return v != 0;
  final s = v.toString().trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes';
}

/// Whether get-context / workflow lists this field for the end-user form.
///
/// Uses [adminFieldShow]: when true, the field is treated as visible even if
/// `fieldShow` is false. **Only use this on BP Wealth `personal_details`** (see
/// [kycFieldVisibleForFormStep]); on all other steps use [kycApiFieldVisibleStrictFieldShow]
/// so `fieldShow: false` stays hidden (old app behaviour).
bool kycApiFieldInitiallyVisible(Map<dynamic, dynamic> f) {
  if (_jsonTruthy(f['adminFieldShow'])) return true;
  final fs = f['fieldShow'];
  if (fs == null) return true;
  return _jsonTruthy(fs);
}

/// Visibility from `fieldShow` only — same as legacy `getVisibleFields` (`fieldShow ?? true`).
/// Does **not** look at `adminFieldShow` (admin-only fields must not appear on nominee etc.).
bool kycApiFieldVisibleStrictFieldShow(Map<dynamic, dynamic> f) {
  final fs = f['fieldShow'];
  if (fs == null) return true;
  return _jsonTruthy(fs);
}

/// BP Wealth `personal_details` only: standing-instruction style questions that the
/// web UI shows even when `fieldShow` is false (expandable on web). Do not use globally.
const Set<String> kBpWealthPersonalDetailsStandingFieldNames = {
  'electronic_transaction',
  'annual_report',
  'receive_contract',
  'directly_bank_account',
  'credit_account',
  'rta',
  'dp_accept',
  'sebi_3years',
  'debitbalance',
  // Web "Standing Instructions" accordion — common API name variants
  'holding_cum_transaction_statement',
  'holding_transaction_statement',
  'transaction_statement_frequency',
  'cum_holding_statement',
  'holding_statement_frequency',
  'statement_frequency',
  'cum_transaction_statement',
  'dis_booklet',
  'dis_book',
  'dis',
  'delivery_instruction_slip',
  'dis_slip',
  'running_account_authorization',
  'running_account',
  'running_ac_authorization',
  'raa',
};

/// BP Wealth personal_details — fields in the **main** block (web 2nd screenshot only).
const Set<String> kBpWealthPersonalDetailsMainScreenFieldNames = {
  'fathers_name',
  'father_name',
  'father',
  'fathername',
  'mothers_name',
  'mother_name',
  'mother',
  'mothername',
  'gender',
  'marital_status',
  'maritalstatus',
  'education',
  'annual_income',
  'income',
  'gross_annual_income',
  'annualincome',
  'trading_experience',
  'tradingexperience',
  'politically_exposed',
  'pep',
  'political_exposed',
  'occupation',
  'citizen_of_india',
  'citizen',
  'indian_citizen',
  'citizenindia',
  'ddpi',
  'execute_ddpi',
  'demat_debit_pledge',
  'tax_residency',
  'tax_residency_outside_india',
  'taxresidency',
  'penny_drop_condition',
};

/// DP / tariff consent checkbox — **outside** Standing Instructions accordion (web design).
bool bpWealthPersonalDetailsTariffConsentCheckboxField(Map<dynamic, dynamic> f) {
  if ((f['type']?.toString() ?? '').toLowerCase() != 'checkbox') return false;
  final dn = (f['displayName']?.toString() ?? '').toLowerCase();
  return dn.contains('standing instruction') || dn.contains('tariff structure');
}

/// Combined user-facing copy (API sometimes uses [label] / [title] instead of [displayName]).
String bpWealthFieldUserFacingTextLower(Map<dynamic, dynamic> f) {
  final buf = StringBuffer();
  for (final k in ['displayName', 'label', 'title', 'placeholder', 'question']) {
    final s = f[k]?.toString().trim();
    if (s == null || s.isEmpty) continue;
    if (buf.isNotEmpty) buf.write(' ');
    buf.write(s);
  }
  return buf.toString().toLowerCase();
}

/// DDPI (Demat Debit Pledge Instructions) — field [name] varies across workflows.
bool isDdpiFormField(Map<dynamic, dynamic> f) {
  final nl = (f['name']?.toString() ?? '').toLowerCase();
  if (nl == 'ddpi' ||
      nl == 'execute_ddpi' ||
      nl == 'demat_debit_pledge' ||
      nl.contains('ddpi') ||
      nl.contains('demat_debit')) {
    return true;
  }
  final dn = bpWealthFieldUserFacingTextLower(f);
  return dn.contains('ddpi') ||
      (dn.contains('demat') && dn.contains('debit') && dn.contains('pledge'));
}

/// User selected Yes / affirmative (radio, select, or checkbox).
bool isAffirmativeYesValue(dynamic value) {
  if (value == null) return false;
  if (value is bool) return value;
  final s = value.toString().trim().toLowerCase();
  if (s.isEmpty) return false;
  return s == 'yes' || s == 'y' || s == 'true' || s == '1' || s.startsWith('yes');
}

/// User selected Yes / affirmative for DDPI (radio, select, or checkbox).
bool isDdpiAffirmativeValue(dynamic value) => isAffirmativeYesValue(value);

/// Personal details — politically exposed person (PEP).
bool bpWealthPersonalDetailsPoliticallyExposedField(Map<dynamic, dynamic> f) {
  final nl = (f['name']?.toString() ?? '').toLowerCase();
  if (nl.contains('pep') ||
      nl == 'politically_exposed' ||
      nl == 'political_exposed' ||
      (nl.contains('political') && nl.contains('expos'))) {
    return true;
  }
  final dn = bpWealthFieldUserFacingTextLower(f);
  return dn.contains('politically') ||
      (dn.contains('political') &&
          (dn.contains('expos') || dn.contains('pep') || dn.contains('person')));
}

/// Personal details — tax residency outside India (FATCA).
bool isTaxResidencyOutsideIndiaField(Map<dynamic, dynamic> f) {
  final nl = (f['name']?.toString() ?? '').toLowerCase();
  if (nl.contains('tax_resid') ||
      nl == 'taxresidency' ||
      nl.contains('taxresidency') ||
      (nl.contains('tax') && nl.contains('residen'))) {
    return true;
  }
  final dn = bpWealthFieldUserFacingTextLower(f);
  return (dn.contains('tax') && dn.contains('residen')) ||
      (dn.contains('residen') && dn.contains('outside')) ||
      dn.contains('fatca');
}

/// KRA review step — fetched KRA data is display-only (live web parity).
bool isKraDetailsStep(String? position, String? pageLabel) {
  final p = (position ?? '').toLowerCase();
  final l = (pageLabel ?? '').toLowerCase();
  return p == 'kradetails' || l == 'kradetails';
}

/// "Do You Want to continue with KRA details?" — user must be able to select Yes/No.
bool kraDetailsContinueWithKraChoiceField(Map<dynamic, dynamic> field) {
  final nl = (field['name']?.toString() ?? '').toLowerCase();
  if (nl == 'kradetail' ||
      nl == 'kra_detail' ||
      nl == 'continue_with_kra' ||
      (nl.contains('kra') && nl.contains('continue'))) {
    return true;
  }
  final dn = bpWealthFieldUserFacingTextLower(field);
  return dn.contains('continue') && dn.contains('kra');
}

/// Applicant address inputs on KRA review (not nominee/bank/guardian).
bool isKraAddressComponentField(Map<dynamic, dynamic> field) {
  final n = (field['name']?.toString() ?? '').toLowerCase().trim();
  if (n.isEmpty) return false;
  if (n.contains('nominee') ||
      n.contains('guardian') ||
      n.contains('bank') ||
      n.contains('ifsc')) {
    return false;
  }
  if (n.startsWith('kra_add') ||
      n.startsWith('kraaddress') ||
      n == 'kra_address' ||
      n == 'kraaddress') {
    return true;
  }
  for (final aliases in _userAddressAliases.values) {
    if (aliases.contains(n)) return true;
  }
  // Common KRA keys not always in the alias table.
  if (n == 'add1' ||
      n == 'add2' ||
      n == 'city' ||
      n == 'state' ||
      n == 'country' ||
      n == 'pincode' ||
      n == 'pin_code' ||
      n.contains('add_line') ||
      n.endsWith('_add1') ||
      n.endsWith('_add2') ||
      n.endsWith('_city') ||
      n.endsWith('_state') ||
      n.endsWith('_country') ||
      n.endsWith('_pincode')) {
    return !n.contains('nominee') && !n.contains('guardian');
  }
  final dn = bpWealthFieldUserFacingTextLower(field);
  if (dn.contains('address line') ||
      dn == 'address' ||
      dn == 'city' ||
      dn == 'state' ||
      dn == 'country' ||
      dn.contains('pincode') ||
      dn.contains('pin code') ||
      dn.contains('postal code')) {
    return true;
  }
  return false;
}

/// Single-line / multi-line display for KRA address summary.
String formatKraAddressDisplay(Map<String, dynamic> formData) {
  final addr = getUserAddressForNomineeCopy(formData);
  final parts = <String>[
    addr['add1'] ?? '',
    addr['add2'] ?? '',
    addr['city'] ?? '',
    addr['state'] ?? '',
    addr['country'] ?? '',
    addr['pincode'] ?? '',
  ].map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  return parts.join(', ');
}

/// On [isKraDetailsStep], fetched KRA inputs are read-only; [kraDetailsContinueWithKraChoiceField] stays editable.
bool kraDetailsFormFieldReadOnly(Map<dynamic, dynamic> field) {
  if (kraDetailsContinueWithKraChoiceField(field)) return false;
  final type = (field['type']?.toString() ?? '').toLowerCase();
  return type != 'button' && type != 'hidden';
}

/// DigiLocker review step — Aadhaar/PAN data fetched from DigiLocker is display-only.
bool isDigilockerStep(String? position, String? pageLabel) {
  final p = (position ?? '').toLowerCase();
  final l = (pageLabel ?? '').toLowerCase();
  return p == 'digilocker' || l == 'digilocker';
}

/// On [isDigilockerStep], all visible inputs (name, DOB, address, photo, etc.) are read-only.
bool digilockerFormFieldReadOnly(Map<dynamic, dynamic> field) {
  final type = (field['type']?.toString() ?? '').toLowerCase();
  return type != 'button' && type != 'hidden';
}

bool isAadharImageFieldName(String? name) {
  final n = (name ?? '').toLowerCase();
  return n == 'aadhar_image' || n == 'aadhaar_image';
}

/// Reads `user-details` payload (`{ data: { ... } }` or flat map).
Map<String, dynamic>? userDetailsDataMap(dynamic userDetails) {
  if (userDetails is! Map) return null;
  final data = userDetails['data'];
  if (data is Map<String, dynamic>) return data;
  if (data is Map) return Map<String, dynamic>.from(data);
  return Map<String, dynamic>.from(userDetails);
}

/// Best Aadhaar photo for DigiLocker card: user-details → get-context `value` → formData.
/// `adharimg` is legacy fallback when `aadhar_image` is empty.
String? resolveDigilockerAadharImageRaw({
  dynamic userDetails,
  dynamic fieldValue,
  dynamic formValue,
}) {
  String? pick(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }

  final ud = userDetailsDataMap(userDetails);
  final fromUser =
      pick(ud?['aadhar_image']) ?? pick(ud?['adharimg']) ?? pick(ud?['aadhaar_image']);

  return fromUser ?? pick(fieldValue) ?? pick(formValue);
}

/// Cache-bust version for remote bucket URLs (e.g. after new DigiLocker fetch).
String? digilockerAadharImageCacheBustVersion(dynamic userDetails) {
  final ud = userDetailsDataMap(userDetails);
  if (ud == null) return null;
  for (final key in [
    'digilocker_timestamp',
    'detailspan_timestamp',
    'digitrans',
  ]) {
    final v = ud[key]?.toString().trim();
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

/// Appends `v=` query param so [Image.network] reloads after DigiLocker refresh.
String cacheBustDocumentUrl(String url, {String? version}) {
  if (version == null || version.trim().isEmpty) return url;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme) return url;
  final q = Map<String, String>.from(uri.queryParameters);
  q['v'] = version.trim();
  return uri.replace(queryParameters: q).toString();
}

/// Fetched-data review steps where most fields must not be edited (KRA, DigiLocker).
bool fetchedDataReviewFieldReadOnly(
  String? position,
  String? pageLabel,
  Map<dynamic, dynamic> field,
) {
  if (isKraDetailsStep(position, pageLabel)) {
    return kraDetailsFormFieldReadOnly(field);
  }
  if (isDigilockerStep(position, pageLabel)) {
    return digilockerFormFieldReadOnly(field);
  }
  return false;
}

/// "How frequently do you want to receive your holding cum Transaction statement?" —
/// backend [name] varies; match by user-facing text and common [name] substrings.
bool bpWealthPersonalDetailsHoldingStatementFrequencyField(
  Map<dynamic, dynamic> f,
) {
  final nl = (f['name']?.toString() ?? '').toLowerCase();
  if (nl.contains('holding') &&
      nl.contains('statement') &&
      (nl.contains('transaction') ||
          nl.contains('cum') ||
          nl.contains('freq') ||
          nl.contains('stmt'))) {
    return true;
  }

  final dn = bpWealthFieldUserFacingTextLower(f);
  if (dn.isEmpty) return false;

  final hasHolding = dn.contains('holding');
  final hasStatement = dn.contains('statement');
  final hasTransaction = dn.contains('transaction');
  final hasCum = dn.contains('cum');
  final hasFreq = dn.contains('frequen') || dn.contains('how often');

  if (hasHolding &&
      hasStatement &&
      (hasTransaction || hasCum || hasFreq || dn.contains('receive'))) {
    return true;
  }
  if (hasStatement &&
      hasFreq &&
      (hasTransaction || hasCum || hasHolding || dn.contains('sebi'))) {
    return true;
  }
  return false;
}

/// DIS booklet delivery frequency — dropdown with Quarterly / Monthly (label varies).
bool bpWealthPersonalDetailsDisBookletFrequencyField(
  Map<dynamic, dynamic> f,
) {
  if (bpWealthPersonalDetailsHoldingStatementFrequencyField(f)) return false;
  final values = f['values'] as List?;
  if (values == null || values.length < 2) return false;
  final lowered = values.map((o) => o.toString().toLowerCase()).toList();
  final hasQuarter = lowered.any((s) => s.contains('quarter'));
  final hasMonth = lowered.any((s) => s.contains('month'));
  if (!hasQuarter || !hasMonth) return false;

  final dn = bpWealthFieldUserFacingTextLower(f);
  final nl = (f['name']?.toString() ?? '').toLowerCase();
  if (dn.contains('delivery instruction') ||
      dn.contains('dis booklet') ||
      dn.contains('dis slip') ||
      (dn.contains('dis') && dn.contains('booklet')) ||
      nl.contains('dis_book') ||
      nl.contains('delivery_instruction') ||
      nl == 'dis' ||
      nl.contains('dis_slip')) {
    return true;
  }
  return false;
}

/// Running Account Authorization — Quarterly / Monthly (standing instructions).
bool bpWealthPersonalDetailsRunningAccountAuthorizationField(
  Map<dynamic, dynamic> f,
) {
  if (bpWealthPersonalDetailsHoldingStatementFrequencyField(f)) return false;
  if (bpWealthPersonalDetailsDisBookletFrequencyField(f)) return false;
  final values = f['values'] as List?;
  if (values == null || values.length < 2) return false;
  final lowered = values.map((o) => o.toString().toLowerCase()).toList();
  final hasQuarter = lowered.any((s) => s.contains('quarter'));
  final hasMonth = lowered.any((s) => s.contains('month'));
  if (!hasQuarter || !hasMonth) return false;

  final nl = (f['name']?.toString() ?? '').toLowerCase();
  if (nl.contains('running_account') ||
      nl.contains('running_ac') ||
      nl == 'raa') {
    return true;
  }
  final dn = bpWealthFieldUserFacingTextLower(f);
  return dn.contains('running account') && dn.contains('author');
}

/// Text input when user answers Yes on SEBI past-actions question (`sebi_3years`).
bool bpWealthPersonalDetailsPastActionField(Map<dynamic, dynamic> f) {
  final name = f['name']?.toString();
  if (name == 'past_action' || name == 'past_actions') return true;
  final nl = (name ?? '').toLowerCase();
  if (nl == 'past_action' ||
      nl == 'past_actions' ||
      nl.contains('past_action')) {
    return true;
  }
  final dn = bpWealthFieldUserFacingTextLower(f);
  if (dn.contains('past action') &&
      (dn.contains('sebi') || dn.contains('exchange'))) {
    return true;
  }
  return false;
}

/// Fields rendered **inside** the Standing Instructions expandable only (not tariff consent).
bool bpWealthPersonalDetailsStandingSectionField(Map<dynamic, dynamic> f) {
  final name = f['name']?.toString();
  if (name != null &&
      kBpWealthPersonalDetailsStandingFieldNames.contains(name)) {
    return true;
  }
  return bpWealthPersonalDetailsHoldingStatementFrequencyField(f) ||
      bpWealthPersonalDetailsDisBookletFrequencyField(f) ||
      bpWealthPersonalDetailsRunningAccountAuthorizationField(f) ||
      bpWealthPersonalDetailsPastActionField(f);
}

bool bpWealthPersonalDetailsHideDobField(
  String? company,
  String? position,
  String? pageLabel,
  String? name,
) {
  if (!bpWealthPersonalDetailsStep(company, position, pageLabel)) return false;
  if (name == null) return false;
  final n = name.toLowerCase();
  if (n == 'dob') return true;
  if (n.contains('date_of_birth')) return true;
  if (n.contains('birth_date')) return true;
  if (n.contains('dob')) return true;
  return false;
}

bool bpWealthPersonalDetailsStep(
  String? company,
  String? position,
  String? pageLabel,
) {
  if (company == null) return false;
  if (company.toLowerCase().trim() != 'bpwealth') return false;
  final pos = position?.toLowerCase() ?? '';
  final label = pageLabel?.toLowerCase() ?? '';
  return pos == 'personal_details' || label == 'personal_details';
}

bool bpWealthPersonalDetailsForceShowStandingField(
  String? company,
  String? position,
  String? pageLabel,
  String? fieldName,
) {
  if (fieldName == null) return false;
  if (!bpWealthPersonalDetailsStep(company, position, pageLabel)) return false;
  return kBpWealthPersonalDetailsStandingFieldNames.contains(fieldName);
}

/// Same as [bpWealthPersonalDetailsForceShowStandingField] but includes holding/statement frequency by display text.
bool bpWealthPersonalDetailsForceShowStandingMap(
  String? company,
  String? position,
  String? pageLabel,
  Map<dynamic, dynamic> f,
) {
  if (!bpWealthPersonalDetailsStep(company, position, pageLabel)) return false;
  final name = f['name']?.toString();
  if (name != null &&
      kBpWealthPersonalDetailsStandingFieldNames.contains(name)) {
    return true;
  }
  return bpWealthPersonalDetailsHoldingStatementFrequencyField(f) ||
      bpWealthPersonalDetailsDisBookletFrequencyField(f) ||
      bpWealthPersonalDetailsRunningAccountAuthorizationField(f) ||
      bpWealthPersonalDetailsPastActionField(f);
}

/// API visibility plus BP Wealth personal-details standing override (fieldShow false).
bool kycFieldVisibleForFormStep(
  Map<dynamic, dynamic> f, {
  String? company,
  String? position,
  String? pageLabel,
}) {
  final name = f['name']?.toString();
  if (bpWealthPersonalDetailsHideDobField(company, position, pageLabel, name)) {
    return false;
  }
  if (bpWealthPersonalDetailsStep(company, position, pageLabel)) {
    if (bpWealthPersonalDetailsTariffConsentCheckboxField(f)) {
      return true;
    }
    if (bpWealthPersonalDetailsHoldingStatementFrequencyField(f)) {
      return kycApiFieldInitiallyVisible(f) ||
          bpWealthPersonalDetailsForceShowStandingMap(
            company,
            position,
            pageLabel,
            f,
          );
    }
    if (bpWealthPersonalDetailsDisBookletFrequencyField(f)) {
      return kycApiFieldInitiallyVisible(f) ||
          bpWealthPersonalDetailsForceShowStandingMap(
            company,
            position,
            pageLabel,
            f,
          );
    }
    if (bpWealthPersonalDetailsRunningAccountAuthorizationField(f)) {
      return kycApiFieldInitiallyVisible(f) ||
          bpWealthPersonalDetailsForceShowStandingMap(
            company,
            position,
            pageLabel,
            f,
          );
    }
    if (name == null) return false;
    if (kBpWealthPersonalDetailsMainScreenFieldNames.contains(name)) {
      // Web main grid only — show even if API hid the field.
      return true;
    }
    if (kBpWealthPersonalDetailsStandingFieldNames.contains(name)) {
      return kycApiFieldInitiallyVisible(f) ||
          bpWealthPersonalDetailsForceShowStandingField(
            company,
            position,
            pageLabel,
            name,
          );
    }
    return false;
  }
  // Non–personal_details: never honour adminFieldShow for UI (avoids extra fields on nominee etc.).
  return kycApiFieldVisibleStrictFieldShow(f);
}

/// `kyc-post-v2` body: only fields visible on the current step (web parity).
/// Drops stale keys from other steps (e.g. empty nominee_* on `pan10`).
Map<String, dynamic> filterKycPostV2BodyForStep({
  required Map<String, dynamic> data,
  required List<dynamic>? fields,
  required Map<String, bool> runtimeFieldVisibility,
  String? company,
  String? position,
  String? pageLabel,
  bool omitEmptyStrings = true,
}) {
  if (fields == null || fields.isEmpty) return data;

  final visible = getVisibleFields(
    fields,
    runtimeFieldVisibility,
    company: company,
    position: position,
    pageLabel: pageLabel,
  );

  final allowed = <String>{};
  for (final f in visible) {
    if (f is! Map) continue;
    final name = f['name']?.toString();
    if (name == null || name.isEmpty) continue;
    final type = (f['type']?.toString() ?? '').toLowerCase();
    if (type == 'button' || type == 'hidden') continue;
    allowed.add(name);
  }

  if (allowed.isEmpty) return data;

  // Computed nominee % totals (`fieldShow: false`, type hidden) must still post.
  // `extra_nominee` blank = backend skips additional_nominee when share is 100%.
  for (final name in [
    'total_nominee_percentage',
    'total_nominee_percentage2',
    'remain_nominee_percent',
    'remain_nominee_percent2',
    'extra_nominee',
  ]) {
    if (data.containsKey(name)) allowed.add(name);
  }

  final out = <String, dynamic>{};
  for (final name in allowed) {
    if (!data.containsKey(name)) continue;
    final v = data[name];
    if (v == null) continue;
    if (omitEmptyStrings && v is String && v.trim().isEmpty) {
      if (name == 'extra_nominee') {
        out[name] = '';
      }
      continue;
    }
    out[name] = v;
  }
  return out;
}

List<dynamic> getVisibleFields(
  List<dynamic> fields,
  Map<String, bool> fieldVisibility, {
  String? company,
  String? position,
  String? pageLabel,
}) {
  return fields.where((f) {
    if (f is! Map) return false;
    final name = f['name']?.toString();
    final show = kycFieldVisibleForFormStep(
      f,
      company: company,
      position: position,
      pageLabel: pageLabel,
    );
    if (name == null) {
      if (!bpWealthPersonalDetailsHoldingStatementFrequencyField(f) &&
          !bpWealthPersonalDetailsDisBookletFrequencyField(f) &&
          !bpWealthPersonalDetailsRunningAccountAuthorizationField(f) &&
          !bpWealthPersonalDetailsPastActionField(f)) {
        return false;
      }
      return show;
    }
    // Match home_page: conditional flow override wins over fieldShow.
    final dynamicVisibility = fieldVisibility[name];
    return dynamicVisibility ?? show;
  }).toList();
}

List<dynamic> getEditableFields(
  List<dynamic> fields,
  Map<String, bool>? fieldEditable,
) {
  if (fieldEditable == null) return [];
  return fields.where((f) {
    if (f is! Map) return false;
    final name = f['name']?.toString();
    if (name == null) return false;
    return fieldEditable[name] == true;
  }).toList();
}

ConditionalFlowState evaluateConditionalFlow(
  List<dynamic>? conditionalFlow,
  Map<String, dynamic> formData,
) {
  final state = ConditionalFlowState(formData: formData);
  if (conditionalFlow == null) return state;

  for (final condition in conditionalFlow) {
    if (condition is! Map) continue;
    final fieldValue = formData[condition['field']];
    var inputValue = condition['inputValue'];
    final operator = condition['operator'] ?? 'equals';
    
    // For age-based conditions (DOB fields), use dateValue ONLY if inputValue is empty
    final dateType = condition['dateType'];
    final dateValue = condition['dateValue'];
    if (dateType != null && dateValue != null && 
        (inputValue == null || inputValue.toString().trim().isEmpty)) {
      inputValue = dateValue;
    }
    
    final opFn = _conditionOperators[operator];
    if (opFn == null || !opFn(fieldValue, inputValue)) continue;

    final thenList = condition['then'];
    if (thenList is! List) continue;

    for (final action in thenList) {
      if (action is! Map) continue;
      final actionType = action['action']?.toString();
      final selected = action['selectedoption']?.toString();
      if (selected == null || selected.isEmpty) continue;

      switch (actionType) {
        case 'hide':
          state.fieldVisibility[selected] = false;
          debugPrint('[ConditionalForm] 🔒 Hide: $selected');
          break;
        case 'show':
          state.fieldVisibility[selected] = true;
          debugPrint('[ConditionalForm] 👁️ Show: $selected');
          break;
        case 'empty':
          state.formData[selected] = '';
          break;
        case 'prePopulate':
          var prePopValue = action['value']?.toString() ?? '';
          final triggerField = condition['field']?.toString() ?? '';
          if (prePopValue.isEmpty &&
              triggerField.contains('same_as_my_address')) {
            final sourceField = _getNomineeAddressSourceField(selected);
            if (sourceField != null) {
              prePopValue = _getAddressValue(formData, sourceField);
            }
          }
          state.formData[selected] = prePopValue;
          break;
        case 'true':
          state.formData[selected] = true;
          break;
        case 'false':
          state.formData[selected] = false;
          break;
        case 'enable':
          final enableVal = action['enable'];
          state.fieldEditable[selected] = enableVal == true || enableVal == 1;
          break;
        case 'disable':
          state.fieldEditable[selected] = true;
          break;
      }
    }
  }

  return state;
}
