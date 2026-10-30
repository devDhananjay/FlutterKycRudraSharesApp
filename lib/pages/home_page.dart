import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:fluttertoast/fluttertoast.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:meon_kyc/firebase_options.dart';
import 'package:meon_kyc/api/api_client.dart';
import 'package:meon_kyc/api/kyc_api.dart';
import 'package:meon_kyc/api/leadsquared_api.dart';
import 'package:meon_kyc/api/sso_api.dart';
import 'package:meon_kyc/sso/sso_temp_credentials_gate.dart';
import 'package:meon_kyc/components/form_field_widget.dart';
import 'package:meon_kyc/components/gradient_cta_button.dart';
import 'package:meon_kyc/components/kyc_layout.dart';
import 'package:meon_kyc/components/kyc_page_background.dart';
import 'package:meon_kyc/components/kyc_stepper_bar.dart';
import 'package:meon_kyc/components/kyc_note_box.dart';
import 'package:meon_kyc/components/loader.dart';
import 'package:meon_kyc/components/nominee_step_section.dart';
import 'package:meon_kyc/components/otp_verify_section.dart';
import 'package:meon_kyc/components/segments_selection.dart';
import 'package:meon_kyc/components/brokerage_plan_dialog.dart';
import 'package:meon_kyc/config/env_config.dart';
import 'package:meon_kyc/hooks/conditional_form.dart';
import 'package:meon_kyc/utils/conditional_flow.dart';
import 'package:meon_kyc/utils/api_error_message.dart';
import 'package:meon_kyc/utils/field_validators.dart';
import 'package:meon_kyc/utils/kyc_date_utils.dart';
import 'package:meon_kyc/services/storage_service.dart';
import 'package:meon_kyc/services/sim_phone_service.dart';
import 'package:meon_kyc/services/connectivity_controller.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:flutter/gestures.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

class HomePage extends StatefulWidget {
  final String company;
  final String workflowName;
  final Map<String, String> queryParams;

  const HomePage({
    super.key,
    required this.company,
    required this.workflowName,
    this.queryParams = const {},
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late ConditionalFormNotifier _formNotifier;
  bool _submitLoading = false;

  /// While submit is in flight, keep the previous step's fields/values on screen.
  Map<dynamic, dynamic>? _submitFrozenPage;
  Map<String, dynamic>? _submitFrozenFormSnapshot;
  Map<String, dynamic>? _submitFrozenContext;
  bool _resendOtpLoading = false;
  /// Bumped after successful resend so [OtpVerifySection] restarts cooldown/expiry timers.
  int _otpResendTimerEpoch = 0;
  bool _webViewTransitionActive = false;
  bool _logoutLoading = false;
  // Non-null when an API call fails while we're returning from WebView.
  // Triggers the retry UI instead of the old step's form UI.
  String? _webViewReturnError;
  // True while _loadWorkflow() is actively running — prevents concurrent calls.
  bool _loadWorkflowActive = false;
  // Message shown in the partial loader during WebView return flow.
  String _returnFlowMessage = 'Loading your next step...';
  // One-shot timers: 5 s → slow-network message, 20 s → show retry UI.
  Timer? _returnFlowWatchdogTimer;
  // 5 s periodic: auto-retries _loadWorkflow() if stuck with no active call.
  Timer? _returnFlowPollingTimer;
  bool _refreshLoading = false;
  bool _backLoading = false;
  String _submitError = '';
  String _submitSuccess = '';
  /// PAN step (`pan10`): last `kyc-post-v2` `msg` / `message` from API (shown on form).
  String _panStepApiFeedback = '';
  bool _panStepApiFeedbackIsError = false;
  bool _termsAccepted = true; // Terms & Conditions checkbox (mobile step) — auto-selected
  bool _showTermsError = false; // Show validation message under T&C checkbox
  bool _showMobileError = false; // Show error below mobile input when invalid on submit
  bool _googleSignInLoading = false;
  /// One fetch of `/api/user-details` per DigiLocker step visit (fresh Aadhaar photo URL).
  bool _digilockerUserDetailsFetchStarted = false;

  // One-shot guard: if we already attempted SSO for this widget instance,
  // don't retry on rebuild.
  bool _ssoAttempted = false;
  bool _ssoInProgress = false;
  bool _navigatingToKycCompleted = false;
  bool _autoSessionRecoverInFlight = false;
  bool _autoSessionRecoverAttempted = false;

  /// Kept when rehydrating after get-context (see `_handleSubmitResponse`): `mobile_otp`
  /// resend + header text still know the number (get-context fields often omit it).
  String? _persistedMobileDigitsForOtp;
  String? _persistedEmailForOtp;
  /// Google profile name — applied on the mobile step after email advance.
  String? _persistedGoogleDisplayName;

  /// Segments step: brokerage click is optional (pre-applied).
  String? _segmentsBrokerageStepKey;
  bool _segmentsBrokerageUserConfirmed = false;
  String? _segmentsBpDefaultsStepKey;

  /// KRA details: single editable address box (individual address fields hidden).
  String? _kraAddressStepKey;
  TextEditingController? _kraAddressController;

  /// activate_fno step: default Yes once per visit.
  String? _activateFnoDefaultsStepKey;

  /// Nominee landing: ensure No + opt-out checkbox ticked once per visit.
  String? _nomineeLandingDefaultsStepKey;

  /// `nominee_percentage` step: auto-fill shares to 100% once per visit.
  String? _nomineePercentageDefaultsStepKey;

  /// Mobile step: SIM number autofill attempted once per visit.
  String? _mobileSimAutofillStepKey;
  bool _mobileSimAutofillInFlight = false;

  /// Mobile step: auto-tick Terms & Conditions once per visit.
  String? _mobileTermsAutoSelectedStepKey;

  /// Last good authenticated step — avoids flashing unauth "Start your KYC" during get-context.
  dynamic _cachedAuthenticatedPageFields;
  String? _cachedPageTitle;
  String? _cachedPosition;

  /// Sticky header step name — stays visible during submit until the next step is synced.
  String? _headerDisplayPosition;

  /// Set when user picks Yes on tax residency; cleared only after they select No.
  bool _fatcaTaxResidencyMustPickNo = false;

  ConnectivityController? _connectivity;
  int _lastReconnectToken = 0;
  /// Prevents post-frame form sync from re-running on every rebuild (same step).
  String? _activeFieldsSyncKey;

  /// Max-3 product: auto-submit through unwanted additional_nominee* steps.
  int _autoSkipAdditionalNomineeDepth = 0;

  bool _responseIndicatesKycCompleted(dynamic response) {
    return response is Map && response['is_admin'] == true;
  }

  Future<void> _navigateToKycCompletedIfNeeded(AppStore store) async {
    if (!mounted || !_responseIndicatesKycCompleted(store.fieldsWithAuth)) {
      return;
    }
    if (_navigatingToKycCompleted) return;

    _navigatingToKycCompleted = true;
    if (mounted) setState(() {});

    debugPrint('[HomePage] Navigating to KYC completed page (is_admin=true)');
    try {
      await store.fetchUserDetails();
      if (!mounted) return;
      if (store.userDetails != null) {
        context.go('/${widget.company}/${widget.workflowName}/completed');
        return;
      }
      debugPrint(
        '[HomePage] KYC completed but user details missing: ${store.errorUserDetails}',
      );
      if (mounted) {
        Fluttertoast.showToast(
          msg: 'Error loading completion details',
          gravity: ToastGravity.TOP,
        );
      }
    } finally {
      if (mounted && store.userDetails == null) {
        _navigatingToKycCompleted = false;
        setState(() {});
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _formNotifier = ConditionalFormNotifier(fields: [], conditionalFlow: []);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _connectivity = context.read<ConnectivityController>();
      _lastReconnectToken = _connectivity!.reconnectToken;
      _connectivity!.addListener(_onInternetRestored);
      _loadWorkflow();
    });
  }

  void _onInternetRestored() {
    final connectivity = _connectivity;
    if (connectivity == null || !mounted) return;
    if (connectivity.reconnectToken == _lastReconnectToken) return;
    _lastReconnectToken = connectivity.reconnectToken;
    if (!connectivity.isConnected) return;
    debugPrint('[HomePage] Internet restored — refreshing workflow');
    unawaited(_refreshAfterInternetRestored());
  }

  Future<void> _refreshAfterInternetRestored() async {
    if (!mounted) return;
    // Don't race get-context with an in-flight submit (session overlap).
    if (_submitLoading) return;
    final queryString = widget.queryParams.isEmpty
        ? ''
        : '?${widget.queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
    final store = context.read<AppStore>();
    final hasToken = await StorageService.hasAccessToken();
    if (!hasToken) {
      _loadWorkflow();
      return;
    }
    final ok = await _fetchContextAndRecoverIfNeeded(store, queryString);
    if (!mounted || !ok) return;
    if (_responseIndicatesKycCompleted(store.fieldsWithAuth)) {
      await _navigateToKycCompletedIfNeeded(store);
      return;
    }
    final response = store.fieldsWithAuth;
    if (response is Map) {
      final ctx = response['context'] as Map<String, dynamic>?;
      final designTemplate = ctx?['design_template']?.toString();
      if (designTemplate != null && designTemplate.contains('-')) {
        final parts = designTemplate.split('-');
        if (parts.length >= 2) {
          await store.fetchStepperWorkflow(widget.workflowName, parts[1]);
        }
      }
    }
    final activeFields = _getActiveFields(store);
    final fieldList = (activeFields?['fields'] as List?) ?? [];
    _formNotifier.updateFields(
      fieldList,
      activeFields?['conditionalFlow'] as List?,
      fieldsWithAuth: store.fieldsWithAuth,
    );
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _connectivity?.removeListener(_onInternetRestored);
    _returnFlowWatchdogTimer?.cancel();
    _returnFlowPollingTimer?.cancel();
    _kraAddressController?.dispose();
    super.dispose();
  }

  // ---------- Return-flow timer helpers ----------

  /// Starts a two-stage watchdog (5 s → slow-network msg, 20 s → retry UI)
  /// and a background 5-second polling timer that auto-retries when not active.
  void _startReturnFlowTimers() {
    _returnFlowWatchdogTimer?.cancel();
    _returnFlowPollingTimer?.cancel();

    // Stage 1 – 5 seconds: update loading message
    _returnFlowWatchdogTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() => _returnFlowMessage =
          'This is taking longer than usual, please wait...');
      debugPrint('[HomePage] Return-flow: slow-network message shown');

      // Stage 2 – 15 more seconds (20 s total): show retry UI
      _returnFlowWatchdogTimer = Timer(const Duration(seconds: 15), () {
        if (!mounted) return;
        final store = context.read<AppStore>();
        if (!store.isReturningFromWebView || _webViewReturnError != null) {
          return;
        }
        if (_loadWorkflowActive) {
          debugPrint(
              '[HomePage] Return-flow watchdog: still loading, waiting...');
          return;
        }
        if (_shouldOpenRedirectImmediately(store.fieldsWithAuth)) {
          debugPrint(
              '[HomePage] Return-flow watchdog: redirect ready — opening WebView');
          _loadWorkflow();
          return;
        }
        debugPrint('[HomePage] Return-flow watchdog fired — showing retry UI');
        setState(() {
          _webViewReturnError =
              'Connection is taking too long. Please check your network and try again.';
          _returnFlowMessage = 'Loading your next step...';
        });
      });
    });

