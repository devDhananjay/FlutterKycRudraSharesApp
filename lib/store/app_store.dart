import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/api/api_client.dart';
import 'package:meon_kyc/api/kyc_api.dart';
import 'package:meon_kyc/utils/api_error_message.dart';

bool _isGenericHtml500(String body) {
  final t = body.trim().toLowerCase();
  return t.contains('<html') && t.contains('internal server error');
}

class AppStore extends ChangeNotifier {
  static const Set<String> _hiddenStepperSteps = {
    'cdsl_upload',
    'nse',
    'bse',
    'kra_new',
    'backoffice',
  };

  // Params
  String? _company;
  String? _workflowName;
  String? get company => _company;
  String? get workflowName => _workflowName;
  void setParams({String? company, String? workflowName}) {
    _company = company ?? _company;
    _workflowName = workflowName ?? _workflowName;
    notifyListeners();
  }

  // Workflow (unauthenticated)
  dynamic _fields;
  bool _loading = false;
  String? _error;
  /// Cached for pdfPassCheck / verifyPdfPassword (survives auth/unauth switches).
  String? _workflowKey;
  dynamic get fields => _fields;
  bool get loading => _loading;
  String? get error => _error;
  String? get workflowKey => _workflowKey;

  void _cacheWorkflowKeyFrom(dynamic source, {required String label}) {
    if (source is! Map) return;
    for (final key in ['workflow_key', 'id', 'muid']) {
      final v = source[key]?.toString().trim();
      if (v != null && v.isNotEmpty) {
        _workflowKey = v;
        debugPrint('[AppStore] workflowKey cached from $label.$key=$_workflowKey');
        return;
      }
    }
  }

  /// Best-effort resolve for PDF password APIs.
  String? resolveWorkflowKey() {
    if (_workflowKey != null && _workflowKey!.trim().isNotEmpty) {
      return _workflowKey!.trim();
    }
    final auth = _fieldsWithAuth;
    if (auth is Map) {
      final ctx = auth['context'];
      if (ctx is Map) {
        final k = ctx['workflow_key']?.toString().trim();
        if (k != null && k.isNotEmpty) {
          _workflowKey = k;
          return k;
        }
      }
      final root = auth['workflow_key']?.toString().trim();
      if (root != null && root.isNotEmpty) {
        _workflowKey = root;
        return root;
      }
    }
    final wf = _fields;
    if (wf is Map) {
      for (final key in ['workflow_key', 'id', 'muid']) {
        final k = wf[key]?.toString().trim();
        if (k != null && k.isNotEmpty) {
          _workflowKey = k;
          return k;
        }
      }
    }
    return null;
  }