    // Background poll every 5 seconds: auto-retry if no active call and still stuck
    _returnFlowPollingTimer =
        Timer.periodic(const Duration(seconds: 5), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final store = context.read<AppStore>();
      if (!store.isReturningFromWebView) {
        timer.cancel();
        _returnFlowPollingTimer = null;
        return;
      }
      if (!_loadWorkflowActive) {
        debugPrint(
            '[HomePage] Return-flow polling: auto-retrying (no active call, still returning)');
        store.clearAuthError();
        if (_webViewReturnError != null) {
          setState(() {
            _webViewReturnError = null;
            _returnFlowMessage = 'Loading your next step...';
          });
        }
        _loadWorkflow();
      }
    });
  }

  void _stopReturnFlowTimers() {
    _returnFlowWatchdogTimer?.cancel();
    _returnFlowWatchdogTimer = null;
    _returnFlowPollingTimer?.cancel();
    _returnFlowPollingTimer = null;
  }

  // ------------------------------------------------
  String _leadQueryParam(List<String> keys) {
    final qp = widget.queryParams;
    for (final key in keys) {
      final direct = qp[key];
      if (direct != null && direct.trim().isNotEmpty) return direct.trim();
      final lower = key.toLowerCase();
      for (final e in qp.entries) {
        if (e.key.toLowerCase() == lower && e.value.trim().isNotEmpty) {
          return e.value.trim();
        }
      }
    }
    return '';
  }

  Future<String?> _fetchKycLeadIdBeforeSso({
    required String mobileNumber,
  }) async {
    try {
      return await LeadSquaredAPI.captureLead(
        mobileNumber: mobileNumber,
        firstName: _leadQueryParam(['firstname', 'first_name', 'FirstName']),
        ageGroup: _leadQueryParam(['age_group', 'mx_Lead_Age_Group']),
      );
    } catch (e, st) {
      debugPrint('[HomePage] LeadSquared before SSO failed: $e\n$st');
      return null;
    }
  }

  Future<bool> _recoverInvalidSessionViaSso(AppStore store) async {
    if (!store.invalidUserSession) return false;
    debugPrint('[HomePage] Invalid session — clearing token and opening SSO');
    await StorageService.clearAuthTokens();
    store.clearAuthError();
    _clearAuthenticatedStepCache();
    _ssoAttempted = false;
    _ssoInProgress = false;
    StorageService.setSsoAutoLoginEnabled(true);
    if (!mounted) return false;
    return _trySsoLoginIfNeeded(context, store);
  }

  Future<bool> _fetchContextAndRecoverIfNeeded(
    AppStore store,
    String queryString,
  ) async {
    await store.fetchWorkflowFieldsWithAuth(
      widget.company,
      widget.workflowName,
      queryString,
    );
    if (!mounted) return false;
    if (store.invalidUserSession) {
      final ssoOk = await _recoverInvalidSessionViaSso(store);
      if (!ssoOk || !mounted) return false;
      await store.fetchWorkflowFieldsWithAuth(
        widget.company,
        widget.workflowName,
        queryString,
      );
      final ok = mounted && !store.invalidUserSession;
      if (ok) _autoSessionRecoverAttempted = false;
      return ok;
    }
    if (store.fieldsWithAuth is Map) {
      _autoSessionRecoverAttempted = false;
      return true;
    }
    return false;
  }

  Future<bool> _trySsoLoginIfNeeded(
    BuildContext context,
    AppStore store,
  ) async {
    if (_ssoAttempted || _ssoInProgress) return _ssoAttempted;

    if (await StorageService.hasAccessToken()) {
      debugPrint('[HomePage] SSO skipped — access token already present');
      _ssoAttempted = true;
      return true;
    }

    if (mounted) {
      setState(() => _ssoInProgress = true);
    } else {
      _ssoInProgress = true;
    }
    try {
      final creds = resolveSsoCredentials();
      final mobileNumber = creds.mobileNumber;
      final email = creds.email;

      debugPrint(
        '[HomePage] SSO credentials mobile=$mobileNumber email=$email',
      );

      debugPrint('[HomePage] No access token - attempting SSO login...');

      final leadFirstName =
          _leadQueryParam(['firstname', 'first_name', 'FirstName']);
      final leadAgeGroup =
          _leadQueryParam(['age_group', 'mx_Lead_Age_Group']);

      final kycLeadId = await _fetchKycLeadIdBeforeSso(
        mobileNumber: mobileNumber,
      );
      if (kycLeadId != null && kycLeadId.isNotEmpty) {
        debugPrint('[HomePage] LeadSquared kyc_lead for SSO: $kycLeadId');
      }

      final tokens = await SsoAPI.getSsoRouteTokens(
        company: widget.company,
        workflowName: widget.workflowName,
        mobileNumber: mobileNumber,
        email: email,
        firstName: leadFirstName,
        ageGroup: leadAgeGroup,
        kycLeadId: kycLeadId,
      );

      if (tokens == null) {
        debugPrint('[HomePage] SSO token fetch failed - fallback to OTP flow');
        return false;
      }

      await StorageService.setAccessToken(tokens.accessToken);
      await StorageService.setRefreshToken(tokens.refreshToken);
      await StorageService.setAuthSuccess('true');

      // Safety fallback in case backend still returns an OTP step.
      _persistedMobileDigitsForOtp = mobileNumber;
      _persistedEmailForOtp = email;

      store.clearAuthError();
      debugPrint('[HomePage] SSO tokens stored successfully');

      // Give backend a moment to persist session before first get-context (avoids intermittent 500).
      await Future.delayed(const Duration(milliseconds: 600));
      return true;
    } catch (e, st) {
      debugPrint('[HomePage] SSO login exception: $e\n$st');
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _ssoInProgress = false;
          _ssoAttempted = true;
        });
      } else {
        _ssoInProgress = false;
        _ssoAttempted = true;
      }
    }
  }

  Future<void> _loadWorkflow() async {
    // Prevent concurrent calls — a second call while one is in flight is a no-op.
    if (_loadWorkflowActive) {
      debugPrint('[HomePage] _loadWorkflow already running, skipping duplicate call');
      return;
    }
    if (!mounted) return;
    setState(() {
      _loadWorkflowActive = true;
      _digilockerUserDetailsFetchStarted = false;
    });

    debugPrint('[HomePage] _loadWorkflow START: ${widget.company} / ${widget.workflowName}');
    debugPrint('[HomePage] _loadWorkflow queryParams: ${widget.queryParams}');
    final store = context.read<AppStore>();
    // Tracks whether we navigated away inside this call so the finally block
    // knows not to prematurely clear isReturningFromWebView.
    bool navigatingAway = false;

    // Start watchdog + polling timers only when in the WebView return flow.
    if (store.isReturningFromWebView) _startReturnFlowTimers();

    try {
      store.setParams(company: widget.company, workflowName: widget.workflowName);
      bool hasToken = await StorageService.hasAccessToken();
      debugPrint('[HomePage] _loadWorkflow hasToken=$hasToken');

      // Auto-SSO only on fresh app journey when there is no saved token.
      final shouldTrySso = !_ssoAttempted &&
          StorageService.ssoAutoLoginEnabled &&
          !store.isReturningFromWebView &&
          !hasToken;
      if (shouldTrySso) {
        debugPrint('[HomePage] First-load: forcing SSO attempt (hasToken=$hasToken)');
        // Do not set _submitLoading — SSO dialog is separate; avoids Processing under modal.
        final ssoOk = context.mounted
            ? await _trySsoLoginIfNeeded(context, store)
            : false;
        hasToken = hasToken || ssoOk;
      } else if (!_ssoAttempted) {
        debugPrint(
            '[HomePage] Skipping auto-SSO (returnFromWebView=${store.isReturningFromWebView}, ssoAutoEnabled=${StorageService.ssoAutoLoginEnabled})');
        _ssoAttempted = true;
      }

      if (hasToken) {
        // Build query string from redirect params (state, client_token, auto)
        final queryString = widget.queryParams.isEmpty
            ? ''
            : '?${widget.queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';

        await _fetchContextAndRecoverIfNeeded(store, queryString);
        
        // Extract workflowId from design_template (format: "company-workflowId-number")
        // Example: "mandotsecurities-2321998632-76" -> workflowId = "2321998632"
        String? workflowId;
        final response = store.fieldsWithAuth;
        if (response is Map) {
          final context = response['context'] as Map<String, dynamic>?;
          final designTemplate = context?['design_template']?.toString();
          if (designTemplate != null && designTemplate.contains('-')) {
            final parts = designTemplate.split('-');
            if (parts.length >= 2) {
              workflowId = parts[1]; // Second part is workflowId
              debugPrint('[HomePage] Extracted workflowId from design_template: $workflowId');
            }
          }
          
          // Also try extracting from user details if available
          if (workflowId == null || workflowId.isEmpty) {
            // Will be fetched later if needed
          }
        }
        
        if (workflowId != null && workflowId.isNotEmpty) {
          debugPrint(
              '[HomePage] Fetching stepper workflow: ${widget.workflowName} / $workflowId');
          await store.fetchStepperWorkflow(widget.workflowName, workflowId);
        }
        
        // Check if KYC is completed (is_admin: true)
        if (_responseIndicatesKycCompleted(response)) {
          navigatingAway = true;
          await _navigateToKycCompletedIfNeeded(store);
          return;
        }
        
        // Check for redirect after get-context
        // Skip redirect if step completion params present (IPV, RPD, eSign, DigiLocker, etc.)
        // Prevents infinite loop when backend returns redirect despite completed step
        final isDigilockerVerifyReturn =
            widget.queryParams['verify'] == 'digilocker';
        final hasCompletionParams = widget.queryParams['success'] == 'yes' ||
            widget.queryParams['verifyCompleted'] == 'true' ||
            widget.queryParams['esign'] == 'yes' ||
            widget.queryParams.containsKey('transaction_id') ||
            widget.queryParams.containsKey('reversepennydrop') ||
            widget.queryParams.containsKey('reverse_pennydrop') ||
            widget.queryParams.containsKey('account_aggregator');
        // Clean RPD return only (no route params). When success/tr_id are present,
        // treat like other WebView steps — first get-context already used those keys.
        final rpdAlreadyCommitted =
            store.rpdSuccessReturn && widget.queryParams.isEmpty;
        if (mounted && isDigilockerVerifyReturn) {
          await _handleDigilockerVerifyReturn(store);
        } else if (mounted && rpdAlreadyCommitted) {
          debugPrint(
              '[HomePage] RPD success already committed in WebView — clean get-context only');
          await store.fetchWorkflowFieldsWithAuth(
            widget.company,
            widget.workflowName,
            '',
          );
          if (mounted) {
            await _checkAndHandleRedirect(store);
            if (!mounted) {
              navigatingAway = true;
            } else {
              final response = store.fieldsWithAuth;
              final stillRpd = response is Map &&
                  response['redirect'] == true &&
                  _isRpdRedirectUrl(response['url']?.toString() ?? '');
              if (!stillRpd) {
                store.setRpdSuccessReturn(false);
              }
              if (response is! Map || response['redirect'] != true || stillRpd) {
                navigatingAway = true;
                context.go('/${widget.company}/${widget.workflowName}');
              }
            }
          }
        } else if (mounted && !hasCompletionParams) {
          await _checkAndHandleRedirect(store);
          // If _checkAndHandleRedirect navigated to WebView, mounted will be false
          if (!mounted) navigatingAway = true;
        } else if (hasCompletionParams) {
          debugPrint(
              '[HomePage] Step completed (success/transaction_id/esign) - handling redirect');

          // API often returns the next external URL (CAMS, DigiLocker, etc.) on the
          // completion-params call itself — open WebView immediately; do not wait for
          // a second get-context (slow/502) while the return-flow loader spins.
          if (mounted && _shouldOpenRedirectImmediately(store.fieldsWithAuth)) {
            debugPrint(
                '[HomePage] External redirect on completion response — opening WebView now');
            _stopReturnFlowTimers();
            await _checkAndHandleRedirect(store);
            if (!mounted) {
              navigatingAway = true;
              return;
            }
          }

          // Refresh context without completion params to update in-app state.
          await store.fetchWorkflowFieldsWithAuth(
            widget.company,
            widget.workflowName,
            '', // Call without completion params to get fresh state
          );

          // Some flows can trigger multiple get-context calls back-to-back (WebView close + route rebuild).
          // Avoid blocking progress just because `errorWithAuth` was set by an earlier call while the latest
          // `fieldsWithAuth` succeeded.
          var refreshed = store.fieldsWithAuth;
          if (mounted && refreshed is! Map) {
            final err = (store.errorWithAuth ?? '').toString();
            final shouldRetryMultipleTabs = err.toLowerCase().contains('multiple tabs');

            if (shouldRetryMultipleTabs) {
              debugPrint('[HomePage] get-context failed due to multiple tabs - retrying once...');
              await Future.delayed(const Duration(milliseconds: 800));
              await store.fetchWorkflowFieldsWithAuth(
                widget.company,
                widget.workflowName,
                '', // Retry without completion params
              );
              refreshed = store.fieldsWithAuth;
            }

            if (mounted && refreshed is! Map) {
              debugPrint('[HomePage] Error refreshing context after step completion: ${store.errorWithAuth ?? "fieldsWithAuth not a Map"}');
              if (_shouldOpenRedirectImmediately(store.fieldsWithAuth)) {
                debugPrint(
                    '[HomePage] Refresh failed but redirect still available — opening WebView');
                _stopReturnFlowTimers();
                await _checkAndHandleRedirect(store);
                if (!mounted) {
                  navigatingAway = true;
                  return;
                }
              } else if (store.isReturningFromWebView) {
                // Show retry UI — never fall back to the old step's form
                setState(() => _webViewReturnError = friendlyApiErrorMessage(
                    store.errorWithAuth ??
                        'Something went wrong, please try again.'));
              } else {
                Fluttertoast.showToast(
                  msg: store.errorWithAuth ?? 'Error refreshing page',
                  gravity: ToastGravity.TOP,
                );
              }
              return;
            }
          }

          // Check if KYC is completed (is_admin: true)
          if (_responseIndicatesKycCompleted(refreshed)) {
            navigatingAway = true;
            await _navigateToKycCompletedIfNeeded(store);
            return;
          }

          // After refreshing context, check for redirects (backend may redirect to next step)
          if (mounted) {
            await _checkAndHandleRedirect(store);
            if (!mounted) navigatingAway = true;
            // If no redirect, navigate to refresh the page with updated data
            if (mounted) {
              final response = store.fieldsWithAuth;
              final stillRpdAfterSuccess = response is Map &&
                  response['redirect'] == true &&
                  _isRpdRedirectUrl(response['url']?.toString() ?? '') &&
                  _isRpdSuccessCompletionReturn();

              if (stillRpdAfterSuccess) {
                // Backend may lag after UPI success — retry get-context a few times
                // instead of looping back into Bank Verification.
                debugPrint(
                    '[HomePage] RPD success but context still points to RPD — retrying get-context');
                var advanced = false;
                for (var i = 0; i < 3; i++) {
                  await Future.delayed(Duration(milliseconds: 600 + (i * 400)));
                  if (!mounted) return;
                  await store.fetchWorkflowFieldsWithAuth(
                    widget.company,
                    widget.workflowName,
                    '',
                  );
                  final retry = store.fieldsWithAuth;
                  final stillRpd = retry is Map &&
                      retry['redirect'] == true &&
                      _isRpdRedirectUrl(retry['url']?.toString() ?? '');
                  if (!stillRpd) {
                    advanced = true;
                    if (store.rpdSuccessReturn) {
                      store.setRpdSuccessReturn(false);
                    }
                    await _checkAndHandleRedirect(store);
                    if (!mounted) {
                      navigatingAway = true;
                      return;
                    }
                    if (mounted &&
                        (store.fieldsWithAuth is! Map ||
                            (store.fieldsWithAuth as Map)['redirect'] != true)) {
                      navigatingAway = true;
                      context.go('/${widget.company}/${widget.workflowName}');
                    }
                    break;
                  }
                }
                if (!advanced && mounted) {
                  // Keep rpdSuccessReturn=true so clean route still skips RPD reopen.
                  debugPrint(
                      '[HomePage] RPD success — staying in-app (skipping RPD reopen loop)');
                  navigatingAway = true;
                  context.go('/${widget.company}/${widget.workflowName}');
                }
              } else if (response is! Map || response['redirect'] != true) {
                if (store.rpdSuccessReturn) {
                  store.setRpdSuccessReturn(false);
                }
                debugPrint('[HomePage] Navigating to refresh page after step completion');
                navigatingAway = true;
                context.go('/${widget.company}/${widget.workflowName}');
              } else if (store.rpdSuccessReturn &&
                  response is Map &&
                  !_isRpdRedirectUrl(response['url']?.toString() ?? '')) {
                // Advanced to a different external step (not RPD) — clear flag.
                store.setRpdSuccessReturn(false);
              }
            }
          }
        }
      } else {
        await store.fetchWorkflowFields(widget.company, widget.workflowName);
      }
      debugPrint('[HomePage] _loadWorkflow DONE, store.error=${store.error}');
    } finally {
      // Cancel the one-shot watchdog (polling timer keeps running until the flag clears).
      _returnFlowWatchdogTimer?.cancel();
      _returnFlowWatchdogTimer = null;

      if (mounted) setState(() => _loadWorkflowActive = false);

      // Clear isReturningFromWebView only when we stayed on this page (no route
      // change happened) and there is no pending retry error to display.
      if (mounted && !navigatingAway && store.isReturningFromWebView && _webViewReturnError == null) {
        store.setReturningFromWebView(false);
        _stopReturnFlowTimers();
      }
    }
  }

  bool _isInternalWorkflowRedirectUrl(String redirectUrl) {
    final lower = redirectUrl.toLowerCase();
    final internalWorkflowPath =
        '/${widget.company.toLowerCase()}/${widget.workflowName.toLowerCase()}';
    if (lower == internalWorkflowPath ||
        lower == '${internalWorkflowPath}/' ||
        lower.startsWith('$internalWorkflowPath?')) {
      return true;
    }
    final uri = Uri.tryParse(redirectUrl);
    if (uri == null) return false;
    final path = uri.path.toLowerCase();
    return path == internalWorkflowPath ||
        path == '${internalWorkflowPath}/' ||
        path.startsWith('$internalWorkflowPath?');
  }

  /// True when get-context already has a non-internal redirect URL (open WebView now).
  bool _shouldOpenRedirectImmediately(dynamic response) {
    if (response is! Map || response['redirect'] != true) return false;
    final redirectUrl = response['url']?.toString() ?? '';
    if (redirectUrl.isEmpty) return false;
    if (_isInternalWorkflowRedirectUrl(redirectUrl)) return false;
    // RPD just succeeded — never reopen Bank Verification from the completion response.
    if (_isRpdRedirectUrl(redirectUrl) && _isRpdSuccessCompletionReturn()) {
      return false;
    }
    return redirectUrl.startsWith('http://') ||
        redirectUrl.startsWith('https://') ||
        redirectUrl.startsWith('/');
  }

  bool _isRpdSuccessCompletionReturn() {
    final store = context.read<AppStore>();
    if (store.rpdSuccessReturn) return true;
    final success = (widget.queryParams['success'] ?? '').toLowerCase();
    if (success != 'yes' && success != 'true' && success != '1') return false;
    // success=yes alone is enough after RPD WebView; also accept explicit RPD keys.
    return widget.queryParams.containsKey('tr_id') ||
        widget.queryParams.containsKey('transaction_id') ||
        widget.queryParams.containsKey('reversepennydrop') ||
        widget.queryParams.containsKey('reverse_pennydrop') ||
        store.isReturningFromWebView;
  }

  String _getContextQueryFromRedirectUrl(String redirectUrl) {
    var uri = Uri.tryParse(redirectUrl);
    if (uri == null || (uri.host.isEmpty && !redirectUrl.startsWith('/'))) {
      return '?verify=digilocker';
    }
    if (uri.host.isEmpty) {
      uri = Uri.parse(
        '${EnvConfig.baseUrl}${redirectUrl.startsWith('/') ? redirectUrl : '/$redirectUrl'}',
      );
    }
    return uri.query.isNotEmpty ? '?${uri.query}' : '?verify=digilocker';
  }

  bool _getContextResponseHasStepContext(dynamic response) {
    return response is Map && response['context'] is Map;
  }

  /// After DigiLocker WebView: pass 1 = save (`verify=digilocker`), pass 2 = verify reload.
  /// Must not call empty get-context (that brings back `render diverge` + breaks the form).
  Future<void> _handleDigilockerVerifyReturn(AppStore store) async {
    debugPrint('[HomePage] DigiLocker verify return flow');
    var response = store.fieldsWithAuth;

    if (response is Map &&
        response['redirect'] == true &&
        (response['msg']?.toString() ?? '') == 'redirect on verify is true') {
      final redirectUrl = response['url']?.toString() ?? '';
      final queryString = _getContextQueryFromRedirectUrl(redirectUrl);
      debugPrint(
          '[HomePage] DigiLocker verify pass 2 — get-context$queryString');
      await store.fetchWorkflowFieldsWithAuth(
        widget.company,
        widget.workflowName,
        queryString,
      );
      response = store.fieldsWithAuth;
    }

    if (_getContextResponseHasStepContext(response)) {
      final pos = (response as Map)['context']?['position'];
      debugPrint('[HomePage] DigiLocker verify OK — step context position=$pos');
      if (mounted) {
        _stopReturnFlowTimers();
        context.go('/${widget.company}/${widget.workflowName}');
        setState(() {});
      }
      return;
    }

    if (response is Map && response['redirect'] == true) {
      final url = response['url']?.toString().toLowerCase() ?? '';
      if (url.contains('digilocker')) {
        debugPrint(
            '[HomePage] DigiLocker still pending on backend — not opening WebView again');
        if (mounted) setState(() {});
        return;
      }
    }

    if (mounted) {
      await _checkAndHandleRedirect(store);
    }
  }

  Future<void> _checkAndHandleRedirect(AppStore store) async {
    final response = store.fieldsWithAuth;
    if (response is Map) {
      final shouldRedirect = response['redirect'] == true;
      final redirectUrl = response['url']?.toString();
      final msg = response['msg']?.toString() ?? '';
      
      // Check if already processed
      final alreadyHasVerifyParam = widget.queryParams.containsKey('verify') || 
                                     widget.queryParams.containsKey('verifyCompleted');

      // User pressed back on Reverse Penny Drop — do not reopen RPD WebView.
      if (store.rpdReturn &&
          shouldRedirect &&
          redirectUrl != null &&
          _isRpdRedirectUrl(redirectUrl)) {
        debugPrint(
            '[HomePage] Skipping RPD WebView redirect — rpd_return is true');
        return;
      }

      // Payment succeeded — backend sometimes still returns a fresh RPD URL.
      // Do not reopen Bank Verification; continue in-app to the next step.
      if (shouldRedirect &&
          redirectUrl != null &&
          _isRpdRedirectUrl(redirectUrl) &&
          _isRpdSuccessCompletionReturn()) {
        debugPrint(
            '[HomePage] Skipping RPD WebView after success — waiting for next step');
        return;
      }

      // DigiLocker just completed — get-context already ran with verify=digilocker + save.
      if (shouldRedirect &&
          widget.queryParams['verify'] == 'digilocker' &&
          (redirectUrl?.toLowerCase().contains('digilocker') ?? false)) {
        debugPrint(
            '[HomePage] Skipping repeat DigiLocker WebView after verify=digilocker return');
        return;
      }
      
      if (shouldRedirect && redirectUrl != null && redirectUrl.isNotEmpty) {
        // SPECIAL CASE: "redirect on verify is true" - call get-context API (no WebView)
        if (msg == 'redirect on verify is true') {
          final digilockerNeedsSecondVerifyPass =
              widget.queryParams['verify'] == 'digilocker';
          if (alreadyHasVerifyParam && !digilockerNeedsSecondVerifyPass) {
            debugPrint('[HomePage] Skipping verify API redirect - already processed');
            return;
          }

          final queryString = _getContextQueryFromRedirectUrl(redirectUrl);
          if (digilockerNeedsSecondVerifyPass ||
              redirectUrl.toLowerCase().contains('verify=digilocker')) {
            debugPrint(
                '[HomePage] DigiLocker verify reload via get-context$queryString');
            await store.fetchWorkflowFieldsWithAuth(
              widget.company,
              widget.workflowName,
              queryString,
            );
            if (_getContextResponseHasStepContext(store.fieldsWithAuth) &&
                mounted) {
              context.go('/${widget.company}/${widget.workflowName}');
              setState(() {});
            }
            return;
          }

          // Extract query params from URL (e.g., verify=digilocker) — IPV / other verify flows
          final uri = Uri.parse(redirectUrl.startsWith('http')
              ? redirectUrl
              : '${EnvConfig.baseUrl}${redirectUrl.startsWith('/') ? redirectUrl : '/$redirectUrl'}');
          {
            final queryFromUri = uri.query;
            final lowerHost = uri.host.toLowerCase();
            final lowerPath = uri.path.toLowerCase();
            final isIpvOrFace =
                lowerHost.contains('ipv') ||
                lowerPath.contains('/ipv/') ||
                lowerPath.contains('face') ||
                lowerPath.contains('facefinder') ||
                lowerHost.contains('face');
            
            debugPrint('[HomePage] Special case: "redirect on verify is true" - calling get-context API');
            debugPrint('[HomePage] Extracted query from URL: $queryFromUri');

            // Call get-context API with verify param
            setState(() => _submitLoading = true);
            await store.fetchWorkflowFieldsWithAuth(
              widget.company,
              widget.workflowName,
              queryFromUri.isEmpty ? '' : '?$queryFromUri',
            );
            setState(() => _submitLoading = false);
            
            // Check for errors
            if (store.errorWithAuth != null) {
              debugPrint('[HomePage] Error after verify get-context: ${store.errorWithAuth}');
              Fluttertoast.showToast(msg: store.errorWithAuth ?? 'Error', gravity: ToastGravity.TOP);
            } else {
              debugPrint('[HomePage] Verify get-context completed successfully - data loaded in app');
            }

            // IPV/Face KYC case:
            // Backend provides a direct return URL (often with EMPTY query params).
            // In that scenario, we must open WebView automatically; otherwise user gets stuck on the non-IPV screen.
            if (isIpvOrFace && queryFromUri.isEmpty && mounted) {
              final ensuredRedirectUrl = _forceHttpsForRpd(redirectUrl);
              final friendlyTitle = _deriveWebViewTitle(msg, ensuredRedirectUrl);
              debugPrint('[HomePage] Auto-opening WebView for IPV/Face after verify reload: $redirectUrl');
              await _openWebViewWithTransitionLoader(ensuredRedirectUrl, friendlyTitle);
              return;
            }

            // If backend after verify-reload asks to redirect to some external page (often IPV),
            // handle it now. Otherwise user gets stuck until manual reload.
            final refreshed = store.fieldsWithAuth;
            if (refreshed is Map &&
                refreshed['redirect'] == true &&
                (refreshed['url']?.toString().isNotEmpty ?? false)) {
              final refreshedRedirectUrl = refreshed['url']!.toString();
              final refreshedMsg = refreshed['msg']?.toString() ?? msg;

              String refreshedFinalUrl;
              if (refreshedRedirectUrl.startsWith('http://') ||
                  refreshedRedirectUrl.startsWith('https://')) {
                refreshedFinalUrl = refreshedRedirectUrl;
              } else {
                // Relative URL - prepend baseUrl and preserve query params
                var relativeUrl = refreshedRedirectUrl.startsWith('/')
                    ? refreshedRedirectUrl
                    : '/$refreshedRedirectUrl';

                if (widget.queryParams.isNotEmpty && !relativeUrl.contains('state')) {
                  final separator = relativeUrl.contains('?') ? '&' : '?';
                  final preservedParams = widget.queryParams.entries
                      .where((e) => e.key != 'verifyCompleted')
                      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
                      .join('&');
                  if (preservedParams.isNotEmpty) {
                    relativeUrl = '$relativeUrl$separator$preservedParams';
                  }
                }

                refreshedFinalUrl = '${EnvConfig.baseUrl}$relativeUrl';
              }

              refreshedFinalUrl = _forceHttpsForRpd(refreshedFinalUrl);
              final friendlyTitle = _deriveWebViewTitle(refreshedMsg, refreshedFinalUrl);
              debugPrint('[HomePage] Opening WebView after verify reload (refreshed redirect): $refreshedFinalUrl');
              await _openWebViewWithTransitionLoader(refreshedFinalUrl, friendlyTitle);
              return;
            }

            return; // Don't open WebView for other verify modes (e.g. digilocker handled by backend via fields)
          }
        }
        
        // For all OTHER redirects - open WebView (like DigiLocker)
        // But if backend returns internal workflow path first (e.g. /bpwealth/individual),
        // do not open that URL in WebView. Refresh context once and open only external URL.
        if (_isInternalWorkflowRedirectUrl(redirectUrl)) {
          debugPrint(
              '[HomePage] Internal workflow redirect received - refreshing context once instead of opening WebView: $redirectUrl');
          await store.fetchWorkflowFieldsWithAuth(widget.company, widget.workflowName, '');
          final refreshed = store.fieldsWithAuth;
          if (refreshed is Map &&
              refreshed['redirect'] == true &&
              (refreshed['url']?.toString().isNotEmpty ?? false)) {
            final nextRedirectUrl = refreshed['url']!.toString();
            final refreshedMsg = refreshed['msg']?.toString() ?? msg;
            if (_isInternalWorkflowRedirectUrl(nextRedirectUrl)) {
              debugPrint(
                  '[HomePage] Refreshed redirect is still internal workflow URL - staying in app flow');
              return;
            }

            String refreshedFinalUrl;
            if (nextRedirectUrl.startsWith('http://') ||
                nextRedirectUrl.startsWith('https://')) {
              refreshedFinalUrl = nextRedirectUrl;
            } else {
              var relativeUrl =
                  nextRedirectUrl.startsWith('/') ? nextRedirectUrl : '/$nextRedirectUrl';
              if (widget.queryParams.isNotEmpty && !relativeUrl.contains('state')) {
                final separator = relativeUrl.contains('?') ? '&' : '?';
                final preservedParams = widget.queryParams.entries
                    .where((e) => e.key != 'verifyCompleted')
                    .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
                    .join('&');
                if (preservedParams.isNotEmpty) {
                  relativeUrl = '$relativeUrl$separator$preservedParams';
                }
              }
              refreshedFinalUrl = '${EnvConfig.baseUrl}$relativeUrl';
            }

            refreshedFinalUrl = _forceHttpsForRpd(refreshedFinalUrl);
            final friendlyTitle = _deriveWebViewTitle(refreshedMsg, refreshedFinalUrl);
            debugPrint(
                '[HomePage] Opening WebView after internal-redirect refresh: $refreshedFinalUrl');
            await _openWebViewWithTransitionLoader(refreshedFinalUrl, friendlyTitle);
          }
          return;
        }

        String finalUrl;
        if (redirectUrl.startsWith('http://') || redirectUrl.startsWith('https://')) {
          finalUrl = redirectUrl;
        } else {
          // Relative URL - prepend baseUrl and preserve query params
          var relativeUrl = redirectUrl.startsWith('/') ? redirectUrl : '/$redirectUrl';
          
          // Append existing query params if not already present
          if (widget.queryParams.isNotEmpty && !relativeUrl.contains('state')) {
            final separator = relativeUrl.contains('?') ? '&' : '?';
            final preservedParams = widget.queryParams.entries
                .where((e) => e.key != 'verifyCompleted')
                .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
                .join('&');
            if (preservedParams.isNotEmpty) {
              relativeUrl = '$relativeUrl$separator$preservedParams';
            }
          }
          
          finalUrl = '${EnvConfig.baseUrl}$relativeUrl';
        }
        
        finalUrl = _forceHttpsForRpd(finalUrl);
        final friendlyTitle = _deriveWebViewTitle(msg, finalUrl);
        debugPrint('[HomePage] Opening WebView for redirect (msg: $msg, title: $friendlyTitle): $finalUrl');
        await _openWebViewWithTransitionLoader(finalUrl, friendlyTitle);
      }
    }
  }

  /// RPD/reverse_pennydrop sometimes returns `http://...` URLs.
  /// Force `https://...` before opening the WebView.
  bool _isRpdRedirectUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('meon_reverse_pennydrop') ||
        lower.contains('reverse_pennydrop') ||
        lower.contains('reversepennydrop') ||
        lower.contains('rpd.meon');
  }

  String _forceHttpsForRpd(String url) {
    if (!_isRpdRedirectUrl(url)) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (url.toLowerCase().startsWith('http://')) {
        return 'https://${url.substring('http://'.length)}';
      }
      return url;
    }
    if (uri.scheme.toLowerCase() == 'http') {
      return uri.replace(scheme: 'https').toString();
    }
    return url;
  }

  /// Prevents "previous step/login screen" flash between redirect API completion
  /// and the actual WebView route rendering.
  Future<void> _openWebViewWithTransitionLoader(String finalUrl, String friendlyTitle) async {
    if (!mounted) return;

    _stopReturnFlowTimers();
    context.read<AppStore>().setReturningFromWebView(false);

    // Show a fully opaque white overlay so no home-page UI is visible during
    // the route transition. This pairs with the FadeTransition on the webview
    // route so the user sees white → white → WebView content with no flash.
    setState(() {
      _webViewTransitionActive = true;
      _webViewReturnError = null;
    });
    // Ensure the white overlay is painted before navigating.
    await WidgetsBinding.instance.endOfFrame;

    final encodedUrl = Uri.encodeComponent(finalUrl);
    final title = Uri.encodeComponent(friendlyTitle);
    context.go('/${widget.company}/${widget.workflowName}/webview?url=$encodedUrl&title=$title');

    // If this widget remains mounted (rare edge-case), clear the overlay so a
    // back-navigation doesn't leave the screen blank.
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      setState(() => _webViewTransitionActive = false);
    });
  }

  /// Derives a user-friendly WebView title based on redirect message and URL.
  /// Avoids showing internal messages like "redirect on render diverge" to the user.
  String _deriveWebViewTitle(String msg, String url) {
    String? module;
    final uri = Uri.tryParse(url);
    if (uri != null) {
      final host = uri.host.toLowerCase();
      final path = uri.path.toLowerCase();
      final query = uri.query.toLowerCase();

      if (path.contains('esign') ||
          query.contains('esign')) {
        module = 'Proceed to eSign';
      } else if (host.contains('digilocker') ||
          path.contains('digilocker') ||
          query.contains('digilocker')) {
        module = 'Digilocker';
      } else if (path.contains('meon_reverse_pennydrop') ||
          path.contains('reverse_pennydrop') ||
          path.contains('reversepennydrop') ||
          query.contains('reverse_pennydrop') ||
          query.contains('reversepennydrop') ||
          host.contains('rpd.meon')) {
        module = 'Bank Verification';
      } else if (path.contains('account_aggregator') ||
          query.contains('account_aggregator')) {
        module = 'Account Aggregator';
      } else if (host.contains('standardjourney.camsfinserv.com')) {
        module = 'Account Aggregator';
      } else if (host.contains('ipv') ||
          path.contains('ipv') ||
          path.contains('face')) {
        module = 'Face Verification';
      }
    }

    if (module != null) return module;

    final lowerMsg = msg.toLowerCase();
    if (lowerMsg.isNotEmpty && !lowerMsg.startsWith('redirect on ')) {
      return msg;
    }

    return 'Verification';
  }

  int _getStepperIndex(AppStore store, bool isAuth) {
    if (!isAuth) return 0;

    final currentIndex = store.getCurrentStepIndex();
    if (currentIndex != null) {
      debugPrint('[HomePage] Stepper index from AppStore: $currentIndex');
      return currentIndex;
    }

    final displayedSteps = _getStepperSteps(store);
    final ctx = (store.fieldsWithAuth as Map?)?['context'];
    var pageKey = store.currentPageId;
    if (pageKey == null || pageKey.isEmpty) {
      if (ctx is Map) {
        final page = ctx['page'];
        if (page is Map) {
          pageKey = page['id']?.toString();
        }
        pageKey ??= ctx['index']?.toString();
      }
    }

    // Never map duplicate positions (e.g. mobile_otp) without page id — that hits step 2.
    if (pageKey != null && pageKey.isNotEmpty) {
      final keyNum = int.tryParse(pageKey);
      if (keyNum != null && keyNum >= 1 && displayedSteps.isNotEmpty) {
        final idx = (keyNum - 1).clamp(0, displayedSteps.length - 1);
        debugPrint('[HomePage] Stepper index from page key $pageKey: $idx');
        return idx;
      }
      debugPrint(
          '[HomePage] Stepper index: page key $pageKey present but not mapped');
      return 0;
    }

    return 0;
  }
  
  List<String> _getStepperSteps(AppStore store) {
    // Get dynamic steps from stepper workflow API
    final steps = store.getStepperSteps();
    if (steps.isNotEmpty) {
      // debugPrint('[HomePage] Using dynamic stepper steps: $steps');
      return steps;
    }
    // Fallback to default steps
    return KycStepperBar.defaultSteps;
  }

  /// True when the user is mid authenticated KYC (never fall back to unauth workflow UI).
  bool _isMidAuthenticatedJourney(AppStore store) {
    return store.fieldsWithAuth != null || _cachedAuthenticatedPageFields != null;
  }

  void _cacheAuthenticatedStepUi({
    required AppStore store,
    required Map? ctx,
    String? pageTitle,
    dynamic activePage,
  }) {
    if (!_isMidAuthenticatedJourney(store) && ctx == null) {
      return;
    }
    final position = ctx?['position']?.toString();
    if (position != null && position.isNotEmpty) {
      _cachedPosition = position;
      if (!store.loadingWithAuth && !_submitLoading) {
        _headerDisplayPosition = position;
      }
    }
    if (pageTitle != null &&
        !pageTitle.toLowerCase().contains('start your kyc')) {
      _cachedPageTitle = pageTitle;
    }
    if (activePage is Map) {
      _cachedAuthenticatedPageFields = activePage;
    }
  }

  void _clearAuthenticatedStepCache() {
    _cachedAuthenticatedPageFields = null;
    _cachedPageTitle = null;
    _cachedPosition = null;
    _headerDisplayPosition = null;
    _fatcaTaxResidencyMustPickNo = false;
  }

  /// Position from get-context only when AppStore and context agree (fully settled).
  String? _resolveSyncedPositionFromStore(AppStore store) {
    final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
    final fromCtx = ctx?['position']?.toString().trim();
    if (fromCtx == null || fromCtx.isEmpty) {
      return null;
    }
    final fromStore = store.currentPosition?.trim();
    if (fromStore != null &&
        fromStore.isNotEmpty &&
        fromStore.toLowerCase() != fromCtx.toLowerCase()) {
      return null;
    }
    return fromCtx;
  }

  /// Pin current step in header before submit so the label does not vanish mid-save.
  void _captureHeaderPositionForSubmit(AppStore store) {
    final p = _resolveSyncedPositionFromStore(store) ??
        _cachedPosition?.trim() ??
        store.currentPosition?.trim();
    if (p != null && p.isNotEmpty) {
      _headerDisplayPosition = p;
    }
  }

  void _beginSubmitTransition(AppStore store) {
    _captureHeaderPositionForSubmit(store);
    final page = _getActiveFields(store);
    if (page is Map) {
      _submitFrozenPage = Map<dynamic, dynamic>.from(page);
    }
    _submitFrozenFormSnapshot =
        Map<String, dynamic>.from(_formNotifier.formData);
    final ctx = (store.fieldsWithAuth as Map?)?['context'];
    if (ctx is Map) {
      _submitFrozenContext = Map<String, dynamic>.from(
        ctx.map((k, v) => MapEntry(k.toString(), v)),
      );
    }
  }

  void _clearSubmitFreeze() {
    _submitFrozenPage = null;
    _submitFrozenFormSnapshot = null;
    _submitFrozenContext = null;
  }

  dynamic _activeFieldsForUi(AppStore store) {
    if (_submitLoading && _submitFrozenPage != null) {
      return _submitFrozenPage;
    }
    return _getActiveFields(store);
  }

  Map? _contextForUi(AppStore store) {
    if (_submitLoading && _submitFrozenContext != null) {
      return _submitFrozenContext;
    }
    return (store.fieldsWithAuth as Map?)?['context'] as Map?;
  }

  dynamic _displayFormValue(String name) {
    if (_submitLoading && _submitFrozenFormSnapshot != null) {
      if (_submitFrozenFormSnapshot!.containsKey(name)) {
        return _submitFrozenFormSnapshot![name];
      }
    }
    return _formNotifier.formData[name];
  }

  Future<void> _applyFreshStepAfterSuccessfulSubmit(AppStore store) async {
    final activeAfter = _getActiveFields(store);
    final listAfter = (activeAfter?['fields'] as List?) ?? [];
    final flowAfter = activeAfter?['conditionalFlow'] as List?;
    _formNotifier.updateFields(
      listAfter,
      flowAfter,
      fieldsWithAuth: store.fieldsWithAuth,
      replaceFormData: true,
    );
    _applyApiDefaultValues(listAfter);
    _runPersonalDetailsBpWealthPipeline(store, listAfter);
    _applyRpdReturnFieldIfNeeded(store, listAfter);
    final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
    _syncDigilockerAadharImage(
      store,
      listAfter,
      position: ctx?['position']?.toString(),
      pageLabel: ctx?['page']?['data']?['label']?.toString(),
    );
  }

  void _finishSubmitTransition({
    required AppStore store,
    required bool applyFreshStep,
  }) {
    if (applyFreshStep) {
      _applyFreshStepAfterSuccessfulSubmit(store);
    }
    _clearSubmitFreeze();
    if (mounted) setState(() => _submitLoading = false);
  }

  dynamic _getActiveFields(AppStore store) {
    if (_responseIndicatesKycCompleted(store.fieldsWithAuth)) {
      return null;
    }
    final withAuth = store.fieldsWithAuth;
    if (withAuth != null && withAuth is Map && withAuth['context'] != null) {
      final page = withAuth['context']['page'];
      if (page is Map) {
        final fields = page['fields'] as List?;
        if (fields != null && fields.isNotEmpty) {
          _cachedAuthenticatedPageFields = page;
          return page;
        }
        // Authenticated journey: keep auth page even if fields are momentarily empty.
        if (_isMidAuthenticatedJourney(store)) {
          return page;
        }
      }
    }
    if (_isMidAuthenticatedJourney(store) &&
        _cachedAuthenticatedPageFields != null) {
      return _cachedAuthenticatedPageFields;
    }
    return store.fields;
  }

  Widget _buildStepTransitionScaffold({
    required bool showStepper,
    required Widget stepperWidget,
    required String message,
  }) {
    return Scaffold(
      backgroundColor: KycTheme.background,
      body: SafeArea(
        child: showStepper
            ? Column(
                children: [
                  stepperWidget,
                  Expanded(
                    child: Loader(message: message, minimal: true),
                  ),
                ],
              )
            : Loader(message: message),
      ),
    );
  }

  /// Position + page label for form validation (same resolution as [_buildForm]).
  ({String? position, String? pageLabel}) _submitValidationStep(AppStore store) {
    final withAuth = store.fieldsWithAuth as Map?;
    final c = withAuth?['context'] as Map?;
    String? position = c?['position']?.toString().toLowerCase();
    String? pageLabel = c?['page']?['data']?['label']?.toString().toLowerCase();
    if ((position ?? '').isEmpty || (pageLabel ?? '').isEmpty) {
      final workflow = store.fields as Map?;
      position = (workflow?['position']?.toString() ?? '').toLowerCase();
      pageLabel = (workflow?['data']?['label']?.toString() ?? '').toLowerCase();
    }
    return (position: position, pageLabel: pageLabel);
  }

  /// `additional_nominee*`: toast only — submit button stays enabled.
  bool _toastAndBlockIfAdditionalNomineeTotalNot100(AppStore store) {
    final step = _submitValidationStep(store);
    if (!isAdditionalNomineeKycStep(step.position, step.pageLabel)) {
      return false;
    }
    final activeFields = _getActiveFields(store);
    final fieldList = (activeFields?['fields'] as List?) ?? [];
    final msg = validateAdditionalNomineeSubmitPercentageRequired100(
      fields: fieldList,
      formData: _formNotifier.formData,
      runtimeFieldVisibility: _formNotifier.fieldVisibility,
      company: widget.company,
      position: step.position,
      pageLabel: step.pageLabel,
    );
    if (msg == null) return false;
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.TOP,
      backgroundColor: Colors.orange.shade700,
      textColor: Colors.white,
    );
    return true;
  }

  /// When product caps at 3 nominees, workflow may still open additional_nominee*.
  /// If prior allocation is already 100%, auto-submit to advance past those steps.
  Future<bool> _maybeAutoSkipAdditionalNomineeForMaxThree(AppStore store) async {
    if (!kNomineeMaxThreeOnly) return false;
    // Allow nested skip for additional_nominee → additional_nominee_second (max 2).
    if (_autoSkipAdditionalNomineeDepth >= 2) return false;
    if (!mounted) return false;

    final step = _submitValidationStep(store);
    if (!isAdditionalNomineeKycStep(step.position, step.pageLabel)) {
      return false;
    }

    final fieldList = (_getActiveFields(store)?['fields'] as List?) ?? [];
    final prior = readPriorNomineeAllocatedPercent(
      formData: _formNotifier.formData,
      fields: fieldList,
      position: step.position,
      pageLabel: step.pageLabel,
    );
    if (prior < 99.999) {
      debugPrint(
        '[HomePage] Max-3: additional_nominee prior=$prior — not auto-skipping',
      );
      return false;
    }

    debugPrint(
      '[HomePage] Max-3: auto-skipping ${step.position}/${step.pageLabel} '
      '(prior=$prior depth=$_autoSkipAdditionalNomineeDepth)',
    );
    _formNotifier.formData[kExtraSecondNomineeField] = 'No';
    if (_findFieldDefByName(fieldList, kRemainNomineePercentField) != null) {
      _formNotifier.formData[kRemainNomineePercentField] = '100';
    }
    if (_findFieldDefByName(fieldList, kRemainNomineePercent2Field) != null) {
      _formNotifier.formData[kRemainNomineePercent2Field] = '100';
    }
    if (_findFieldDefByName(fieldList, kTotalNomineePercentage2Field) != null) {
      _formNotifier.formData[kTotalNomineePercentage2Field] = '100';
    }

    _autoSkipAdditionalNomineeDepth++;
    try {
      await _handleCommonSubmit(true);
    } finally {
      _autoSkipAdditionalNomineeDepth--;
    }
    return true;
  }

  void _showValidationFailureToast() {
    final formToast = _formNotifier.validationToastMessage;
    if (formToast != null && formToast.trim().isNotEmpty) {
      Fluttertoast.showToast(
        msg: formToast,
        toastLength: Toast.LENGTH_LONG,
        gravity: ToastGravity.TOP,
        backgroundColor: Colors.red.shade700,
        textColor: Colors.white,
      );
      return;
    }
    final errors = _formNotifier.errors;
    if (errors.isNotEmpty) {
      final firstError = errors.values.first;
      if (firstError != null && firstError.toString().isNotEmpty) {
        Fluttertoast.showToast(
          msg: firstError.toString(),
          toastLength: Toast.LENGTH_LONG,
          gravity: ToastGravity.TOP,
          backgroundColor: Colors.red.shade700,
          textColor: Colors.white,
        );
        return;
      }
    }
    Fluttertoast.showToast(
      msg: 'Please fill all required fields correctly',
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.TOP,
      backgroundColor: Colors.red.shade700,
      textColor: Colors.white,
    );
  }

  /// BP Wealth personal-details: UI grouping for standing-instruction fields (collapsed by default).
  bool _bpWealthPersonalDetailsStandingUi(String? position, String? pageLabel) {
    return _isBpWealthCompany &&
        ((position ?? '') == 'personal_details' ||
            (pageLabel ?? '') == 'personal_details');
  }

  bool _isOnboardingAuthStep(String? position, String? pageLabel) {
    final p = (position ?? '').toLowerCase();
    final l = (pageLabel ?? '').toLowerCase();
    if (p == 'mobile' || l == 'mobile') return true;
    if (p == 'mobile_otp' || p.startsWith('mobile_otp')) return true;
    if (p == 'email_otp' || p.startsWith('email_otp')) return true;
    return _isEmailCaptureStep(position, pageLabel);
  }

  bool _isEmailCaptureStep(String? position, String? pageLabel) {
    final p = (position ?? '').toLowerCase();
    final l = (pageLabel ?? '').toLowerCase();
    if (p == 'email_otp' || p.startsWith('email_otp')) return false;
    if (p == 'email' || l == 'email' || p == 'emailid' || p == 'email_id') {
      return true;
    }
    return p.startsWith('email') && !p.startsWith('email_otp');
  }

  bool _isPersonalDetailsStep(String? position, String? pageLabel) {
    return (position ?? '') == 'personal_details' ||
        (pageLabel ?? '') == 'personal_details';
  }

  /// When user returns from RPD via back, backend expects `rpd_return: true` on personal_details submit.
  void _applyRpdReturnFieldIfNeeded(
    AppStore store,
    List<dynamic> fieldList,
  ) {
    final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
    final position = ctx?['position']?.toString().toLowerCase() ?? '';
    final pageLabel =
        ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';
    if (!_isPersonalDetailsStep(position, pageLabel)) return;

    if (!store.rpdReturn) {
      final stale = _formNotifier.formData['rpd_return'];
      if (stale == true ||
          (stale is String && stale.toLowerCase() == 'true')) {
        _formNotifier.formData.remove('rpd_return');
        _activeFieldsSyncKey = null;
        debugPrint(
            '[HomePage] personal_details: removed stale rpd_return form value');
      }
      return;
    }

    final existing = _formNotifier.formData['rpd_return'];
    if (existing == true ||
        (existing is String && existing.toLowerCase() == 'true')) {
      return;
    }

    for (final f in fieldList) {
      if (f is! Map) continue;
      if (f['name']?.toString() != 'rpd_return') continue;
      final type = f['type']?.toString() ?? 'hidden';
      _formNotifier.handleChange(
        'rpd_return',
        true,
        type: type,
        validationType: f['validation']?.toString(),
      );
      debugPrint('[HomePage] personal_details: rpd_return form field set to true');
      return;
    }
  }

  bool _submissionIncludedRpdReturn(
    AppStore store,
    Map<String, dynamic> submissionData, {
    required String? position,
    required String? pageLabel,
  }) {
    if (!_isPersonalDetailsStep(position, pageLabel)) return false;
    if (store.rpdReturn) return true;
    final v = submissionData['rpd_return'];
    return v == true || v?.toString().toLowerCase() == 'true';
  }

  /// After personal_details submit with RPD return — stop passing `rpd_return` on later steps.
  void _clearRpdReturnState(AppStore store) {
    final hadGlobal = store.rpdReturn;
    final hadForm = _formNotifier.formData.containsKey('rpd_return');
    if (!hadGlobal && !hadForm) return;
    store.setRpdReturn(false);
    _formNotifier.formData.remove('rpd_return');
    _activeFieldsSyncKey = null;
    debugPrint('[HomePage] rpd_return cleared after personal_details submit');
  }

  /// Personal details fields currently set to Yes for tax residency outside India.
  List<Map<dynamic, dynamic>> _fatcaTaxResidencyYesFields(List<dynamic> fieldList) {
    final out = <Map<dynamic, dynamic>>[];
    for (final raw in fieldList) {
      if (raw is! Map) continue;
      final f = Map<dynamic, dynamic>.from(raw);
      if (!isTaxResidencyOutsideIndiaField(f)) continue;
      final name = f['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      if (isAffirmativeYesValue(_formNotifier.formData[name])) {
        out.add(f);
      }
    }
    return out;
  }

  void _resetFatcaTaxResidencyFieldsToNo(List<Map<dynamic, dynamic>> fields) {
    for (final f in fields) {
      final name = f['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final values = f['values'] as List?;
      final vNo = _matchRadioOption(values, 'No');
      _formNotifier.handleChange(
        name,
        vNo ?? 'No',
        type: f['type']?.toString() ?? 'select',
        validationType: f['validation']?.toString(),
        validateWith: f['validateWith']?.toString(),
      );
    }
  }

  /// After header refresh / get-context reload, unblock submit if form is not Yes.
  void _clearFatcaTaxResidencySubmitBlockIfFormAllows(List<dynamic> fieldList) {
    if (_fatcaTaxResidencyYesFields(fieldList).isNotEmpty) return;
    if (!_fatcaTaxResidencyMustPickNo) return;
    if (mounted) {
      setState(() => _fatcaTaxResidencyMustPickNo = false);
    } else {
      _fatcaTaxResidencyMustPickNo = false;
    }
  }

  Future<void> _refreshWorkflowFromHeader(AppStore store) async {
    store.clearAuthError();
    if (!mounted) return;
    setState(() {
      _webViewReturnError = null;
      _returnFlowMessage = 'Loading your next step...';
      _fatcaTaxResidencyMustPickNo = false;
      _refreshLoading = true;
    });
    try {
      await _loadWorkflow();
      if (!mounted) return;
      final active = _getActiveFields(store);
      final list = (active?['fields'] as List?) ?? <dynamic>[];
      final flow = active?['conditionalFlow'] as List?;
      _formNotifier.updateFields(
        list,
        flow,
        fieldsWithAuth: store.fieldsWithAuth,
      );
      _runPersonalDetailsBpWealthPipeline(store, list);
      _applyRpdReturnFieldIfNeeded(store, list);
      _clearFatcaTaxResidencySubmitBlockIfFormAllows(list);
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _refreshLoading = false);
    }
  }

  /// Resets tax residency to No, shows modal + toast. Returns true if submit must stop.
  bool _enforceFatcaTaxResidencyNoOnSubmit({
    required String? position,
    required String? pageLabel,
    required List<dynamic> fieldList,
  }) {
    if (!_isPersonalDetailsStep(position, pageLabel)) return false;
    final yesFields = _fatcaTaxResidencyYesFields(fieldList);
    if (!_fatcaTaxResidencyMustPickNo && yesFields.isEmpty) return false;

    if (yesFields.isNotEmpty) {
      _resetFatcaTaxResidencyFieldsToNo(yesFields);
    }
    if (mounted) {
      setState(() => _fatcaTaxResidencyMustPickNo = true);
    } else {
      _fatcaTaxResidencyMustPickNo = true;
    }
    if (mounted) setState(() {});

    Fluttertoast.showToast(
      msg: 'Tax Residency outside India must be marked as No to continue.',
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.TOP,
      backgroundColor: Colors.red.shade700,
      textColor: Colors.white,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showFatcaTaxResidencyBlockedModal();
    });
    return true;
  }

  /// FATCA: eKYC cannot proceed when tax residency outside India is Yes.
  Future<void> _showFatcaTaxResidencyBlockedModal() {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Since you have opted "Yes" for FATCA, you are not allowed to continue the process',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: KycTheme.textPrimary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 24),
                Material(
                  color: KycTheme.buttonEnabledPurple,
                  borderRadius: BorderRadius.circular(6),
                  child: InkWell(
                    onTap: () => Navigator.of(ctx).pop(),
                    borderRadius: BorderRadius.circular(6),
                    child: const SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showDdpiSebiCircularModal() {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        const bodyStyle = TextStyle(
          fontSize: 14,
          color: KycTheme.textPrimary,
          height: 1.45,
        );
        return Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "As per SEBI circular No's: SEBI/HO/MIRSD/DoP/CIR/2022/44 "
                          'Dated April 04, 2022',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: KycTheme.textPrimary,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'The use of DDPI (Demat Debit & Pledge Instruction) will be '
                          'limited only for below four purposes to authorize BP Equities '
                          'Pvt. Ltd. to access your Demat account only to meet:',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '1. Pay-in obligations for settlement or deliveries of trades '
                          'executed by you.',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '2. To pledge/re-pledge securities to avail margin on trades.',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '3. Mutual Fund Transactions being executed on Stock Exchanges '
                          'order entry platforms.',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '4. Tendering shares in open offers through Stock Exchanges '
                          'platforms.',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'In case any changes are required to the above purposes, kindly '
                          'proceed with the offline account opening process.',
                          style: bodyStyle,
                        ),
                        const SizedBox(height: 12),
                        Text.rich(
                          TextSpan(
                            style: bodyStyle,
                            children: const [
                              TextSpan(
                                text: 'Note: ',
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                              TextSpan(
                                text: 'One-time charge of ₹100/- (excluding GST) will be '
                                    'debited from your trading ledger account to enable DDPI',
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KycTheme.buttonEnabledPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 40,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'OK',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// PAN capture (`detailspan`), PAN verify (`pan`), and KRA details (`kradetails`): **DD/MM/YYYY**.
  bool _useDdMmYyyyPanDateStep(String? position, String? pageLabel) {
    if (isKraDetailsStep(position, pageLabel)) return true;
    final p = (position ?? '').toLowerCase();
    final l = (pageLabel ?? '').toLowerCase();
    return p == 'pan' ||
        l == 'pan' ||
        p.startsWith('detailspan') ||
        l.startsWith('detailspan');
  }

  /// Primary submit text: strip trailing arrows/chevrons from API `buttonName` (avoids double-arrow UI).
  String _primarySubmitLabel({
    required bool isMobileStep,
    required Map? submitButton,
  }) {
    if (isMobileStep) return 'Proceed';
    var s = (submitButton?['buttonName'] ?? 'Submit').toString().trim();
    if (s.isEmpty) s = 'Submit';
    while (true) {
      final t = s.replaceFirst(RegExp(r'[\s→➜➤▶›>]+$'), '');
      if (t == s || t.isEmpty) break;
      s = t.trim();
    }
    return s.isEmpty ? 'Submit' : s;
  }

  bool _isNomineeSubmitDisabled(String? position, String? pageLabel) {
    return isNomineeSubmitCtaDisabled(
      formData: _formNotifier.formData,
      position: position,
      pageLabel: pageLabel,
    );
  }

  Map<dynamic, dynamic>? _findFieldDefByName(
    List<dynamic> fieldList,
    String name,
  ) {
    for (final f in fieldList) {
      if (f is Map && f['name']?.toString() == name) {
        return f;
      }
    }
    return null;
  }

  void _setAddNomineeSelection({
    required List<dynamic> fieldList,
    required bool yes,
    required String? position,
    required String? pageLabel,
  }) {
    final def = _findFieldDefByName(fieldList, kAddNomineeField);
    if (def == null) return;
    final values = def['values'] as List?;
    final pick = resolveKycYesNoOptionValue(values, yes ? 'Yes' : 'No');
    if (!yes) {
      clearMainNomineeBlockFormData(
        formData: _formNotifier.formData,
        fields: fieldList,
      );
    }
    _formNotifier.handleChange(
      kAddNomineeField,
      pick,
      type: def['type']?.toString() ?? 'select',
      validationType: def['validation']?.toString(),
      validateWith: def['validateWith']?.toString(),
    );
    if (mounted) setState(() {});
  }

  List<Widget> _buildNomineeKycFormLayout({
    required List<dynamic> visibleFieldsForDisplay,
    required Map? otpField,
    required String? otpFieldName,
    required bool hasAadharImage,
    required dynamic activeFields,
    required AppStore store,
    required List<dynamic> fieldList,
    required String? position,
    required String? pageLabel,
    required Map? ctx,
  }) {
    final addingNominee = isAddNomineeSelectedYes(_formNotifier.formData);
    final rows = <Widget>[];

    // Always show Add Nominee Details Yes/No (API field) — was hidden by custom landing.
    final addNomineeField = _findFieldDefByName(fieldList, kAddNomineeField);
    if (addNomineeField != null) {
      rows.add(
        _buildFormFieldRow(
          field: Map<dynamic, dynamic>.from(addNomineeField),
          otpField: otpField,
          otpFieldName: otpFieldName,
          hasAadharImage: hasAadharImage,
          activeFields: activeFields,
          store: store,
          fieldList: fieldList,
          position: position,
          pageLabel: pageLabel,
          ctx: ctx,
        ),
      );
    }

    if (addingNominee) {
      rows.add(NomineeStepSection.maxNomineesHint());
      for (final raw in visibleFieldsForDisplay) {
        if (raw is! Map) continue;
        final fieldMap = Map<dynamic, dynamic>.from(raw);
        final name = fieldMap['name']?.toString() ?? '';
        if (!NomineeStepSection.isNomineeFormContentField(name)) continue;

        if (NomineeStepSection.shouldRenderStyledAddCheckbox(
          name: name,
          formData: _formNotifier.formData,
        )) {
          rows.add(
            NomineeStepSection.optionalAddCheckboxButton(
              onTap: () {
                _formNotifier.handleChange(
                  name,
                  true,
                  type: fieldMap['type']?.toString() ?? 'checkbox',
                  validationType: fieldMap['validation']?.toString(),
                  validateWith: fieldMap['validateWith']?.toString(),
                );
                if (mounted) setState(() {});
              },
            ),
          );
          continue;
        }

        if (isNomineeStyledAddCheckboxField(name) &&
            isCheckboxCheckedValue(_formNotifier.formData[name])) {
          continue;
        }

        rows.add(
          _buildFormFieldRow(
            field: fieldMap,
            otpField: otpField,
            otpFieldName: otpFieldName,
            hasAadharImage: hasAadharImage,
            activeFields: activeFields,
            store: store,
            fieldList: fieldList,
            position: position,
            pageLabel: pageLabel,
            ctx: ctx,
          ),
        );
      }
    }

    return rows;
  }

  /// One dynamic form row (shared by main list and Standing Instructions expansion).
  Widget _buildFormFieldRow({
    required Map<dynamic, dynamic> field,
    required Map? otpField,
    required String? otpFieldName,
    required bool hasAadharImage,
    required dynamic activeFields,
    required AppStore store,
    required List<dynamic> fieldList,
    required String? position,
    required String? pageLabel,
    required Map? ctx,
  }) {
    final name = field['name']?.toString() ?? '';
    final type = field['type']?.toString() ?? 'text';
    final lowerName = name.toLowerCase();
    final isAadharImageField =
        lowerName == 'aadhar_image' || lowerName == 'aadhaar_image';
    if (isAadharImageField && hasAadharImage) {
      return const SizedBox.shrink();
    }
    if (otpField != null && name == otpFieldName) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: _buildOtpVerifyCard(otpField, activeFields),
      );
    }

    if (isAdditionalNomineeKycStep(position, pageLabel) &&
        NomineeStepSection.shouldRenderStyledAddCheckbox(
          name: name,
          formData: _formNotifier.formData,
        )) {
      return NomineeStepSection.optionalAddCheckboxButton(
        onTap: () {
          _formNotifier.handleChange(
            name,
            true,
            type: type,
            validationType: field['validation']?.toString(),
            validateWith: field['validateWith']?.toString(),
          );
          if (mounted) setState(() {});
        },
      );
    }

    if (isAdditionalNomineeKycStep(position, pageLabel) &&
        isNomineeStyledAddCheckboxField(name) &&
        isCheckboxCheckedValue(_formNotifier.formData[name])) {
      return const SizedBox.shrink();
    }

    final label = ctx?['page']?['data']?['label']?.toString()?.toLowerCase();
    final isBankScreen = position == 'bank' ||
        position == 'bank_details' ||
        label == 'bank';
    final isIfscField = isBankScreen &&
        (name == 'ifsc' || name.toLowerCase().contains('ifsc'));

    final editableFields = _formNotifier.editableFieldsList;
    final disableFromConditionalFlow =
        editableFields.any((e) => e is Map && e['name'] == name);
    final disableOnFetchedDataReview = fetchedDataReviewFieldReadOnly(
      position,
      pageLabel,
      field,
    );
    final isKraContinueChoice = isKraDetailsStep(position, pageLabel) &&
        kraDetailsContinueWithKraChoiceField(field);
    final disable = !isKraContinueChoice &&
        (disableFromConditionalFlow || disableOnFetchedDataReview);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          FormFieldWidget(
            key: ValueKey<String>(name),
            name: name,
            displayName: field['displayName'] ?? name,
            type: type,
            fileType: field['fileType'] as List?,
            size: field['size'],
            mandatory: field['mandatory'] == true,
            validation: field['validation'],
            popupAfterSubmit: activeFields?['popupAfterSubmit'] as List?,
            value: _coalesceFormFieldValue(
              _displayFormValue(name),
              resolveApiFieldSeedValue(field),
              type: type,
            ),
            onGoogleSignIn: _handleGoogleSignIn,
            googleSignInLoading: _googleSignInLoading,
            onChange: (n, v) {
              final f = fieldList.cast<Map?>().firstWhere(
                    (x) => x?['name'] == n,
                    orElse: () => null,
                  );
              final previousValue = _formNotifier.formData[n];
              final changedField = f ?? field;
              final isTaxResidencyYesOnPersonalDetails =
                  _isPersonalDetailsStep(position, pageLabel) &&
                      isTaxResidencyOutsideIndiaField(changedField) &&
                      isAffirmativeYesValue(v);
              if (_isPersonalDetailsStep(position, pageLabel) &&
                  isTaxResidencyOutsideIndiaField(changedField) &&
                  !isAffirmativeYesValue(v)) {
                if (_fatcaTaxResidencyMustPickNo && mounted) {
                  setState(() => _fatcaTaxResidencyMustPickNo = false);
                }
              }
              if (isTaxResidencyYesOnPersonalDetails) {
                final values = changedField['values'] as List?;
                final vNo = _matchRadioOption(values, 'No');
                if (mounted) {
                  setState(() => _fatcaTaxResidencyMustPickNo = true);
                } else {
                  _fatcaTaxResidencyMustPickNo = true;
                }
                _formNotifier.handleChange(
                  n,
                  vNo ?? 'No',
                  type: f?['type'] ?? changedField['type']?.toString() ?? 'select',
                  validationType: f?['validation']?.toString(),
                  validateWith: f?['validateWith']?.toString(),
                );
                if (mounted) setState(() {});
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _showFatcaTaxResidencyBlockedModal();
                });
                return;
              }

              final isDdpiYesOnPersonalDetails = _isPersonalDetailsStep(
                    position,
                    pageLabel,
                  ) &&
                  isDdpiFormField(changedField) &&
                  isDdpiAffirmativeValue(v) &&
                  !isDdpiAffirmativeValue(previousValue);
              _formNotifier.handleChange(
                n,
                v,
                type: f?['type'] ?? 'text',
                validationType: f?['validation']?.toString(),
                validateWith: f?['validateWith']?.toString(),
              );
              if (n == 'sebi_3years' || n == 'sebi_3year') {
                final pastVal = _formNotifier.formData['past_action'];
                if (pastVal is bool) {
                  _formNotifier.handleChange(
                    'past_action',
                    '',
                    type: 'text',
                  );
                }
              }
              if (isDdpiYesOnPersonalDetails) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _showDdpiSebiCircularModal();
                });
              }
              if (pageLabel == 'mobile' &&
                  (n == 'mobile' || n == 'phone' || n == 'mobile_number')) {
                setState(() => _showMobileError = false);
              }
            },
            onBlur: (n) {
              _formNotifier.handleBlur(
                n,
                position: position,
                pageLabel: pageLabel,
              );
              if (isIfscField) {
                final ifscValue = _formNotifier.formData[n]?.toString() ?? '';
                if (ifscValue.length == 11) {
                  _fetchBankDetailsByIfsc(ifscValue);
                }
              }
            },
            values: field['values'] as List?,
            visible: true,
            errorField: _formNotifier.errors[name],
            rows: field['rows'] is int
                ? field['rows']
                : int.tryParse(field['rows']?.toString() ?? ''),
            cols: field['cols'] is int
                ? field['cols']
                : int.tryParse(field['cols']?.toString() ?? ''),
            urlCompany: widget.company,
            workflowKey: store.resolveWorkflowKey(),
            disable: disable,
            apiFieldMeta: field,
            useDdMmYyyyDateDisplay: _useDdMmYyyyPanDateStep(position, pageLabel),
          ),
          if (isIfscField) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () {
                final ifscValue = _formNotifier.formData[name]?.toString() ?? '';
                if (ifscValue.length == 11) {
                  _fetchBankDetailsByIfsc(ifscValue);
                } else {
                  Fluttertoast.showToast(
                      msg: 'Please enter valid 11-digit IFSC code',
                      gravity: ToastGravity.TOP);
                }
              },
              icon: const Icon(Icons.search, size: 20),
              label: const Text('Fetch Bank Details'),
              style: OutlinedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                side: BorderSide(color: KycTheme.primary),
                foregroundColor: KycTheme.primary,
              ),
            ),
          ],
          if (pageLabel == 'mobile' &&
              (name == 'mobile' || name == 'phone' || name == 'mobile_number') &&
              _showMobileError) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Please enter a valid 10-digit mobile number',
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> _prepareFormData(bool skipValidation) async {
    final data = Map<String, dynamic>.from(_formNotifier.formData);
    // Do not send `save` in kyc-post-v2 body (backend expectation).

    final store = context.read<AppStore>();
    final activeFields = _getActiveFields(store);
    final fieldList = activeFields?['fields'] as List?;
    final ctx = (store.fieldsWithAuth as Map?)?['context'];
    final nomineePos = ctx?['position']?.toString();
    final nomineeLbl = ctx?['page']?['data']?['label']?.toString();
    applyNomineeStepSubmitPayload(
      data: data,
      fields: fieldList,
      runtimeFieldVisibility: _formNotifier.fieldVisibility,
      company: widget.company,
      position: nomineePos,
      pageLabel: nomineeLbl,
    );

    // Add brokerage_plan for segments screen
    var panPos = ctx?['position']?.toString().toLowerCase() ?? '';
    var panLbl = ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';
    if (panPos.isEmpty || panLbl.isEmpty) {
      final workflow = store.fields as Map?;
      panPos = (workflow?['position']?.toString() ?? panPos).toLowerCase();
      panLbl = (workflow?['data']?['label']?.toString() ?? panLbl).toLowerCase();
    }
    final pathSegment = _getKycPostPathSegment(ctx);
    if (isPanVerifyKycPostStep(panPos, pathSegment)) {
      final normalized = buildPanVerifyKycPostBody(data);
      data
        ..clear()
        ..addAll(normalized);
      _syncPanVerifyFieldsToForm(normalized);
    } else if (_useDdMmYyyyPanDateStep(panPos, panLbl)) {
      final apiPanDob = tryFormatKycPanDobForMatchApi(data['pan_dob_for_match']);
      if (apiPanDob != null) data['pan_dob_for_match'] = apiPanDob;
      final rawName = data['name']?.toString();
      if (rawName != null && rawName.trim().isNotEmpty) {
        data['name'] = rawName.trim().toUpperCase();
      }
      final rawPan = data['pan_number']?.toString();
      if (rawPan != null && rawPan.trim().isNotEmpty) {
        data['pan_number'] = rawPan.trim().toUpperCase();
      }
    }
    final position = ctx?['position']?.toString()?.toLowerCase();
    if (position == 'segments') {
      // UI no longer exposes MTF / currency; keep payload aligned with backend.
      data['mtf'] = false;
      data['nse_currency'] = false;
      data['bse_currency'] = false;
      // All visible segments selected by default.
      data['nse_cash'] = true;
      data['bse_cash'] = true;
      data['nse_fo'] = true;
      data['bse_fo'] = true;
      data['mf'] = true;
      // NSE SLBM is not selectable — always submit as false.
      data['nse_slbm'] = false;
      if ((data['brokerage_plan']?.toString().trim() ?? '').isEmpty) {
        data['brokerage_plan'] = 'Brokerage Plan';
      }
    }

    // Only send fields for the active step — not entire accumulated formData.
    if (fieldList != null && position != 'segments') {
      final filtered = isNomineeExtendedUiStep(nomineePos, nomineeLbl)
          ? buildNomineeKycPostV2Body(data: data, fields: fieldList)
          : filterKycPostV2BodyForStep(
              data: data,
              fields: fieldList,
              runtimeFieldVisibility: _formNotifier.fieldVisibility,
              company: widget.company,
              position: nomineePos,
              pageLabel: nomineeLbl,
            );
      data
        ..clear()
        ..addAll(filtered);
      syncExtraNomineeSubmitPayload(
        data: data,
        fields: fieldList,
        runtimeFieldVisibility: _formNotifier.fieldVisibility,
        company: widget.company,
        position: nomineePos,
        pageLabel: nomineeLbl,
      );
      // After filter: re-inject step % total (filter drops hidden computed fields).
      syncNomineeStepPercentTotalsSubmitPayload(
        data: data,
        fields: fieldList,
        position: nomineePos,
        pageLabel: nomineeLbl,
      );
    }

    // Step filter drops companion keys like `{fileField}_pass` (not in API field list).
    // Web sends them with the upload — re-inject from formData for every File on this step.
    for (final e in List<MapEntry<String, dynamic>>.from(data.entries)) {
      if (e.value is! File) continue;
      final passKey = '${e.key}_pass';
      final passVal = _formNotifier.formData[passKey];
      if (passVal == null) continue;
      final passStr = passVal.toString();
      if (passStr.isEmpty) continue;
      data[passKey] = passStr;
      debugPrint(
        '[HomePage] Re-injected PDF password field: $passKey (len=${passStr.length})',
      );
    }

    if (store.rpdReturn &&
        _isPersonalDetailsStep(nomineePos, nomineeLbl)) {
      data['rpd_return'] = true;
    }

    if (activeFields == null) return data;
    if (fieldList == null) return data;
    final hasFile = fieldList.any((f) => f is Map && f['type'] == 'file');
    if (!hasFile) return data;

    final req = http.MultipartRequest(
      'POST',
      Uri.parse('${EnvConfig.baseUrl}/api/get-user/${widget.company}/${widget.workflowName}'),
    );
    for (final e in data.entries) {
      final v = e.value;
      if (v is File) {
        req.files.add(await http.MultipartFile.fromPath(e.key, v.path));
      } else if (v is bool) {
        req.fields[e.key] = v.toString();
      } else if (v != null) {
        req.fields[e.key] = v.toString();
      }
    }
    return data; // Caller uses multipart separately
  }

  Future<void> _handleSubmit(bool skipValidation) async {
    _submitError = '';
    _submitSuccess = '';
    final store = context.read<AppStore>();

    // Enforce Terms & Conditions on mobile login step
    if (!skipValidation) {
      final withAuth = store.fieldsWithAuth as Map?;
      final ctx = withAuth?['context'] as Map?;

      String position = ctx?['position']?.toString().toLowerCase() ?? '';
      String label = ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';

      if (position.isEmpty || label.isEmpty) {
        final workflow = store.fields as Map?;
        position = (workflow?['position']?.toString() ?? position).toLowerCase();
        label = (workflow?['data']?['label']?.toString() ?? label).toLowerCase();
      }

      debugPrint('[HomePage] _handleSubmit position=$position label=$label');

      final isMobileScreen = position == 'mobile' && label == 'mobile';
      if (isMobileScreen) {
        if (!_termsAccepted) {
          setState(() {
            _showTermsError = true;
            _showMobileError = false;
          });
          Fluttertoast.showToast(
            msg: 'Please accept the Terms & Conditions to continue',
            toastLength: Toast.LENGTH_LONG,
            gravity: ToastGravity.TOP,
            backgroundColor: Colors.red.shade700,
            textColor: Colors.white,
          );
          return;
        }
        final mobile = _formNotifier.formData['mobile'] ?? _formNotifier.formData['phone'] ?? _formNotifier.formData['mobile_number'] ?? '';
        final digits = mobile.toString().replaceAll(RegExp(r'\D'), '');
        if (digits.length != 10 || !RegExp(r'^[6-9]').hasMatch(digits)) {
          setState(() {
            _showMobileError = true;
            _showTermsError = false;
          });
          Fluttertoast.showToast(
            msg: 'Please enter a valid 10-digit mobile number',
            toastLength: Toast.LENGTH_LONG,
            gravity: ToastGravity.TOP,
            backgroundColor: Colors.red.shade700,
            textColor: Colors.white,
          );
          return;
        }
      }
    }

    if (!skipValidation) {
      final step = _submitValidationStep(store);
      final isValid = _formNotifier.validate(
        company: widget.company,
        position: step.position,
        pageLabel: step.pageLabel,
      );
      if (!isValid) {
        debugPrint('[HomePage] Send OTP / Submit: validation failed');
        debugPrint('[HomePage] Validation errors: ${_formNotifier.errors}');
        _showValidationFailureToast();
        return;
      }
      if (_toastAndBlockIfAdditionalNomineeTotalNot100(store)) return;
    }
    FocusScope.of(context).unfocus();
    debugPrint('[HomePage] Send OTP / Submit START');
    await _waitIfGetContextInFlight(store);
    if (!mounted) return;
    setState(() {
      _beginSubmitTransition(store);
      _submitLoading = true;
    });

    try {
      final data = await _prepareFormData(skipValidation);
      debugPrint('[HomePage] Form data (Send OTP): $data');
      final activeFields = _getActiveFields(store);
      final fieldList = (activeFields?['fields'] as List?) ?? [];
      final hasFile = fieldList.any((f) => f is Map && f['type'] == 'file') ||
                      data.values.any((v) => v is File);
      
      // Check saveFilesAPI flag from context.page (check both fieldsWithAuth and fields)
      final withAuth = store.fieldsWithAuth as Map?;
      final workflow = store.fields as Map?;
      final ctx = (withAuth?['context'] ?? workflow?['context']) as Map?;
      final page = ctx?['page'] as Map?;
      final saveFilesAPI = page?['saveFilesAPI'] == true;
      debugPrint('[HomePage] _handleSubmit saveFilesAPI flag: $saveFilesAPI');
      
      final endpoint = '/api/get-user/${widget.company}/${widget.workflowName}';
      final fullUrl = '${EnvConfig.baseUrl}$endpoint';
      debugPrint('[HomePage] _handleSubmit hasFile=$hasFile');
      debugPrint('[HomePage] _handleSubmit FULL URL: $fullUrl');
      debugPrint('[HomePage] _handleSubmit ENDPOINT: $endpoint');

      // If saveFilesAPI is true, upload files separately first
      if (hasFile && saveFilesAPI) {
        debugPrint('[HomePage] _handleSubmit saveFilesAPI=true: Uploading files separately to /api/upload_files_new');
        final filesToUpload = <String, File>{};
        
        // Extract files from data
        for (final e in data.entries) {
          if (e.value is File) {
            filesToUpload[e.key] = e.value as File;
          }
        }
        
        // Upload each file separately to /api/upload_files_new
        for (final entry in filesToUpload.entries) {
          final fileKey = entry.key; // e.g., signature_upload, pan_upload, etc.
          final file = entry.value;
          
          try {
            debugPrint('[HomePage] _handleSubmit Uploading file: $fileKey = ${file.path}');
            final client = ApiClient();
            final uploadRes = await client.postMultipart(
              () async {
                final uploadReq = http.MultipartRequest(
                  'POST',
                  Uri.parse('${EnvConfig.baseUrl}/api/upload_files_new'),
                );
                uploadReq.headers['accept'] = '*/*';
                uploadReq.files.add(await http.MultipartFile.fromPath(fileKey, file.path));
                return uploadReq;
              },
              skipRefreshOn401: true,
            );
            debugPrint('[HomePage] _handleSubmit File upload response for $fileKey: ${uploadRes.statusCode}');
            
            if (uploadRes.statusCode < 200 || uploadRes.statusCode >= 300) {
              debugPrint('[HomePage] _handleSubmit File upload failed for $fileKey: ${uploadRes.body}');
              Fluttertoast.showToast(
                msg: 'Failed to upload $fileKey',
                gravity: ToastGravity.TOP,
              );
              if (mounted) {
                _clearSubmitFreeze();
                setState(() => _submitLoading = false);
              }
              return;
            }
          } catch (e) {
            debugPrint('[HomePage] _handleSubmit Error uploading file $fileKey: $e');
            Fluttertoast.showToast(
              msg: 'Error uploading file: $e',
              gravity: ToastGravity.TOP,
            );
            if (mounted) {
              _clearSubmitFreeze();
              setState(() => _submitLoading = false);
            }
            return;
          }
        }
        
        // Remove files from data after successful upload
        for (final key in filesToUpload.keys) {
          data.remove(key);
        }
        debugPrint('[HomePage] _handleSubmit Files uploaded successfully, continuing with form submission');
      }

      if (hasFile && !saveFilesAPI) {
        // Use multipart/form-data for file uploads (existing flow when saveFilesAPI=false)
        final client = ApiClient();
        final res = await client.postMultipart(() async {
          final req = http.MultipartRequest('POST', Uri.parse(fullUrl));
          for (final e in data.entries) {
            final v = e.value;
            if (v is File) {
              req.files.add(await http.MultipartFile.fromPath(e.key, v.path));
            } else if (v is bool) {
              req.fields[e.key] = v.toString();
            } else if (v != null) {
              req.fields[e.key] = v.toString();
            }
          }
          return req;
        });
        await _handleSubmitResponse(res, store);
      } else {
        // Use JSON for non-file submissions (or after files uploaded separately)
        final headers = {'Content-Type': 'application/json'};
        final res = await KycAPI.submitKyc(
          widget.company,
          widget.workflowName,
          data,
          headers,
        );
        await _handleSubmitResponse(res, store);
      }
    } catch (e, st) {
      debugPrint('[HomePage] Send OTP / Submit Exception: $e\n$st');
      Fluttertoast.showToast(msg: e.toString(), gravity: ToastGravity.TOP);
    } finally {
      if (mounted && _submitFrozenPage != null) {
        _clearSubmitFreeze();
        setState(() => _submitLoading = false);
      }
      debugPrint('[HomePage] Send OTP / Submit DONE');
    }
  }

  Future<void> _handleSubmitResponse(http.Response res, AppStore store) async {
    debugPrint('[HomePage] _handleSubmitResponse status=${res.statusCode} body=${res.body.length > 300 ? res.body.substring(0, 300) + "..." : res.body}');
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>?;
    } catch (_) {
      body = null;
    }
    try {
      if (res.statusCode >= 200 && res.statusCode < 300 && body?['success'] == true) {
        final ctxBeforeRefresh =
            (store.fieldsWithAuth as Map?)?['context'] as Map?;
        final submitPosition =
            ctxBeforeRefresh?['position']?.toString().toLowerCase() ?? '';
        final submitLabel = ctxBeforeRefresh?['page']?['data']?['label']
                ?.toString()
                .toLowerCase() ??
            '';
        final submittedPersonalDetailsWithRpdReturn = store.rpdReturn &&
            _isPersonalDetailsStep(submitPosition, submitLabel);

        final token = body?['access_token'] as String?;
        final refresh = body?['refresh_token'] as String?;
        if (token != null) StorageService.setAccessToken(token);
        if (refresh != null) StorageService.setRefreshToken(refresh);
        StorageService.setAuthSuccess('true');
        StorageService.setMessage(body?['msg']?.toString() ?? '');
        StorageService.setUserStep(body?['position']?.toString() ?? '');
        final formSnapshot = Map<String, dynamic>.from(_formNotifier.formData);
        final digitsBeforeReset = _digitsFromFormMapOnly(formSnapshot);
        if (digitsBeforeReset.length == 10) {
          _persistedMobileDigitsForOtp = digitsBeforeReset;
        }
        final emailBeforeReset = _resolveEmailForOtpUi(formSnapshot);
        if (emailBeforeReset.contains('@')) {
          _persistedEmailForOtp = emailBeforeReset;
        }
        if (submittedPersonalDetailsWithRpdReturn) {
          _clearRpdReturnState(store);
        }
        // Keep filled values visible until get-context returns; then clear and apply new step.
        await store.fetchWorkflowFieldsWithAuth(widget.company, widget.workflowName, '');
        if (mounted && store.errorWithAuth != null) {
          await _handleGetContextFailureAfterSubmit(store);
          return;
        }
        if (mounted) {
          final authResponse = store.fieldsWithAuth;
          if (_responseIndicatesKycCompleted(authResponse)) {
            _clearSubmitFreeze();
            setState(() => _submitLoading = false);
            await _navigateToKycCompletedIfNeeded(store);
            return;
          }
        }
        if (mounted) {
          await Future.delayed(const Duration(milliseconds: 300));
          _applyFreshStepAfterSuccessfulSubmit(store);
          final ctx = store.fieldsWithAuth as Map?;
          final pos =
              ctx?['context']?['position']?.toString().toLowerCase() ?? '';
          if (pos == 'mobile_otp') {
            _applyPersistedMobileToForm();
            _persistedEmailForOtp = null;
          } else if (pos == 'email_otp') {
            _persistedMobileDigitsForOtp = null;
            _applyPersistedEmailToForm();
          } else {
            _persistedMobileDigitsForOtp = null;
            _persistedEmailForOtp = null;
          }
          final nextLabel = ctx?['context']?['page']?['data']?['label']
                  ?.toString()
                  .toLowerCase() ??
              '';
          if (pos == 'mobile' || nextLabel == 'mobile') {
            _applyPersistedGoogleNameToForm();
          }
          _clearSubmitFreeze();
          setState(() => _submitLoading = false);
          // Workflow still opens additional_nominee even with extra_nominee=No —
          // auto-advance those steps when product caps at 3 nominees.
          if (await _maybeAutoSkipAdditionalNomineeForMaxThree(store)) {
            return;
          }
          await _checkAndHandleRedirect(store);
        }
      } else if (_isSessionOverlapResponse(body)) {
        await _recoverFromSessionOverlap(store);
      } else {
        final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
        final position =
            ctx?['position']?.toString().toLowerCase() ?? '';
        final pageLabel =
            ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';
        final pathSegment = _getKycPostPathSegment(ctx).toLowerCase();
        final errMsg = _resolveSubmitErrorMessage(
          position: position,
          pageLabel: pageLabel,
          pathSegment: pathSegment,
          statusCode: res.statusCode,
          bodyStr: res.body,
          body: body,
        );
        if (_isPanKycStep(position, pageLabel)) {
          _showPanStepKycPostFeedback(errMsg, isError: true);
        } else {
          Fluttertoast.showToast(msg: errMsg, gravity: ToastGravity.TOP);
        }
        if (mounted) {
          _clearSubmitFreeze();
          setState(() => _submitLoading = false);
        }
      }
    } catch (_) {
      Fluttertoast.showToast(msg: 'Submission failed', gravity: ToastGravity.TOP);
      if (mounted) {
        _clearSubmitFreeze();
        setState(() => _submitLoading = false);
      }
    }
  }

  bool _isPanKycStep(String? position, String? pageLabel) {
    return _useDdMmYyyyPanDateStep(position, pageLabel);
  }

  /// `kyc-post-v2` body: prefer API `msg` / `message` as returned (e.g. PAN step).
  static String? _kycPostV2UserMessage(Map<String, dynamic>? body) {
    if (body == null) return null;
    for (final key in ['msg', 'message', 'error']) {
      final v = body[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  /// Backend: journey advanced elsewhere / stale step cursor — sync via get-context.
  static bool _isSessionOverlapResponse(Map<String, dynamic>? body) {
    final msg = _kycPostV2UserMessage(body)?.toLowerCase() ?? '';
    return msg.contains('session overlap') ||
        msg.contains('another tab') ||
        msg.contains('latest step');
  }

  Future<void> _waitIfGetContextInFlight(AppStore store) async {
    var waits = 0;
    while (store.loadingWithAuth && waits < 40) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      waits++;
    }
  }

  /// Sync UI to server's latest step after "Session overlap detected".
  Future<void> _recoverFromSessionOverlap(AppStore store) async {
    debugPrint('[HomePage] Session overlap — refreshing get-context to latest step');
    Fluttertoast.showToast(
      msg: 'Syncing your latest step...',
      gravity: ToastGravity.TOP,
    );
    await store.fetchWorkflowFieldsWithAuth(
      widget.company,
      widget.workflowName,
      '',
    );
    if (!mounted) return;
    if (store.errorWithAuth != null) {
      if (store.invalidUserSession) {
        await _recoverInvalidSessionViaSso(store);
        if (mounted) {
          await store.fetchWorkflowFieldsWithAuth(
            widget.company,
            widget.workflowName,
            '',
          );
        }
      }
    }
    if (!mounted) return;
    if (store.fieldsWithAuth is Map && store.errorWithAuth == null) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      _applyFreshStepAfterSuccessfulSubmit(store);
      _clearSubmitFreeze();
      setState(() => _submitLoading = false);
      await _checkAndHandleRedirect(store);
      Fluttertoast.showToast(
        msg: 'Updated to your latest step. Please continue.',
        gravity: ToastGravity.TOP,
      );
      return;
    }
    _finishSubmitTransition(store: store, applyFreshStep: false);
    Fluttertoast.showToast(
      msg: 'Please try again to continue from your latest step.',
      gravity: ToastGravity.TOP,
    );
  }

  String _resolveSubmitErrorMessage({
    required String position,
    required String pageLabel,
    required String pathSegment,
    required int statusCode,
    required String bodyStr,
    Map<String, dynamic>? body,
  }) {
    final errMsg = _kycPostV2UserMessage(body) ??
        _errorMessageFromResponse(statusCode, bodyStr);
    if (isDetailspanKycStep(position, pageLabel) ||
        pathSegment.toLowerCase().startsWith('detailspan')) {
      return detailspanPanDuplicateFriendlyMessage(_kycPostV2UserMessage(body)) ??
          errMsg;
    }
    return errMsg;
  }

  /// PAN already saved on this session — refresh workflow and continue (web parity).
  Future<bool> _tryRecoverPanVerifyAlreadyExists(
    AppStore store, {
    required Map<String, dynamic> submissionData,
  }) async {
    await store.fetchUserDetails();
    final ud = userDetailsDataMap(store.userDetails);
    if (!panNumberMatchesUserDetails(submissionData, ud)) {
      debugPrint(
          '[HomePage] PAN already exists but user-details PAN mismatch — not recovering');
      return false;
    }
    debugPrint(
        '[HomePage] PAN already on this journey — refreshing get-context to advance');
    await store.fetchWorkflowFieldsWithAuth(
      widget.company,
      widget.workflowName,
      '',
    );
    return store.errorWithAuth == null;
  }

  void _showPanStepKycPostFeedback(String message, {required bool isError}) {
    if (!mounted) return;
    // API often returns message "working" on success — not user-facing copy.
    if (message.trim().toLowerCase() == 'working') return;
    setState(() {
      _panStepApiFeedback = message;
      _panStepApiFeedbackIsError = isError;
    });
    Fluttertoast.showToast(
      msg: message,
      toastLength: Toast.LENGTH_LONG,
      gravity: ToastGravity.TOP,
      backgroundColor:
          isError ? Colors.red.shade700 : Colors.green.shade700,
      textColor: Colors.white,
    );
  }

  /// Extract user-facing error message from API response body.
  /// Supports common keys: msg, message, error, detail (string or list).
  static String _errorMessageFromResponse(int statusCode, String bodyStr) {
    if (bodyStr.trim().isEmpty) {
      return friendlyApiErrorMessage(null, statusCode: statusCode);
    }
    try {
      final body = jsonDecode(bodyStr) as Map<String, dynamic>?;
      if (body == null) {
        return friendlyApiErrorMessage(bodyStr, statusCode: statusCode);
      }
      final msg = body['msg'] ?? body['message'] ?? body['error'];
      if (msg != null) {
        if (msg is String) {
          return friendlyApiErrorMessage(msg, statusCode: statusCode);
        }
        if (msg is List && msg.isNotEmpty) {
          return friendlyApiErrorMessage(msg.first.toString(), statusCode: statusCode);
        }
      }
      final detail = body['detail'];
      if (detail is String) {
        return friendlyApiErrorMessage(detail, statusCode: statusCode);
      }
      if (detail is List && detail.isNotEmpty) {
        return friendlyApiErrorMessage(detail.first.toString(), statusCode: statusCode);
      }
    } catch (_) {
      return friendlyApiErrorMessage(bodyStr, statusCode: statusCode);
    }
    return friendlyApiErrorMessage(bodyStr, statusCode: statusCode);
  }

  /// Builds kyc-post-v2 path segment from get-context page: page.name + page.id (e.g. mobile_otp2, email3).
  String _getKycPostPathSegment(Map? ctx) {
    final page = ctx?['page'] as Map?;
    if (page != null) {
      final name = page['name']?.toString() ?? '';
      final id = page['id']?.toString() ?? '';
      if (name.isNotEmpty || id.isNotEmpty) return '$name$id';
    }
    final pos = ctx?['position']?.toString() ?? '';
    final idx = ctx?['index']?.toString() ?? '';
    return pos.isNotEmpty || idx.isNotEmpty ? '$pos$idx' : '';
  }

  /// Bank `kyc-post-v2` can return HTTP 200 with `success: false` and either:
  /// - `msg` containing "Penny Drop Verified" (confirm save), or
  /// - eKYC name-mismatch / retry flow with top-level `pennydrop` (e.g. unsuccessful message).
  static bool _isBankKycPostStep(String position, String lowerPath) {
    return lowerPath.startsWith('bank') ||
        position == 'bank' ||
        position == 'bank_details';
  }

  static bool _isSignUploadKycPostStep(String position, String lowerPath) {
    return lowerPath.startsWith('sign_upload') || position == 'sign_upload';
  }

  static bool _isPanUploadKycPostStep(String position, String lowerPath) {
    return lowerPath.startsWith('pan_upload') || position == 'pan_upload';
  }

  static const Set<String> _forcedBlankRejectionFields = {
    'reject_reason_pan_upload',
    'rejected_by_pan_upload',
    'reject_reason_signature_upload',
    'rejected_by_signature_upload',
  };

  static bool _isSaveFilesApiDocumentUploadStep(String position, String lowerPath) {
    return _isSignUploadKycPostStep(position, lowerPath) ||
        _isPanUploadKycPostStep(position, lowerPath);
  }

  static const String _signUploadBoidValue = 'CDSL';

  static List<String> _signUploadPrepopulateSourceKeys(dynamic prepopulateValue) {
    if (prepopulateValue == null) return const [];
    if (prepopulateValue is String) {
      final s = prepopulateValue.trim();
      return s.isEmpty ? const [] : [s];
    }
    if (prepopulateValue is List) {
      final keys = <String>[];
      for (final item in prepopulateValue) {
        if (item is Map) {
          final v = item['value']?.toString().trim() ??
              item['label']?.toString().trim();
          if (v != null && v.isNotEmpty) keys.add(v);
        } else if (item != null && item.toString().trim().isNotEmpty) {
          keys.add(item.toString().trim());
        }
      }
      return keys;
    }
    return const [];
  }

  String _resolveSignUploadFieldValue(
    Map<dynamic, dynamic> field,
    Map<String, dynamic> formData,
  ) {
    final name = field['name']?.toString() ?? '';
    final formValue = formData[name];
    if (formValue != null && formValue.toString().trim().isNotEmpty) {
      return formValue.toString();
    }

    final fieldValue = field['value'];
    if (fieldValue != null && fieldValue.toString().trim().isNotEmpty) {
      return fieldValue.toString();
    }

    if (field['isPrepopulate'] == true) {
      for (final source in _signUploadPrepopulateSourceKeys(
        field['prepopulateValue'],
      )) {
        final v = formData[source];
        if (v != null && v.toString().trim().isNotEmpty) {
          return v.toString();
        }
      }
    }

    return '';
  }

  Map<String, dynamic> _buildSignUploadKycPostBody({
    required List<dynamic> fieldList,
    required Map<String, dynamic> formData,
  }) {
    final payload = <String, dynamic>{};

    for (final raw in fieldList) {
      if (raw is! Map) continue;
      final field = Map<dynamic, dynamic>.from(raw);
      final name = field['name']?.toString();
      if (name == null || name.isEmpty) continue;

      final type = (field['type']?.toString() ?? '').toLowerCase();
      if (type == 'file' || type == 'button' || type == 'hidden') continue;

      if (name == 'boid') {
        payload[name] = _signUploadBoidValue;
        continue;
      }

      if (_forcedBlankRejectionFields.contains(name)) {
        payload[name] = '';
        continue;
      }

      payload[name] = _resolveSignUploadFieldValue(field, formData);
    }

    return payload;
  }

  /// Bank step Proceed (penny drop confirm) — web parity payload.
  static Map<String, dynamic> _buildBankProceedConfirmPayload(
    Map<String, dynamic> formData,
  ) {
    const fieldKeys = <String>[
      'ifsc',
      'micr1',
      'account_number',
      'reenter_account_number',
      'bank_add',
      'account_type',
    ];
    final payload = <String, dynamic>{
      'save': true,
      'middlewareCall': false,
    };
    for (final key in fieldKeys) {
      if (formData.containsKey(key) && formData[key] != null) {
        payload[key] = formData[key];
      }
    }
    return payload;
  }

  static const String _bank18LogTag = '[Bank18]';

  static void _logBank18Api({
    required String phase,
    required String endpoint,
    Map<String, dynamic>? payload,
    int? statusCode,
    String? responseBody,
    Map<String, dynamic>? responseJson,
  }) {
    debugPrint('');
    debugPrint('════ $_bank18LogTag $phase ════');
    debugPrint('$_bank18LogTag URL: $endpoint');
    if (payload != null) {
      debugPrint('$_bank18LogTag PAYLOAD: ${jsonEncode(payload)}');
    }
    if (statusCode != null) {
      debugPrint('$_bank18LogTag HTTP: $statusCode');
      if (responseBody != null && responseBody.isNotEmpty) {
        debugPrint('$_bank18LogTag RESPONSE: $responseBody');
      } else if (responseJson != null) {
        debugPrint(
          '$_bank18LogTag RESPONSE: success=${responseJson['success']} '
          'index=${(responseJson['context'] as Map?)?['index']} '
          'position=${(responseJson['context'] as Map?)?['position']}',
        );
      }
    }
    debugPrint('════════════════════════════════');
    debugPrint('');
  }

  static bool _isPennyDropVerifiedAwaitingSaveOrRetake(Map? body) {
    if (body == null) return false;
    final msg = body['msg']?.toString().toLowerCase().trim() ?? '';
    if (msg.contains('penny drop verified')) return true;
    final pennydrop = body['pennydrop']?.toString().trim() ?? '';
    if (pennydrop.isNotEmpty) return true;
    return false;
  }

  static String _pennyDropSaveRetakeDialogTitle(Map body) {
    final msg = body['msg']?.toString().toLowerCase().trim() ?? '';
    if (msg.contains('penny drop verified')) {
      return 'Penny drop verification successful';
    }
    return 'Penny drop failed';
  }

  static String _formatPennyDropApiMessage(String raw) {
    return raw
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .trim();
  }

  String _pennyDropVerifiedDialogMessage(Map body) {
    final data = body['data'];
    final pennyRaw = data is Map
        ? data['pennydrop_accountholder_name']?.toString().trim() ?? ''
        : '';
    final panRaw = (_formNotifier.formData['name'] ??
            _formNotifier.formData['full_name'] ??
            _formNotifier.formData['pan_name'])
        ?.toString()
        .trim() ??
        '';

    final pennyName = pennyRaw.toUpperCase();
    final panName = panRaw.toUpperCase();

    if (pennyName.isEmpty && panName.isEmpty) {
      return 'Proceed with These Bank Details or Modify Penny Drop Verification';
    }

    final bankHolder = pennyName.isNotEmpty ? pennyName : panName;
    final panPageName = panName.isNotEmpty ? panName : bankHolder;

    return 'Your Pennydrop name "$bankHolder" and the name on PAN page "$panPageName" are verified.\n\nPenny Drop Verified';
  }

  String _pennyDropDialogMessage(Map body) {
    final msg = body['msg']?.toString().trim() ?? '';
    final pennydrop = body['pennydrop']?.toString().trim() ?? '';
    final raw = msg.isNotEmpty ? msg : pennydrop;

    if (raw.isEmpty) {
      return 'Proceed with These Bank Details or Modify Penny Drop Verification';
    }

    if (raw.toLowerCase().contains('penny drop verified')) {
      return _pennyDropVerifiedDialogMessage(body);
    }

    final formatted = _formatPennyDropApiMessage(raw);
    if (formatted.toLowerCase() == 'error') {
      return 'Bank Penny Drop Verification failed. Please upload valid bank proof to proceed';
    }

    return formatted;
  }

  Future<String?> _showPennyDropVerifiedSaveRetakeDialog(
    String title, {
    required String message,
  }) async {
    final isVerifiedSuccess =
        title.toLowerCase().contains('verification successful');
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              message,
              textAlign: TextAlign.start,
              style: const TextStyle(
                fontSize: 14,
                height: 1.5,
                color: KycTheme.textPrimary,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: isVerifiedSuccess
                ? null
                : () => Navigator.of(ctx).pop('retake'),
            child: const Text('Modify'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: const Text('Proceed'),
          ),
        ],
      ),
    );
  }

  Future<void> _afterKycPostV2Success(
    AppStore store,
    Map<String, dynamic>? body,
    Map<String, dynamic> submissionData, {
    Map<String, dynamic>? getContextPostBody,
    bool logBank18GetContext = false,
  }) async {
    final ctxBeforeRefresh =
        (store.fieldsWithAuth as Map?)?['context'] as Map?;
    final submitPosition =
        ctxBeforeRefresh?['position']?.toString().toLowerCase() ?? '';
    final submitLabel = ctxBeforeRefresh?['page']?['data']?['label']
            ?.toString()
            .toLowerCase() ??
        '';
    if (_submissionIncludedRpdReturn(
      store,
      submissionData,
      position: submitPosition,
      pageLabel: submitLabel,
    )) {
      _clearRpdReturnState(store);
    }

    StorageService.setUserStep(body?['step']?.toString() ?? '');
    // Persist email for OTP UI before any reset (payload + snapshot still valid here).
    final formSnapshot = Map<String, dynamic>.from(_formNotifier.formData);
    final emailFromPayload = (submissionData['email'] ??
            submissionData['email_id'] ??
            submissionData['emailId'])
            ?.toString()
            .trim() ??
        '';
    if (emailFromPayload.contains('@')) {
      _persistedEmailForOtp = emailFromPayload;
    } else {
      final resolved = _resolveEmailForOtpUi(formSnapshot);
      if (resolved.contains('@')) _persistedEmailForOtp = resolved;
    }
    // Do not reset the form before get-context: the UI would show empty fields while the
    // request is in flight even though the save succeeded. Clear + rehydrate only after fresh context.
    final getContextPath =
        '/api/get-context/${widget.company}/${widget.workflowName}';
    final contextPayload = getContextPostBody ?? const <String, dynamic>{};
    if (logBank18GetContext) {
      _logBank18Api(
        phase: 'STEP-3 → get-context REQUEST',
        endpoint: getContextPath,
        payload: contextPayload,
      );
    }
    await store.fetchWorkflowFieldsWithAuth(
      widget.company,
      widget.workflowName,
      '',
      postBody: getContextPostBody,
    );
    if (logBank18GetContext) {
      _logBank18Api(
        phase: 'STEP-3 → get-context RESPONSE',
        endpoint: getContextPath,
        statusCode: 200,
        responseJson: store.fieldsWithAuth is Map
            ? Map<String, dynamic>.from(store.fieldsWithAuth as Map)
            : null,
      );
    }
    if (mounted && store.errorWithAuth != null) {
      await _handleGetContextFailureAfterSubmit(store);
      return;
    }
    if (mounted) {
      final authResponse = store.fieldsWithAuth;
      if (_responseIndicatesKycCompleted(authResponse)) {
        _clearSubmitFreeze();
        setState(() => _submitLoading = false);
        await _navigateToKycCompletedIfNeeded(store);
        return;
      }
    }
    if (mounted) {
      await Future.delayed(const Duration(milliseconds: 300));
      _applyFreshStepAfterSuccessfulSubmit(store);
      final ctx = store.fieldsWithAuth as Map?;
      final contextMap = ctx?['context'] as Map?;
      final pos = contextMap?['position']?.toString().toLowerCase() ?? '';
      if (pos == 'bank' || pos == 'bank_details') {
        _formNotifier.applyFullConditionalFlowEvaluation();
        debugPrint(
          '[Bank18] Still on bank — bank_upload path via conditional flow',
        );
      }
      if (pos == 'email_otp') {
        _applyPersistedEmailToForm();
        debugPrint(
            '[HomePage] email_otp: applied persisted email for UI: $_persistedEmailForOtp');
      }
      final nextLabel = contextMap?['page']?['data']?['label']
              ?.toString()
              .toLowerCase() ??
          '';
      if (pos == 'mobile' || nextLabel == 'mobile') {
        _applyPersistedGoogleNameToForm();
      }
      _clearSubmitFreeze();
      setState(() => _submitLoading = false);
      await _checkAndHandleRedirect(store);
    }
  }

  Future<void> _handleCommonSubmit(bool skipValidation) async {
    debugPrint('[HomePage] _handleCommonSubmit CALLED - skipValidation=$skipValidation');
    final store = context.read<AppStore>();
    _panStepApiFeedback = '';
    _panStepApiFeedbackIsError = false;

    final submitStep = _submitValidationStep(store);
    final submitActiveFields = _getActiveFields(store);
    final submitFieldList =
        (submitActiveFields?['fields'] as List?) ?? <dynamic>[];
    if (_enforceFatcaTaxResidencyNoOnSubmit(
      position: submitStep.position,
      pageLabel: submitStep.pageLabel,
      fieldList: submitFieldList,
    )) {
      return;
    }

    // Enforce Terms & Conditions on mobile step for authenticated flows
    if (!skipValidation) {
      final withAuth = store.fieldsWithAuth as Map?;
      final ctx = withAuth?['context'] as Map?;

      String position = ctx?['position']?.toString().toLowerCase() ?? '';
      String label = ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';

      if (position.isEmpty || label.isEmpty) {
        final workflow = store.fields as Map?;
        position = (workflow?['position']?.toString() ?? position).toLowerCase();
        label = (workflow?['data']?['label']?.toString() ?? label).toLowerCase();
      }

      debugPrint('[HomePage] _handleCommonSubmit position=$position label=$label');

      final isMobileScreen = position == 'mobile' && label == 'mobile';
      if (isMobileScreen) {
        if (!_termsAccepted) {
          setState(() {
            _showTermsError = true;
            _showMobileError = false;
          });
          Fluttertoast.showToast(
            msg: 'Please accept the Terms & Conditions to continue',
            toastLength: Toast.LENGTH_LONG,
            gravity: ToastGravity.TOP,
            backgroundColor: Colors.red.shade700,
            textColor: Colors.white,
          );
          return;
        }
        final mobile = _formNotifier.formData['mobile'] ?? _formNotifier.formData['phone'] ?? _formNotifier.formData['mobile_number'] ?? '';
        final digits = mobile.toString().replaceAll(RegExp(r'\D'), '');
        if (digits.length != 10 || !RegExp(r'^[6-9]').hasMatch(digits)) {
          setState(() {
            _showMobileError = true;
            _showTermsError = false;
          });
          Fluttertoast.showToast(
            msg: 'Please enter a valid 10-digit mobile number',
            toastLength: Toast.LENGTH_LONG,
            gravity: ToastGravity.TOP,
            backgroundColor: Colors.red.shade700,
            textColor: Colors.white,
          );
          return;
        }
      }
    }

    if (!skipValidation) {
      final step = _submitValidationStep(store);
      final isValid = _formNotifier.validate(
        company: widget.company,
        position: step.position,
        pageLabel: step.pageLabel,
      );
      debugPrint('[HomePage] Form validation result: $isValid');
      if (!isValid) {
        debugPrint('[HomePage] Validation failed, returning early');
        debugPrint('[HomePage] Validation errors: ${_formNotifier.errors}');
        _showValidationFailureToast();
        return;
      }
      if (_toastAndBlockIfAdditionalNomineeTotalNot100(store)) return;
    }
    FocusScope.of(context).unfocus();
    debugPrint('[HomePage] _handleCommonSubmit START');
    // Avoid racing get-context (causes backend "Session overlap detected").
    await _waitIfGetContextInFlight(store);
    if (!mounted) return;
    setState(() {
      _beginSubmitTransition(store);
      _submitLoading = true;
    });
    try {
      final withAuth = store.fieldsWithAuth as Map?;
      final ctx = withAuth?['context'] as Map?;
      final pathSegment = _getKycPostPathSegment(ctx);
      if (pathSegment.isEmpty) {
        Fluttertoast.showToast(msg: 'Invalid step. Please refresh.', gravity: ToastGravity.TOP);
        if (mounted) {
          _clearSubmitFreeze();
          setState(() => _submitLoading = false);
        }
        return;
      }
      
      final currentPosition =
          (ctx?['position']?.toString().toLowerCase() ?? '').trim();
      final lowerPath = pathSegment.toLowerCase();

      final data = await _prepareFormData(skipValidation);
      data.remove('save');

      // PAN verify (`pan10`): curl/web body only — trim name/PAN (trailing space breaks verify).
      if (isPanVerifyKycPostStep(currentPosition, lowerPath)) {
        final normalized = buildPanVerifyKycPostBody(data);
        data
          ..clear()
          ..addAll(normalized);
        debugPrint('[HomePage] PAN verify POST body: $data');
      }

      // Initial email capture step: backend expects a trimmed body (email + a few fields).
      // Must NOT run on `email_otp` — pathSegment e.g. `email_otp4` still starts with `email`,
      // and clearing here would drop the OTP field and break verify_otp on the server.
      final isEmailOtpStep =
          currentPosition == 'email_otp' || lowerPath.startsWith('email_otp');
      final isEmailOnlySubmitStep = !isEmailOtpStep &&
          (currentPosition == 'email' ||
              (lowerPath.startsWith('email') &&
                  !lowerPath.startsWith('email_otp')));
      if (isEmailOnlySubmitStep) {
        final resolvedEmail =
            (data['email'] ?? data['email_id'] ?? data['emailId'])
                    ?.toString()
                    .trim() ??
                '';
        final selectDependency = (data['select__dependency'] ?? 'Self')
            .toString()
            .trim();
        final branchReferenceCode =
            (data['branch_reference_code'] ?? '').toString();
        final panNumber1 = (data['pan_number1'] ?? '').toString();
        data
          ..clear()
          ..['email'] = resolvedEmail
          ..['select__dependency'] =
              selectDependency.isEmpty ? 'Self' : selectDependency
          ..['branch_reference_code'] = branchReferenceCode
          ..['pan_number1'] = panNumber1;
      }

      // DigiLocker: backend expects `save: true` on kyc-post-v2 (e.g. `/digilocker9`).
      // Do not require `?verify=digilocker` on the app route — that flag is often only sent to
      // get-context, so `widget.queryParams` is empty here even after a successful verify flow.
      final onDigilockerStep = currentPosition == 'digilocker' ||
          lowerPath.startsWith('digilocker');
      if (onDigilockerStep) {
        data['save'] = true;
        debugPrint('[HomePage] DigiLocker step: save=true on kyc-post-v2');
      }

      final pageLabelForSubmit = ctx?['page']?['data']?['label']?.toString();
      if (isNomineeExtendedUiStep(currentPosition, pageLabelForSubmit)) {
        logNomineeKycPostPayloadDiagnostics(
          data: data,
          position: currentPosition,
          pageLabel: pageLabelForSubmit,
        );
      }

      debugPrint(
        '[HomePage] _handleCommonSubmit data keys=${data.length} pathSegment=$pathSegment',
      );

      // Check saveFilesAPI flag from context.page
      final page = ctx?['page'] as Map?;
      final saveFilesAPI = page?['saveFilesAPI'] == true;
      debugPrint('[HomePage] saveFilesAPI flag: $saveFilesAPI');
      
      // Check if form has file fields - if yes, use multipart/form-data
      final activeFields = _getActiveFields(store);
      final fieldList = (activeFields?['fields'] as List?) ?? [];
      final hasFile = fieldList.any((f) => f is Map && f['type'] == 'file') ||
                      data.values.any((v) => v is File);
      
      final client = ApiClient();
      final endpoint = '/api/kyc-post-v2/${widget.company}/${widget.workflowName}/$pathSegment';
      final fullUrl = '${EnvConfig.baseUrl}$endpoint';
      debugPrint('[HomePage] _handleCommonSubmit hasFile=$hasFile');
      debugPrint('[HomePage] _handleCommonSubmit FULL URL: $fullUrl');
      debugPrint('[HomePage] _handleCommonSubmit ENDPOINT: $endpoint');
      
      // If saveFilesAPI is true, upload files separately first
      if (hasFile && saveFilesAPI) {
        debugPrint('[HomePage] saveFilesAPI=true: Uploading files separately to /api/upload_files_new');
        final filesToUpload = <String, File>{};
        
        // Extract files from data
        for (final e in data.entries) {
          if (e.value is File) {
            filesToUpload[e.key] = e.value as File;
          }
        }
        
        // Upload each file separately to /api/upload_files_new (token set in ApiClient; 401 triggers refresh + retry)
        for (final entry in filesToUpload.entries) {
          final fileKey = entry.key; // e.g., signature_upload, pan_upload, etc.
          final file = entry.value;
          
          try {
            debugPrint('[HomePage] Uploading file: $fileKey = ${file.path}');
            final uploadRes = await client.postMultipart(
              () async {
                final uploadReq = http.MultipartRequest(
                  'POST',
                  Uri.parse('${EnvConfig.baseUrl}/api/upload_files_new'),
                );
                uploadReq.headers['accept'] = '*/*';
                uploadReq.files.add(await http.MultipartFile.fromPath(fileKey, file.path));
                return uploadReq;
              },
              skipRefreshOn401: true,
            );
            debugPrint('[HomePage] File upload response for $fileKey: ${uploadRes.statusCode}');
            
            if (uploadRes.statusCode < 200 || uploadRes.statusCode >= 300) {
              debugPrint('[HomePage] File upload failed for $fileKey: ${uploadRes.body}');
              Fluttertoast.showToast(
                msg: 'Failed to upload $fileKey',
                gravity: ToastGravity.TOP,
              );
              if (mounted) setState(() => _submitLoading = false);
              return;
            }
          } catch (e) {
            debugPrint('[HomePage] Error uploading file $fileKey: $e');
            Fluttertoast.showToast(
              msg: 'Error uploading file: $e',
              gravity: ToastGravity.TOP,
            );
            if (mounted) setState(() => _submitLoading = false);
            return;
          }
        }
        
        // Remove files from data after successful upload
        for (final key in filesToUpload.keys) {
          data.remove(key);
        }
        debugPrint('[HomePage] Files uploaded successfully, continuing with form submission');
      }

      if (_isSaveFilesApiDocumentUploadStep(currentPosition, lowerPath)) {
        final documentUploadBody = _buildSignUploadKycPostBody(
          fieldList: fieldList,
          formData: Map<String, dynamic>.from(_formNotifier.formData),
        );
        data
          ..clear()
          ..addAll(documentUploadBody);
        debugPrint('[HomePage] document upload step payload: $data');
      }

      final http.Response res;
      if (hasFile && !saveFilesAPI) {
        // Use multipart/form-data for file uploads (existing flow when saveFilesAPI=false)
        debugPrint('[HomePage] Using multipart/form-data (file upload detected, saveFilesAPI=false)');
        res = await client.postMultipart(() async {
          final req = http.MultipartRequest('POST', Uri.parse(fullUrl));
          final nomineeStep = isNomineeExtendedUiStep(
            currentPosition,
            pageLabelForSubmit,
          );
          for (final e in data.entries) {
            final v = e.value;
            if (v is File) {
              req.files.add(await http.MultipartFile.fromPath(e.key, v.path));
              debugPrint('[HomePage] Added file: ${e.key} = ${v.path}');
            } else if (v is bool) {
              req.fields[e.key] = v.toString();
            } else if (v != null &&
                (v.toString().isNotEmpty ||
                    nomineeStep ||
                    shouldSendEmptyNomineeKycPostField(e.key))) {
              req.fields[e.key] = v.toString();
            }
          }
          debugPrint(
            '[HomePage] multipart fields keys=${req.fields.keys.toList()} '
            'files=${req.files.map((f) => f.field).toList()}',
          );
          if (nomineeStep) {
            logNomineeKycPostPayloadDiagnostics(
              data: data,
              position: currentPosition,
              pageLabel: pageLabelForSubmit,
              wireMultipartFields: req.fields,
            );
          }
          return req;
        });
      } else {
        // Use JSON for non-file submissions (or after files uploaded separately)
        debugPrint('[HomePage] Using application/json (no files or files already uploaded)');
        if (isNomineeExtendedUiStep(currentPosition, pageLabelForSubmit)) {
          final wire = <String, String>{};
          for (final e in data.entries) {
            if (e.value is File) continue;
            wire[e.key] = e.value?.toString() ?? '';
          }
          logNomineeKycPostPayloadDiagnostics(
            data: data,
            position: currentPosition,
            pageLabel: pageLabelForSubmit,
            wireMultipartFields: wire,
          );
        }
        if (_isBankKycPostStep(currentPosition, lowerPath)) {
          _logBank18Api(
            phase: 'STEP-1 → kyc-post-v2 REQUEST',
            endpoint: endpoint,
            payload: Map<String, dynamic>.from(data),
          );
        }
        res = await client.post(
          endpoint,
          body: data,
          headers: {'Content-Type': 'application/json'},
        );
      }
      Map<String, dynamic>? body;
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>?;
      } catch (_) {
        body = null;
      }
      if (_isBankKycPostStep(currentPosition, lowerPath)) {
        _logBank18Api(
          phase: 'STEP-1 → kyc-post-v2 RESPONSE',
          endpoint: endpoint,
          statusCode: res.statusCode,
          responseBody: res.body,
          responseJson: body,
        );
      }
      final currentPageLabel =
          ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';
      final isPanStep = _isPanKycStep(currentPosition, currentPageLabel) ||
          lowerPath.startsWith('pan');
      final isSuccess = res.statusCode >= 200 && res.statusCode < 300 && body?['success'] == true;
      if (isSuccess) {
        if (isPanStep) {
          final apiMsg = _kycPostV2UserMessage(body);
          if (apiMsg != null && apiMsg.isNotEmpty) {
            _showPanStepKycPostFeedback(apiMsg, isError: false);
          }
        }
        await _afterKycPostV2Success(store, body, data);
      } else if (res.statusCode >= 200 &&
          res.statusCode < 300 &&
          _isPennyDropVerifiedAwaitingSaveOrRetake(body)) {
        if (mounted) setState(() => _submitLoading = false);
        final dialogTitle = _pennyDropSaveRetakeDialogTitle(body!);
        final dialogMessage = _pennyDropDialogMessage(body);
        final choice = await _showPennyDropVerifiedSaveRetakeDialog(
          dialogTitle,
          message: dialogMessage,
        );
        if (!mounted) return;
        if (choice == null) return;
        setState(() => _submitLoading = true);
        final retryPayload = Map<String, dynamic>.from(data);
        retryPayload.remove('save');
        retryPayload.remove('retake');
        retryPayload.remove('middlewareCall');

        final Map<String, dynamic> postPayload;
        if (choice == 'save') {
          postPayload = _buildBankProceedConfirmPayload(data);
        } else {
          retryPayload['retake'] = true;
          postPayload = retryPayload;
        }
        _logBank18Api(
          phase: choice == 'save'
              ? 'STEP-2 PROCEED → kyc-post-v2 REQUEST'
              : 'STEP-2 MODIFY → kyc-post-v2 REQUEST',
          endpoint: endpoint,
          payload: postPayload,
        );
        final res2 = await client.post(
          endpoint,
          body: postPayload,
          headers: {'Content-Type': 'application/json'},
        );
        Map<String, dynamic>? body2;
        try {
          body2 = jsonDecode(res2.body) as Map<String, dynamic>?;
        } catch (_) {
          body2 = null;
        }
        _logBank18Api(
          phase: choice == 'save'
              ? 'STEP-2 PROCEED → kyc-post-v2 RESPONSE'
              : 'STEP-2 MODIFY → kyc-post-v2 RESPONSE',
          endpoint: endpoint,
          statusCode: res2.statusCode,
          responseBody: res2.body,
          responseJson: body2,
        );
        final httpOk =
            res2.statusCode >= 200 && res2.statusCode < 300;
        if (choice == 'save' && httpOk) {
          await _afterKycPostV2Success(
            store,
            body2 ?? <String, dynamic>{'success': true},
            postPayload,
            logBank18GetContext: true,
          );
        } else if (choice == 'retake' &&
            httpOk &&
            body2?['success'] == true) {
          await _afterKycPostV2Success(store, body2, postPayload);
        } else {
          final err2 = _kycPostV2UserMessage(body2) ??
              _errorMessageFromResponse(res2.statusCode, res2.body);
          Fluttertoast.showToast(msg: err2, gravity: ToastGravity.TOP);
          if (mounted) {
            _clearSubmitFreeze();
            setState(() => _submitLoading = false);
          }
        }
      } else if (_isSessionOverlapResponse(body)) {
        await _recoverFromSessionOverlap(store);
      } else if (isPanStep &&
          isPanNumberAlreadyExistsResponse(body) &&
          await _tryRecoverPanVerifyAlreadyExists(store, submissionData: data)) {
        debugPrint(
            '[HomePage] PAN verify: already exists — treated as success, advancing');
        _showPanStepKycPostFeedback('PAN verified successfully', isError: false);
        await _afterKycPostV2Success(
          store,
          <String, dynamic>{'success': true, 'message': 'working'},
          data,
        );
      } else {
        final errMsg = _resolveSubmitErrorMessage(
          position: currentPosition,
          pageLabel: currentPageLabel,
          pathSegment: lowerPath,
          statusCode: res.statusCode,
          bodyStr: res.body,
          body: body,
        );
        if (isPanStep) {
          _showPanStepKycPostFeedback(errMsg, isError: true);
        } else {
          Fluttertoast.showToast(msg: errMsg, gravity: ToastGravity.TOP);
        }
        if (mounted) {
          _clearSubmitFreeze();
          setState(() => _submitLoading = false);
        }
      }
    } catch (e) {
      Fluttertoast.showToast(msg: 'Something went wrong. Please try again.', gravity: ToastGravity.TOP);
      if (mounted) {
        _clearSubmitFreeze();
        setState(() => _submitLoading = false);
      }
    }
  }

  /// When [AppStore.errorWithAuth] is set to an HTML/5xx page, the session is usually still valid;
  /// wiping storage only forces an unauthenticated workflow load (`hasToken=false`).
  static bool _isHtmlOrInfraErrorBody(String? err) {
    if (err == null || err.isEmpty) return false;
    final t = err.trim().toLowerCase();
    return t.startsWith('<!doctype') ||
        t.contains('<html') ||
        t.contains('internal server error') ||
        t.contains('502 bad gateway') ||
        t.contains('503 service unavailable') ||
        t.contains('504 gateway') ||
        t.contains('temporarily unavailable') ||
        t.contains('temporarily busy') ||
        t.contains('took too long') ||
        t.contains('something went wrong') ||
        t.contains('check your connection');
  }

  /// get-context failed after a successful submit — recover without wiping the whole session.
  Future<void> _handleGetContextFailureAfterSubmit(AppStore store) async {
    if (store.hasPdfDocumentEncryptedContextError) {
      _recoverFromPdfDocumentEncryptedError(store);
      _finishSubmitTransition(store: store, applyFreshStep: false);
      return;
    }

    if (store.hasInvalidPanContextError) {
      _recoverFromInvalidPanContextError(store);
      return;
    }

    if (store.invalidUserSession) {
      debugPrint(
        '[HomePage] get-context invalid session — trying SSO recovery (no full wipe)',
      );
      final ssoOk = await _recoverInvalidSessionViaSso(store);
      if (ssoOk && mounted) {
        await store.fetchWorkflowFieldsWithAuth(
          widget.company,
          widget.workflowName,
          '',
        );
        if (mounted &&
            store.errorWithAuth == null &&
            store.fieldsWithAuth is Map) {
          // Continue with normal success path below — caller must not early-return.
          // Signal success by clearing freeze and applying step here.
          await Future.delayed(const Duration(milliseconds: 200));
          if (!mounted) return;
          _applyFreshStepAfterSuccessfulSubmit(store);
          _clearSubmitFreeze();
          setState(() => _submitLoading = false);
          await _checkAndHandleRedirect(store);
          return;
        }
      }
      Fluttertoast.showToast(
        msg: 'Session expired. Please continue from the start.',
        gravity: ToastGravity.TOP,
      );
      _finishSubmitTransition(store: store, applyFreshStep: false);
      return;
    }

    // Transient / infra errors: keep tokens so Retry works.
    debugPrint(
      '[HomePage] get-context failed — keeping session (not clearing storage): ${store.errorWithAuth}',
    );
    Fluttertoast.showToast(
      msg: store.errorWithAuth ??
          'Could not refresh your progress. Please try again.',
      gravity: ToastGravity.TOP,
    );
    _finishSubmitTransition(store: store, applyFreshStep: false);
  }

  /// Keep user on the current upload step after backend rejects encrypted/closed PDF.
  void _recoverFromPdfDocumentEncryptedError(AppStore store) {
    debugPrint(
      '[HomePage] PDF document closed/encrypted — staying on upload step (not clearing session)',
    );
    store.clearAuthError();

    // Clear file + companion password fields so user can re-upload.
    final active = _getActiveFields(store);
    final fieldList = (active?['fields'] as List?) ?? const [];
    for (final f in fieldList) {
      if (f is! Map) continue;
      if (f['type']?.toString() != 'file') continue;
      final name = f['name']?.toString();
      if (name == null || name.isEmpty) continue;
      _formNotifier.handleChange(name, null, type: 'file');
      _formNotifier.handleChange('${name}_pass', null, type: 'text');
    }

    Fluttertoast.showToast(
      msg: kPdfDocumentEncryptedUserMessage,
      gravity: ToastGravity.TOP,
      toastLength: Toast.LENGTH_LONG,
    );
    if (mounted) setState(() {});
  }

  /// Invalid PAN from get-context / KRA — stay on PAN details so user can correct it.
  void _recoverFromInvalidPanContextError(AppStore store) {
    final raw = store.errorWithAuth ?? store.lastGetContextRawBody;
    final msg = invalidPanUserFacingMessage(raw);
    debugPrint(
      '[HomePage] Invalid PAN from get-context — staying on PAN step: $msg',
    );
    store.clearAuthError();

    // Keep PAN editable; clear only if you want a blank field — leave value for edit.
    _showPanStepKycPostFeedback(msg, isError: true);
    _finishSubmitTransition(store: store, applyFreshStep: false);
    if (mounted) setState(() {});
  }

  Future<void> _clearCookiesAndRefresh() async {
    // Prefer token-only clear — wiping SharedPreferences caused intermittent "session" loops.
    await StorageService.clearAuthTokens();
    storeClearAuthErrorIfMounted();
    if (mounted) _loadWorkflow();
  }

  void storeClearAuthErrorIfMounted() {
    if (!mounted) return;
    context.read<AppStore>().clearAuthError();
    _clearAuthenticatedStepCache();
  }

  Future<void> _autoRecoverInvalidSessionIfNeeded(AppStore store) async {
    if (_submitLoading ||
        !store.invalidUserSession ||
        _autoSessionRecoverInFlight ||
        _autoSessionRecoverAttempted) {
      return;
    }
    _autoSessionRecoverInFlight = true;
    _autoSessionRecoverAttempted = true;
    try {
      debugPrint('[HomePage] Auto-recovering invalid session...');
      final ssoOk = await _recoverInvalidSessionViaSso(store);
      if (ssoOk && mounted) {
        await _loadWorkflow();
        if (mounted && store.errorWithAuth == null) {
          _autoSessionRecoverAttempted = false;
        }
      }
    } finally {
      _autoSessionRecoverInFlight = false;
    }
  }

  /// Fetch bank details by IFSC code and auto-fill bank fields
  Future<void> _fetchBankDetailsByIfsc(String ifsc) async {
    if (ifsc.length != 11) {
      debugPrint('[HomePage] IFSC invalid length: ${ifsc.length}');
      return;
    }
    
    try {
      debugPrint('[HomePage] Fetching bank details for IFSC: $ifsc');
      final client = ApiClient();
      final res = await client.post(
        '/get_bank_address_by_ifsc',
        body: {'ifsc': ifsc},
        headers: {'Content-Type': 'application/json'},
      );
      
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>?;
        debugPrint('[HomePage] Bank details response: $data');
        
        if (data != null && mounted) {
          final bankName = data['bank_name']?.toString().trim() ?? '';
          if (bankName.isEmpty) {
            debugPrint(
                '[HomePage] IFSC lookup returned empty bank_name — invalid IFSC');
            Fluttertoast.showToast(
              msg: 'Invalid IFSC code',
              gravity: ToastGravity.TOP,
            );
            return;
          }

          // Ensure we are on a bank / bank_details screen before auto-fill
          final store = context.read<AppStore>();
          final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
          final position = ctx?['position']?.toString()?.toLowerCase();
          final label = ctx?['page']?['data']?['label']?.toString()?.toLowerCase();
          final isBankScreen = position == 'bank' ||
              position == 'bank_details' ||
              label == 'bank';
          if (!isBankScreen) {
            debugPrint('[HomePage] IFSC response received but not on bank screen (position=$position, label=$label)');
            return;
          }

          // Build list of current field names (for this workflow / company)
          final activeFields = _getActiveFields(store);
          final fieldList = (activeFields?['fields'] as List?) ?? [];
          final fieldNames = <String>{};
          for (final f in fieldList) {
            if (f is Map && f['name'] != null) {
              fieldNames.add(f['name'].toString());
            }
          }

          // Map API response fields to actual field names present in current screen
          final updates = <String, dynamic>{};

          // bank_name → bank_name / bankName
          if (data['bank_name'] != null) {
            final v = data['bank_name'];
            if (fieldNames.contains('bank_name')) updates['bank_name'] = v;
            if (fieldNames.contains('bankName')) updates['bankName'] = v;
          }

          // BRANCH → branch_name / branchName
          if (data['BRANCH'] != null) {
            final v = data['BRANCH'];
            if (fieldNames.contains('branch_name')) updates['branch_name'] = v;
            if (fieldNames.contains('branchName')) updates['branchName'] = v;
          }

          // address → bank_address / bankAddress / bank_add (payload alias on some workflows)
          if (data['address'] != null) {
            final v = data['address'];
            if (fieldNames.contains('bank_address')) updates['bank_address'] = v;
            if (fieldNames.contains('bankAddress')) updates['bankAddress'] = v;
            if (fieldNames.contains('bank_add')) updates['bank_add'] = v;
          }

          // city → bank_city
          if (data['city'] != null && fieldNames.contains('bank_city')) {
            updates['bank_city'] = data['city'];
          }

          // district → bank_district
          if (data['district'] != null && fieldNames.contains('bank_district')) {
            updates['bank_district'] = data['district'];
          }

          // state → bank_state
          if (data['state'] != null && fieldNames.contains('bank_state')) {
            updates['bank_state'] = data['state'];
          }

          // micr → micr / micr1
          if (data['micr'] != null) {
            final v = data['micr'];
            if (fieldNames.contains('micr')) updates['micr'] = v;
            if (fieldNames.contains('micr1')) updates['micr1'] = v;
          }

          // pincode → bank_pincode
          if (data['pincode'] != null && fieldNames.contains('bank_pincode')) {
            updates['bank_pincode'] = data['pincode'];
          }
          
          debugPrint('[HomePage] Bank fields to update (after position & field filter): $updates');
          
          if (updates.isEmpty) {
            debugPrint('[HomePage] No matching bank fields found to update for this screen.');
          } else {
            for (final e in updates.entries) {
              debugPrint('[HomePage] Updating field: ${e.key} = ${e.value}');
            }
            // Use notifier API (not raw map + notifyListeners) so Provider/Consumer rebuilds;
            // avoid handleChange here — it runs [_processValue] and truncates generic text to 35 chars.
            _formNotifier.applyExternalFormValues(updates);
            if (mounted) setState(() {});
            Fluttertoast.showToast(msg: 'Bank details fetched successfully', gravity: ToastGravity.TOP);
            debugPrint('[HomePage] Auto-filled ${updates.length} bank fields - UI should update now');
          }
        }
      } else {
        debugPrint('[HomePage] IFSC lookup failed: ${res.statusCode}');
        Fluttertoast.showToast(msg: 'Invalid IFSC code', gravity: ToastGravity.TOP);
      }
    } catch (e) {
      debugPrint('[HomePage] IFSC lookup error: $e');
      Fluttertoast.showToast(msg: 'Failed to fetch bank details', gravity: ToastGravity.TOP);
    }
  }

  Future<void> _handleLogout() async {
    final token = await StorageService.getAccessToken();
    setState(() => _logoutLoading = true);
    try {
      // Step 1: Call logout API
      if (token != null) {
        try {
          final client = ApiClient();
          await client.post('/api/user/logout', headers: {'Authorization': 'Bearer $token'});
          debugPrint('[HomePage] Logout API called successfully');
        } catch (e) {
          debugPrint('[HomePage] Logout API error (continuing anyway): $e');
        }
      }

      // Step 2: Clear all auth tokens and data
      await StorageService.clearAll();
      debugPrint('[HomePage] Tokens cleared');
      _clearAuthenticatedStepCache();

      // Post-logout: SSO-only login (user must sign in again via SSO).
      // StorageService.setSsoAutoLoginEnabled(false);
      StorageService.setSsoAutoLoginEnabled(true);
      _ssoAttempted = false;
      _ssoInProgress = false;

      // Step 3: Reset form state
      _formNotifier.resetForm();

      // Step 4: Reset AppStore state
      final store = context.read<AppStore>();
      store.resetState();

      // Step 5 (legacy): unauth get-workflow + Start your KYC screen — disabled for SSO-only.
      // await store.fetchWorkflowFields(widget.company, widget.workflowName);
      // debugPrint('[HomePage] Workflow refreshed after logout');
      // if (mounted) {
      //   context.go('/${widget.company}/${widget.workflowName}');
      //   Fluttertoast.showToast(msg: 'Logged out successfully', gravity: ToastGravity.TOP);
      // }

      if (!mounted) return;
      // Stop logout spinner before SSO modal — user has not submitted KYC yet.
      setState(() => _logoutLoading = false);
      final ssoOk = await _trySsoLoginIfNeeded(context, store);
      if (!mounted) return;
      if (ssoOk) {
        await store.fetchWorkflowFieldsWithAuth(
          widget.company,
          widget.workflowName,
          '',
        );
        if (!mounted) return;
        if (_responseIndicatesKycCompleted(store.fieldsWithAuth)) {
          await _navigateToKycCompletedIfNeeded(store);
          return;
        }
        if (mounted) {
          final activeAfter = _getActiveFields(store);
          final listAfter = (activeAfter?['fields'] as List?) ?? [];
          final flowAfter = activeAfter?['conditionalFlow'] as List?;
          _formNotifier.updateFields(
            listAfter,
            flowAfter,
            fieldsWithAuth: store.fieldsWithAuth,
          );
          setState(() {});
          Fluttertoast.showToast(
            msg: 'Signed in via SSO',
            gravity: ToastGravity.TOP,
          );
        }
      } else {
        Fluttertoast.showToast(
          msg: 'SSO sign-in required. Enter credentials to continue.',
          gravity: ToastGravity.TOP,
        );
        await _loadWorkflow();
      }
    } catch (e) {
      debugPrint('[HomePage] Logout error: $e');
      Fluttertoast.showToast(msg: 'Error during logout', gravity: ToastGravity.TOP);
    } finally {
      if (mounted) setState(() => _logoutLoading = false);
    }
  }

  // ---------- WebView-return partial-loader helpers ----------

  Widget _buildWebViewReturnLoaderContent() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: KycTheme.primary, strokeWidth: 3),
          const SizedBox(height: 16),
          Text(
            _returnFlowMessage,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  /// Header step label: sticky during submit, updates only when the next step is synced.
  String? _headerPositionLabel(AppStore store) {
    if (_ssoInProgress) {
      return null;
    }

    final settled = _resolveSyncedPositionFromStore(store);
    final inTransition = _submitLoading || store.loadingWithAuth;

    if (!inTransition && settled != null) {
      _headerDisplayPosition = settled;
      return settled;
    }

    if (inTransition && (_headerDisplayPosition ?? '').isNotEmpty) {
      return _headerDisplayPosition;
    }

    if (settled != null) {
      _headerDisplayPosition = settled;
      return settled;
    }

    return _headerDisplayPosition;
  }

  /// Workflow position → centered header title.
  String _formatPositionDisplayText(String position) {
    return KycStepperBar.formatLabel(position);
  }

  Widget _buildHeaderPositionText(String position) {
    return Text(
      _formatPositionDisplayText(position),
      textAlign: TextAlign.center,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: KycTheme.fontSizeBodyLg,
        fontWeight: FontWeight.w600,
        color: KycTheme.textPrimary,
      ),
    );
  }

  void _showHelpDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KycTheme.radiusLg),
        ),
        title: const Text(
          'Need help?',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        content: const Text(
          'For assistance with your KYC, contact Rudra Shares support. '
          'You can also refresh this step or exit and continue later.',
          style: TextStyle(height: 1.45, color: KycTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthenticatedHeaderActions(
    AppStore store, {
    VoidCallback? onRefreshOverride,
    bool refreshBusyOverride = false,
  }) {
    final position = _headerPositionLabel(store);
    final refreshBusy = refreshBusyOverride ||
        _refreshLoading ||
        (_loadWorkflowActive && !_ssoInProgress);

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: SizedBox(
        height: 48,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (position != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 108),
                child: _buildHeaderPositionText(position),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Long-press Help to refresh (Figma shows Help; refresh kept as gesture)
                  GestureDetector(
                    onLongPress: (refreshBusy || _logoutLoading)
                        ? null
                        : () async {
                            if (onRefreshOverride != null) {
                              store.clearAuthError();
                              if (mounted) {
                                setState(
                                    () => _fatcaTaxResidencyMustPickNo = false);
                              }
                              onRefreshOverride();
                              return;
                            }
                            await _refreshWorkflowFromHeader(store);
                          },
                    child: TextButton.icon(
                      onPressed: _showHelpDialog,
                      style: TextButton.styleFrom(
                        foregroundColor: KycTheme.textPrimary,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: KycTheme.textSecondary,
                            width: 1.4,
                          ),
                        ),
                        child: refreshBusy
                            ? const Padding(
                                padding: EdgeInsets.all(3),
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: KycTheme.primary,
                                ),
                              )
                            : const Icon(
                                Icons.question_mark_rounded,
                                size: 14,
                                color: KycTheme.textSecondary,
                              ),
                      ),
                      label: const Text(
                        'Help',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Exit',
                    onPressed: _logoutLoading ? null : _handleLogout,
                    icon: _logoutLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: KycTheme.exitRed,
                            ),
                          )
                        : const Icon(
                            Icons.power_settings_new_rounded,
                            color: KycTheme.exitRed,
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildApiErrorRetryContent(
    AppStore store, {
    required String message,
    VoidCallback? onRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 64, color: Colors.orange.shade400),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade700,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text(
                'Try Again',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: KycTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0,
              ),
              onPressed: (_refreshLoading || _loadWorkflowActive)
                  ? null
                  : () {
                      store.clearAuthError();
                      setState(() => _webViewReturnError = null);
                      if (onRetry != null) {
                        onRetry();
                      } else {
                        _loadWorkflow();
                      }
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildApiErrorScaffold({
    required AppStore store,
    required String message,
    required bool isAuthenticated,
    VoidCallback? onRetry,
  }) {
    final friendly = friendlyApiErrorMessage(message);
    return Scaffold(
      backgroundColor: KycTheme.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isAuthenticated) _buildAuthenticatedHeaderActions(store),
            Expanded(
              child: KycLayout(
                title: 'Unable to load',
                stepperSteps: null,
                stepperIndex: null,
                skipScaffold: true,
                showDocumentsSection: false,
                child: _buildApiErrorRetryContent(
                  store,
                  message: friendly,
                  onRetry: onRetry,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebViewReturnRetryContent(AppStore store) {
    return _buildApiErrorRetryContent(
      store,
      message: friendlyApiErrorMessage(_webViewReturnError),
      onRetry: () {
        setState(() => _returnFlowMessage = 'Loading your next step...');
        _loadWorkflow();
      },
    );
  }

  // ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _formNotifier,
      child: Consumer2<AppStore, ConditionalFormNotifier>(
        builder: (context, store, form, _) {
          final activeFields = _activeFieldsForUi(store);
          final fieldList = (activeFields?['fields'] as List?) ?? [];
          final conditionalFlow = activeFields?['conditionalFlow'] as List?;
          final submitButton = activeFields?['submitButton'] as Map?;

          return FutureBuilder<bool>(
            future: StorageService.hasAccessToken(),
            builder: (context, snapshot) {
              final isAuthenticated = snapshot.data ?? false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                if (_submitLoading && _submitFrozenPage != null) return;
                final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
                final syncKey = [
                  ctx?['position']?.toString() ?? '',
                  ctx?['page']?['id']?.toString() ?? '',
                  store.rpdReturn,
                  fieldList.length,
                ].join('|');
                if (_activeFieldsSyncKey == syncKey) return;
                _activeFieldsSyncKey = syncKey;
                _formNotifier.updateFields(
                  fieldList,
                  conditionalFlow,
                  fieldsWithAuth: store.fieldsWithAuth,
                );
                // Must run in same callback *after* updateFields so API `value`/`defaultValue` is in formData first.
                _applyApiDefaultValues(fieldList);
                _runPersonalDetailsBpWealthPipeline(store, fieldList);
                _applyRpdReturnFieldIfNeeded(store, fieldList);
                _syncDigilockerAadharImage(
                  store,
                  fieldList,
                  position: ctx?['position']?.toString(),
                  pageLabel: ctx?['page']?['data']?['label']?.toString(),
                );
                final pos =
                    (ctx?['position']?.toString() ?? '').toLowerCase();
                final label = (ctx?['page']?['data']?['label']?.toString() ?? '')
                    .toLowerCase();
                if (pos == 'mobile' || label == 'mobile') {
                  // Run after fields are synced — earlier _buildForm can fire with empty list.
                  unawaited(_tryAutofillMobileFromSim(fieldList));
                  final pageId =
                      ctx?['page']?['id']?.toString() ?? '';
                  final termsKey = 'mobile|$pageId';
                  if (_mobileTermsAutoSelectedStepKey != termsKey ||
                      !_termsAccepted) {
                    _mobileTermsAutoSelectedStepKey = termsKey;
                    _termsAccepted = true;
                    _showTermsError = false;
                  }
                } else {
                  _mobileSimAutofillStepKey = null;
                  _mobileTermsAutoSelectedStepKey = null;
                }
              });

              // --- Stepper UI (hidden temporarily) ---
              // Re-enable showStepper + stepperWidget when bringing the stepper back.
              // final stepperSteps = _getStepperSteps(store);
              // Stepper visible only from 2nd step (mobile_otp) onwards; hidden on first step (mobile number entry)
              // final ctxForStepper = (store.fieldsWithAuth as Map?)?['context'] as Map?;
              // final currentPosition = (ctxForStepper?['position']?.toString() ?? '').toLowerCase();
              // final showStepper = currentPosition.isNotEmpty && currentPosition != 'mobile';
              const showStepper = false;

              // final stepperWidget = Container(
              //   height: 100, // Fixed height for stepper (circle + label + padding)
              //   color: Colors.white, // Ensure background color
              //   child: KycStepperBar(
              //     steps: stepperSteps,
              //     currentIndex: stepperIndex,
              //   ),
              // );
              // Placeholder so existing showStepper branches compile while stepper is off.
              final stepperWidget = const SizedBox.shrink();

              // Partial loader / retry while returning from WebView.
              // Checked before anything else so the old step's form UI is NEVER
              // rendered between WebView exit and both API calls completing.
              // Refresh and Logout buttons remain visible so the user always
              // has an escape hatch — only the content area shows the loader.
              if (store.isReturningFromWebView) {
                return Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (isAuthenticated)
                          _buildAuthenticatedHeaderActions(
                            store,
                            refreshBusyOverride: _loadWorkflowActive,
                            onRefreshOverride: (_loadWorkflowActive || _logoutLoading)
                                ? null
                                : () {
                                    _refreshWorkflowFromHeader(store);
                                  },
                          ),
                        // Stepper stays visible throughout (hidden — see showStepper above)
                        // if (showStepper) stepperWidget,
                        // Content area: spinner or retry
                        Expanded(
                          child: _webViewReturnError != null
                              ? _buildWebViewReturnRetryContent(store)
                              : _buildWebViewReturnLoaderContent(),
                        ),
                      ],
                    ),
                  ),
                );
              }

              // Subtle loader shown just before navigating to WebView.
              // Paired with the FadeTransition on the webview route to guarantee
              // smooth transition without flash of home-page UI.
              if (_webViewTransitionActive) {
                return Scaffold(
                  backgroundColor: Colors.white,
                  body: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: KycTheme.primary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Opening verification...',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: KycTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              if (_ssoInProgress) {
                return const Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: Loader(message: 'Signing you in...'),
                  ),
                );
              }

              if (_loadWorkflowActive) {
                return const Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: Loader(message: 'Setting up your KYC journey...'),
                  ),
                );
              }

              if (_responseIndicatesKycCompleted(store.fieldsWithAuth) ||
                  _navigatingToKycCompleted) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  unawaited(_navigateToKycCompletedIfNeeded(store));
                });
                return const Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: Loader(message: 'Loading your KYC status...'),
                  ),
                );
              }

              // Handle loading states - full screen when no stepper, else loader below stepper
              if (store.loading && !_ssoInProgress) {
                return Scaffold(
                  backgroundColor: KycTheme.background,
                  body: SafeArea(
                    child: showStepper
                        ? Column(
                            children: [
                              stepperWidget,
                              const Expanded(child: Loader(
                                message: 'Setting up your KYC journey...',
                                minimal: true,
                              )),
                            ],
                          )
                        : const Loader(
                            message: 'Setting up your KYC journey...',
                          ),
                  ),
                );
              }
              
              if (store.error != null) {
                return _buildApiErrorScaffold(
                  store: store,
                  message: store.error!,
                  isAuthenticated: isAuthenticated,
                );
              }
              
              // get-context refresh (not submit): full-screen loader. Submit keeps button spinner.
              if (store.loadingWithAuth && !_submitLoading && !_ssoInProgress) {
                return _buildStepTransitionScaffold(
                  showStepper: showStepper,
                  stepperWidget: stepperWidget,
                  message: 'Loading your next step...',
                );
              }

              // Show error if get-context API failed (502, server HTML, technical tokens, etc.)
              // PDF encrypted/closed: keep upload step visible (previous context still valid).
              if (store.errorWithAuth != null) {
                if (store.hasPdfDocumentEncryptedContextError &&
                    store.fieldsWithAuth is Map) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    if (!store.hasPdfDocumentEncryptedContextError) return;
                    _recoverFromPdfDocumentEncryptedError(store);
                  });
                } else {
                  if (store.invalidUserSession) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      unawaited(_autoRecoverInvalidSessionIfNeeded(store));
                    });
                  }
                  return _buildApiErrorScaffold(
                    store: store,
                    message: store.hasPdfDocumentEncryptedContextError
                        ? kPdfDocumentEncryptedUserMessage
                        : store.errorWithAuth!,
                    isAuthenticated: isAuthenticated,
                    onRetry: () async {
                      if (store.hasPdfDocumentEncryptedContextError &&
                          store.fieldsWithAuth is! Map) {
                        // Stuck session after encrypted PDF with no step context —
                        // reset auth so user can continue from a clean upload journey.
                        await StorageService.clearAuthTokens();
                        store.clearAuthError();
                        if (mounted) await _loadWorkflow();
                        return;
                      }
                      if (store.invalidUserSession) {
                        final ssoOk = await _recoverInvalidSessionViaSso(store);
                        if (ssoOk && mounted) {
                          await _loadWorkflow();
                        }
                      } else {
                        await _loadWorkflow();
                      }
                    },
                  );
                }
              }

              // Get page title from context.page.data.label or context.page.name, fallback to title/pageTitle
              final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
              final page = ctx?['page'] as Map?;
              final pageData = page?['data'] as Map?;
              final rawPageLabel = pageData?['label']?.toString();
              final pageName = page?['name']?.toString();
              final rawPosition = ctx?['position']?.toString();

              String? pageTitle;

              if (ctx == null) {
                // Hero title only on true first screen (no token). Mid-journey never show it.
                if (isAuthenticated || _isMidAuthenticatedJourney(store)) {
                  pageTitle = _cachedPageTitle;
                } else {
                  pageTitle = 'Start your KYC or pickup where you left off';
                }
              } else {
                // Prefer human-friendly titles from context / activeFields.
                String? pageLabel = rawPageLabel;

                // If backend label is same as technical position (e.g. "personal_details"),
                // don't show it as a title – stepper already shows the step name.
                if (rawPageLabel != null &&
                    rawPosition != null &&
                    rawPageLabel.toLowerCase().trim() == rawPosition.toLowerCase().trim()) {
                  pageLabel = null;
                }

                pageTitle = pageLabel ??
                    pageName ??
                    (activeFields is Map
                        ? activeFields['title'] ?? activeFields['pageTitle']
                        : null)?.toString();

                // If title still looks like a technical key (all lowercase/underscores),
                // hide it and rely on the stepper only.
                if (pageTitle != null) {
                  final simple = pageTitle.trim();
                  final isCodeStyle = RegExp(r'^[a-z0-9_]+$').hasMatch(simple);
                  if (isCodeStyle) {
                    pageTitle = null;
                  }
                }
                _cacheAuthenticatedStepUi(
                  store: store,
                  ctx: ctx,
                  pageTitle: pageTitle,
                  activePage: activeFields,
                );
              }

              // Figma Start KYC hero — force title even if API sends "mobile"
              final posKey = (rawPosition ?? '').toLowerCase().trim();
              final labelKey = (rawPageLabel ?? '').toLowerCase().trim();
              if (posKey == 'mobile' || labelKey == 'mobile') {
                pageTitle = 'Start your KYC';
              }

              const showDocumentsSection = false;

              return Scaffold(
                backgroundColor: Colors.transparent,
                body: KycPageBackground(
                  child: SafeArea(
                  child: showStepper
                      ? Column(
                          children: [
                            if (isAuthenticated)
                              _buildAuthenticatedHeaderActions(store),
                            stepperWidget,
                            Expanded(
                              child: KycLayout(
                                title: pageTitle,
                                stepperSteps: null,
                                stepperIndex: null,
                                skipScaffold: true,
                                showDocumentsSection: showDocumentsSection,
                                leading: (isAuthenticated && (submitButton?['backShowButton'] ?? false))
                                    ? IconButton(
                                        onPressed: _backLoading
                                            ? null
                                            : () => Navigator.of(context).maybePop(),
                                        icon: _backLoading
                                            ? const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child: CircularProgressIndicator(
                                                    strokeWidth: 2, color: KycTheme.primary),
                                              )
                                            : const Icon(Icons.arrow_back, color: KycTheme.textPrimary),
                                      )
                                    : null,
                                trailing: null,
                                child: _buildForm(
                                  fieldList,
                                  activeFields,
                                  submitButton,
                                  store,
                                  isAuthenticated,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          children: [
                            if (isAuthenticated)
                              _buildAuthenticatedHeaderActions(store),
                            Expanded(
                              child: KycLayout(
                                title: pageTitle,
                                stepperSteps: null,
                                stepperIndex: null,
                                skipScaffold: true,
                                leading: (isAuthenticated && (submitButton?['backShowButton'] ?? false))
                                    ? IconButton(
                                        onPressed: _backLoading
                                            ? null
                                            : () => Navigator.of(context).maybePop(),
                                        icon: _backLoading
                                            ? const SizedBox(
                                                width: 24,
                                                height: 24,
                                                child: CircularProgressIndicator(
                                                    strokeWidth: 2, color: KycTheme.primary),
                                              )
                                            : const Icon(Icons.arrow_back, color: KycTheme.textPrimary),
                                      )
                                    : null,
                                trailing: null,
                                showDocumentsSection: showDocumentsSection,
                                child: _buildForm(
                                  fieldList,
                                  activeFields,
                                  submitButton,
                                  store,
                                  isAuthenticated,
                                ),
                              ),
                            ),
                          ],
                        ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  // --- BP Wealth bugfixes (BugFixes → segmentBugResolved) ---
  // Personal-details step: merge get-context `field.value` (dropoff) into formData,
  // normalize radio/select option strings, apply PEP/citizen/tax/tariff defaults.
  // Segments step: `_prepareFormData` forces mtf / NSE-BSE currency off when UI hides them.
  // ---------------------------------------------------------------------------

  /// Matches workflow option labels (radio or **select** dropdown). Exact match first, then Yes/No prefix.
  String? _matchRadioOption(List<dynamic>? values, String desired) {
    if (values == null || values.isEmpty) return null;
    final want = desired.toLowerCase().trim();
    for (final o in values) {
      final s = o.toString();
      if (s.toLowerCase().trim() == want) return s;
    }
    if (want == 'yes') {
      for (final o in values) {
        final sl = o.toString().toLowerCase().trim();
        if (sl.startsWith('y')) return o.toString();
      }
    }
    if (want == 'no') {
      for (final o in values) {
        final sl = o.toString().toLowerCase().trim();
        if (sl.startsWith('n')) return o.toString();
      }
    }
    return null;
  }

  Map<dynamic, dynamic>? _findKraContinueField(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is Map && kraDetailsContinueWithKraChoiceField(f)) return f;
    }
    return null;
  }

  void _ensureKraContinueDefaultYes(List<dynamic> fieldList) {
    final kraField = _findKraContinueField(fieldList);
    if (kraField == null) return;
    final name = kraField['name']?.toString();
    if (name == null || name.isEmpty) return;
    final current = _formNotifier.formData[name]?.toString().trim() ?? '';
    if (current.isNotEmpty) return;
    final values = kraField['values'] as List?;
    final yes = _matchRadioOption(values, 'Yes');
    if (yes == null) return;
    _formNotifier.handleChange(
      name,
      yes,
      type: kraField['type']?.toString() ?? 'radio',
      validationType: kraField['validation']?.toString(),
    );
  }

  Map<dynamic, dynamic>? _findActivateFnoField(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      final n = (f['name']?.toString() ?? '').toLowerCase();
      if (n == 'activate_fno') return f;
    }
    return null;
  }

  String? _resolveMobileFieldName(List<dynamic> fieldList) {
    const preferred = ['mobile', 'mobile_number', 'phone', 'phone_number'];
    for (final key in preferred) {
      if (_findFieldDefByName(fieldList, key) != null) return key;
    }
    for (final f in fieldList) {
      if (f is! Map) continue;
      final name = (f['name']?.toString() ?? '').toLowerCase();
      final type = (f['type']?.toString() ?? '').toLowerCase();
      final validation = (f['validation']?.toString() ?? '').toLowerCase();
      if (type == 'text' &&
          (validation == 'mobile' ||
              name == 'mobile' ||
              name.contains('mobile') ||
              name == 'phone')) {
        return f['name']?.toString();
      }
    }
    return null;
  }

  void _applyMobileNumberToForm(List<dynamic> fieldList, String digits) {
    final name = _resolveMobileFieldName(fieldList) ?? 'mobile';
    final def = _findFieldDefByName(fieldList, name);
    _formNotifier.handleChange(
      name,
      digits,
      type: def?['type']?.toString() ?? 'text',
      validationType: def?['validation']?.toString() ?? 'mobile',
      validateWith: def?['validateWith']?.toString(),
    );
    if (mounted) {
      setState(() => _showMobileError = false);
    }
  }

  Future<void> _showSimPhonePickerDialog(
    List<SimPhoneOption> options,
    List<dynamic> fieldList,
  ) async {
    if (!mounted || options.isEmpty) return;
    final selected = await showDialog<SimPhoneOption>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Select mobile number'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                options.length == 1
                    ? 'Use this SIM number?'
                    : 'Choose which SIM number to use:',
                style: const TextStyle(
                  fontSize: 14,
                  color: KycTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 12),
              for (final opt in options)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.sim_card_outlined),
                  title: Text(
                    opt.displayNumber,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    [
                      if (opt.slotIndex != null) 'SIM ${(opt.slotIndex! + 1)}',
                      if (opt.carrierName != null && opt.carrierName!.isNotEmpty)
                        opt.carrierName!,
                    ].join(' · '),
                  ),
                  onTap: () => Navigator.of(ctx).pop(opt),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Enter manually'),
            ),
          ],
        );
      },
    );
    if (!mounted || selected == null) return;
    _applyMobileNumberToForm(fieldList, selected.phoneNumber);
  }

  Future<void> _tryAutofillMobileFromSim(
    List<dynamic> fieldList, {
    bool forcePicker = false,
  }) async {
    if (!mounted || _mobileSimAutofillInFlight) return;
    if (!Platform.isAndroid) {
      debugPrint('[HomePage] SIM autofill skipped — not Android');
      return;
    }

    final fieldName = _resolveMobileFieldName(fieldList);
    if (fieldName == null) {
      debugPrint(
        '[HomePage] SIM autofill: mobile field not in list yet (fields=${fieldList.length})',
      );
      // Allow retry when fields arrive on next sync.
      _mobileSimAutofillStepKey = null;
      return;
    }

    final existing = _formNotifier.formData[fieldName]?.toString() ?? '';
    final existingDigits = existing.replaceAll(RegExp(r'\D'), '');
    if (!forcePicker && existingDigits.length >= 10) {
      debugPrint('[HomePage] SIM autofill skipped — mobile already filled');
      return;
    }

    final pageId = (() {
      try {
        final ctx = context.read<AppStore>().fieldsWithAuth;
        if (ctx is Map) {
          return (ctx['context'] as Map?)?['page']?['id']?.toString() ?? '';
        }
      } catch (_) {}
      return '';
    })();
    final attemptKey = 'mobile|$pageId|$fieldName';
    if (!forcePicker && _mobileSimAutofillStepKey == attemptKey) {
      debugPrint('[HomePage] SIM autofill already attempted for $attemptKey');
      return;
    }

    _mobileSimAutofillInFlight = true;
    try {
      // Custom picker only (no Google Phone Number Hint — avoids Google branding).
      final options = await SimPhoneService.fetchSimPhoneNumbers();
      if (!mounted) return;
      _mobileSimAutofillStepKey = attemptKey;
      if (options.isEmpty) {
        debugPrint(
          '[HomePage] SIM autofill: no numbers from SubscriptionManager',
        );
        if (forcePicker) {
          Fluttertoast.showToast(
            msg: 'SIM number not available. Please enter manually.',
            gravity: ToastGravity.TOP,
          );
        }
        return;
      }
      await _showSimPhonePickerDialog(options, fieldList);
    } finally {
      _mobileSimAutofillInFlight = false;
    }
  }

  void _ensureActivateFnoDefaultYes(List<dynamic> fieldList) {
    final field = _findActivateFnoField(fieldList);
    if (field == null) return;
    final name = field['name']?.toString();
    if (name == null || name.isEmpty) return;
    final current = _formNotifier.formData[name]?.toString().trim() ?? '';
    if (current.isNotEmpty && !isApiFieldPlaceholderValue(current)) return;
    final values = field['values'] as List?;
    final yes = _matchRadioOption(values, 'Yes');
    if (yes == null) return;
    _formNotifier.handleChange(
      name,
      yes,
      type: field['type']?.toString() ?? 'select',
      validationType: field['validation']?.toString(),
    );
  }

  /// Previous nominee landing: `add_nominee` = No + opt-out checkbox ticked.
  void _ensureNomineeLandingDefaultNoChecked(List<dynamic> fieldList) {
    final addDef = _findFieldDefByName(fieldList, kAddNomineeField);
    if (addDef == null) return;

    if (isAddNomineeSelectedYes(_formNotifier.formData) &&
        nomineeDropoffHasSlot1Data(
          formData: _formNotifier.formData,
          fields: fieldList,
        )) {
      return;
    }

    final values = addDef['values'] as List?;
    final no = resolveKycYesNoOptionValue(values, 'No');
    final currentAdd =
        _formNotifier.formData[kAddNomineeField]?.toString().trim() ?? '';
    if (currentAdd.isEmpty ||
        isApiFieldPlaceholderValue(currentAdd) ||
        isAddNomineeSelectedYes(_formNotifier.formData)) {
      _formNotifier.handleChange(
        kAddNomineeField,
        no,
        type: addDef['type']?.toString() ?? 'select',
        validationType: addDef['validation']?.toString(),
        validateWith: addDef['validateWith']?.toString(),
      );
    }

    if (!isCheckboxCheckedValue(
      _formNotifier.formData[kNomineeOptOutTermsField],
    )) {
      final optOut = _findFieldDefByName(fieldList, kNomineeOptOutTermsField);
      _formNotifier.handleChange(
        kNomineeOptOutTermsField,
        true,
        type: optOut?['type']?.toString() ?? 'checkbox',
        validationType: optOut?['validation']?.toString(),
        validateWith: optOut?['validateWith']?.toString(),
      );
    }
    if (mounted) setState(() {});
  }

  /// `nominee_percentage` step: auto-assign remaining share so total is 100%.
  void _ensureNomineePercentageStepAuto100(List<dynamic> fieldList) {
    final pctDefs = <Map<dynamic, dynamic>>[];
    for (final f in fieldList) {
      if (f is! Map) continue;
      final name = f['name']?.toString() ?? '';
      if (!isNomineePercentageFieldName(name)) continue;
      pctDefs.add(Map<dynamic, dynamic>.from(f));
    }
    if (pctDefs.isEmpty) {
      // Fallback: any field with percentage in the name (except totals already handled).
      for (final f in fieldList) {
        if (f is! Map) continue;
        final name = (f['name']?.toString() ?? '').toLowerCase();
        if (name.isEmpty) continue;
        if (name == kTotalNomineePercentageField ||
            name == kTotalNomineePercentage2Field ||
            name == kRemainNomineePercentField ||
            name == kRemainNomineePercent2Field) {
          continue;
        }
        if (name.contains('percentage') || name.endsWith('_percent')) {
          pctDefs.add(Map<dynamic, dynamic>.from(f));
        }
      }
    }
    if (pctDefs.isEmpty) return;

    var filledSum = 0.0;
    final emptyNames = <String>[];
    for (final def in pctDefs) {
      final name = def['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final raw = _formNotifier.formData[name]?.toString().trim() ?? '';
      if (raw.isEmpty || isApiFieldPlaceholderValue(raw)) {
        emptyNames.add(name);
        continue;
      }
      filledSum += double.tryParse(raw) ?? 0;
    }

    if (emptyNames.isNotEmpty) {
      final remain = (100.0 - filledSum).clamp(0.0, 100.0);
      final targetName = emptyNames.first;
      final def = pctDefs.firstWhere(
        (d) => d['name']?.toString() == targetName,
        orElse: () => pctDefs.first,
      );
      final value = remain == remain.roundToDouble()
          ? remain.toInt().toString()
          : remain.toString();
      _formNotifier.handleChange(
        targetName,
        value,
        type: def['type']?.toString() ?? 'number',
        validationType: def['validation']?.toString(),
        validateWith: def['validateWith']?.toString(),
      );
      filledSum += remain;
    }

    // Keep hidden total in sync when present on this step.
    if (_findFieldDefByName(fieldList, kTotalNomineePercentageField) != null) {
      final totalVal = filledSum == filledSum.roundToDouble()
          ? filledSum.toInt().toString()
          : filledSum.toString();
      final current =
          _formNotifier.formData[kTotalNomineePercentageField]?.toString().trim() ??
              '';
      if (current != totalVal) {
        _formNotifier.handleChange(
          kTotalNomineePercentageField,
          totalVal,
          type: 'text',
        );
      }
    }

    debugPrint(
      '[HomePage] nominee_percentage auto-100 applied (filledSum=$filledSum, empty=${emptyNames.length})',
    );
    if (mounted) setState(() {});
  }

  String? _primaryKraAddressFieldName(List<dynamic> fieldList) {
    String? fallback;
    for (final f in fieldList) {
      if (f is! Map || !isKraAddressComponentField(f)) continue;
      final n = f['name']?.toString() ?? '';
      if (n.isEmpty) continue;
      fallback ??= n;
      final nl = n.toLowerCase();
      if (nl.contains('line1') ||
          nl == 'add1' ||
          nl.endsWith('_add1') ||
          nl == 'kraaddress' ||
          nl == 'kra_address') {
        return n;
      }
    }
    return fallback;
  }

  void _applyEditedKraAddress(String text, List<dynamic> fieldList) {
    final primary = _primaryKraAddressFieldName(fieldList);
    if (primary == null) return;
    _formNotifier.handleChange(primary, text, type: 'textarea');
    for (final f in fieldList) {
      if (f is! Map || !isKraAddressComponentField(f)) continue;
      final n = f['name']?.toString();
      if (n == null || n.isEmpty || n == primary) continue;
      final existing = _formNotifier.formData[n]?.toString().trim() ?? '';
      if (existing.isNotEmpty) {
        _formNotifier.handleChange(n, '', type: 'text');
      }
    }
  }

  Widget _buildKraAddressSummarySection(List<dynamic> fieldList) {
    final controller = _kraAddressController;
    if (controller == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Address',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: KycTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          minLines: 1,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(
            fontSize: 15,
            height: 1.45,
            color: KycTheme.textPrimary,
          ),
          onChanged: (v) => _applyEditedKraAddress(v, fieldList),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            hintText: 'Enter full address',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(KycTheme.radiusMd),
              borderSide: const BorderSide(color: KycTheme.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(KycTheme.radiusMd),
              borderSide: const BorderSide(color: KycTheme.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(KycTheme.radiusMd),
              borderSide:
                  const BorderSide(color: KycTheme.primaryLight, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  /// Map API/dropoff value to the exact option string (radio or **select**).
  String _normalizeRadioToOptions(dynamic raw, List<dynamic>? options) {
    if (raw == null || options == null || options.isEmpty) {
      return raw?.toString() ?? '';
    }
    final want = raw.toString().trim().toLowerCase();
    for (final o in options) {
      final s = o.toString();
      if (s.toLowerCase().trim() == want) return s;
    }
    if (want == 'yes' || want == 'y') {
      final m = _matchRadioOption(options, 'Yes');
      if (m != null) return m;
    }
    if (want == 'no' || want == 'n') {
      final m = _matchRadioOption(options, 'No');
      if (m != null) return m;
    }
    if (want.startsWith('y')) {
      final m = _matchRadioOption(options, 'Yes');
      if (m != null) return m;
    }
    if (want.startsWith('n')) {
      final m = _matchRadioOption(options, 'No');
      if (m != null) return m;
    }
    return raw.toString();
  }

  Map<dynamic, dynamic>? _findAadharImageFieldDef(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      if (isAadharImageFieldName(f['name']?.toString())) return f;
    }
    return null;
  }

  void _applyDigilockerAadharImageToForm(AppStore store, List<dynamic> fieldList) {
    final aadharField = _findAadharImageFieldDef(fieldList);
    if (aadharField == null) return;
    final name = aadharField['name']?.toString();
    if (name == null || name.isEmpty) return;

    final resolved = resolveDigilockerAadharImageRaw(
      userDetails: store.userDetails,
      fieldValue: aadharField['value'],
      formValue: _formNotifier.formData[name],
    );
    if (resolved == null) return;
    final current = _formNotifier.formData[name]?.toString().trim() ?? '';
    if (resolved.trim() == current) return;

    debugPrint(
        '[HomePage] DigiLocker aadhar_image sync: $current → ${resolved.trim()}');
    _formNotifier.handleChange(
      name,
      resolved,
      type: aadharField['type']?.toString() ?? 'text',
      validationType: aadharField['validation']?.toString(),
    );
  }

  void _syncDigilockerAadharImage(
    AppStore store,
    List<dynamic> fieldList, {
    String? position,
    String? pageLabel,
  }) {
    if (!isDigilockerStep(position, pageLabel)) return;

    _applyDigilockerAadharImageToForm(store, fieldList);

    if (_digilockerUserDetailsFetchStarted) return;
    _digilockerUserDetailsFetchStarted = true;
    store.fetchUserDetails().then((_) {
      if (!mounted) return;
      _applyDigilockerAadharImageToForm(store, fieldList);
      setState(() {});
    });
  }

  void _syncPanVerifyFieldsToForm(Map<String, dynamic> normalized) {
    for (final entry in normalized.entries) {
      final current = _formNotifier.formData[entry.key]?.toString() ?? '';
      final next = entry.value?.toString() ?? '';
      if (current == next) continue;
      _formNotifier.handleChange(entry.key, entry.value, type: 'text');
    }
  }

  /// Prefer in-memory value; if unset (`null` / blank), use workflow seed
  /// (`value` → literal prepopulate → `defaultValue`).
  dynamic _coalesceFormFieldValue(
    dynamic formValue,
    dynamic fieldValue, {
    String? type,
  }) {
    final fieldType = (type ?? '').toLowerCase();
    if (formValue is bool &&
        (fieldType == 'text' ||
            fieldType == 'textarea' ||
            fieldType == 'number' ||
            fieldType == 'password')) {
      formValue = '';
    }
    // Never show prepopulate source mappings / key names in inputs.
    if (formValue is List || formValue is Map) {
      formValue = null;
    } else if (formValue is String &&
        looksLikePrepopulateSourceKey(formValue) &&
        !isKycChoiceFieldType(fieldType) &&
        fieldType != 'checkbox') {
      formValue = null;
    }
    if (fieldValue is List || fieldValue is Map) {
      fieldValue = null;
    } else if (fieldValue is String &&
        looksLikePrepopulateSourceKey(fieldValue) &&
        !isKycChoiceFieldType(fieldType) &&
        fieldType != 'checkbox') {
      fieldValue = null;
    }
    if (formValue == null) return fieldValue;
    // Choice / checkbox: blank or placeholder (`Select`) falls back to API defaultValue.
    final isChoiceOrCheckbox =
        isKycChoiceFieldType(fieldType) || fieldType == 'checkbox';
    if (formValue is String &&
        (formValue.trim().isEmpty || isApiFieldPlaceholderValue(formValue))) {
      return isChoiceOrCheckbox ? fieldValue : formValue;
    }
    return formValue;
  }

  /// True when [formData] has no meaningful value yet (merge dropoff/API into form).
  /// Blank string means the user cleared the field — do not merge API prepopulate again.
  bool _shouldMergeFromApi(dynamic existing) {
    if (existing == null) return true;
    if (existing is String && existing.trim().isEmpty) return false;
    return false;
  }

  /// Personal-details defaults (PEP, tax residency): apply when null or still empty.
  bool _shouldApplyPersonalDetailsDefault(dynamic existing) {
    if (existing == null) return true;
    if (existing is String && existing.trim().isEmpty) return true;
    // API often sends placeholder `Select` until user picks — treat as unset.
    if (isApiFieldPlaceholderValue(existing)) return true;
    return false;
  }

  /// Push `field['value']` / `defaultValue` from get-context (incl. dropoff) into [formData]
  /// so radios/checkboxes match option strings and submit payload is correct.
  /// Skips when user already has a value.
  void _mergePersonalDetailsFromFieldDefinitions(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      final name = f['name']?.toString();
      if (name == null || name.isEmpty) continue;
      final existing = _formNotifier.formData[name];
      if (!_shouldMergeFromApi(existing)) continue;

      final apiValue = resolveApiFieldSeedValue(f);
      if (apiValue == null) continue;
      if (apiValue is String && apiValue.trim().isEmpty) continue;

      final type = f['type']?.toString() ?? '';
      final validation = f['validation']?.toString();
      final values = f['values'] as List?;

      if (isKycChoiceFieldType(type)) {
        final normalized = _normalizeRadioToOptions(apiValue, values);
        _formNotifier.handleChange(name, normalized,
            type: type, validationType: validation);
      } else if (type == 'checkbox') {
        final v = isCheckboxCheckedValue(apiValue);
        _formNotifier.handleChange(name, v,
            type: 'checkbox', validationType: validation);
      } else {
        _formNotifier.handleChange(name, apiValue,
            type: type.isEmpty ? 'text' : type, validationType: validation);
      }
    }
  }

  /// Apply API `defaultValue` (and dropoff `value`) on unset checkbox / choice fields
  /// for every step — not only personal-details.
  void _applyApiDefaultValues(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      final name = f['name']?.toString();
      if (name == null || name.isEmpty) continue;
      final type = (f['type']?.toString() ?? '').toLowerCase();
      final isChoice = isKycChoiceFieldType(type);
      final isCheckbox = type == 'checkbox';
      if (!isChoice && !isCheckbox) continue;

      final existing = _formNotifier.formData[name];
      // add_nominee: honour API defaultValue when still blank / placeholder ("Select").
      final forceAddNominee = name == kAddNomineeField;
      if (!forceAddNominee &&
          !_shouldApplyPersonalDetailsDefault(existing)) {
        continue;
      }
      if (forceAddNominee &&
          existing != null &&
          existing.toString().trim().isNotEmpty &&
          !isApiFieldPlaceholderValue(existing)) {
        continue;
      }

      final seed = resolveApiFieldSeedValue(f);
      if (seed == null) continue;
      if (seed is String && seed.trim().isEmpty) continue;

      final validation = f['validation']?.toString();
      if (isCheckbox) {
        _formNotifier.handleChange(
          name,
          isCheckboxCheckedValue(seed),
          type: 'checkbox',
          validationType: validation,
        );
      } else {
        final values = f['values'] as List?;
        final normalized = _normalizeRadioToOptions(seed, values);
        _formNotifier.handleChange(
          name,
          normalized,
          type: f['type']?.toString() ?? type,
          validationType: validation,
        );
      }
    }
  }

  /// Fix casing mismatch for radio and **select** (dropdown) option lists.
  void _normalizePersonalDetailRadios(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      final type = f['type']?.toString() ?? '';
      if (!isKycChoiceFieldType(type)) continue;
      final name = f['name']?.toString();
      if (name == null || name.isEmpty) continue;
      final values = f['values'] as List?;
      final raw = _formNotifier.formData[name];
      if (raw == null) continue;
      final fixed = _normalizeRadioToOptions(raw, values);
      if (fixed != raw.toString()) {
        _formNotifier.handleChange(name, fixed,
            type: type, validationType: f['validation']?.toString());
      }
    }
  }

  bool get _isBpWealthCompany =>
      widget.company.toLowerCase().trim() == 'bpwealth';

  /// BP Wealth only: merge dropoff, normalize radios, then PEP/citizen/tax/tariff defaults.
  void _runPersonalDetailsBpWealthPipeline(
    AppStore store,
    List<dynamic> fieldList,
  ) {
    if (!_isBpWealthCompany) return;
    final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
    var position = ctx?['position']?.toString().toLowerCase() ?? '';
    var pageLabel =
        ctx?['page']?['data']?['label']?.toString().toLowerCase() ?? '';
    if (position.isEmpty || pageLabel.isEmpty) {
      final workflow = store.fields as Map?;
      position = (workflow?['position']?.toString() ?? '').toLowerCase();
      pageLabel = (workflow?['data']?['label']?.toString() ?? '').toLowerCase();
    }
    final isPersonalDetails = position == 'personal_details' ||
        pageLabel == 'personal_details';
    if (!isPersonalDetails) return;

    debugPrint(
        '[HomePage] personal_details BP Wealth pipeline: fields=${fieldList.length}');
    _mergePersonalDetailsFromFieldDefinitions(fieldList);
    _normalizePersonalDetailRadios(fieldList); // radio + select (dropdowns)
    _applyPersonalDetailsDefaults(fieldList);
    _applyBpWealthStandingInstructionScreenshotDefaults(fieldList);
  }

  /// Web standing-instructions accordion defaults (screenshot parity) when value still unset.
  void _applyBpWealthStandingInstructionScreenshotDefaults(
    List<dynamic> fieldList,
  ) {
    if (!_isBpWealthCompany) return;

    String? _pickElectronic(List? values) {
      if (values == null) return null;
      for (final o in values) {
        final s = o.toString();
        if (s.toLowerCase().contains('elect')) return s;
      }
      return null;
    }

    String? _pickSebiRegulations(List? values) {
      if (values == null) return null;
      for (final o in values) {
        final s = o.toString();
        final sl = s.toLowerCase();
        if (sl.contains('sebi') && sl.contains('regul')) return s;
        if (sl.contains('as per')) return s;
      }
      return null;
    }

    void applyYesNo(String fieldName, String yesOrNo) {
      for (final f in fieldList) {
        if (f is! Map) continue;
        if (f['name']?.toString() != fieldName) continue;
        final type = f['type']?.toString() ?? '';
        if (!isKycChoiceFieldType(type)) return;
        if (!_shouldMergeFromApi(_formNotifier.formData[fieldName])) return;
        final values = f['values'] as List?;
        final pick = _matchRadioOption(values, yesOrNo);
        if (pick != null) {
          _formNotifier.handleChange(
            fieldName,
            pick,
            type: type,
            validationType: f['validation']?.toString(),
          );
        }
        return;
      }
    }

    void applyElectronic(String fieldName) {
      for (final f in fieldList) {
        if (f is! Map) continue;
        if (f['name']?.toString() != fieldName) continue;
        final type = f['type']?.toString() ?? '';
        if (!isKycChoiceFieldType(type)) return;
        if (!_shouldMergeFromApi(_formNotifier.formData[fieldName])) return;
        final values = f['values'] as List?;
        final raw = _pickElectronic(values);
        if (raw == null) return;
        final normalized = _normalizeRadioToOptions(raw, values);
        _formNotifier.handleChange(
          fieldName,
          normalized,
          type: type,
          validationType: f['validation']?.toString(),
        );
        return;
      }
    }

    String? _pickQuarterly(List? values) {
      if (values == null) return null;
      for (final o in values) {
        final s = o.toString();
        if (s.toLowerCase().contains('quarter')) return s;
      }
      return _matchRadioOption(values, 'Quarterly');
    }

    void applyStatementFrequencyByDisplayName() {
      for (final f in fieldList) {
        if (f is! Map) continue;
        final name = f['name']?.toString();
        if (name == null) continue;
        if (!bpWealthPersonalDetailsHoldingStatementFrequencyField(f)) continue;
        final type = f['type']?.toString() ?? '';
        if (!isKycChoiceFieldType(type)) continue;
        if (!_shouldMergeFromApi(_formNotifier.formData[name])) continue;
        final values = f['values'] as List?;
        final raw = _pickSebiRegulations(values);
        if (raw == null) continue;
        final normalized = _normalizeRadioToOptions(raw, values);
        _formNotifier.handleChange(
          name,
          normalized,
          type: type,
          validationType: f['validation']?.toString(),
        );
      }
    }

    void applyDisBookletFrequencyDefault() {
      for (final f in fieldList) {
        if (f is! Map) continue;
        if (!bpWealthPersonalDetailsDisBookletFrequencyField(f)) continue;
        final name = f['name']?.toString();
        if (name == null || name.isEmpty) continue;
        final type = f['type']?.toString() ?? '';
        if (!isKycChoiceFieldType(type)) continue;
        if (!_shouldMergeFromApi(_formNotifier.formData[name])) continue;
        final values = f['values'] as List?;
        final raw = _pickQuarterly(values);
        if (raw == null) continue;
        final normalized = _normalizeRadioToOptions(raw, values);
        _formNotifier.handleChange(
          name,
          normalized,
          type: type,
          validationType: f['validation']?.toString(),
        );
      }
    }

    void applyRunningAccountAuthorizationDefault() {
      for (final f in fieldList) {
        if (f is! Map) continue;
        if (!bpWealthPersonalDetailsRunningAccountAuthorizationField(f)) {
          continue;
        }
        final name = f['name']?.toString();
        if (name == null || name.isEmpty) continue;
        final type = f['type']?.toString() ?? '';
        if (!isKycChoiceFieldType(type)) continue;
        if (!_shouldMergeFromApi(_formNotifier.formData[name])) continue;
        final values = f['values'] as List?;
        final raw = _pickQuarterly(values);
        if (raw == null) continue;
        final normalized = _normalizeRadioToOptions(raw, values);
        _formNotifier.handleChange(
          name,
          normalized,
          type: type,
          validationType: f['validation']?.toString(),
        );
      }
    }

    applyYesNo('sebi_3years', 'No');
    applyYesNo('directly_bank_account', 'Yes');
    applyYesNo('credit_account', 'Yes');
    applyYesNo('rta', 'Yes');
    applyYesNo('dp_accept', 'No');
    applyYesNo('electronic_transaction', 'Yes');
    applyElectronic('receive_contract');
    applyElectronic('annual_report');
    applyStatementFrequencyByDisplayName();
    applyYesNo('debitbalance', 'Yes');
    applyYesNo('dis_booklet', 'No');
    applyYesNo('dis_book', 'No');
    applyYesNo('dis', 'No');
    applyYesNo('delivery_instruction_slip', 'No');
    applyYesNo('dis_slip', 'No');
    applyDisBookletFrequencyDefault();
    applyRunningAccountAuthorizationDefault();
    _applyBpWealthPersonalDetailsPepAndTaxDefaults(fieldList);
  }

  void _applyBpWealthPersonalDetailsPepAndTaxDefaults(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      final map = Map<dynamic, dynamic>.from(f);
      final name = map['name']?.toString();
      if (name == null || name.isEmpty) continue;
      final isPep = bpWealthPersonalDetailsPoliticallyExposedField(map);
      final isTax = isTaxResidencyOutsideIndiaField(map);
      if (!isPep && !isTax) continue;

      final type = map['type']?.toString() ?? '';
      if (!isKycChoiceFieldType(type)) continue;
      if (!_shouldApplyPersonalDetailsDefault(_formNotifier.formData[name])) {
        continue;
      }

      final values = map['values'] as List?;
      final pick = _matchRadioOption(values, 'No');
      if (pick == null) continue;
      _formNotifier.handleChange(
        name,
        pick,
        type: type,
        validationType: map['validation']?.toString(),
      );
    }
  }

  /// Personal details step: defaults when API/dropoff did not pre-fill.
  void _applyPersonalDetailsDefaults(List<dynamic> fieldList) {
    for (final f in fieldList) {
      if (f is! Map) continue;
      final name = f['name']?.toString();
      if (name == null || name.isEmpty) continue;
      if (!_shouldApplyPersonalDetailsDefault(_formNotifier.formData[name])) {
        continue;
      }

      final map = Map<dynamic, dynamic>.from(f);
      final dn = (f['displayName']?.toString() ?? '').toLowerCase();
      final nl = name.toLowerCase();
      final type = f['type']?.toString() ?? '';
      final values = f['values'] as List?;
      final validation = f['validation']?.toString();

      if (isKycChoiceFieldType(type)) {
        final vYes = _matchRadioOption(values, 'Yes');
        final vNo = _matchRadioOption(values, 'No');

        if (bpWealthPersonalDetailsPoliticallyExposedField(map) && vNo != null) {
          _formNotifier.handleChange(name, vNo,
              type: type, validationType: validation);
          continue;
        }

        final citizenIndia = (dn.contains('citizen') && dn.contains('india')) ||
            (nl.contains('citizen') &&
                (nl.contains('india') || nl.contains('indian')));
        if (citizenIndia && vYes != null) {
          _formNotifier.handleChange(name, vYes,
              type: type, validationType: validation);
          continue;
        }

        if (isTaxResidencyOutsideIndiaField(map) && vNo != null) {
          _formNotifier.handleChange(name, vNo,
              type: type, validationType: validation);
          continue;
        }

        // Tariff / "continue your journey" style dropdown — pick default/tariff option if any.
        final journeyTariff = dn.contains('tariff') ||
            nl.contains('tariff') ||
            (dn.contains('journey') && dn.contains('continue')) ||
            (dn.contains('please select') && dn.contains('continue')) ||
            (dn.contains('option') && dn.contains('continue'));
        if (journeyTariff && values != null && values.isNotEmpty) {
          String? pick;
          for (final o in values) {
            final s = o.toString();
            final sl = s.toLowerCase();
            if (sl.contains('default') ||
                sl.contains('tariff') ||
                sl.contains('brokerage') ||
                sl.contains('stoxbox')) {
              pick = s;
              break;
            }
          }
          pick ??= values.first.toString();
          _formNotifier.handleChange(name, pick,
              type: type, validationType: validation);
          continue;
        }
        continue;
      }

      if (type == 'checkbox') {
        final tariff = dn.contains('tariff') || nl.contains('tariff');
        if (tariff) {
          _formNotifier.handleChange(name, true,
              type: 'checkbox', validationType: validation);
        }
      }
    }
  }

  int _bpWealthPersonalMainSortKey(String? name) {
    if (name == null) return 99999;
    final n = name.toLowerCase();
    const order = <String>[
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
      'spouse_name',
      'spouse',
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
    ];
    final i = order.indexOf(n);
    if (i >= 0) return i;
    return 9000 + n.hashCode.remainder(10000);
  }

  int _bpWealthStandingSortKey(Map<dynamic, dynamic> f) {
    if (bpWealthPersonalDetailsPastActionField(f)) {
      return 1;
    }
    if (bpWealthPersonalDetailsHoldingStatementFrequencyField(f)) {
      return 8;
    }
    if (bpWealthPersonalDetailsDisBookletFrequencyField(f)) {
      return 14;
    }
    if (bpWealthPersonalDetailsRunningAccountAuthorizationField(f)) {
      return 13;
    }
    final name = f['name']?.toString();
    if (name == null) return 99999;
    const order = <String>[
      'sebi_3years',
      'past_action',
      'past_actions',
      'directly_bank_account',
      'credit_account',
      'rta',
      'dp_accept',
      'electronic_transaction',
      'receive_contract',
      'annual_report',
      'holding_cum_transaction_statement',
      'holding_transaction_statement',
      'transaction_statement_frequency',
      'cum_holding_statement',
      'debitbalance',
      'running_account_authorization',
      'running_account',
      'running_ac_authorization',
      'raa',
      'dis_booklet',
      'dis_book',
      'dis',
      'delivery_instruction_slip',
      'dis_slip',
    ];
    final i = order.indexOf(name);
    if (i >= 0) return i;
    return 8000 + name.hashCode.remainder(1000);
  }

  static const String _kBpWealthTariffPdfAsset =
      'assets/pdf/bpwealth_tariff_plan.pdf';

  bool _bpWealthTariffPdfOpening = false;

  /// Opens the bundled tariff PDF.
  /// iOS: in-app WebView (QuickLook/open_filex needs 2 taps after dismiss).
  /// Android: system viewer via open_filex.
  Future<void> _openBpWealthTariffPdf() async {
    if (_bpWealthTariffPdfOpening) return;
    _bpWealthTariffPdfOpening = true;
    try {
      if (Platform.isIOS) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => const _BpWealthTariffPdfPreviewDialog(
            assetPath: _kBpWealthTariffPdfAsset,
          ),
        );
        return;
      }

      final data = await rootBundle.load(_kBpWealthTariffPdfAsset);
      final bytes = data.buffer.asUint8List();
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/bpwealth_tariff_plan_${DateTime.now().millisecondsSinceEpoch}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);

      final result = await OpenFilex.open(
        file.path,
        type: 'application/pdf',
      );
      debugPrint(
          '[HomePage] Tariff PDF open: type=${result.type} message=${result.message} path=${file.path}');

      if (result.type != ResultType.done) {
        Fluttertoast.showToast(
          msg: result.message.isNotEmpty
              ? result.message
              : 'Unable to open PDF. Please install a PDF viewer and try again.',
          gravity: ToastGravity.TOP,
          toastLength: Toast.LENGTH_LONG,
        );
      }
    } catch (e) {
      debugPrint('[HomePage] Tariff PDF open failed: $e');
      Fluttertoast.showToast(
        msg: 'Unable to open PDF. Please try again later.',
        gravity: ToastGravity.TOP,
      );
    } finally {
      _bpWealthTariffPdfOpening = false;
    }
  }

  /// BP Wealth personal_details: web-like header, single-column main (2nd screenshot fields only),
  /// Standing accordion, then tariff consent + View (PDF) **below** accordion.
  List<Widget> _buildBpWealthPersonalWebFormLayout({
    required List<dynamic> visibleFieldsForDisplay,
    required Map? otpField,
    required String? otpFieldName,
    required bool hasAadharImage,
    required dynamic activeFields,
    required AppStore store,
    required List<dynamic> fieldList,
    required String? position,
    required String? pageLabel,
    required Map? ctx,
  }) {
    final maps = visibleFieldsForDisplay
        .whereType<Map>()
        .map((e) => Map<dynamic, dynamic>.from(e))
        .toList();

    final main = <Map<dynamic, dynamic>>[];
    final standing = <Map<dynamic, dynamic>>[];
    Map<dynamic, dynamic>? consentField;

    for (final f in maps) {
      if (bpWealthPersonalDetailsTariffConsentCheckboxField(f)) {
        consentField = f;
        continue;
      }
      // Must use [bpWealthPersonalDetailsStandingSectionField] — not only
      // [kBpWealthPersonalDetailsStandingFieldNames], so displayName-based
      // rows (e.g. holding cum transaction statement frequency) land here.
      if (bpWealthPersonalDetailsStandingSectionField(f)) {
        standing.add(f);
      } else {
        // Main grid: whitelisted fields + conditionally revealed rows (e.g. spouse_name).
        main.add(f);
      }
    }

    if (consentField == null) {
      for (final raw in fieldList) {
        if (raw is! Map) continue;
        final f = Map<dynamic, dynamic>.from(raw);
        if (bpWealthPersonalDetailsTariffConsentCheckboxField(f)) {
          consentField = f;
          break;
        }
      }
    }

    main.sort((a, b) => _bpWealthPersonalMainSortKey(a['name']?.toString())
        .compareTo(_bpWealthPersonalMainSortKey(b['name']?.toString())));
    standing.sort((a, b) =>
        _bpWealthStandingSortKey(a).compareTo(_bpWealthStandingSortKey(b)));

    final out = <Widget>[
      const SizedBox(height: 8),
      ...main.map(
        (f) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: _buildFormFieldRow(
            field: f,
            otpField: otpField,
            otpFieldName: otpFieldName,
            hasAadharImage: hasAadharImage,
            activeFields: activeFields,
            store: store,
            fieldList: fieldList,
            position: position,
            pageLabel: pageLabel,
            ctx: ctx,
          ),
        ),
      ),
    ];

    if (standing.isNotEmpty) {
      out.add(const SizedBox(height: 8));
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey<String>('bpwealth_standing_instructions'),
              initiallyExpanded: false,
              tilePadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              collapsedShape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KycTheme.radiusSm),
                side: const BorderSide(color: KycTheme.border),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KycTheme.radiusSm),
                side: const BorderSide(color: KycTheme.border),
              ),
              title: const Text(
                'Standing instructions',
                style: TextStyle(
                  fontSize: KycTheme.fontSizeBodyLg,
                  fontWeight: FontWeight.w600,
                  color: KycTheme.textPrimary,
                ),
              ),
              subtitle: const Text(
                'DP preferences & statement options',
                style: TextStyle(
                  fontSize: KycTheme.fontSizeCaption,
                  color: KycTheme.textSecondary,
                ),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    key: ValueKey<String>(
                      standing
                          .map((g) => g['name']?.toString() ?? '')
                          .join('|'),
                    ),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: standing
                        .map(
                          (g) => KeyedSubtree(
                            key: ValueKey<String>(
                              'bp-standing-${g['name']?.toString() ?? ''}',
                            ),
                            child: _buildFormFieldRow(
                              field: g,
                              otpField: otpField,
                              otpFieldName: otpFieldName,
                              hasAadharImage: hasAadharImage,
                              activeFields: activeFields,
                              store: store,
                              fieldList: fieldList,
                              position: position,
                              pageLabel: pageLabel,
                              ctx: ctx,
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (consentField != null) {
      out.add(const SizedBox(height: 8));
      out.add(
        _buildFormFieldRow(
          field: consentField,
          otpField: otpField,
          otpFieldName: otpFieldName,
          hasAadharImage: hasAadharImage,
          activeFields: activeFields,
          store: store,
          fieldList: fieldList,
          position: position,
          pageLabel: pageLabel,
          ctx: ctx,
        ),
      );
    } else {
      out.add(const SizedBox(height: 8));
      out.add(
        Text(
          'I have read and understood the contents pertaining to the DP Standing Instructions and Tariff Structure details. I hereby agree and give my consent to the same.',
          style: TextStyle(
            fontSize: KycTheme.fontSizeBody,
            color: KycTheme.textPrimary,
            height: 1.35,
          ),
        ),
      );
    }

    out.add(const SizedBox(height: 12));
    out.add(
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          onPressed: _openBpWealthTariffPdf,
          style: FilledButton.styleFrom(
            backgroundColor: KycTheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          child: const Text('View'),
        ),
      ),
    );

    return out;
  }

  /// Default: sequential rows + BP Wealth standing expansion (non–personal_details).
  List<Widget> _buildSequencedFormRowsWithStandingExpansion({
    required List<dynamic> visibleFieldsForDisplay,
    required Map? otpField,
    required String? otpFieldName,
    required bool hasAadharImage,
    required dynamic activeFields,
    required AppStore store,
    required List<dynamic> fieldList,
    required String? position,
    required String? pageLabel,
    required Map? ctx,
  }) {
    final rows = <Widget>[];
    var idx = 0;
    while (idx < visibleFieldsForDisplay.length) {
      final raw = visibleFieldsForDisplay[idx];
      if (raw is! Map) {
        idx++;
        continue;
      }
      final fieldMap = Map<dynamic, dynamic>.from(raw);
      if (_bpWealthPersonalDetailsStandingUi(position, pageLabel) &&
          bpWealthPersonalDetailsStandingSectionField(fieldMap)) {
        final group = <Map<dynamic, dynamic>>[];
        while (idx < visibleFieldsForDisplay.length) {
          final r2 = visibleFieldsForDisplay[idx];
          if (r2 is! Map) break;
          final m2 = Map<dynamic, dynamic>.from(r2);
          if (!_bpWealthPersonalDetailsStandingUi(position, pageLabel) ||
              !bpWealthPersonalDetailsStandingSectionField(m2)) {
            break;
          }
          group.add(m2);
          idx++;
        }
        rows.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
              ),
              child: ExpansionTile(
                key: const ValueKey<String>('bpwealth_standing_instructions'),
                initiallyExpanded: false,
                tilePadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                collapsedShape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(KycTheme.radiusSm),
                  side: const BorderSide(color: KycTheme.border),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(KycTheme.radiusSm),
                  side: const BorderSide(color: KycTheme.border),
                ),
                title: const Text(
                  'Standing instructions & declarations',
                  style: TextStyle(
                    fontSize: KycTheme.fontSizeBodyLg,
                    fontWeight: FontWeight.w600,
                    color: KycTheme.textPrimary,
                  ),
                ),
                subtitle: const Text(
                  'Tap to expand (same as website)',
                  style: TextStyle(
                    fontSize: KycTheme.fontSizeCaption,
                    color: KycTheme.textSecondary,
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(
                      key: ValueKey<String>(
                        group
                            .map((g) => g['name']?.toString() ?? '')
                            .join('|'),
                      ),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: group
                          .map(
                            (g) => KeyedSubtree(
                              key: ValueKey<String>(
                                'bp-standing-${g['name']?.toString() ?? ''}',
                              ),
                              child: _buildFormFieldRow(
                                field: g,
                                otpField: otpField,
                                otpFieldName: otpFieldName,
                                hasAadharImage: hasAadharImage,
                                activeFields: activeFields,
                                store: store,
                                fieldList: fieldList,
                                position: position,
                                pageLabel: pageLabel,
                                ctx: ctx,
                              ),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        continue;
      }
      rows.add(
        _buildFormFieldRow(
          field: fieldMap,
          otpField: otpField,
          otpFieldName: otpFieldName,
          hasAadharImage: hasAadharImage,
          activeFields: activeFields,
          store: store,
          fieldList: fieldList,
          position: position,
          pageLabel: pageLabel,
          ctx: ctx,
        ),
      );
      idx++;
    }
    return rows;
  }

  Widget _buildForm(
    List fieldList,
    dynamic activeFields,
    Map? submitButton,
    AppStore store,
    bool isAuth,
  ) {
    // Check if this is segments screen / mobile screen
    final withAuth = store.fieldsWithAuth as Map?;
    final ctx = _contextForUi(store) ?? withAuth?['context'] as Map?;

    String? position = ctx?['position']?.toString()?.toLowerCase();
    String? pageLabel = ctx?['page']?['data']?['label']?.toString()?.toLowerCase();

    // Fallback for unauthenticated flow where context may be null:
    // use workflow root from store.fields (get-workflow-details response)
    if (position == null || position.isEmpty || pageLabel == null || pageLabel.isEmpty) {
      if (_isMidAuthenticatedJourney(store) &&
          (_cachedPosition ?? '').isNotEmpty) {
        position = _cachedPosition!.toLowerCase();
      } else {
        final workflow = store.fields as Map?;
        position =
            (workflow?['position']?.toString() ?? position ?? '').toLowerCase();
        pageLabel = (workflow?['data']?['label']?.toString() ?? pageLabel ?? '')
            .toLowerCase();
      }
    }

    debugPrint('[HomePage] _buildForm position=$position pageLabel=$pageLabel');

    if ((position == 'mobile' || pageLabel == 'mobile') &&
        (_persistedGoogleDisplayName?.trim().isNotEmpty ?? false)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _applyPersistedGoogleNameToForm();
      });
    }

    // Mobile T&C: auto-tick once when this step is shown (hot-restart / revisit safe).
    if (position == 'mobile' || pageLabel == 'mobile') {
      final pageId = ctx?['page']?['id']?.toString() ?? '';
      final termsKey = 'mobile|$pageId';
      if (_mobileTermsAutoSelectedStepKey != termsKey) {
        _mobileTermsAutoSelectedStepKey = termsKey;
        _termsAccepted = true;
        _showTermsError = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_mobileTermsAutoSelectedStepKey != termsKey) return;
          setState(() {
            _termsAccepted = true;
            _showTermsError = false;
          });
        });
      }
    } else if (_mobileTermsAutoSelectedStepKey != null) {
      _mobileTermsAutoSelectedStepKey = null;
    }

    final isSegmentsScreen = position == 'segments';
    final isActivateFnoStep =
        position == 'activate_fno' || pageLabel == 'activate_fno';
    final isNomineeStep = isNomineeKycStep(position, pageLabel);
    final isNomineePercentageStep =
        isNomineePercentageKycStep(position, pageLabel);

    if (isNomineePercentageStep) {
      final pageId = ctx?['page']?['id']?.toString() ?? '';
      final stepKey = '${position ?? ''}|$pageId';
      if (stepKey != _nomineePercentageDefaultsStepKey) {
        _nomineePercentageDefaultsStepKey = stepKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_nomineePercentageDefaultsStepKey != stepKey) return;
          _ensureNomineePercentageStepAuto100(fieldList);
        });
      }
    } else if (_nomineePercentageDefaultsStepKey != null) {
      _nomineePercentageDefaultsStepKey = null;
    }

    if (isNomineeStep) {
      final pageId = ctx?['page']?['id']?.toString() ?? '';
      final stepKey = '${position ?? ''}|$pageId';
      if (stepKey != _nomineeLandingDefaultsStepKey) {
        _nomineeLandingDefaultsStepKey = stepKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_nomineeLandingDefaultsStepKey != stepKey) return;
          _ensureNomineeLandingDefaultNoChecked(fieldList);
        });
      }
    } else if (_nomineeLandingDefaultsStepKey != null) {
      _nomineeLandingDefaultsStepKey = null;
    }

    if (isActivateFnoStep) {
      final pageId = ctx?['page']?['id']?.toString() ?? '';
      final stepKey = '${position ?? ''}|$pageId';
      if (stepKey != _activateFnoDefaultsStepKey) {
        _activateFnoDefaultsStepKey = stepKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_activateFnoDefaultsStepKey != stepKey) return;
          _ensureActivateFnoDefaultYes(fieldList);
        });
      }
    } else if (_activateFnoDefaultsStepKey != null) {
      _activateFnoDefaultsStepKey = null;
    }

    if (isSegmentsScreen) {
      final pageId = ctx?['page']?['id']?.toString() ?? '';
      final stepKey = '${position ?? ''}|$pageId';
      if (stepKey != _segmentsBrokerageStepKey) {
        _segmentsBrokerageStepKey = stepKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_segmentsBrokerageStepKey != stepKey) return;
          // Brokerage click is optional — pre-apply so Next is never blocked.
          _segmentsBrokerageUserConfirmed = true;
          if ((_formNotifier.formData['brokerage_plan']?.toString().trim() ?? '')
              .isEmpty) {
            _formNotifier.handleChange('brokerage_plan', 'Brokerage Plan');
          }
          setState(() {});
        });
      }
    } else {
      if (_segmentsBrokerageStepKey != null) {
        _segmentsBrokerageStepKey = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _segmentsBrokerageUserConfirmed = false;
          setState(() {});
        });
      }
    }

    // Segment defaults — never call handleChange during build (causes freeze).
    // All visible segments pre-selected; brokerage click not required.
    if (isSegmentsScreen) {
      final pageId = ctx?['page']?['id']?.toString() ?? '';
      final defaultsStepKey = '${position ?? ''}|$pageId';
      if (defaultsStepKey != _segmentsBpDefaultsStepKey) {
        _segmentsBpDefaultsStepKey = defaultsStepKey;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_segmentsBpDefaultsStepKey != defaultsStepKey) return;
          const allSegmentKeys = <String>[
            'nse_cash',
            'bse_cash',
            'nse_fo',
            'bse_fo',
            'mf',
          ];
          var didApplyDefaults = false;
          for (final key in allSegmentKeys) {
            if (_formNotifier.formData[key] != true) {
              _formNotifier.handleChange(key, true);
              didApplyDefaults = true;
            }
          }
          // NSE SLBM: always unchecked and non-selectable.
          if (_formNotifier.formData['nse_slbm'] != false) {
            _formNotifier.handleChange('nse_slbm', false);
            didApplyDefaults = true;
          }
          if (didApplyDefaults) {
            debugPrint(
                '[HomePage] Applied all-segment defaults for ${widget.company}');
          }
        });
      }
    } else if (_segmentsBpDefaultsStepKey != null) {
      _segmentsBpDefaultsStepKey = null;
    }

    // Show segments selection UI for segments screen
    if (isSegmentsScreen) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        padding: const EdgeInsets.fromLTRB(
          KycTheme.spacing3xl,
          KycTheme.spacing2xl,
          KycTheme.spacing3xl,
          KycTheme.spacing2xl,
        ),
        decoration: BoxDecoration(
          color: KycTheme.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: KycTheme.border),
          boxShadow: KycTheme.cardShadow,
        ),
        child: SegmentsSelection(
          formData: _formNotifier.formData,
          onChange: (name, value) {
            if (name == 'nse_cash' || name == 'bse_cash' || name == 'mf') {
              if (value != true) return;
            }
            if (name == 'nse_slbm') {
              return;
            }
            _formNotifier.handleChange(name, value);
          },
          onViewBrokeragePlan: () {
            BrokeragePlanDialog.show(
              context,
              () {
                // Only after user taps Done in the dialog
                _formNotifier.handleChange('brokerage_plan', 'Brokerage Plan');
                setState(() {
                  _segmentsBrokerageUserConfirmed = true;
                });
                Fluttertoast.showToast(
                    msg: 'Brokerage plan applied', gravity: ToastGravity.TOP);
              },
            );
          },
          onSubmit: () {
            if (_submitLoading) return;
            // Ensure all segments + brokerage are present before submit.
            for (final key in const [
              'nse_cash',
              'bse_cash',
              'nse_fo',
              'bse_fo',
              'mf',
            ]) {
              if (_formNotifier.formData[key] != true) {
                _formNotifier.handleChange(key, true);
              }
            }
            if ((_formNotifier.formData['brokerage_plan']?.toString().trim() ?? '')
                .isEmpty) {
              _formNotifier.handleChange('brokerage_plan', 'Brokerage Plan');
            }
            _segmentsBrokerageUserConfirmed = true;

            if (isAuth) {
              _handleCommonSubmit(false);
            } else {
              _handleSubmit(false);
            }
          },
          submitLoading: _submitLoading,
          hasBrokeragePlanSelected: true,
        ),
      );
    }
    final visibleFields = fieldList.where((f) {
      if (f is! Map) return false;
      final name = f['name']?.toString();
      final initialShow = kycFieldVisibleForFormStep(
        f,
        company: widget.company,
        position: position,
        pageLabel: pageLabel,
      );

      // If conditional flow has explicitly set visibility, use that (takes precedence)
      // Otherwise, use API visibility (+ BP Wealth personal_details standing override)
      final dynamicVisibility = _formNotifier.fieldVisibility[name];
      final show = dynamicVisibility ?? initialShow;
      
      return show;
    }).toList();

    final pageId = ctx?['page']?['id']?.toString();
    final pickedOtpField = _pickOtpFieldForContext(visibleFields, position, pageId);
    final nomineeOptOutOtp = _isNomineeOptOutOtpStep(
      fields: visibleFields,
      otpField: pickedOtpField,
    );
    // Nominee opt-out OTP: normal labelled field + Submit (not SMS OtpVerify card).
    final otpField = nomineeOptOutOtp ? null : pickedOtpField;
    final otpFieldName = pickedOtpField?['name']?.toString();

    // Hide sirf "confirm OTP" / re-enter OTP type field – design: one OTP entry
    // Account number jaise "Confirm Account Number" fields ko HIDE mat karo
    // Filter step-specific fields: no mobile inputs on mobile_otp, no email input on email_otp
    final isMobileOtpScreen = position == 'mobile_otp';
    final isEmailOtpScreen = position == 'email_otp';
    final isEmailCaptureStep = position == 'email' ||
        position == 'emailid' ||
        position == 'email_id' ||
        pageLabel == 'email';
    final isKraDetails = isKraDetailsStep(position, pageLabel);

    // KRA step: keep one editable address box in sync with form/API values.
    if (isKraDetails) {
      final kraKey =
          '${position ?? ''}|${ctx?['page']?['id']?.toString() ?? ''}';
      if (_kraAddressStepKey != kraKey) {
        _kraAddressStepKey = kraKey;
        final addressText = formatKraAddressDisplay(_formNotifier.formData);
        _kraAddressController?.dispose();
        _kraAddressController = TextEditingController(text: addressText);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _kraAddressStepKey != kraKey) return;
          _ensureKraContinueDefaultYes(fieldList);
          // Re-sync after form fields merge API values.
          final latest = formatKraAddressDisplay(_formNotifier.formData);
          if (_kraAddressController != null &&
              _kraAddressController!.text.trim().isEmpty &&
              latest.isNotEmpty) {
            _kraAddressController!.text = latest;
          }
          if (mounted) setState(() {});
        });
      }
    } else if (_kraAddressStepKey != null) {
      _kraAddressStepKey = null;
      _kraAddressController?.dispose();
      _kraAddressController = null;
    }

    final visibleFieldsForDisplay = visibleFields.where((f) {
      if (f is! Map) return false;

      // KRA: hide individual address fields — one editable address box instead.
      if (isKraDetails && isKraAddressComponentField(f)) {
        return false;
      }

      // Email capture step: hide email text inputs — Google Sign-In only.
      if (isEmailCaptureStep) {
        final validation =
            (f['validation']?.toString() ?? '').toLowerCase();
        if (validation == 'googlesignin') return true;
        final fieldName = (f['name']?.toString() ?? '').toLowerCase();
        final type = (f['type']?.toString() ?? '').toLowerCase();
        final isEmailTextInput = type == 'text' &&
            (fieldName == 'email' ||
                fieldName == 'email_id' ||
                fieldName == 'emailid' ||
                fieldName.contains('email'));
        if (isEmailTextInput) return false;
        // Keep only Google Sign-In control on this step.
        return false;
      }

      // On mobile_otp screen: hide mobile number inputs, keep OTP fields (e.g. otp_nom).
      if (isMobileOtpScreen && !_isOtpFormField(f)) {
        final fieldName = (f['name']?.toString() ?? '').toLowerCase();
        if (fieldName == 'mobile' ||
            fieldName == 'phone' ||
            fieldName == 'mobile_number' ||
            fieldName == 'phone_number' ||
            fieldName.contains('mobile') ||
            fieldName.contains('phone')) {
          return false;
        }
      }

      // On email_otp screen: HIDE email input field (OTP only; no email field below)
      if (isEmailOtpScreen) {
        final fieldName = (f['name']?.toString() ?? '').toLowerCase();
        final isOtpField = _isOtpFormField(f);
        if (!isOtpField &&
            (fieldName == 'email' ||
                fieldName == 'email_id' ||
                fieldName == 'emailid' ||
                fieldName.contains('email'))) {
          return false; // Hide email input on OTP verify screen
        }
      }

      // Agar OTP field identified hai aur yeh field usi OTP ko validateWith kar rahi hai
      // (confirm OTP / re-enter OTP), tabhi hide karo
      if (otpFieldName != null &&
          (f['validateWith']?.toString() ?? '') == otpFieldName) {
        return false;
      }

      // Nominee: hide ghost PAN/Aadhaar boxes (nominee 2 / 3) with no label.
      if (isNomineeExtendedUiStep(position, pageLabel) &&
          shouldHideNomineeGhostInputField(
            field: f,
            formData: _formNotifier.formData,
            fields: fieldList,
          )) {
        return false;
      }

      // Baaki sab fields (including reenter_account_number) dikhao
      return true;
    }).toList();

    // Sequence: OTP field pahle dikhao, phir baaki fields
    if (otpField != null) {
      visibleFieldsForDisplay.sort((a, b) {
        final aIsOtp = a['name'] == otpFieldName;
        final bIsOtp = b['name'] == otpFieldName;
        if (aIsOtp && !bIsOtp) return -1;
        if (!aIsOtp && bIsOtp) return 1;
        return 0;
      });
    }

    // Extract Aadhaar image (Digilocker success) from "aadhar_image" field
    Uint8List? aadharImageBytes;
    String? aadharImageUrl;
    bool hasAadharImage = false;

    final bool isDigilockerScreen = position == 'digilocker' || pageLabel == 'digilocker';
    if (isDigilockerScreen) {
      final aadharField = visibleFieldsForDisplay.cast<Map?>().firstWhere(
        (f) {
          if (f == null) return false;
          final n = (f['name']?.toString() ?? '').toLowerCase();
          return n == 'aadhar_image' || n == 'aadhaar_image';
        },
        orElse: () => null,
      );

      if (aadharField != null) {
        final aName = aadharField['name']?.toString() ?? '';
        final rawValue = resolveDigilockerAadharImageRaw(
          userDetails: store.userDetails,
          fieldValue: aadharField['value'],
          formValue: _formNotifier.formData[aName],
        );
        final valueStr = rawValue?.toString() ?? '';
        if (valueStr.isNotEmpty) {
          if (valueStr.startsWith('http')) {
            aadharImageUrl = cacheBustDocumentUrl(
              valueStr,
              version: digilockerAadharImageCacheBustVersion(store.userDetails),
            );
          } else {
            String base64Data = valueStr.trim();
            final match = RegExp(r'data:image/[^;]+;base64,', caseSensitive: false).firstMatch(base64Data);
            if (match != null) {
              base64Data = base64Data.substring(match.end);
            }
            try {
              aadharImageBytes = base64Decode(base64Data);
            } catch (_) {
              aadharImageBytes = null;
            }
          }
        }
        hasAadharImage =
            aadharImageBytes != null || (aadharImageUrl != null && aadharImageUrl!.isNotEmpty);
      }
    }

    // Generic submit button: sirf tab dikhao jab OTP field nahi hai
    // Agar OTP field hai (chahe kitni bhi aur fields ho), sirf OtpVerifySection ka "Verify OTP" button use hoga
    // Email capture: Google Sign-In only — no Next/Submit.
    final showGenericSubmit = otpField == null && !isEmailCaptureStep;
    final isOnboardingAuthStep = _isOnboardingAuthStep(position, pageLabel);
    final hideOnboardingFooter =
        kHideOnboardingFormFooter && isOnboardingAuthStep;
    final isMobileStep = position == 'mobile' || pageLabel == 'mobile';
    // Figma Start KYC: open layout (no card / lock footer / aadhaar note).
    final showSecurityFooter = !hideOnboardingFooter && !isMobileStep;
    final addingNominee =
        isNomineeStep && isAddNomineeSelectedYes(_formNotifier.formData);
    final nomineeBlocksSubmit = _isNomineeSubmitDisabled(position, pageLabel);
    final fatcaBlocksSubmit = _isPersonalDetailsStep(position, pageLabel) &&
        (_fatcaTaxResidencyMustPickNo ||
            _fatcaTaxResidencyYesFields(fieldList).isNotEmpty);
    final submitCtaDisabled = _submitLoading ||
        _ssoInProgress ||
        fatcaBlocksSubmit ||
        _isSendOtpDisabled(position) ||
        nomineeBlocksSubmit;

    final formBody = Form(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isPanKycStep(position, pageLabel) &&
                _panStepApiFeedback.trim().isNotEmpty) ...[
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: _panStepApiFeedbackIsError
                      ? Colors.red.shade50
                      : Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _panStepApiFeedbackIsError
                        ? Colors.red.shade300
                        : Colors.green.shade300,
                  ),
                ),
                child: Text(
                  _panStepApiFeedback,
                  style: TextStyle(
                    color: _panStepApiFeedbackIsError
                        ? Colors.red.shade900
                        : Colors.green.shade900,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
            if (hasAadharImage) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 4 / 3,
                  child: aadharImageBytes != null
                      ? Image.memory(
                          aadharImageBytes!,
                          fit: BoxFit.cover,
                        )
                      : Image.network(
                          aadharImageUrl!,
                          key: ValueKey<String>(aadharImageUrl!),
                          fit: BoxFit.cover,
                          loadingBuilder: (context, child, loadingProgress) {
                            if (loadingProgress == null) return child;
                            final expected = loadingProgress.expectedTotalBytes;
                            final value = expected != null
                                ? loadingProgress.cumulativeBytesLoaded / expected
                                : null;
                            return Center(
                              child: CircularProgressIndicator(
                                value: value,
                                strokeWidth: 2,
                                color: KycTheme.primary,
                              ),
                            );
                          },
                          errorBuilder: (context, error, stackTrace) => Container(
                            color: Colors.grey.shade200,
                            alignment: Alignment.center,
                            child: const Text(
                              'Preview not available',
                              style: TextStyle(
                                fontSize: 12,
                                color: KycTheme.textSecondary,
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (isEmailCaptureStep) ...[
              const Text(
                'Continue with Google',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: KycTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Sign in with your Google account to continue KYC.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: KycTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed:
                      _googleSignInLoading ? null : _handleGoogleSignIn,
                  icon: _googleSignInLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.g_mobiledata, size: 26),
                  label: Text(
                    _googleSignInLoading
                        ? 'Signing in...'
                        : 'Sign in with Google',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    side: const BorderSide(color: KycTheme.primary, width: 1.5),
                    foregroundColor: KycTheme.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(KycTheme.radiusMd),
                    ),
                  ),
                ),
              ),
            ] else ...[
              if (isKraDetails) ...[
                _buildKraAddressSummarySection(fieldList),
                const SizedBox(height: 16),
              ],
              ...(_bpWealthPersonalDetailsStandingUi(position, pageLabel)
                  ? _buildBpWealthPersonalWebFormLayout(
                      visibleFieldsForDisplay: visibleFieldsForDisplay,
                      otpField: otpField,
                      otpFieldName: otpFieldName,
                      hasAadharImage: hasAadharImage,
                      activeFields: activeFields,
                      store: store,
                      fieldList: fieldList,
                      position: position,
                      pageLabel: pageLabel,
                      ctx: ctx,
                    )
                  : isNomineeStep
                      ? _buildNomineeKycFormLayout(
                          visibleFieldsForDisplay: visibleFieldsForDisplay,
                          otpField: otpField,
                          otpFieldName: otpFieldName,
                          hasAadharImage: hasAadharImage,
                          activeFields: activeFields,
                          store: store,
                          fieldList: fieldList,
                          position: position,
                          pageLabel: pageLabel,
                          ctx: ctx,
                        )
                      : _buildSequencedFormRowsWithStandingExpansion(
                          visibleFieldsForDisplay: visibleFieldsForDisplay,
                          otpField: otpField,
                          otpFieldName: otpFieldName,
                          hasAadharImage: hasAadharImage,
                          activeFields: activeFields,
                          store: store,
                          fieldList: fieldList,
                          position: position,
                          pageLabel: pageLabel,
                          ctx: ctx,
                        )),
            ],
            if (nomineeOptOutOtp && pickedOtpField != null) ...[
              const SizedBox(height: 4),
              OtpResendControls(
                key: ValueKey('nominee-otp-resend-$_otpResendTimerEpoch'),
                otpExpiry: _resolveOtpExpiryConfig(visibleFields, pickedOtpField),
                onResendOtp: _resendMobileOtp,
                resendLoading: _resendOtpLoading,
              ),
              const SizedBox(height: 8),
            ],
            // Terms — compact (Figma start screen keeps this light)
            if (isMobileStep) ...[
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () => setState(() {
                      _termsAccepted = !_termsAccepted;
                      if (_termsAccepted) _showTermsError = false;
                    }),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Container(
                        width: 18,
                        height: 18,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _termsAccepted
                              ? KycTheme.success
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: _termsAccepted
                                ? KycTheme.success
                                : KycTheme.border,
                            width: 1.5,
                          ),
                        ),
                        child: _termsAccepted
                            ? const Icon(Icons.check,
                                size: 13, color: Colors.white)
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _termsAccepted = !_termsAccepted;
                        if (_termsAccepted) _showTermsError = false;
                      }),
                      child: RichText(
                        text: TextSpan(
                          style: const TextStyle(
                            fontSize: 12,
                            color: KycTheme.textSecondary,
                            height: 1.3,
                          ),
                          children: [
                            const TextSpan(text: 'I accept the '),
                            TextSpan(
                              text: 'Terms and Conditions',
                              style: const TextStyle(
                                color: KycTheme.primary,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                              ),
                              recognizer: TapGestureRecognizer()
                                ..onTap = () => _showTermsModal(context),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (_showTermsError && !_termsAccepted) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 28.0),
                  child: Text(
                    'Please accept the Terms & Conditions to continue',
                    style: TextStyle(fontSize: 11, color: Colors.red.shade700),
                  ),
                ),
              ],
            ],
            if (showGenericSubmit) const SizedBox(height: 28),
            if (showGenericSubmit)
              GradientCtaButton(
                label: _primarySubmitLabel(
                  isMobileStep: isMobileStep,
                  submitButton: submitButton,
                ),
                loadingLabel: 'Processing...',
                isLoading: _submitLoading && !_ssoInProgress,
                enabled: !submitCtaDisabled,
                height: isMobileStep ? 54 : 48,
                onPressed: () {
                  debugPrint(
                      '[HomePage] Submit button clicked! isAuth=$isAuth, position=$position');
                  if (isAuth) {
                    if (_enforceFatcaTaxResidencyNoOnSubmit(
                      position: position,
                      pageLabel: pageLabel,
                      fieldList: fieldList,
                    )) {
                      return;
                    }
                    _handleCommonSubmit(false);
                  } else {
                    _handleSubmit(false);
                  }
                },
              ),
            if (showGenericSubmit &&
                submitButton?['showSubmitAnywayButton'] == true) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.yellow.shade50,
                  border: Border.all(color: Colors.yellow.shade200),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'You can submit the form without filling field.',
                      style: TextStyle(color: Colors.yellow.shade900),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: _submitLoading || fatcaBlocksSubmit
                          ? null
                          : () {
                              if (isAuth) {
                                if (_enforceFatcaTaxResidencyNoOnSubmit(
                                  position: position,
                                  pageLabel: pageLabel,
                                  fieldList: fieldList,
                                )) {
                                  return;
                                }
                                _handleCommonSubmit(true);
                              } else {
                                _handleSubmit(true);
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: KycTheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                      child: Text(submitButton?['submitAnywayButtonName'] ?? 'Submit Anyway'),
                    ),
                  ],
                ),
              ),
            ],
            if (showSecurityFooter) ...[
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock, size: 16, color: KycTheme.textSecondary),
                  const SizedBox(width: 8),
                  Text(
                    'Your information is securely encrypted',
                    style: TextStyle(fontSize: 12, color: KycTheme.textSecondary),
                  ),
                ],
              ),
            ],
          ],
        ),
    );

    // Figma Start KYC is open (no white card). Other steps keep soft card chrome.
    if (isMobileStep) return formBody;
    return Container(
      padding: const EdgeInsets.all(KycTheme.spacing2xl),
      decoration: BoxDecoration(
        color: KycTheme.surface.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(KycTheme.radiusXl),
        border: Border.all(color: KycTheme.border.withValues(alpha: 0.65)),
        boxShadow: KycTheme.cardShadowSm,
      ),
      child: formBody,
    );
  }

  /// Disable Send OTP on mobile step until 10 digits entered AND terms accepted
  bool _isSendOtpDisabled(String? position) {
    if (position != 'mobile') return false;
    if (!_termsAccepted) return true;
    final mobile = _formNotifier.formData['mobile'] ?? 
        _formNotifier.formData['phone'] ?? 
        _formNotifier.formData['mobile_number'] ?? '';
    final digits = mobile.toString().replaceAll(RegExp(r'\D'), '');
    return digits.length != 10 || !RegExp(r'^[6-9]').hasMatch(digits);
  }

  void _showTermsModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Terms & Conditions',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'By signing up, you agree that a Rudra Shares representative may contact you telephonically in connection with the services or your registration on the platform or to introduce new product/service offerings.',
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAadhaarNote() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(KycTheme.spacingLg),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(KycTheme.radiusMd),
        border: Border.all(color: KycTheme.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 13, color: KycTheme.textPrimary, height: 1.4),
                children: [
                  const TextSpan(
                    text:
                        'Note: Online account opening requires your number to be linked with Aadhaar. You can check if your mobile number is linked to Aadhaar ',
                  ),
                  TextSpan(
                    text: 'here',
                    style: const TextStyle(
                      color: KycTheme.primary,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () async {
                        final uri = Uri.parse('https://resident.uidai.gov.in/verify');
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      },
                  ),
                  const TextSpan(
                    text:
                        '. If your mobile number isn\'t linked to Aadhaar, please open your account offline.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Extract 10-digit Indian mobile from form map only (no persisted fallback).
  String _digitsFromFormMapOnly(Map<String, dynamic> fd) {
    const keys = ['change_mobile', 'mobile_number', 'mobile', 'phone'];
    for (final key in keys) {
      final raw = fd[key];
      if (raw == null) continue;
      final digits = raw.toString().replaceAll(RegExp(r'\D'), '');
      if (digits.length == 10 && RegExp(r'^[6-9]').hasMatch(digits)) {
        return digits;
      }
    }
    for (final key in keys) {
      final raw = fd[key];
      if (raw == null) continue;
      final digits = raw.toString().replaceAll(RegExp(r'\D'), '');
      if (digits.length >= 10) {
        final last10 = digits.substring(digits.length - 10);
        if (RegExp(r'^[6-9]').hasMatch(last10)) return last10;
      }
    }
    return '';
  }

  /// Prefer live form data; fall back to [ _persistedMobileDigitsForOtp ] after get-context reset.
  String _resolveMobileDigitsForOtpUi(Map<String, dynamic> fd) {
    final fromForm = _digitsFromFormMapOnly(fd);
    if (fromForm.length == 10) return fromForm;
    final p = _persistedMobileDigitsForOtp;
    if (p != null &&
        p.length == 10 &&
        RegExp(r'^[6-9]').hasMatch(p)) {
      return p;
    }
    return '';
  }

  void _applyPersistedMobileToForm() {
    final m = _persistedMobileDigitsForOtp;
    if (m == null || m.length != 10) return;
    _formNotifier.handleChange('mobile_number', m, validationType: 'mobile');
    _formNotifier.handleChange('phone', m, validationType: 'mobile');
    _formNotifier.handleChange('mobile', m, validationType: 'mobile');
    _formNotifier.handleChange('change_mobile', m, validationType: 'mobile');
  }

  String _resolveEmailForOtpUi(Map<String, dynamic> fd) {
    const keys = ['email', 'email_id', 'emailId'];
    for (final key in keys) {
      final raw = fd[key]?.toString().trim() ?? '';
      if (raw.contains('@')) return raw;
    }
    final p = _persistedEmailForOtp?.trim() ?? '';
    return p.contains('@') ? p : '';
  }

  void _applyPersistedEmailToForm() {
    final e = _persistedEmailForOtp?.trim() ?? '';
    if (!e.contains('@')) return;
    _formNotifier.handleChange('email', e, validationType: 'email');
    _formNotifier.handleChange('email_id', e, validationType: 'email');
    _formNotifier.handleChange('emailId', e, validationType: 'email');
  }

  bool _isLikelyPersonNameField(String fieldName, String displayName) {
    final n = fieldName.toLowerCase();
    final dn = displayName.toLowerCase();
    const blocked = [
      'email',
      'mobile',
      'phone',
      'pan',
      'bank',
      'nominee',
      'father',
      'mother',
      'spouse',
      'ifsc',
      'account',
      'company',
      'branch',
      'otp',
      'aadhar',
      'aadhaar',
    ];
    for (final b in blocked) {
      if (n.contains(b) || dn.contains(b)) return false;
    }
    if (n == 'name' ||
        n == 'full_name' ||
        n == 'fullname' ||
        n == 'first_name' ||
        n == 'firstname' ||
        n == 'customer_name' ||
        n == 'applicant_name' ||
        n == 'user_name' ||
        n.endsWith('_name')) {
      return true;
    }
    if (dn == 'name' ||
        dn.contains('full name') ||
        dn.contains('your name') ||
        dn.contains('applicant name') ||
        dn.contains('customer name') ||
        dn.startsWith('name ')) {
      return true;
    }
    return false;
  }

  void _applyPersistedGoogleNameToForm() {
    final name = _persistedGoogleDisplayName?.trim() ?? '';
    if (name.isEmpty) return;

    const knownKeys = [
      'name',
      'full_name',
      'fullName',
      'first_name',
      'firstname',
      'customer_name',
      'applicant_name',
      'user_name',
    ];
    for (final key in knownKeys) {
      final existing = _formNotifier.formData[key]?.toString().trim() ?? '';
      if (existing.isEmpty) {
        _formNotifier.handleChange(key, name);
      }
    }

    final fields = _formNotifier.fields;
    if (fields == null) return;
    for (final f in fields) {
      if (f is! Map) continue;
      final fieldName = f['name']?.toString() ?? '';
      if (fieldName.isEmpty) continue;
      final dn = f['displayName']?.toString() ?? '';
      if (!_isLikelyPersonNameField(fieldName, dn)) continue;
      final existing =
          _formNotifier.formData[fieldName]?.toString().trim() ?? '';
      if (existing.isEmpty) {
        _formNotifier.handleChange(fieldName, name);
      }
    }
    debugPrint('[GoogleSignIn] Applied Google name to form: $name');
  }

  Future<void> _handleGoogleSignIn() async {
    if (_googleSignInLoading) return;
    setState(() => _googleSignInLoading = true);
    try {
      final googleSignIn = GoogleSignIn(
        scopes: const ['email', 'profile'],
        // Android: Web client ID is required so Google returns an ID token for Firebase Auth.
        serverClientId: Platform.isAndroid
            ? DefaultFirebaseOptions.googleOAuthWebClientId
            : null,
      );
      final selectedAccount = await googleSignIn.signIn();
      if (selectedAccount == null) {
        Fluttertoast.showToast(
          msg: 'Sign-in cancelled',
          gravity: ToastGravity.TOP,
        );
        return;
      }

      final authData = await selectedAccount.authentication;
      if (authData.idToken == null || authData.idToken!.isEmpty) {
        debugPrint(
          '[GoogleSignIn] idToken missing; check SHA-1 in Firebase & Web client ID.',
        );
        Fluttertoast.showToast(
          msg: 'Could not get Google credentials. Check app signing (SHA-1) in Firebase.',
          gravity: ToastGravity.TOP,
        );
        return;
      }
      final credential = GoogleAuthProvider.credential(
        accessToken: authData.accessToken,
        idToken: authData.idToken,
      );
      final userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);
      final email = (userCredential.user?.email ?? selectedAccount.email).trim();
      if (email.isEmpty) {
        Fluttertoast.showToast(
          msg: 'Google account email not available',
          gravity: ToastGravity.TOP,
        );
        return;
      }

      final googleName = (userCredential.user?.displayName ??
              selectedAccount.displayName)
          ?.trim() ??
          '';
      _persistedEmailForOtp = email;
      if (googleName.isNotEmpty) {
        _persistedGoogleDisplayName = googleName;
      }
      _applyPersistedEmailToForm();
      if (mounted) setState(() {});
      Fluttertoast.showToast(
        msg: 'Google sign-in successful',
        gravity: ToastGravity.TOP,
      );

      // Fill email and auto-advance to the next workflow step.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      final hasToken = await StorageService.hasAccessToken();
      debugPrint(
        '[GoogleSignIn] Advancing email step hasToken=$hasToken name=$googleName',
      );
      if (hasToken) {
        await _handleCommonSubmit(false);
      } else {
        await _handleSubmit(false);
      }
    } on FirebaseAuthException catch (e) {
      debugPrint('[GoogleSignIn] FirebaseAuthException: ${e.code} ${e.message}');
      Fluttertoast.showToast(
        msg: e.message ?? 'Google sign-in failed',
        gravity: ToastGravity.TOP,
      );
    } on PlatformException catch (e) {
      debugPrint('[GoogleSignIn] PlatformException: ${e.code} ${e.message}');
      final msg = e.code == 'sign_in_failed' || e.code == '10'
          ? 'Google Sign-In setup error. Add debug SHA-1 in Firebase Console.'
          : (e.message ?? 'Google sign-in failed');
      Fluttertoast.showToast(msg: msg, gravity: ToastGravity.TOP);
    } catch (e, st) {
      debugPrint('[GoogleSignIn] $e\n$st');
      Fluttertoast.showToast(
        msg: 'Unable to sign in with Google. Please try again.',
        gravity: ToastGravity.TOP,
      );
    } finally {
      if (mounted) {
        setState(() => _googleSignInLoading = false);
      }
    }
  }

  /// Edit from OTP screen: `GET /api_review_edit_page/...` — only on success refresh journey via get-context.
  Future<void> _requestReviewEditAndRefreshContext(String currentField) async {
    final store = context.read<AppStore>();
    if (!mounted) return;
    setState(() {
      _captureHeaderPositionForSubmit(store);
      _submitLoading = true;
    });
    try {
      debugPrint(
          '[HomePage] review_edit_page: $currentField (${widget.company}/${widget.workflowName})');
      final res = await KycAPI.reviewEditPage(
        widget.company,
        widget.workflowName,
        currentField,
      );
      Map<String, dynamic>? body;
      try {
        body = jsonDecode(res.body) as Map<String, dynamic>?;
      } catch (_) {
        body = null;
      }
      final success =
          body?['success'] == true || body?['success']?.toString() == 'true';
      if (res.statusCode < 200 || res.statusCode >= 300 || !success) {
        final msg = body?['msg']?.toString() ??
            body?['message']?.toString() ??
            'Could not open edit for this step';
        Fluttertoast.showToast(msg: msg, gravity: ToastGravity.TOP);
        return;
      }
      debugPrint('[HomePage] review_edit_page OK — fetching get-context');
      await store.fetchWorkflowFieldsWithAuth(
          widget.company, widget.workflowName, '');
      if (!mounted) return;
      if (store.errorWithAuth != null) {
        Fluttertoast.showToast(
            msg: store.errorWithAuth!, gravity: ToastGravity.TOP);
        return;
      }
      if (mounted) {
        await Future.delayed(const Duration(milliseconds: 200));
        await _checkAndHandleRedirect(store);
        if (!mounted) return;
        final response = store.fieldsWithAuth;
        if (response is! Map || response['redirect'] != true) {
          context.go('/${widget.company}/${widget.workflowName}');
        }
      }
    } catch (e, st) {
      debugPrint('[HomePage] review_edit_page error: $e\n$st');
      Fluttertoast.showToast(
          msg: 'Something went wrong. Please try again.',
          gravity: ToastGravity.TOP);
    } finally {
      if (mounted) setState(() => _submitLoading = false);
    }
  }

  /// Nominee opt-out OTP (page 16 / otp_nom) — use standard form, not mobile SMS verify card.
  bool _isNomineeOptOutOtpStep({
    required List<dynamic> fields,
    required Map? otpField,
  }) {
    if (otpField != null) {
      final n = (otpField['name']?.toString() ?? '').toLowerCase();
      final dn = (otpField['displayName']?.toString() ?? '').toLowerCase();
      if (n.contains('nom') || n == 'otp_nom') return true;
      if (dn.contains('nominee') && dn.contains('otp')) return true;
    }
    for (final f in fields) {
      if (f is! Map) continue;
      if (f['otpExpiry'] is Map) {
        final ref =
            (f['otpExpiry'] as Map)['otpField']?.toString().toLowerCase() ?? '';
        if (ref.contains('nom')) return true;
      }
      final dn = (f['displayName']?.toString() ?? '').toLowerCase();
      if (dn.contains('nominee') && dn.contains('opt') && dn.contains('otp')) {
        return true;
      }
    }
    return false;
  }

  bool _isOtpFormField(Map<dynamic, dynamic> f) {
    final t = (f['type']?.toString() ?? '').toLowerCase();
    final n = (f['name']?.toString() ?? '').toLowerCase();
    final v = (f['validation']?.toString() ?? '').toLowerCase();
    if (t == 'otp' || v == 'otp') return true;
    if (n == 'otp' || n == 'otp_code') return true;
    if (n.contains('otp')) return true;
    return false;
  }

  /// Picks the OTP input for this page when multiple OTP fields exist (e.g. mobile_otp vs mobile_otp_nom).
  Map<dynamic, dynamic>? _pickOtpFieldForContext(
    List<dynamic> fields,
    String? position,
    String? pageId,
  ) {
    final candidates = fields
        .whereType<Map>()
        .where(_isOtpFormField)
        .cast<Map<dynamic, dynamic>>()
        .toList();
    if (candidates.isEmpty) return null;
    if (candidates.length == 1) return candidates.first;

    for (final f in fields) {
      if (f is! Map || f['otpExpiry'] is! Map) continue;
      final ref = (f['otpExpiry'] as Map)['otpField']?.toString();
      if (ref == null || ref.isEmpty) continue;
      final match =
          candidates.where((c) => c['name']?.toString() == ref).toList();
      if (match.isNotEmpty) return match.first;
    }

    final pageNum = int.tryParse(pageId ?? '');
    final nomineeCandidates = candidates
        .where((c) => (c['name']?.toString() ?? '').toLowerCase().contains('nom'))
        .toList();
    // Later workflow pages (e.g. id 16) reuse position mobile_otp for nominee OTP.
    if (nomineeCandidates.isNotEmpty && pageNum != null && pageNum >= 10) {
      return nomineeCandidates.first;
    }

    final primaryCandidates = candidates
        .where((c) => !(c['name']?.toString() ?? '').toLowerCase().contains('nom'))
        .toList();
    return primaryCandidates.isNotEmpty ? primaryCandidates.first : candidates.first;
  }

  Map<String, dynamic>? _resolveOtpExpiryConfig(
    List<dynamic> fields,
    Map? otpField,
  ) {
    if (otpField == null) return null;
    final name = otpField['name']?.toString();
    final direct = otpField['otpExpiry'];
    if (direct is Map) return Map<String, dynamic>.from(direct);
    if (name != null) {
      for (final f in fields) {
        if (f is! Map || f['otpExpiry'] is! Map) continue;
        final exp = Map<String, dynamic>.from(f['otpExpiry'] as Map);
        if (exp['otpField']?.toString() == name) return exp;
      }
    }
    return null;
  }

  /// OTP verify card: separate UI for email_otp vs mobile_otp (Figma)
  Future<bool> _resendOtpByPosition({
    required AppStore store,
    required String positionSegment,
    required Map<String, dynamic> payload,
    required String failureMessage,
  }) async {
    final endpoint = '/api/resend-otp/$positionSegment';
    debugPrint('[HomePage] Resend OTP via $endpoint payload=$payload');
    final client = ApiClient();
    final res = await client.post(endpoint, body: payload);
    debugPrint('[HomePage] Resend OTP response status=${res.statusCode}');
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Fluttertoast.showToast(
        msg: _errorMessageFromResponse(res.statusCode, res.body),
        gravity: ToastGravity.TOP,
      );
      return false;
    }
    if (mounted) {
      setState(() => _otpResendTimerEpoch++);
      Fluttertoast.showToast(
        msg: 'OTP sent successfully',
        gravity: ToastGravity.TOP,
      );
    }
    return true;
  }

  String _getResendOtpPositionSegment(Map? ctx, String fallbackPosition) {
    final position = (ctx?['position']?.toString().toLowerCase() ?? '').trim();
    final pageId = (ctx?['page']?['id']?.toString() ?? '').trim();
    final effectivePosition = position.isNotEmpty ? position : fallbackPosition;
    if (pageId.isEmpty) return effectivePosition;
    return '$effectivePosition$pageId';
  }

  Future<void> _resendMobileOtp() async {
    final store = context.read<AppStore>();
    FocusScope.of(context).unfocus();
    if (!mounted) return;
    setState(() => _resendOtpLoading = true);
    try {
      final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
      final resendPositionSegment =
          _getResendOtpPositionSegment(ctx, 'mobile_otp');
      await _resendOtpByPosition(
        store: store,
        positionSegment: resendPositionSegment,
        payload: const <String, dynamic>{},
        failureMessage: 'Failed to resend OTP',
      );
    } finally {
      if (mounted) {
        setState(() => _resendOtpLoading = false);
      }
    }
  }

  Future<void> _resendEmailOtpAfterEdit(String email) async {
    final store = context.read<AppStore>();
    final trimmed = email.trim();
    _persistedEmailForOtp = trimmed;
    FocusScope.of(context).unfocus();
    if (!mounted) return;
    setState(() => _resendOtpLoading = true);
    try {
      final ctx = (store.fieldsWithAuth as Map?)?['context'] as Map?;
      final resendPositionSegment =
          _getResendOtpPositionSegment(ctx, 'email_otp');
      final payload = <String, dynamic>{'email': trimmed};
      await _resendOtpByPosition(
        store: store,
        positionSegment: resendPositionSegment,
        payload: payload,
        failureMessage: 'Failed to refresh OTP step',
      );
      if (mounted) {
        _applyPersistedEmailToForm();
      }
    } catch (_) {
      Fluttertoast.showToast(msg: 'Failed to resend email OTP', gravity: ToastGravity.TOP);
    } finally {
      if (mounted) {
        setState(() => _resendOtpLoading = false);
      }
    }
  }

  // Previous flow: Edit opened a modal and then called get-user / kyc-post resend.
  // Replaced by `_requestReviewEditAndRefreshContext` → GET `/api_review_edit_page/...` then get-context.

  Widget _buildOtpVerifyCard(Map otpField, dynamic activeFields) {
    final otpName = otpField['name']?.toString() ?? 'otp';
    final formData = _formNotifier.formData;
    final store = context.read<AppStore>();
    final position =
        (store.fieldsWithAuth as Map?)?['context']?['position']?.toString().toLowerCase() ?? '';
    final isEmailOtp = position == 'email_otp' || position.startsWith('email_otp');
    final isMobileOtp = position == 'mobile_otp' || position.startsWith('mobile_otp');

    // Step-specific copy: no mobile/SMS wording on email_otp
    final String sentToText;
    final VoidCallback? onEdit;
    if (isEmailOtp) {
      final displayEmail = _resolveEmailForOtpUi(formData);
      sentToText =
          'We have sent you an OTP on ${displayEmail.isEmpty ? 'your email' : displayEmail}';
      onEdit = () {
        _requestReviewEditAndRefreshContext('change_email');
      };
    } else {
      final displayDigits = _resolveMobileDigitsForOtpUi(formData);
      sentToText =
          'We have sent you an OTP via sms on +91 ${displayDigits.isEmpty ? '' : displayDigits}';
      onEdit = isMobileOtp
          ? () {
              _requestReviewEditAndRefreshContext('change_mobile');
            }
          : null;
    }

    final fieldList = activeFields is List ? activeFields : <dynamic>[];
    final otpExpiry = _resolveOtpExpiryConfig(fieldList, otpField);
    if (otpExpiry != null) {
      debugPrint('[HomePage] OTP expiry config: $otpExpiry');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        OtpVerifySection(
          key: ValueKey('otp-$position-$_otpResendTimerEpoch'),
          sentToText: sentToText,
          onEdit: onEdit,
          onVerify: (otp) {
            _formNotifier.handleChange(otpName, otp);
            _handleCommonSubmit(false);
          },
          onResendOtp: () {
            debugPrint('[HomePage] Resend OTP clicked');
            _formNotifier.handleChange(otpName, '');
            if (isMobileOtp) {
              _resendMobileOtp();
            } else {
              final email = _resolveEmailForOtpUi(
                  Map<String, dynamic>.from(_formNotifier.formData));
              if (!email.contains('@')) {
                Fluttertoast.showToast(
                  msg: 'Please use Edit to enter a valid email',
                  gravity: ToastGravity.TOP,
                );
                return;
              }
              _resendEmailOtpAfterEdit(email);
            }
          },
          otpExpiry: otpExpiry,
          verifyLoading: _submitLoading,
          resendLoading: _resendOtpLoading,
          useSixBoxes: false, // Email OTP: single input per Figma (no 6 boxes)
        ),
        const SizedBox(height: 20),
        KycNoteBox(
          text: KycNoteBox.aadhaarNote,
          linkText: 'here',
          onLinkTap: () {
            // Optional: open Aadhaar link
          },
        ),
      ],
    );
  }
}

/// In-app tariff PDF preview (iOS). Avoids QuickLook/open_filex reopen race
/// where the first tap after dismiss returns done but shows nothing.
class _BpWealthTariffPdfPreviewDialog extends StatefulWidget {
  final String assetPath;

  const _BpWealthTariffPdfPreviewDialog({
    required this.assetPath,
  });

  @override
  State<_BpWealthTariffPdfPreviewDialog> createState() =>
      _BpWealthTariffPdfPreviewDialogState();
}

class _BpWealthTariffPdfPreviewDialogState
    extends State<_BpWealthTariffPdfPreviewDialog> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            debugPrint(
                '[HomePage] Tariff PDF WebView error: ${error.description}');
            if (mounted) {
              setState(() {
                _loading = false;
                _error = 'Unable to load PDF.';
              });
            }
          },
        ),
      );
    _loadPdf();
  }

  Future<void> _loadPdf() async {
    try {
      await _controller.loadFlutterAsset(widget.assetPath);
    } catch (e) {
      debugPrint('[HomePage] Tariff PDF asset load failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Unable to load PDF.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final maxWidth = mq.size.width - 32;
    final maxHeight = mq.size.height - mq.viewPadding.vertical - 40;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: maxWidth.clamp(280.0, mq.size.width),
        height: (maxHeight * 0.88).clamp(320.0, maxHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColoredBox(
              color: KycTheme.primary,
              child: Row(
                children: [
                  const Expanded(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(16, 14, 8, 14),
                      child: Text(
                        'DP Standing Instructions & Tariff',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ColoredBox(
                color: Colors.white,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_error == null) WebViewWidget(controller: _controller),
                    if (_error != null)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ),
                      ),
                    if (_loading)
                      const ColoredBox(
                        color: Colors.white,
                        child: Center(
                          child: CircularProgressIndicator(
                            color: KycTheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