  Future<void> fetchWorkflowFields(String urlCompany, String urlWorkflowName) async {
    debugPrint('[AppStore] fetchWorkflowFields START: $urlCompany / $urlWorkflowName');
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final client = ApiClient();
      final res = await client.post('/api/get-workflow-details/$urlCompany/$urlWorkflowName', body: {});
      debugPrint('[AppStore] fetchWorkflowFields Response: ${res.statusCode}');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = _parseJson(res.body);
        _fields = data?['workflow'];
        _cacheWorkflowKeyFrom(_fields, label: 'workflow');
        debugPrint('[AppStore] fetchWorkflowFields OK, workflow keys: ${_fields is Map ? (_fields as Map).keys.toList() : 'n/a'}');
      } else {
        _error = friendlyApiErrorMessage(res.body, statusCode: res.statusCode);
        debugPrint('[AppStore] fetchWorkflowFields ERROR: ${res.body}');
      }
    } catch (e, st) {
      _error = friendlyApiErrorMessage(e.toString());
      debugPrint('[AppStore] fetchWorkflowFields Exception: $e\n$st');
    } finally {
      _loading = false;
      notifyListeners();
      debugPrint('[AppStore] fetchWorkflowFields DONE');
    }
  }

  // Workflow with auth
  dynamic _fieldsWithAuth;
  bool _loadingWithAuth = false;
  String? _errorWithAuth;
  int? _lastGetContextStatusCode;
  String? _lastGetContextRawBody;
  // Set true in WebViewPage before context.go() back to HomePage so the
  // build method can show a full-screen loader through the entire return flow
  // (covers first-frame flash AND the gap between sequential API calls).
  bool _isReturningFromWebView = false;
  bool _rpdReturn = false;
  /// Set when RPD WebView closes with success=yes — skip reopening RPD until
  /// get-context advances past bank verification.
  bool _rpdSuccessReturn = false;
  dynamic get fieldsWithAuth => _fieldsWithAuth;
  bool get loadingWithAuth => _loadingWithAuth;
  String? get errorWithAuth => _errorWithAuth;
  String? get lastGetContextRawBody => _lastGetContextRawBody;
  bool get isReturningFromWebView => _isReturningFromWebView;
  bool get rpdReturn => _rpdReturn;
  bool get rpdSuccessReturn => _rpdSuccessReturn;

  /// True when get-context failed because uploaded PDF is still encrypted/closed.
  bool get hasPdfDocumentEncryptedContextError {
    return isPdfDocumentEncryptedError(_lastGetContextRawBody) ||
        isPdfDocumentEncryptedError(_errorWithAuth);
  }

  /// True when get-context failed on PAN/KRA validation (stay on PAN step to retry).
  bool get hasInvalidPanContextError {
    return isInvalidPanContextError(_lastGetContextRawBody) ||
        isInvalidPanContextError(_errorWithAuth);
  }

  /// True when saved token is rejected (e.g. get-context 404 User not found).
  bool get invalidUserSession {
    final body = (_lastGetContextRawBody ?? '').toLowerCase();
    final code = _lastGetContextStatusCode;
    if (code == 401 || code == 403) return true;
    if (code == 404 && body.contains('user not found')) return true;
    if (body.contains('user not found')) return true;
    return false;
  }

  void setReturningFromWebView(bool value) {
    _isReturningFromWebView = value;
    notifyListeners();
  }

  void setRpdReturn(bool value) {
    _rpdReturn = value;
    notifyListeners();
  }

  void setRpdSuccessReturn(bool value) {
    _rpdSuccessReturn = value;
    notifyListeners();
  }

  void clearAuthError() {
    _errorWithAuth = null;
    _lastGetContextRawBody = null;
    _lastGetContextStatusCode = null;
    notifyListeners();
  }

  Future<void> fetchWorkflowFieldsWithAuth(
    String urlCompany,
    String urlWorkflowName,
    String fullQueryString, {
    Map<String, dynamic>? postBody,
  }) async {
    // Normalize query string: remove any leading '?' and rebuild path correctly
    final cleanQuery = fullQueryString.startsWith('?') 
        ? fullQueryString.substring(1) 
        : fullQueryString;
    
    final fullPath = cleanQuery.isEmpty
        ? '/api/get-context/$urlCompany/$urlWorkflowName'
        : '/api/get-context/$urlCompany/$urlWorkflowName?$cleanQuery';

    // When `verify=digilocker` is on the URL, backend expects `save: true` in the POST body
    // (query string is unchanged; only JSON body is set).
    final Map<String, dynamic> requestBody = {
      if (postBody != null) ...postBody,
      if (_rpdReturn) 'rpd_return': true,
    };
    if (cleanQuery.isNotEmpty) {
      final qp = Uri.splitQueryString(cleanQuery);
      if (qp['verify'] == 'digilocker') {
        requestBody['save'] = true;
      }
    }

    debugPrint('[AppStore] fetchWorkflowFieldsWithAuth START: $fullPath');
    _loadingWithAuth = true;
    _errorWithAuth = null;
    _lastGetContextStatusCode = null;
    _lastGetContextRawBody = null;
    notifyListeners();
    try {
      final client = ApiClient();
      http.Response res = await client.post(fullPath, body: requestBody);
      const maxAttempts = 3;
      for (var attempt = 1;
          attempt < maxAttempts && res.statusCode == 500 && _isGenericHtml500(res.body);
          attempt++) {
        final wait = Duration(milliseconds: 450 * attempt);
        debugPrint(
          '[AppStore] get-context HTTP 500 (generic HTML) — retry $attempt/$maxAttempts after ${wait.inMilliseconds}ms',
        );
        await Future.delayed(wait);
        res = await client.post(fullPath, body: requestBody);
      }
      // Occasional race after submit/SSO: one more get-context try if still unauthorized.
      if (res.statusCode == 401) {
        debugPrint(
          '[AppStore] get-context still 401 after interceptor — one delayed retry',
        );
        await Future.delayed(const Duration(milliseconds: 500));
        res = await client.post(fullPath, body: requestBody);
      }
      debugPrint('[AppStore] fetchWorkflowFieldsWithAuth Response: ${res.statusCode}');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = _parseJson(res.body);
        final success = data is Map && data['success'] == true;
        if (success) {
          _fieldsWithAuth = data;
          
          // Extract Position and Page ID from context for stepper
          if (data is Map && data.containsKey('context')) {
            final context = data['context'];
            if (context is Map) {
              _cacheWorkflowKeyFrom(context, label: 'context');
              if (context.containsKey('position')) {
                _currentPosition = context['position']?.toString();
                debugPrint('[AppStore] Position extracted: $_currentPosition');
              }
              // Extract page.id for duplicate position handling
              if (context.containsKey('page')) {
                final page = context['page'];
                if (page is Map && page.containsKey('id')) {
                  _currentPageId = page['id']?.toString();
                  debugPrint('[AppStore] Page ID extracted: $_currentPageId');
                }
              }
            }
          }
          
          debugPrint('[AppStore] fetchWorkflowFieldsWithAuth OK');
        } else {
          _lastGetContextStatusCode = res.statusCode;
          _lastGetContextRawBody = res.body;
          // Extract error message from nested error object first, then fallback to top-level msg
          String? errorMsg;
          if (data is Map) {
            // Check for nested error.msg first (e.g., "Missing account details...")
            final errorObj = data['error'];
            if (errorObj is Map && errorObj['msg'] != null) {
              errorMsg = errorObj['msg']?.toString();
            } else {
              // Fallback to top-level msg
              errorMsg = data['msg']?.toString();
            }
          }
          _errorWithAuth = friendlyApiErrorMessage(
            errorMsg ?? res.body,
            statusCode: res.statusCode,
          );
          debugPrint('[AppStore] fetchWorkflowFieldsWithAuth ERROR (success: false): $_errorWithAuth');
        }
      } else {
        _lastGetContextStatusCode = res.statusCode;
        _lastGetContextRawBody = res.body;
        _errorWithAuth = friendlyApiErrorMessage(
          res.body,
          statusCode: res.statusCode,
        );
        debugPrint('[AppStore] fetchWorkflowFieldsWithAuth ERROR: ${res.body}');
      }
    } catch (e, st) {
      _errorWithAuth = friendlyApiErrorMessage(e.toString());
      debugPrint('[AppStore] fetchWorkflowFieldsWithAuth Exception: $e\n$st');
    } finally {
      _loadingWithAuth = false;
      notifyListeners();
      debugPrint('[AppStore] fetchWorkflowFieldsWithAuth DONE');
    }
  }

  // User details (for KYC Completed page)
  dynamic _userDetails;
  bool _loadingUserDetails = false;
  String? _errorUserDetails;
  dynamic get userDetails => _userDetails;
  bool get loadingUserDetails => _loadingUserDetails;
  String? get errorUserDetails => _errorUserDetails;

  Future<void> fetchUserDetails() async {
    debugPrint('[AppStore] fetchUserDetails START');
    _loadingUserDetails = true;
    _errorUserDetails = null;
    notifyListeners();
    try {
      final client = ApiClient();
      final res = await client.post('/api/user-details', body: {});
      debugPrint('[AppStore] fetchUserDetails Response: ${res.statusCode}');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = _parseJson(res.body);
        _userDetails = data;
        debugPrint('[AppStore] fetchUserDetails OK');
      } else {
        _errorUserDetails = res.body;
        debugPrint('[AppStore] fetchUserDetails ERROR: ${res.body}');
      }
    } catch (e, st) {
      _errorUserDetails = e.toString();
      debugPrint('[AppStore] fetchUserDetails Exception: $e\n$st');
    } finally {
      _loadingUserDetails = false;
      notifyListeners();
      debugPrint('[AppStore] fetchUserDetails DONE');
    }
  }

  // Stepper workflow (dynamic steps from API)
  dynamic _stepperWorkflow;
  bool _loadingStepperWorkflow = false;
  String? _errorStepperWorkflow;
  String? _currentPosition; // Position from get-context API (e.g., "mobile", "mobile_otp")
  String? _currentPageId; // Page ID from get-context API (e.g., "16", "17") - corresponds to workflow key
  
  dynamic get stepperWorkflow => _stepperWorkflow;
  bool get loadingStepperWorkflow => _loadingStepperWorkflow;
  String? get errorStepperWorkflow => _errorStepperWorkflow;
  String? get currentPosition => _currentPosition;
  String? get currentPageId => _currentPageId;

  /// Extract data.label list from stepper workflow API response
  /// Returns ordered list of label values from data.label
  List<String> getStepperSteps() {
    if (_stepperWorkflow is! Map) return [];
    
    // Sort by key to maintain order (keys are like "1", "2", "3", etc.)
    final sortedKeys = _stepperWorkflow.keys.toList()
      ..sort((a, b) {
        final aInt = int.tryParse(a.toString());
        final bInt = int.tryParse(b.toString());
        if (aInt != null && bInt != null) {
          return aInt.compareTo(bInt);
        }
        return a.toString().compareTo(b.toString());
      });
    
    final steps = <String>[];
    for (final key in sortedKeys) {
      final value = _stepperWorkflow[key];
      if (value is Map) {
        // Extract from data.label (new format)
        final data = value['data'] as Map?;
        if (data != null && data.containsKey('label')) {
          final label = data['label']?.toString();
          if (label != null && label.isNotEmpty) {
            steps.add(label);
            continue;
          }
        }
        // Fallback to moduleName (for backward compatibility)
        if (value.containsKey('moduleName')) {
          final moduleName = value['moduleName']?.toString();
          if (moduleName != null && moduleName.isNotEmpty) {
            steps.add(moduleName);
          }
        }
      }
    }
    
    return steps
        .where((s) => !_hiddenStepperSteps.contains(s.toLowerCase().trim()))
        .toList();
  }

  /// Maps workflow page key (e.g. "16") to a 0-based step index in [steps].
  int? _stepIndexFromPageKey(String pageKey, List<String> steps) {
    if (pageKey.isEmpty || steps.isEmpty) return null;

    if (_stepperWorkflow is Map && (_stepperWorkflow as Map).isNotEmpty) {
      final sortedKeys = (_stepperWorkflow as Map).keys.toList()
        ..sort((a, b) {
          final aInt = int.tryParse(a.toString());
          final bInt = int.tryParse(b.toString());
          if (aInt != null && bInt != null) return aInt.compareTo(bInt);
          return a.toString().compareTo(b.toString());
        });

      var visibleIndex = -1;
      for (final key in sortedKeys) {
        final workflowValue = _stepperWorkflow[key];
        if (workflowValue is! Map) continue;
        final data = workflowValue['data'] as Map?;
        final rawLabel =
            data?['label']?.toString() ?? workflowValue['moduleName']?.toString();
        final label = rawLabel?.toLowerCase().trim() ?? '';
        if (label.isEmpty || _hiddenStepperSteps.contains(label)) continue;

        visibleIndex++;
        if (key.toString() == pageKey) {
          return visibleIndex.clamp(0, steps.length - 1);
        }
      }
    }

    // No stepper metadata (or key missing): workflow keys are 1-based ordinals.
    final keyNum = int.tryParse(pageKey);
    if (keyNum != null && keyNum >= 1) {
      return (keyNum - 1).clamp(0, steps.length - 1);
    }
    return null;
  }

  /// Get current step index based on Position and Page ID
  /// Returns index of Position in stepper steps, or null if not found
  /// IMPORTANT: Current step should NOT be marked as completed, only steps BEFORE it
  /// Uses page.id (workflow key) along with position to handle duplicate step names
  int? getCurrentStepIndex() {
    if (_currentPosition == null || _currentPosition!.isEmpty) return null;
    
    final steps = getStepperSteps();
    if (steps.isEmpty) return null;
    
    final positionLower = _currentPosition!.toLowerCase().trim();
    final pageId = _currentPageId?.trim();

    // Priority 1: workflow page id / index (handles duplicate position names)
    if (pageId != null && pageId.isNotEmpty) {
      final fromPage = _stepIndexFromPageKey(pageId, steps);
      if (fromPage != null) return fromPage;
      return null;
    }

    // Priority 2: Exact match by position (case-insensitive)
    int index = steps.indexWhere(
      (step) => step.toLowerCase().trim() == positionLower,
    );
    
    // Priority 3: Step starts with position (e.g., position "mobile" matches step "mobile_otp")
    if (index == -1) {
      index = steps.indexWhere(
        (step) => step.toLowerCase().trim().startsWith(positionLower) ||
                   positionLower.startsWith(step.toLowerCase().trim()),
      );
    }
    
    // Priority 4: Contains match (last resort)
    if (index == -1) {
      index = steps.indexWhere(
        (step) => step.toLowerCase().contains(positionLower) ||
                   positionLower.contains(step.toLowerCase()),
      );
    }
    
    // Index may be -1 if no matching step is found; return null in that case.
    return index == -1 ? null : index;
  }

  /// Fetch stepper workflow metadata.
  /// Backend route is: /kycadmin_getWorkflow/{workflowName}/{workflowId}
  Future<void> fetchStepperWorkflow(String workflowName, String workflowId) async {
    debugPrint('[AppStore] fetchStepperWorkflow START: $workflowName / $workflowId');
    _loadingStepperWorkflow = true;
    _errorStepperWorkflow = null;
    notifyListeners();

    try {
      final res = await KycAPI.getStepperWorkflow(workflowName, workflowId);
      debugPrint('[AppStore] fetchStepperWorkflow Response: ${res.statusCode}');
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final data = _parseJson(res.body);
        _stepperWorkflow = data;
        final steps = getStepperSteps();
        debugPrint('[AppStore] fetchStepperWorkflow OK - Found ${steps.length} steps: $steps');
      } else {
        _errorStepperWorkflow = res.body;
        debugPrint('[AppStore] fetchStepperWorkflow ERROR: ${res.body}');
      }
    } catch (e, st) {
      _errorStepperWorkflow = e.toString();
      debugPrint('[AppStore] fetchStepperWorkflow Exception: $e\n$st');
    } finally {
      _loadingStepperWorkflow = false;
      notifyListeners();
      debugPrint('[AppStore] fetchStepperWorkflow DONE');
    }
  }

  /// Reset all state (used after logout)
  void resetState() {
    _fields = null;
    _fieldsWithAuth = null;
    _workflowKey = null;
    _userDetails = null;
    _stepperWorkflow = null;
    _currentPosition = null;
    _currentPageId = null;
    _loading = false;
    _loadingWithAuth = false;
    _loadingUserDetails = false;
    _loadingStepperWorkflow = false;
    _error = null;
    _errorWithAuth = null;
    _errorUserDetails = null;
    _errorStepperWorkflow = null;
    _isReturningFromWebView = false;
    _rpdReturn = false;
    _rpdSuccessReturn = false;
    notifyListeners();
    debugPrint('[AppStore] State reset');
  }

  dynamic _parseJson(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }
}
