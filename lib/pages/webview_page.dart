import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:meon_kyc/store/app_store.dart';
import 'package:meon_kyc/services/storage_service.dart';
import 'package:meon_kyc/services/connectivity_controller.dart';
import 'package:meon_kyc/api/kyc_api.dart';
import 'package:meon_kyc/api/base_api.dart';

/// Set true only when debugging WebView navigation noise.
const bool _kWebViewVerboseLogs = false;

const _kPaymentMethodChannel = MethodChannel('com.kycsuperadmin/payment');
const _kGooglePayPackage = 'com.google.android.apps.nbu.paisa.user';

void _wvLog(String message) {
  if (kDebugMode && _kWebViewVerboseLogs) {
    debugPrint(message);
  }
}

void _paymentLog(String message) {
  if (kDebugMode) {
    debugPrint('[Payment] $message');
  }
}

bool _isPaymentDeepLink(String url) {
  final lower = url.toLowerCase();
  return lower.startsWith('upi://') ||
      lower.startsWith('intent:') ||
      lower.startsWith('phonepe://') ||
      lower.startsWith('paytmmp://') ||
      lower.startsWith('paytm://') ||
      lower.startsWith('gpay://') ||
      lower.startsWith('tez://') ||
      lower.startsWith('google.payments://') ||
      lower.startsWith('googlepay://') ||
      lower.startsWith('bhim://') ||
      lower.startsWith('ppe://');
}

String? _extractIntentPackage(String url) {
  final match =
      RegExp(r'package=([^;]+)', caseSensitive: false).firstMatch(url);
  return match?.group(1)?.trim();
}

Future<bool> _launchIntentUrlNative(String intentUrl) async {
  if (!Platform.isAndroid) return false;
  try {
    final ok = await _kPaymentMethodChannel.invokeMethod<bool>('launchIntentUrl', {
      'intentUrl': intentUrl,
    });
    return ok == true;
  } catch (e) {
    _paymentLog('Intent.parseUri failed: $e');
    return false;
  }
}

Future<bool> _launchPaymentUriNative({
  required String dataUri,
  String? packageName,
}) async {
  if (!Platform.isAndroid) return false;
  try {
    final ok = await _kPaymentMethodChannel.invokeMethod<bool>('launchUpi', {
      'dataUri': dataUri,
      'packageName': packageName,
    });
    return ok == true;
  } catch (e) {
    _paymentLog('Native launch failed: $e');
    return false;
  }
}

class _ParsedAndroidPaymentIntent {
  final String dataUri;
  final String? packageName;

  const _ParsedAndroidPaymentIntent({
    required this.dataUri,
    this.packageName,
  });
}

_ParsedAndroidPaymentIntent? _parseAndroidPaymentIntentUrl(String url) {
  final lower = url.toLowerCase();
  if (!lower.startsWith('intent:')) return null;

  var body = url.substring('intent:'.length);
  var fragment = '';
  const marker = '#Intent';
  final markerIndex = body.indexOf(marker);
  if (markerIndex != -1) {
    fragment = body.substring(markerIndex + marker.length);
    body = body.substring(0, markerIndex);
  }

  String? scheme;
  String? packageName;
  for (final part in fragment.split(';')) {
    final segment = part.trim();
    if (segment.isEmpty || segment == 'end') continue;
    final segmentLower = segment.toLowerCase();
    if (segmentLower.startsWith('scheme=')) {
      scheme = segment.substring('scheme='.length).trim();
    } else if (segmentLower.startsWith('package=')) {
      packageName = segment.substring('package='.length).trim();
    }
  }

  body = body.replaceAll(RegExp(r';+$'), '').trim();
  if (body.isEmpty) return null;

  final String dataUri;
  if (body.contains('://')) {
    dataUri = body;
  } else if (body.startsWith('//')) {
    dataUri = '${scheme ?? 'upi'}:$body';
  } else {
    dataUri = '${scheme ?? 'upi'}://$body';
  }

  return _ParsedAndroidPaymentIntent(
    dataUri: dataUri,
    packageName: packageName,
  );
}

const _kPhonePePackage = 'com.phonepe.app';
const _kPaytmPackage = 'net.one97.paytm';
const _kBhimPackage = 'in.org.npci.upiapp';
const _kWhatsAppPackage = 'com.whatsapp';
const _kWhatsAppBusinessPackage = 'com.whatsapp.w4b';

String? _packageForPaymentUri(String dataUri) {
  final lower = dataUri.toLowerCase();
  if (lower.startsWith('tez://') ||
      lower.startsWith('gpay://') ||
      lower.startsWith('google.payments://') ||
      lower.startsWith('googlepay://')) {
    return _kGooglePayPackage;
  }
  if (lower.startsWith('phonepe://') || lower.startsWith('ppe://')) {
    return _kPhonePePackage;
  }
  if (lower.startsWith('paytm://') || lower.startsWith('paytmmp://')) {
    return _kPaytmPackage;
  }
  if (lower.startsWith('bhim://')) {
    return _kBhimPackage;
  }
  if (lower.startsWith('whatsapp://')) {
    return _kWhatsAppPackage;
  }
  return null;
}

String? _packageForRpdAppName(String? appName) {
  switch ((appName ?? '').toLowerCase().trim()) {
    case 'gpay':
    case 'googlepay':
    case 'tez':
      return _kGooglePayPackage;
    case 'phonepe':
      return _kPhonePePackage;
    case 'paytm':
      return _kPaytmPackage;
    case 'bhim':
      return _kBhimPackage;
    case 'whatsapp':
      return _kWhatsAppPackage;
    default:
      return null;
  }
}

/// Prefer NPCI `upi://pay?...` for PhonePe/Paytm/BHIM — custom schemes often
/// only open the app home without the amount/pay screen.
/// GPay still gets a tez/gpay variant as a secondary candidate in native code.
String _synthesizeRpdAppLink(String appName, String upiUrl) {
  final lower = upiUrl.toLowerCase();
  if (!lower.startsWith('upi://')) return upiUrl;
  final path = upiUrl.substring('upi://'.length); // pay?...
  switch (appName.toLowerCase().trim()) {
    case 'gpay':
    case 'googlepay':
    case 'tez':
      return 'gpay://upi/$path';
    case 'phonepe':
    case 'paytm':
    case 'bhim':
    case 'whatsapp':
      // Keep upi:// — target app via setPackage in native launch.
      return upiUrl;
    default:
      return upiUrl;
  }
}

/// Extract standard `upi://pay?...` from phonepe/paytm/gpay/tez/bhim variants.
String? _toStandardUpiPayUri(String url) {
  final lower = url.toLowerCase();
  if (lower.startsWith('upi://')) return url;
  final payIdx = lower.indexOf('pay?');
  if (payIdx < 0) return null;
  return 'upi://${url.substring(payIdx)}';
}

/// Hard-freezes page scroll while Aadhaar/PIN inputs are focused (DigiLocker step only).
const String _kDigilockerFreezeJs = r'''
(function() {
  if (window.__meonDigilockerFreeze) return;
  window.__meonDigilockerFreeze = true;
  var origScrollTo = window.scrollTo.bind(window);
  var origScrollBy = window.scrollBy.bind(window);
  Element.prototype.scrollIntoView = function() {};
  if (Element.prototype.scrollIntoViewIfNeeded) {
    Element.prototype.scrollIntoViewIfNeeded = function() {};
  }
  var frozen = false;
  var lockedY = 0;
  var savedBody = null;
  var rafId = 0;
  function isFormField(el) {
    if (!el || el.nodeType !== 1) return false;
    var t = el.tagName;
    if (!t) return false;
    t = t.toUpperCase();
    return t === "INPUT" || t === "TEXTAREA" || t === "SELECT" || el.isContentEditable === true;
  }
  function anyFormFieldFocused() {
    return isFormField(document.activeElement);
  }
  function enforceScroll() {
    if (!frozen) return;
    origScrollTo.call(window, 0, lockedY);
    rafId = requestAnimationFrame(enforceScroll);
  }
  function freeze() {
    if (frozen) return;
    frozen = true;
    lockedY = window.pageYOffset || document.documentElement.scrollTop || document.body.scrollTop || 0;
    var html = document.documentElement;
    var body = document.body;
    if (body) {
      savedBody = {
        htmlOverflow: html.style.overflow,
        htmlHeight: html.style.height,
        bodyOverflow: body.style.overflow,
        bodyPosition: body.style.position,
        bodyTop: body.style.top,
        bodyLeft: body.style.left,
        bodyWidth: body.style.width,
        bodyHeight: body.style.height,
        bodyTouchAction: body.style.touchAction
      };
      html.style.overflow = "hidden";
      html.style.height = "100%";
      body.style.overflow = "hidden";
      body.style.position = "fixed";
      body.style.top = (-lockedY) + "px";
      body.style.left = "0";
      body.style.right = "0";
      body.style.width = "100%";
      body.style.height = "100%";
      body.style.touchAction = "manipulation";
    }
    window.scrollTo = function() {
      if (frozen) origScrollTo.call(window, 0, lockedY);
    };
    window.scrollBy = function() {
      if (!frozen) origScrollBy.apply(window, arguments);
    };
    cancelAnimationFrame(rafId);
    rafId = requestAnimationFrame(enforceScroll);
  }
  function unfreeze() {
    if (!frozen) return;
    frozen = false;
    cancelAnimationFrame(rafId);
    rafId = 0;
    window.scrollTo = origScrollTo;
    window.scrollBy = origScrollBy;
    var html = document.documentElement;
    var body = document.body;
    if (savedBody && body) {
      html.style.overflow = savedBody.htmlOverflow;
      html.style.height = savedBody.htmlHeight;
      body.style.overflow = savedBody.bodyOverflow;
      body.style.position = savedBody.bodyPosition;
      body.style.top = savedBody.bodyTop;
      body.style.left = savedBody.bodyLeft;
      body.style.width = savedBody.bodyWidth;
      body.style.height = savedBody.bodyHeight;
      body.style.touchAction = savedBody.bodyTouchAction;
      savedBody = null;
      origScrollTo.call(window, 0, lockedY);
    }
  }
  document.addEventListener("focusin", function(e) {
    if (isFormField(e.target)) freeze();
  }, true);
  document.addEventListener("focusout", function() {
    setTimeout(function() {
      if (!anyFormFieldFocused()) unfreeze();
    }, 150);
  }, true);
  document.addEventListener("input", function(e) {
    if (isFormField(e.target)) freeze();
  }, true);
  window.addEventListener("scroll", function() {
    if (frozen) origScrollTo.call(window, 0, lockedY);
  }, { passive: false });
  document.addEventListener("touchmove", function(e) {
    if (frozen) e.preventDefault();
  }, { passive: false });
  if (window.visualViewport) {
    var vv = window.visualViewport;
    vv.addEventListener("resize", function() {
      if (frozen) {
        origScrollTo.call(window, 0, lockedY);
        requestAnimationFrame(function() { origScrollTo.call(window, 0, lockedY); });
      }
    });
    vv.addEventListener("scroll", function() {
      if (frozen) origScrollTo.call(window, 0, lockedY);
    });
  }
})();
''';

/// CAMS AA pages sometimes report a 980px desktop layout in WKWebView, which
/// renders as a small centred box. Force mobile viewport before first paint.
const String _kAccountAggregatorViewportFixJs = r'''
(function() {
  if (window.__meonAaViewportFixV1) return;
  window.__meonAaViewportFixV1 = true;
  function apply() {
    try {
      var meta = document.querySelector('meta[name="viewport"]');
      if (!meta) {
        meta = document.createElement('meta');
        meta.setAttribute('name', 'viewport');
        var head = document.head || document.getElementsByTagName('head')[0];
        if (head) head.appendChild(meta);
      }
      meta.setAttribute(
        'content',
        'width=device-width, initial-scale=1.0, maximum-scale=1.0, viewport-fit=cover'
      );
    } catch (_) {}
  }
  apply();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', apply);
  }
})();
''';

/// iOS Proceed to eSign: keep focused fields visible above keyboard + banner.
/// (Account Aggregator no longer uses this JS — native WKWebView insets only.)
const String _kAccountAggregatorKeyboardAssistJs = r'''
(function() {
  // Bump flag so reinject replaces older scroll logic (eSign ENTER OTP clearance).
  if (window.__meonAaKeyboardAssistV3) return;
  window.__meonAaKeyboardAssistV3 = true;
  window.__meonAaKeyboardAssist = true;

  function isField(el) {
    if (!el || el.nodeType !== 1) return false;
    var t = (el.tagName || '').toUpperCase();
    return t === 'INPUT' || t === 'TEXTAREA' || t === 'SELECT' || el.isContentEditable === true;
  }

  function isOtpLike(el) {
    if (!isField(el)) return false;
    var ml = el.getAttribute && el.getAttribute('maxlength');
    if (ml === '1' || ml === '1 ') return true;
    var inputMode = (el.getAttribute && (el.getAttribute('inputmode') || '')) || '';
    var name = ((el.name || el.id || el.className || '') + '').toLowerCase();
    var ac = ((el.getAttribute && el.getAttribute('autocomplete')) || '').toLowerCase();
    if (ac.indexOf('one-time-code') >= 0) return true;
    if (name.indexOf('otp') >= 0 || name.indexOf('pin') >= 0) return true;
    if (inputMode === 'numeric' && (el.size === 1 || ml === '1')) return true;
    return false;
  }

  function isInOverlay(el) {
    var p = el;
    while (p && p !== document.body && p !== document.documentElement) {
      try {
        var s = window.getComputedStyle(p);
        if (s.position === 'fixed' || s.position === 'sticky') return true;
        var role = (p.getAttribute && p.getAttribute('role')) || '';
        var cls = ((p.className && p.className.toString) ? p.className.toString() : '').toLowerCase();
        if (role === 'dialog' || role === 'alertdialog') return true;
        if (cls.indexOf('modal') >= 0 || cls.indexOf('sheet') >= 0 ||
            cls.indexOf('drawer') >= 0 || cls.indexOf('bottomsheet') >= 0 ||
            cls.indexOf('bottom-sheet') >= 0 || cls.indexOf('overlay') >= 0) {
          return true;
        }
      } catch (_) {}
      p = p.parentElement;
    }
    return false;
  }

  function findScrollParent(el) {
    var p = el && el.parentElement;
    while (p && p !== document.body && p !== document.documentElement) {
      try {
        var s = window.getComputedStyle(p);
        var oy = s.overflowY;
        if ((oy === 'auto' || oy === 'scroll' || oy === 'overlay') &&
            p.scrollHeight > p.clientHeight + 4) {
          return p;
        }
      } catch (_) {}
      p = p.parentElement;
    }
    return null;
  }

  function scrollFocusedIntoView() {
    var el = document.activeElement;
    if (!isField(el)) return;

    var vv = window.visualViewport;
    var rect = el.getBoundingClientRect();
    var viewH = vv ? vv.height : (window.innerHeight || 0);
    if (viewH <= 0) return;

    // Leave room for eSign bottom warning banner + iOS accessory bar.
    var safeBottom = viewH * 0.52;
    if (rect.top >= 4 && rect.bottom <= safeBottom) return;

    // Soft path only for real modals — page OTP (eSign ENTER OTP) needs stronger scroll.
    if (isInOverlay(el)) {
      try {
        el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'auto' });
      } catch (_) {
        try { el.scrollIntoView(false); } catch (__) {}
      }
      var parent = findScrollParent(el);
      if (parent) {
        rect = el.getBoundingClientRect();
        var prect = parent.getBoundingClientRect();
        var limit = Math.min(prect.bottom, viewH * 0.78);
        var overflow = rect.bottom - limit;
        if (overflow > 8) parent.scrollTop += overflow + 12;
        if (rect.top < prect.top + 4) parent.scrollTop -= (prect.top + 4 - rect.top);
      }
      return;
    }

    // Full-page fields (eSign Aadhaar / ENTER OTP): park above keyboard + banner.
    try {
      el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'auto' });
    } catch (_) {
      try { el.scrollIntoView(true); } catch (__) {}
    }
    try {
      rect = el.getBoundingClientRect();
      var targetBottom = viewH * 0.42;
      if (rect.bottom > targetBottom) {
        window.scrollBy(0, rect.bottom - targetBottom);
      } else if (rect.top < 8) {
        window.scrollBy(0, rect.top - 12);
      }
    } catch (_) {}
  }

  var timer = null;
  function schedule(delay) {
    if (timer) clearTimeout(timer);
    timer = setTimeout(scrollFocusedIntoView, delay || 300);
  }

  window.__meonAaNudgeKeyboardField = function() {
    schedule(180);
  };

  document.addEventListener('focusin', function(e) {
    if (!isField(e.target)) return;
    schedule(isOtpLike(e.target) || isInOverlay(e.target) ? 220 : 300);
  }, true);

  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', function() {
      if (isField(document.activeElement)) schedule(320);
    });
  }
  window.addEventListener('resize', function() {
    if (isField(document.activeElement)) schedule(320);
  });
})();
''';

/// WebView page for external redirects (DigiLocker, IPV/Face Finder)
/// Uses InAppWebView for camera/microphone (getUserMedia) support
class WebViewPage extends StatefulWidget {
  final String url;
  final String title;
  final String company;
  final String workflowName;

  const WebViewPage({
    super.key,
    required this.url,
    this.title = 'External Verification',
    required this.company,
    required this.workflowName,
  });

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> with WidgetsBindingObserver {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  String _currentUrl = '';
  String? _preservedState;
  String? _preservedClientToken;
  String? _preservedAuto;
  bool _hasSeenCleanUrl = false;
  bool _permissionsRequested = false;
  bool _hasReloadedAfterPermissions = false;
  bool _pendingReloadAfterPermissions = false;
  bool _permissionRequestScheduled = false;
  bool _permissionHandlerInFlight = false;
  bool _ipvPermissionGateActive = false;
  bool _redirectHandled = false;
  /// Set as soon as IPV success URL is seen — blocks website paint before API finishes.
  bool _ipvSuccessHandoff = false;
  /// One silent reload if Face/IPV main-frame fails once (permission/reload race).
  int _ipvLoadErrorAutoRetryCount = 0;
  /// Params captured from completion/success URLs (e.g. success=yes, transaction_id=...)
  /// Passed to get-context API so backend marks step as complete
  final Map<String, String> _completionParams = {};
  // Popup window (Digio etc.) for reverse_pennydrop
  int? _popupWindowId;
  // Track if a UPI app was opened so we can auto-refresh on return
  bool _upiAppLaunched = false;
  /// Prevents bare `upi://` error callbacks from opening Paytm after a GPay intent attempt.
  String? _lastPaymentTargetPackage;
  DateTime? _lastPaymentAttemptAt;
  /// RPD Android page logs app-specific links but navigates to generic `upi://`.
  /// Capture the intended BHIM/GPay/Paytm/PhonePe/WhatsApp target and prefer it.
  String? _pendingRpdAppSpecificLink;
  String? _pendingRpdAppName;
  DateTime? _pendingRpdAppSpecificAt;
  DateTime? _rpdPaymentLaunchAt;
  bool _rpdPaymentLaunchInFlight = false;
  Map<String, String> _rpdAppLinks = const {};
  String? _rpdGenericUpiLink;
  ConnectivityController? _connectivity;
  int _lastReconnectToken = 0;
  // Track if any payment app was launched (for iOS auto-reload)
  bool _paymentAppLaunched = false;
  // Periodic polling timer to auto-refresh Reverse Penny Drop page after UPI payment
  Timer? _reversePennyPollTimer;

  // --- Loading / error UX state ---
  bool _hasError = false;
  String _errorMessage = 'Something went wrong, please try again.';
  String _loadingMessage = 'Loading...';
  // Set true once the first page finishes loading (controls full-screen cover behaviour)
  bool _initialPageLoaded = false;
  // Timeout timer: fires if the page hasn't loaded within 15 seconds (45 s for eSign/PDF)
  Timer? _loadTimeoutTimer;
  // Slow-network / hint timers — staged messages on heavy document loads
  Timer? _slowNetworkTimer;
  Timer? _loadHintTimer2;
  int _reversePennyPollAttempts = 0;
  static const int _maxReversePennyPollAttempts = 18; // ~90 seconds @ 5s interval
  // Avoid repeating special scroll adjustment for eSign (clouDesign) pages
  bool _esignScrollAdjusted = false;
  // Track if we already handled RPD success (to avoid double-close)
  bool _rpdSuccessHandled = false;
  /// True while loading `meon_reverse_pennydrop/...?success=yes` so backend can advance.
  bool _rpdSuccessCallbackPending = false;
  bool _rpdBackLoading = false;

  // Reverse Penny Drop: only reload after we see signing-complete text,
  // to avoid refresh loops while user is entering UPI details.
  bool _rpdSigningCompletedReloadTriggered = false;

  // Reset the sessionStorage flag only once per WebViewPage instance,
  // so a reload caused by the console message doesn't re-clear the guard.
  bool _rpdSigningSessionFlagReset = false;
  // iOS AA keyboard: track inset so we nudge OTP when keyboard opens/grows.
  double _lastKeyboardBottomInset = 0;
  // eSign / cloudesign: retry only when server returns transient JSON (Invalid Token, etc.).
  int _cloudesignAutoReloadAttempts = 0;
  static const int _maxCloudesignAutoReloadAttempts = 3;
  Timer? _cloudesignRecoveryTimer;
  bool _cloudesignRecoveryPending = false;
  String? _cloudesignRecoveryUrl;

  /// True while an eSign PDF save is in flight (ignore duplicate download events).
  bool _esignPdfDownloadInProgress = false;

  /// One reload if iOS still interrupts cloudesign inline load (WK error 102).
  bool _cloudesignInterruptRecoveryUsed = false;

  /// Account Aggregator ke external-flow ke dauran kabhi-kabhi server
  /// "Pretty print" JSON error (success:false) return karta hai. Us raw JSON
  /// ko user ko dikhne se rokne ke liye limited auto-reload.
  int _aaJsonErrorAutoReloadAttempts = 0;
  static const int _maxAaJsonErrorAutoReloadAttempts = 2;
  String? _aaJsonErrorAutoReloadUrl;

  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// pdf.js can fire several `onDownloadStartRequest` events for one toolbar tap.
  DateTime? _lastEsignPdfDownloadEventAt;

  /// eSign / PDF (pdf.js) pages often need more time than a normal HTML page.
  bool _isEsignPdfHeavyUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('cloudesign') ||
        u.contains('esign.meon') ||
        u.contains('esignservices') ||
        u.contains('/esign/') ||
        u.contains('proteantech') ||
        u.contains('pdf.js') ||
        u.contains('cdnjs.cloudflare.com/ajax/libs/pdf.js');
  }

  bool _isBlobDownloadUrl(String url) =>
      url.toLowerCase().startsWith('blob:');

  bool _isCloudesignDocumentUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    return (host.contains('meon.co.in') || host.contains('stoxbox.in')) &&
        path.contains('/cloudesign/document-');
  }

  /// eSign HTML app (`esign.meon.co.in/EsignServices/...`) — loads via JS after
  /// `onLoadStop`. Never auto-reload; user interacts on the live page.
  bool _isEsignServiceSpaUrl(String url) {
    final u = url.toLowerCase();
    return u.contains('esign.meon.co.in') &&
        (u.contains('/esignservices/') || u.contains('/esign/'));
  }

  /// In-app auto-retry only for cloudesign **document** PDF pages (blank first paint).
  /// eSign service SPAs and other heavy URLs must not reload after a successful load.
  bool _usesInAppDocumentAutoRetry(String url) {
    if (_isEsignServiceSpaUrl(url)) return false;
    return _isCloudesignDocumentUrl(url);
  }

  void _cancelCloudesignRecovery() {
    _cloudesignRecoveryTimer?.cancel();
    _cloudesignRecoveryTimer = null;
  }

  void _resetDocumentRetryState() {
    _cloudesignAutoReloadAttempts = 0;
    _cloudesignRecoveryPending = false;
    _cloudesignRecoveryUrl = null;
    _cancelCloudesignRecovery();
  }

  void _showInAppDocumentRetryAfterFailedRecovery() {
    _cancelCloudesignRecovery();
    if (!mounted || _redirectHandled) return;
    debugPrint(
        '[WebView] Document still not loaded after $_maxCloudesignAutoReloadAttempts in-app retries — showing retry UI');
    setState(() {
      _isLoading = false;
      _hasError = true;
      _errorMessage =
          'We could not load the document after several tries. Please check your connection and tap Try Again to reload inside the app.';
      _loadingMessage = 'Loading...';
    });
  }

  bool _isProceedToEsignFlowContext([String? url]) {
    final sample = (url ?? _currentUrl).toLowerCase();
    if (_isEsignPdfHeavyUrl(sample) || _isCloudesignDocumentUrl(sample)) {
      return true;
    }
    return widget.title.toLowerCase().contains('esign');
  }

  bool _looksLikePdfFileNavigation(String url) {
    final lower = url.toLowerCase();
    if (lower.endsWith('.pdf')) return true;
    if (lower.contains('application/pdf')) return true;
    if (lower.contains('content-disposition=attachment') &&
        lower.contains('pdf')) {
      return true;
    }
    return false;
  }

  Future<void> _resetEsignDownloadUserGesture(
      InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(
        source: 'try { window.__meonUserGestureForDownload = false; } catch(e) {}',
      );
    } catch (_) {}
  }

  Future<void> _injectEsignDownloadUserGestureTracker(
      InAppWebViewController controller) async {
    const script = r'''
      (function() {
        try {
          if (window.__meonEsignDownloadHookInstalled) return;
          window.__meonEsignDownloadHookInstalled = true;
          window.__meonUserGestureForDownload = false;
          function arm() { window.__meonUserGestureForDownload = true; }
          ['click', 'touchstart', 'touchend', 'pointerdown', 'pointerup'].forEach(function(evt) {
            document.addEventListener(evt, arm, true);
          });
        } catch (e) {}
      })();
    ''';
    try {
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('[WebView] Error injecting eSign download gesture tracker: $e');
    }
  }

  /// Benign load errors (blob PDF save, cancelled reloads, etc.). Cloudesign document
  /// URLs are handled via [_onNavigationResponse] + optional reload — not silently ignored.
  bool _shouldIgnoreWebViewLoadError(
    String url, {
    int? code,
    String? description,
  }) {
    final u = url.toLowerCase();
    if (u.startsWith('blob:')) return true;
    if (_isCloudesignDocumentUrl(url)) return false;
    // iOS NSURLErrorCancelled / interrupted navigations (permission dialog, reload).
    if (code == -999 || code == 102) return true;
    final d = (description ?? '').toLowerCase();
    if (d.contains('frame load interrupted')) return true;
    if (d.contains('cancelled') || d.contains('canceled')) return true;
    if (d.contains('aborted')) return true;
    if (d.contains('operation canceled') || d.contains('operation cancelled')) {
      return true;
    }
    return false;
  }

  /// True when Face/IPV permission UI or post-grant reload is mid-flight.
  /// Load cancels here are not real connectivity failures.
  bool get _isIpvPermissionLoadTransient {
    if (!_isIpvOrFaceFinderUrl(_activeWebViewUrl) &&
        !widget.title.toLowerCase().contains('face')) {
      return false;
    }
    return _ipvPermissionGateActive ||
        _permissionHandlerInFlight ||
        _permissionRequestScheduled ||
        (_permissionsRequested && !_hasReloadedAfterPermissions);
  }

  /// Main-frame only — IPV pages load many camera/CDN subresources that must not
  /// trigger the full-screen "check your connection" overlay.
  bool _isMainFrameErrorUrl(String errorUrl) {
    if (errorUrl.isEmpty) return true;
    final current = _currentUrl.isNotEmpty ? _currentUrl : widget.url;
    if (errorUrl == current) return true;
    try {
      final a = Uri.parse(errorUrl);
      final b = Uri.parse(current);
      if (a.host.isEmpty || b.host.isEmpty) return false;
      return a.host.toLowerCase() == b.host.toLowerCase() &&
          a.path == b.path;
    } catch (_) {
      return false;
    }
  }

  /// Surfaces a load failure only for real main-frame problems (not IPV noise).
  void _surfaceWebViewLoadFailure({
    required String errorUrl,
    int? code,
    String? description,
  }) {
    if (_shouldIgnoreWebViewLoadError(
      errorUrl,
      code: code,
      description: description,
    )) {
      debugPrint(
          '[WebView] Ignoring benign load error ($code): $description, url=$errorUrl');
      return;
    }
    if (errorUrl.isNotEmpty && !_isMainFrameErrorUrl(errorUrl)) {
      debugPrint(
          '[WebView] Ignoring non-main-frame load error ($code): $errorUrl');
      return;
    }
    if (_isIpvPermissionLoadTransient) {
      debugPrint(
          '[WebView] Ignoring IPV permission/reload transient error ($code): $description');
      return;
    }
    if (_redirectHandled || _ipvSuccessHandoff) return;

    final isFaceStep = _isIpvOrFaceFinderUrl(_activeWebViewUrl) ||
        widget.title.toLowerCase().contains('face');
    if (isFaceStep && _ipvLoadErrorAutoRetryCount < 1) {
      _ipvLoadErrorAutoRetryCount++;
      debugPrint(
          '[WebView] Face/IPV load error — silent auto-retry ($_ipvLoadErrorAutoRetryCount)');
      if (mounted) {
        setState(() {
          _isLoading = true;
          _hasError = false;
          _loadingMessage = 'Loading...';
        });
      }
      _startLoadTimers(url: _activeWebViewUrl);
      Future.delayed(const Duration(milliseconds: 400), () {
        if (!mounted || _redirectHandled) return;
        _webViewController?.reload();
      });
      return;
    }

    _cancelLoadTimers();
    if (!mounted) return;
    final looksNetwork = () {
      final d = (description ?? '').toLowerCase();
      return code == -2 || // HOST_LOOKUP
          code == -6 || // CONNECT
          code == -8 || // TIMEOUT
          d.contains('host_lookup') ||
          d.contains('err_internet') ||
          d.contains('err_name_not_resolved') ||
          d.contains('err_connection') ||
          d.contains('network');
    }();
    setState(() {
      _isLoading = false;
      _hasError = true;
      _errorMessage = looksNetwork
          ? 'Failed to load page. Please check your connection and try again.'
          : 'Failed to load this page. Tap Try Again to reload.';
    });
  }

  bool _isCloudesignLoadInterruptError({
    required String url,
    int? code,
    String? description,
  }) {
    if (!_isCloudesignDocumentUrl(url)) return false;
    final d = (description ?? '').toLowerCase();
    return code == 102 || d.contains('frame load interrupted');
  }

  Future<bool> _hasEsignDownloadUserGesture(
      InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: 'window.__meonUserGestureForDownload === true',
      );
      if (result is bool) return result;
      return result?.toString().toLowerCase() == 'true';
    } catch (e) {
      debugPrint('[WebView] Error reading eSign download gesture flag: $e');
      return false;
    }
  }

  String _sanitizeDownloadFilename(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'kyc_esign_document.pdf';
    return trimmed.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_');
  }

  String _filenameFromDownloadUrl(String url) {
    if (url.toLowerCase().startsWith('blob:')) {
      return 'kyc_esign_document.pdf';
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'kyc_esign_document.pdf';
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return 'kyc_esign_document.pdf';
    final last = segments.last;
    if (last.toLowerCase().endsWith('.pdf')) {
      return _sanitizeDownloadFilename(last);
    }
    return 'kyc_esign_document.pdf';
  }

  /// pdf.js on eSign uses in-memory `blob:https://...` URLs. Those only exist inside this
  /// WebView — never pass them to Dart [http.get]. Read bytes in-page via [callAsyncJavaScript].
  Future<Uint8List> _readBlobUrlBytesInWebView(
    InAppWebViewController controller,
    String blobUrl,
  ) async {
    final result = await controller.callAsyncJavaScript(
      functionBody: '''
        const response = await fetch(arguments.blobUrl);
        if (!response.ok) {
          throw new Error('fetch failed: ' + response.status);
        }
        const blob = await response.blob();
        const buffer = await blob.arrayBuffer();
        const bytes = new Uint8Array(buffer);
        let binary = '';
        for (let i = 0; i < bytes.byteLength; i++) {
          binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
      ''',
      arguments: {'blobUrl': blobUrl},
    );

    if (result == null) {
      throw Exception('WebView did not return blob bytes');
    }
    if (result.error != null && result.error!.trim().isNotEmpty) {
      throw Exception(result.error!.trim());
    }
    final value = result.value;
    if (value == null || value.toString().isEmpty) {
      throw Exception('Empty blob bytes from WebView');
    }
    return base64Decode(value.toString());
  }

  void _showEsignDownloadMessage(
    String message, {
    bool isError = false,
    bool clearPrevious = true,
  }) {
    if (!mounted) return;
    final messenger =
        _scaffoldMessengerKey.currentState ?? ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      if (clearPrevious) {
        messenger.hideCurrentSnackBar();
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            message,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          backgroundColor: isError ? Colors.red.shade700 : KycTheme.primary,
          duration: Duration(seconds: isError ? 4 : 10),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 28),
        ),
      );
    }
    // Short toast as backup (no gravity — avoids Android text-toast issues).
    final summary = message.split('\n').first.trim();
    if (summary.isNotEmpty) {
      Fluttertoast.cancel();
      Fluttertoast.showToast(
        msg: summary,
        toastLength: Toast.LENGTH_LONG,
      );
    }
  }

  Future<void> _handleEsignPdfDownload(
    InAppWebViewController controller, {
    required WebUri downloadUrl,
    String? suggestedFilename,
    String? userAgent,
    String? mimeType,
    bool skipGestureCheck = false,
  }) async {
    if (!mounted) return;
    if (!_isProceedToEsignFlowContext()) {
      debugPrint('[WebView] Ignoring download outside eSign/PDF context');
      return;
    }
    if (_esignPdfDownloadInProgress) return;

    if (!skipGestureCheck) {
      final allowed = await _hasEsignDownloadUserGesture(controller);
      if (!allowed) {
        debugPrint(
            '[WebView] Blocked PDF download without user tap (auto-download prevented)');
        return;
      }
    }

    final now = DateTime.now();
    if (_lastEsignPdfDownloadEventAt != null &&
        now.difference(_lastEsignPdfDownloadEventAt!) <
            const Duration(seconds: 3)) {
      debugPrint('[WebView] Ignoring duplicate PDF download event');
      return;
    }
    _lastEsignPdfDownloadEventAt = now;

    _esignPdfDownloadInProgress = true;
    try {
      var filename = suggestedFilename?.trim();
      if (filename == null || filename.isEmpty) {
        filename = _filenameFromDownloadUrl(downloadUrl.toString());
      }
      filename = _sanitizeDownloadFilename(filename);
      final mime = mimeType?.toLowerCase() ?? '';
      if (!filename.toLowerCase().endsWith('.pdf') && mime.contains('pdf')) {
        filename = '$filename.pdf';
      }

      final docsDir = await getApplicationDocumentsDirectory();
      final downloadsDir = Directory('${docsDir.path}/esign_downloads');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }

      var savePath = '${downloadsDir.path}/$filename';
      if (await File(savePath).exists()) {
        final stamp = DateTime.now().millisecondsSinceEpoch;
        savePath = '${downloadsDir.path}/${stamp}_$filename';
      }

      final urlStr = downloadUrl.toString();
      final Uint8List fileBytes;
      if (urlStr.toLowerCase().startsWith('blob:')) {
        debugPrint(
            '[WebView] Saving PDF from in-WebView blob (not an HTTP download URL)');
        fileBytes = await _readBlobUrlBytesInWebView(controller, urlStr);
        if (fileBytes.isEmpty) {
          throw Exception('Downloaded PDF is empty');
        }
      } else {
        final httpUri = Uri.parse(urlStr);
        if (!httpUri.hasScheme || httpUri.host.isEmpty) {
          throw Exception('Invalid download URL');
        }
        final cookieBase = WebUri(_currentUrl);
        final cookies = await CookieManager.instance().getCookies(url: cookieBase);
        final headers = <String, String>{};
        if (userAgent != null && userAgent.trim().isNotEmpty) {
          headers['User-Agent'] = userAgent;
        }
        if (cookies.isNotEmpty) {
          headers['Cookie'] =
              cookies.map((c) => '${c.name}=${c.value}').join('; ');
        }
        final response = await http.get(httpUri, headers: headers);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('HTTP ${response.statusCode}');
        }
        fileBytes = response.bodyBytes;
      }

      await File(savePath).writeAsBytes(fileBytes, flush: true);
      debugPrint('[WebView] eSign PDF saved: $savePath');
      final savedName = savePath.split('/').last;
      _showEsignDownloadMessage(
        'PDF downloaded successfully\n$savedName\n$savePath',
      );
    } catch (e) {
      debugPrint('[WebView] eSign PDF download failed: $e');
      _showEsignDownloadMessage(
        'Download failed. Please try again.',
        isError: true,
      );
    } finally {
      _esignPdfDownloadInProgress = false;
      // Keep the eSign page visible — blob navigation must not leave a loader up.
      if (mounted && _initialPageLoaded && !_redirectHandled) {
        setState(() {
          _isLoading = false;
          _hasError = false;
        });
      }
    }
  }

  /// iOS: allow cloudesign / eSign responses to render in-WebView instead of
  /// cancelling navigation as a download (prevents WK error 102 + 45s timeout).
  Future<NavigationResponseAction?> _onNavigationResponse(
    InAppWebViewController controller,
    NavigationResponse navigationResponse,
  ) async {
    if (!navigationResponse.isForMainFrame) {
      return NavigationResponseAction.ALLOW;
    }

    final url = navigationResponse.response?.url?.toString() ?? '';
    if (url.isEmpty) return NavigationResponseAction.ALLOW;

    if (_isCloudesignDocumentUrl(url)) {
      final hasGesture = await _hasEsignDownloadUserGesture(controller);
      if (!hasGesture) {
        debugPrint(
            '[WebView] Cloudesign document — inline WebView (no auto-download): $url');
        return NavigationResponseAction.ALLOW;
      }
      debugPrint('[WebView] Cloudesign document — user download: $url');
      return NavigationResponseAction.DOWNLOAD;
    }

    if (_isProceedToEsignFlowContext(url)) {
      final mime = navigationResponse.response?.mimeType?.toLowerCase() ?? '';
      if (mime.startsWith('text/') || mime.contains('html')) {
        return NavigationResponseAction.ALLOW;
      }
      final hasGesture = await _hasEsignDownloadUserGesture(controller);
      if (!hasGesture) {
        return NavigationResponseAction.ALLOW;
      }
      if (_looksLikePdfFileNavigation(url) || mime.contains('pdf')) {
        return NavigationResponseAction.DOWNLOAD;
      }
    }

    return NavigationResponseAction.ALLOW;
  }

  /// WebView signals a download (often `blob:https://...` from pdf.js).
  /// Cloudesign document URLs stay in-WebView via [_onNavigationResponse]; this
  /// handler runs only for explicit user downloads (gesture) or blob/pdf.js.
  Future<void> _onDownloadStartRequest(
    InAppWebViewController controller,
    DownloadStartRequest downloadStartRequest,
  ) async {
    final url = downloadStartRequest.url;
    if (url == null) return;
    final urlStr = url.toString();

    // Cloudesign page load: native may still emit this event — do not save or interrupt.
    if (_isCloudesignDocumentUrl(urlStr) &&
        !await _hasEsignDownloadUserGesture(controller)) {
      return;
    }

    debugPrint('[WebView] onDownloadStartRequest: $urlStr');
    if (!_isProceedToEsignFlowContext()) return;
    // Blob save handled in shouldOverrideUrlLoading (navigation cancelled).
    if (_isBlobDownloadUrl(urlStr) && _esignPdfDownloadInProgress) {
      return;
    }
    final isIosBlobDownload = Platform.isIOS &&
        urlStr.toLowerCase().startsWith('blob:') &&
        _initialPageLoaded;

    if (!isIosBlobDownload && !await _hasEsignDownloadUserGesture(controller)) {
      debugPrint('[WebView] Ignoring download start (no user tap yet)');
      return;
    }

    await _handleEsignPdfDownload(
      controller,
      downloadUrl: url,
      suggestedFilename: downloadStartRequest.suggestedFilename,
      userAgent: downloadStartRequest.userAgent,
      mimeType: downloadStartRequest.mimeType,
      skipGestureCheck: isIosBlobDownload,
    );
  }

  /// Visible document text — used to detect transient JSON bridge pages before PDF/eSign is ready.
  Future<String> _readMainFrameBodyText(InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: r'''(() => {
          try {
            var b = document.body;
            if (!b) return '';
            return (b.innerText || b.textContent || '').trim();
          } catch (e) { return ''; }
        })()''',
      );
      if (result == null) return '';
      if (result is String) return result.trim();
      return result.toString().trim();
    } catch (e) {
      debugPrint('[WebView] _readMainFrameBodyText error: $e');
      return '';
    }
  }

  /// Cloudesign / eSign sometimes returns a short JSON error (e.g. Invalid Token) or a
  /// Chromium-style "Pretty print" JSON view; auto-reload then loads the real document.
  /// Treat as transient: keep the loader overlay so users never see raw JSON.
  bool _isTransientEsignBridgePayload(String url, String bodyText) {
    if (!_isCloudesignDocumentUrl(url)) return false;
    final t = bodyText.trim().toLowerCase();
    if (t.isEmpty || t.length > 8000) return false;

    final pretty = t.contains('pretty print');
    final hasMsgKey = t.contains('"msg"');
    final hasErrorKey = t.contains('"error"');
    final statusFalse = t.contains('"status":false') ||
        t.contains('"status": false') ||
        t.contains('"success":false') ||
        t.contains('"success": false');
    final tokenOrPdf = t.contains('invalid token') ||
        t.contains('pdf is not generated') ||
        t.contains('journey status');

    // Some backend JSON errors use `error` instead of `msg` (e.g. Python TypeError).
    // Treat both as transient to avoid showing raw JSON UI.
    if (statusFalse && (hasMsgKey || hasErrorKey)) return true;
    if (pretty && (statusFalse || tokenOrPdf)) return true;
    if (tokenOrPdf && hasMsgKey && t.length < 600) return true;
    return false;
  }

  static const Duration _defaultLoadTimeout = Duration(seconds: 25);
  static const Duration _esignLoadTimeout = Duration(seconds: 45);

  /// Starts hint timers and a timeout. Call on every `onLoadStart`; cancel on `onLoadStop`.
  void _startLoadTimers({String? url, bool resetMessageOnCancel = true}) {
    _cancelLoadTimers(resetLoadingMessage: resetMessageOnCancel);

    final sample = (url ?? _currentUrl).toLowerCase();
    final heavy = _isEsignPdfHeavyUrl(sample);
    final timeout = heavy ? _esignLoadTimeout : _defaultLoadTimeout;

    if (heavy) {
      _slowNetworkTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted || !_isLoading) return;
        setState(() => _loadingMessage = 'Loading document...');
      });
      _loadHintTimer2 = Timer(const Duration(seconds: 10), () {
        if (!mounted || !_isLoading) return;
        setState(() => _loadingMessage = 'Still loading, please wait...');
      });
    } else {
      _slowNetworkTimer = Timer(const Duration(seconds: 5), () {
        if (!mounted || !_isLoading) return;
        setState(() => _loadingMessage = 'Loading, please wait...');
      });
    }

    _loadTimeoutTimer = Timer(timeout, () {
      if (!mounted || !_isLoading || _hasError) return;
      debugPrint('[WebView] Load timeout (${timeout.inSeconds}s) — showing retry UI');
      setState(() {
        _isLoading = false;
        _hasError = true;
        _errorMessage =
            'This step is taking longer than usual. Check your network and tap Try Again.';
        _loadingMessage = 'Loading...';
      });
    });
  }

  /// Cancels load timers. Optionally keeps [ _loadingMessage ] (e.g. before "Rendering document...").
  void _cancelLoadTimers({bool resetLoadingMessage = true}) {
    _loadTimeoutTimer?.cancel();
    _loadTimeoutTimer = null;
    _slowNetworkTimer?.cancel();
    _slowNetworkTimer = null;
    _loadHintTimer2?.cancel();
    _loadHintTimer2 = null;
    if (resetLoadingMessage &&
        mounted &&
        _loadingMessage != 'Loading...') {
      setState(() => _loadingMessage = 'Loading...');
    }
  }

  Future<void> _maybeReloadAfterRpdSigningCompleted({
    required InAppWebViewController controller,
    required String urlForCheck,
  }) async {
    if (_redirectHandled || _rpdSuccessHandled) return;
    if (_rpdSigningCompletedReloadTriggered) return;

    // Only check text on the reverse_pennydrop page.
    if (!_isReversePennyDropUrl(urlForCheck) && !_isReversePennyDropFlow) {
      return;
    }

    try {
      final result = await controller.evaluateJavascript(
        source:
            'try { var t = (document.body && document.body.innerText) ? document.body.innerText : ""; return t.indexOf("Signing completed successfully.") !== -1; } catch(e) { return false; }',
      );

      final isSignedComplete = (result is bool)
          ? result
          : result?.toString().toLowerCase() == 'true';

      if (!isSignedComplete) return;

      _rpdSigningCompletedReloadTriggered = true;
      debugPrint('[WebView] Detected RPD signing completed text - reloading to proceed');

      // Reload main webview so the URL/params can update and we can close+advance.
      await _webViewController?.reload();
    } catch (e) {
      debugPrint('[WebView] Error checking RPD signing-complete text: $e');
    }
  }

  /// Reverse Penny Drop: status-based reload when Digio prints
  /// "Signing completed successfully." to JS console.
  ///
  /// This avoids reloading while user is typing UPI details, because we only
  /// reload after the exact signing completion console message appears.
  Future<void> _injectRpdConsoleSigningReload(InAppWebViewController controller) async {
    const script = r'''
      (function() {
        try {
          if (window.__meonRpdConsoleHookInstalled) return;
          window.__meonRpdConsoleHookInstalled = true;

          function hook(methodName) {
            var original = console[methodName];
            if (!original) return;
            console[methodName] = function() {
              try {
                var msg = '';
                for (var i = 0; i < arguments.length; i++) {
                  msg += String(arguments[i]) + ' ';
                }
                if (msg.indexOf('Signing completed successfully.') !== -1) {
                  if (sessionStorage.getItem('meon_rpd_signing_reloaded') !== '1') {
                    sessionStorage.setItem('meon_rpd_signing_reloaded', '1');
                    setTimeout(function() {
                      try { location.reload(); } catch(e) {}
                    }, 800);
                  }
                }
              } catch (e) {}
              try { original.apply(console, arguments); } catch (e) {}
            };
          }

          hook('log');
          hook('info');
          hook('warn');
          hook('error');
        } catch (e) {}
      })();
    ''';

    try {
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('[WebView] Error injecting RPD console signing reload JS: $e');
    }
  }

  /// Reverse Penny Drop: Digio's timer starts when the transaction is created
  /// server-side, so by the time the WebView (or Digio popup) renders the
  /// timer the displayed countdown is usually 4:40–4:55. We override the
  /// visible timer text with our own 5:00 countdown for a consistent user
  /// experience. Backend expiration is still owned by Digio — this is purely
  /// cosmetic.
  ///
  /// Key behaviours:
  /// • Countdown starts the moment a timer DOM node first becomes visible
  ///   (not when the script loads), so it always begins at 5:00.
  /// • If the timer DOM goes away and reappears (e.g. user submits UPI and
  ///   transitions to a "waiting for payment" screen with its own timer),
  ///   the countdown resets to 5:00 again.
  Future<void> _injectRpdTimerOverride(InAppWebViewController controller) async {
    const script = r'''
      (function() {
        try {
          if (window.__meonRpdTimerOverrideInstalled) return;
          window.__meonRpdTimerOverrideInstalled = true;

          var TOTAL_SECONDS = 5 * 60;
          var startedAt = null;     // null until a timer node is first seen
          var hadTimerLastTick = false;

          function fmt(s) {
            if (s < 0) s = 0;
            var m = Math.floor(s / 60);
            var sec = s % 60;
            return m + ':' + (sec < 10 ? '0' : '') + sec;
          }

          function looksLikeTimerNode(node) {
            try {
              if (!node || node.nodeType !== 1) return false;
              if (node.children && node.children.length > 0) return false;
              var t = (node.textContent || '').trim();
              if (!t || t.length > 6) return false;
              return /^\d{1,2}:\d{2}$/.test(t);
            } catch (e) { return false; }
          }

          function findTimerNodes() {
            var nodes = [];
            try {
              var explicit = document.querySelectorAll(
                '.timer, #timer, [class*="timer" i], [class*="countdown" i], ' +
                '[id*="timer" i], [id*="countdown" i]'
              );
              for (var i = 0; i < explicit.length; i++) {
                if (looksLikeTimerNode(explicit[i])) nodes.push(explicit[i]);
              }
              if (nodes.length > 0) return nodes;

              var all = document.body ? document.body.querySelectorAll('*') : [];
              for (var j = 0; j < all.length; j++) {
                if (looksLikeTimerNode(all[j])) nodes.push(all[j]);
              }
            } catch (e) {}
            return nodes;
          }

          function paint() {
            var nodes = findTimerNodes();
            var hasTimer = nodes.length > 0;

            // (Re)start countdown whenever timer DOM transitions from absent
            // to present. This covers initial render, popup load, AND the
            // "waiting for payment" screen which shows its own timer.
            if (hasTimer && !hadTimerLastTick) {
              startedAt = Date.now();
            }
            hadTimerLastTick = hasTimer;
            if (!hasTimer || startedAt == null) return;

            var elapsed = Math.floor((Date.now() - startedAt) / 1000);
            var remaining = TOTAL_SECONDS - elapsed;
            if (remaining < 0) return; // let Digio's own expired UI show through

            var text = fmt(remaining);
            for (var i = 0; i < nodes.length; i++) {
              try {
                if (nodes[i].textContent !== text) {
                  nodes[i].textContent = text;
                }
              } catch (e) {}
            }
          }

          // Initial paints (catch SPA renders).
          setTimeout(paint, 50);
          setTimeout(paint, 300);
          setTimeout(paint, 800);
          setTimeout(paint, 1500);
          setTimeout(paint, 3000);

          // Repaint frequently — overrides Digio's own updates quickly.
          setInterval(paint, 250);

          // React to dynamic DOM updates immediately.
          try {
            var mo = new MutationObserver(function() { paint(); });
            mo.observe(document.documentElement || document.body, {
              childList: true,
              subtree: true,
              characterData: true,
            });
          } catch (e) {}
        } catch (e) {}
      })();
    ''';

    try {
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('[WebView] Error injecting RPD timer override JS: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentUrl = widget.url;

    final initialUri = Uri.tryParse(widget.url);
    if (initialUri != null) {
      _preservedState = initialUri.queryParameters['state'];
      _preservedClientToken = initialUri.queryParameters['client_token'];
      _preservedAuto = initialUri.queryParameters['auto'];
      debugPrint('[WebView] Initial params from URL: state=$_preservedState, client_token=$_preservedClientToken, auto=$_preservedAuto');
    }

    // For Android: Request permissions BEFORE loading IPV page to ensure camera/mic work
    // For iOS: Permissions can be requested after load (works fine)
    if (_isIpvOrFaceFinderUrl(widget.url)) {
      if (Platform.isAndroid) {
        // Request permissions immediately on Android before WebView loads
        _ipvPermissionGateActive = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Prevent duplicate scheduling between initState and onLoadStart.
          _permissionRequestScheduled = true;
          // Gate WebView rendering until permissions request completes.
          () async {
            await _requestPermissionsBeforeLoad();
            if (!mounted) return;
            setState(() {
              _ipvPermissionGateActive = false;
            });
          }();
        });
      } else {
        // iOS: Request after load (existing behavior)
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _requestPermissionsAndReload();
        });
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _connectivity = context.read<ConnectivityController>();
      _lastReconnectToken = _connectivity!.reconnectToken;
      _connectivity!.addListener(_onInternetRestored);
    });
  }

  void _onInternetRestored() {
    final connectivity = _connectivity;
    if (connectivity == null || !mounted) return;
    if (connectivity.reconnectToken == _lastReconnectToken) return;
    _lastReconnectToken = connectivity.reconnectToken;
    if (!connectivity.isConnected) return;
    debugPrint('[WebView] Internet restored — reloading page');
    _webViewController?.reload();
  }

  @override
  void dispose() {
    _connectivity?.removeListener(_onInternetRestored);
    WidgetsBinding.instance.removeObserver(this);
    _reversePennyPollTimer?.cancel();
    _loadTimeoutTimer?.cancel();
    _slowNetworkTimer?.cancel();
    _loadHintTimer2?.cancel();
    _cancelCloudesignRecovery();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When returning from a payment app, auto-reload the WebView
    if (state == AppLifecycleState.resumed) {
      if (_isReversePennyDropFlow && _upiAppLaunched) {
        _upiAppLaunched = false;
        // Auto-reload/polling disabled temporarily to avoid hard refresh loops
        // while user is still interacting with the RPD flow.
        // Completion handling is handled via query-param capture.
      } else if (_paymentAppLaunched) {
        // For iOS: auto-reload when returning from any payment app
        _paymentAppLaunched = false;
        debugPrint('[WebView] App resumed after payment - reloading WebView');
        Future.delayed(const Duration(milliseconds: 500), () {
          _reloadWebView();
        });
      }
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (!Platform.isIOS || !_needsIosKeyboardFieldAssist()) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    final bottom = view.viewInsets.bottom / view.devicePixelRatio;
    final openedOrGrew = bottom > 80 && bottom > _lastKeyboardBottomInset + 8;
    _lastKeyboardBottomInset = bottom;
    if (!openedOrGrew) return;
    // Single delayed nudge — triple-fire made CAMS OTP sheet jump while typing digits.
    Future<void>.delayed(
      const Duration(milliseconds: 350),
      _nudgeIosKeyboardFocusedField,
    );
  }

  bool _isIpvOrFaceFinderUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    // Hosts like face-finder.meon.co.in put "face" in the host, not the path.
    return host.contains('ipv.meon.co.in') ||
        host.contains('ipv.stoxbox.in') ||
        host.contains('ipv') ||
        host.contains('face') ||
        host.contains('face-finder') ||
        host.contains('facefinder') ||
        path.contains('ipv') ||
        path.contains('face') ||
        path.contains('facefinder');
  }

  /// True when [path] is our `/{company}/{workflow}` (case-insensitive).
  bool _isOurWorkflowPath(String path) {
    final needle =
        '/${widget.company}/${widget.workflowName}'.toLowerCase();
    return path.toLowerCase().contains(needle);
  }

  /// IPV/Face return to our workflow URL (`?success=yes` and/or `state=`),
  /// OR Face Finder / IPV host itself reporting `success=yes`.
  /// Must not render the website — go straight to get-context API.
  bool _isIpvOrFaceSuccessReturnUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final hasSuccess =
        uri.queryParameters['success']?.toLowerCase() == 'yes';
    final hasState = uri.queryParameters.containsKey('state');
    if (!hasSuccess && !hasState) return false;

    // face-finder.meon.co.in/?hash=...&success=yes — close immediately (do not wait
    // for the follow-up redirect to live.meon.co.in/COMPANY/workflow without params).
    if (hasSuccess && _isIpvOrFaceFinderUrl(url)) {
      return true;
    }

    final isWorkflowPath = _isOurWorkflowPath(path);
    final isOurFrontend = (host.contains('meon.co.in') ||
            host.contains('stoxbox.in')) &&
        !host.contains('ipv.') &&
        !host.contains('api.') &&
        !host.contains('digilocker.') &&
        !host.contains('face');
    return isOurFrontend && isWorkflowPath;
  }

  /// Keep white loader up, stop WebView paint, then run get-context / navigate.
  Future<void> _beginIpvSuccessReturn(Uri uri) async {
    if (_redirectHandled || _ipvSuccessHandoff || !mounted) return;
    _ipvSuccessHandoff = true;
    _cancelLoadTimers(resetLoadingMessage: false);
    setState(() {
      _isLoading = true;
      _hasError = false;
      _loadingMessage = 'Completing verification...';
    });
    try {
      await _webViewController?.stopLoading();
    } catch (_) {}
    debugPrint(
        '[WebView] IPV success redirect detected - closing WebView immediately');
    await _handleRedirectComplete(
      state: uri.queryParameters['state'] ?? _preservedState,
      clientToken:
          uri.queryParameters['client_token'] ?? _preservedClientToken,
      auto: uri.queryParameters['auto'] ?? _preservedAuto,
      verifyCompleted:
          uri.queryParameters['success']?.toLowerCase() == 'yes',
    );
  }

  /// DigiLocker OAuth / Aadhaar–PIN pages (digitallocker.gov.in, digilocker.*).
  bool _isDigilockerUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host.contains('digilocker') || host.contains('digitallocker');
  }

  /// Account Aggregator / CAMS linked-account OTP pages.
  bool _isAccountAggregatorUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final query = uri.query.toLowerCase();
    if (host.contains('camsfinserv') ||
        host.contains('standardjourney.camsfinserv.com')) {
      return true;
    }
    if (path.contains('account_aggregator') ||
        query.contains('account_aggregator')) {
      return true;
    }
    return false;
  }

  bool get _isAccountAggregatorFlow =>
      widget.title.toLowerCase().contains('account aggregator') ||
      _isAccountAggregatorUrl(widget.url) ||
      _isAccountAggregatorUrl(_activeWebViewUrl);

  /// iOS form fields under keyboard: Proceed to eSign Aadhaar only.
  /// Account Aggregator uses native WKWebView insets (JS scroll fights CAMS modals).
  /// DigiLocker keeps its own freeze JS and must stay excluded.
  bool _needsIosKeyboardFieldAssist([String? url]) {
    if (!Platform.isIOS) return false;
    if (_isDigilockerFlow(url)) return false;
    // AA/CAMS: do not inject scroll assist — breaks "Link accounts" OTP sheet layout.
    if (_isAccountAggregatorFlow) return false;
    final sample = url ?? _activeWebViewUrl;
    if (_isProceedToEsignFlowContext(sample) ||
        _isDigioEsignUrl(sample) ||
        _isEsignServiceSpaUrl(sample) ||
        widget.title.toLowerCase().contains('esign')) {
      return true;
    }
    return false;
  }

  /// True only for the DigiLocker KYC step (title + live URL).
  bool _isDigilockerFlow([String? url]) {
    if (widget.title.toLowerCase().contains('digilocker')) return true;
    final sample = url ?? _activeWebViewUrl;
    return _isDigilockerUrl(sample);
  }

  /// After DigiLocker WebView, Home must call get-context with `verify=digilocker` (save: true).
  void _appendDigilockerVerifyIfNeeded(Map<String, String> queryParams) {
    if (!_isDigilockerFlow()) return;
    queryParams['verify'] = 'digilocker';
    debugPrint(
        '[WebView] DigiLocker flow complete — passing verify=digilocker to Home/get-context');
  }

  String get _activeWebViewUrl =>
      _currentUrl.isNotEmpty ? _currentUrl : widget.url;

  UnmodifiableListView<UserScript>? get _digilockerInitialUserScripts {
    if (!_isDigilockerFlow(widget.url)) return null;
    return UnmodifiableListView<UserScript>([
      UserScript(
        source: _kDigilockerFreezeJs,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
    ]);
  }

  UnmodifiableListView<UserScript>? get _accountAggregatorInitialUserScripts {
    final isAaFromStart = widget.title.toLowerCase().contains('account aggregator') ||
        _isAccountAggregatorUrl(widget.url);
    if (!isAaFromStart) return null;
    return UnmodifiableListView<UserScript>([
      UserScript(
        source: _kAccountAggregatorViewportFixJs,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: true,
      ),
    ]);
  }

  /// RPD Android page always does `location.href = upi://...` for every button.
  /// This script fetches app-specific links and intercepts button clicks in capture
  /// phase so Flutter can open BHIM/GPay/Paytm/PhonePe/WhatsApp correctly.
  static const String _kRpdAppLinkBridgeJs = r'''
(function() {
  if (window.__meonRpdFixV4) return;
  window.__meonRpdFixV4 = true;

  function openViaFlutter(app, link) {
    try {
      if (!link || typeof link !== 'string' || link.indexOf('://') === -1) return false;
      window.__meonPendingRpdAppLink = link;
      window.__meonPendingRpdAppName = (app || '').toLowerCase();
      window.__meonRpdHandledAt = Date.now();
      if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
        window.flutter_inappwebview.callHandler('rpdOpenPayment', app || '', link);
        return true;
      }
    } catch (e) {}
    return false;
  }

  function normalizeLabel(text) {
    return String(text || '').replace(/\s+/g, '').toLowerCase();
  }

  function resolveAppFromButton(btn) {
    if (!btn) return '';
    var label = normalizeLabel(btn.innerText || btn.textContent || '');
    var keys = ['gpay', 'phonepe', 'paytm', 'bhim', 'whatsapp'];
    for (var i = 0; i < keys.length; i++) {
      if (label.indexOf(keys[i]) !== -1) return keys[i];
    }
    var img = btn.querySelector('img');
    var alt = normalizeLabel((img && (img.alt || img.getAttribute('alt'))) || '');
    for (var j = 0; j < keys.length; j++) {
      if (alt.indexOf(keys[j]) !== -1) return keys[j];
    }
    return '';
  }

  function linkForApp(app) {
    var links = window.__meonRpdLinks || {};
    if (links[app]) return links[app];
    var upi = window.__meonRpdPaymentLink || '';
    if (!upi || upi.indexOf('upi://') !== 0) return '';
    var path = upi.substring('upi://'.length);
    if (app === 'gpay') return 'gpay://upi/' + path;
    if (app === 'phonepe') return 'phonepe://upi/' + path;
    if (app === 'paytm') return 'paytm://upi/' + path;
    if (app === 'bhim') return 'bhim://upi/' + path;
    if (app === 'whatsapp') return upi;
    return '';
  }

  async function loadLinks() {
    try {
      var trId = new URLSearchParams(window.location.search).get('tr_id');
      if (!trId) return;
      var res = await fetch('/api/bank-verification/' + trId + '/payment-link', {
        headers: { 'Accept': 'application/json' }
      });
      var json = await res.json();
      if (json && json.data) {
        window.__meonRpdLinks = json.data.ios_links || {};
        window.__meonRpdPaymentLink = json.data.payment_link || '';
        console.log('[MeonRPD] links ready', window.__meonRpdLinks);
      }
    } catch (e) {
      console.log('[MeonRPD] link fetch failed', e);
    }
  }

  document.addEventListener('click', function(e) {
    try {
      var btn = e.target && e.target.closest ? e.target.closest('button') : null;
      if (!btn) return;
      var app = resolveAppFromButton(btn);
      if (!app) return;
      var link = linkForApp(app);
      if (!link) return;
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      console.log('[MeonRPD] intercept ' + app + ' -> ' + link);
      openViaFlutter(app, link);
    } catch (err) {}
  }, true);

  var origLog = console.log.bind(console);
  console.log = function() {
    try {
      var a0 = arguments[0];
      var a1 = arguments[1];
      if (typeof a0 === 'string' && a0.indexOf('Opening ') === 0 && a0.indexOf(' link:') !== -1) {
        var m = a0.match(/^Opening\s+(\w+)\s+link:\s*(.*)$/i);
        var app = m ? String(m[1] || '').toLowerCase() : '';
        var link = (typeof a1 === 'string' && a1.indexOf('://') !== -1)
          ? a1
          : ((m && m[2]) ? String(m[2]).trim() : '');
        if (link) openViaFlutter(app, link);
      }
    } catch (e) {}
    return origLog.apply(null, arguments);
  };

  loadLinks();
  setTimeout(loadLinks, 800);
  setTimeout(loadLinks, 2000);
})();
''';

  Future<void> _injectRpdAppLinkBridge(InAppWebViewController controller) async {
    try {
      await controller.evaluateJavascript(source: _kRpdAppLinkBridgeJs);
      _paymentLog('RPD bridge injected');
    } catch (e) {
      _paymentLog('RPD bridge inject failed: $e');
    }
  }

  Future<void> _syncPendingRpdTargetFromJs(
    InAppWebViewController controller,
  ) async {
    try {
      final raw = await controller.evaluateJavascript(source: r'''
(function() {
  return JSON.stringify({
    app: window.__meonPendingRpdAppName || '',
    link: window.__meonPendingRpdAppLink || ''
  });
})();
''');
      if (raw == null) return;
      var text = raw.toString().trim();
      if (text.startsWith('"') && text.endsWith('"')) {
        text = jsonDecode(text) as String;
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final app = decoded['app']?.toString();
      final link = decoded['link']?.toString();
      if ((app != null && app.isNotEmpty) ||
          (link != null && link.contains('://'))) {
        _rememberRpdAppTarget(appName: app, link: link);
      }
    } catch (e) {
      _paymentLog('RPD JS sync failed: $e');
    }
  }

  Future<void> _prefetchRpdAppLinks(String pageUrl) async {
    try {
      final uri = Uri.tryParse(pageUrl);
      final trId = uri?.queryParameters['tr_id'];
      if (trId == null || trId.isEmpty) return;
      final apiUri = Uri.parse(
        '${uri!.scheme}://${uri.host}/api/bank-verification/$trId/payment-link',
      );
      final res = await http.get(
        apiUri,
        headers: const {'Accept': 'application/json'},
      );
      if (res.statusCode != 200) return;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return;
      final data = decoded['data'];
      if (data is! Map) return;
      final iosLinks = data['ios_links'];
      final paymentLink = data['payment_link']?.toString();
      if (paymentLink != null && paymentLink.startsWith('upi://')) {
        _rpdGenericUpiLink = paymentLink;
      }
      if (iosLinks is Map) {
        _rpdAppLinks = iosLinks.map(
          (key, value) => MapEntry(key.toString().toLowerCase(), value.toString()),
        );
        _paymentLog('RPD links prefetched: ${_rpdAppLinks.keys.join(",")}');
      }
    } catch (e) {
      _paymentLog('RPD link prefetch failed: $e');
    }
  }

  String _preferredRpdLinkForApp(String appName, String fallbackLink) {
    final app = appName.trim().toLowerCase();
    // Android: always prefer NPCI upi:// so PhonePe/Paytm open with amount.
    if (Platform.isAndroid) {
      final upi = fallbackLink.toLowerCase().startsWith('upi://')
          ? fallbackLink
          : (_toStandardUpiPayUri(fallbackLink) ??
              _rpdGenericUpiLink ??
              fallbackLink);
      if (upi.toLowerCase().startsWith('upi://')) return upi;
    }
    final fromApi = _rpdAppLinks[app];
    if (fromApi != null && fromApi.contains('://')) {
      final asUpi = _toStandardUpiPayUri(fromApi);
      if (Platform.isAndroid && asUpi != null) return asUpi;
      return fromApi;
    }
    if (fallbackLink.contains('://') &&
        !fallbackLink.toLowerCase().startsWith('upi://')) {
      return fallbackLink;
    }
    final upi = fallbackLink.toLowerCase().startsWith('upi://')
        ? fallbackLink
        : (_rpdGenericUpiLink ?? fallbackLink);
    return app.isEmpty ? upi : _synthesizeRpdAppLink(app, upi);
  }

  Future<void> _openRpdPaymentApp({
    required String appName,
    required String link,
  }) async {
    if (_rpdPaymentLaunchInFlight || _isRecentRpdPaymentLaunch()) {
      _paymentLog('Skip duplicate RPD open for $appName');
      return;
    }
    _rpdPaymentLaunchInFlight = true;
    _rpdPaymentLaunchAt = DateTime.now();
    try {
      final app = appName.trim().toLowerCase();
      final launchUrl = _preferredRpdLinkForApp(app, link);
      _rememberRpdAppTarget(appName: app, link: launchUrl);
      _paymentLog('RPD open app=$app link=$launchUrl');
      final ok = await _launchPaymentUri(
        launchUrl,
        packageName: _packageForRpdAppName(app),
      );
      if (ok) {
        _markPaymentAppLaunched(launchUrl);
      } else if (mounted) {
        final label = app.isEmpty ? 'UPI app' : app;
        Fluttertoast.showToast(
          msg: 'Could not open $label. Please install or check the app.',
          gravity: ToastGravity.BOTTOM,
        );
      }
    } finally {
      _rpdPaymentLaunchInFlight = false;
    }
  }

  UnmodifiableListView<UserScript>? get _rpdInitialUserScripts {
    if (!_isReversePennyDropUrl(widget.url)) return null;
    return UnmodifiableListView<UserScript>([
      UserScript(
        source: _kRpdAppLinkBridgeJs,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ]);
  }

  UnmodifiableListView<UserScript>? get _initialUserScripts {
    return _digilockerInitialUserScripts ??
        _accountAggregatorInitialUserScripts ??
        _rpdInitialUserScripts;
  }

  void _rememberRpdAppTarget({String? appName, String? link}) {
    final trimmedLink = link?.trim();
    final trimmedApp = appName?.trim();
    if ((trimmedLink == null || trimmedLink.isEmpty || !trimmedLink.contains('://')) &&
        (trimmedApp == null || trimmedApp.isEmpty)) {
      return;
    }
    if (trimmedLink != null &&
        trimmedLink.isNotEmpty &&
        trimmedLink.contains('://')) {
      _pendingRpdAppSpecificLink = trimmedLink;
    }
    if (trimmedApp != null && trimmedApp.isNotEmpty) {
      _pendingRpdAppName = trimmedApp.toLowerCase();
    }
    _pendingRpdAppSpecificAt = DateTime.now();
    _paymentLog(
        'RPD pending app=${_pendingRpdAppName ?? "-"} link=${_pendingRpdAppSpecificLink ?? "-"}');
  }

  void _clearPendingRpdAppTarget() {
    _pendingRpdAppSpecificLink = null;
    _pendingRpdAppName = null;
    _pendingRpdAppSpecificAt = null;
  }

  bool _isRecentRpdPaymentLaunch() {
    final at = _rpdPaymentLaunchAt;
    if (at == null) return false;
    return DateTime.now().difference(at) <= const Duration(seconds: 3);
  }

  String _resolvePaymentLaunchUrl(String url) {
    final pending = _pendingRpdAppSpecificLink;
    final appName = _pendingRpdAppName;
    final at = _pendingRpdAppSpecificAt;
    if (at == null || (pending == null && appName == null)) return url;
    if (DateTime.now().difference(at) > const Duration(seconds: 6)) {
      _clearPendingRpdAppTarget();
      return url;
    }

    final lower = url.toLowerCase();
    final isGenericUpi = lower.startsWith('upi://');

    // Keep NPCI upi:// for PhonePe/Paytm/BHIM — package targeting opens pay screen.
    // Only remap to GPay custom scheme when that was the tapped app.
    if (isGenericUpi && appName != null && appName.isNotEmpty) {
      final app = appName.toLowerCase().trim();
      if (app == 'gpay' || app == 'googlepay' || app == 'tez') {
        final synthesized = _synthesizeRpdAppLink(appName, url);
        if (synthesized.toLowerCase() != lower) {
          _paymentLog('RPD Android remap via app=$appName: $url -> $synthesized');
          return synthesized;
        }
      }
      return url;
    }

    if (pending != null) {
      final pendingLower = pending.toLowerCase();
      final pendingIsGpay = pendingLower.startsWith('gpay://') ||
          pendingLower.startsWith('tez://') ||
          pendingLower.startsWith('googlepay://');
      if (isGenericUpi && pendingIsGpay) {
        _paymentLog('RPD Android remap $url -> $pending');
        return pending;
      }
    }

    return url;
  }

  Future<bool> _launchWhatsAppWithUpi(String upiUrl) async {
    _paymentLog('WhatsApp launch for $upiUrl');

    if (await _launchPaymentUriNative(
      dataUri: upiUrl,
      packageName: _kWhatsAppPackage,
    )) {
      return true;
    }
    if (await _launchPaymentUriNative(
      dataUri: upiUrl,
      packageName: _kWhatsAppBusinessPackage,
    )) {
      return true;
    }

    final encoded = Uri.encodeComponent(
      'Please complete ₹1 verification:\n$upiUrl',
    );
    final shareCandidates = <String>[
      'whatsapp://send?text=$encoded',
      'https://api.whatsapp.com/send?text=$encoded',
      'https://wa.me/?text=$encoded',
    ];
    for (final candidate in shareCandidates) {
      try {
        final uri = Uri.parse(candidate);
        final launched = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
        if (launched) {
          _paymentLog('WhatsApp opened via $candidate');
          return true;
        }
      } catch (e) {
        _paymentLog('WhatsApp candidate failed: $candidate ($e)');
      }
    }
    return false;
  }

  /// On iOS, disabling `scrollIntoView` breaks OTP on CAMS/Digio; enable only where
  /// auto-scroll-on-focus causes visible jank (IPV/Face). DigiLocker uses [_injectDigilockerFreezeJs].
  bool _shouldInjectNoAutoScrollJs(String? url) {
    if (url == null || url.isEmpty) return !Platform.isIOS;
    if (!Platform.isIOS) return true;
    if (_isDigilockerFlow(url)) return false;
    return _isIpvOrFaceFinderUrl(url);
  }

  /// iOS scaffold resize: DigiLocker + Account Aggregator keep fixed WebView height.
  /// AA/CAMS layout breaks when Flutter shrinks the WebView while the page has bottom sheets.
  bool _shouldResizeForKeyboard() {
    if (!Platform.isIOS) return false;
    if (_isDigilockerFlow()) return false;
    if (_isAccountAggregatorFlow) return false;
    return true;
  }

  /// DigiLocker-only: disable rubber-band / over-scroll on the native WebView.
  Future<void> _applyDigilockerWebViewSettings(
      InAppWebViewController controller) async {
    if (!_isDigilockerFlow()) return;
    try {
      await controller.setSettings(
        settings: InAppWebViewSettings(
          disallowOverScroll: true,
          alwaysBounceVertical: false,
          alwaysBounceHorizontal: false,
          contentInsetAdjustmentBehavior:
              ScrollViewContentInsetAdjustmentBehavior.NEVER,
        ),
      );
    } catch (e) {
      debugPrint('[WebView] DigiLocker native scroll settings error: $e');
    }
  }

  /// AA/CAMS: mobile viewport + iOS keyboard insets (stable OTP sheet layout).
  Future<void> _applyAccountAggregatorWebViewSettings(
    InAppWebViewController controller, {
    String? url,
  }) async {
    final sample = url ?? _activeWebViewUrl;
    if (!_isAccountAggregatorUrl(sample) &&
        !widget.title.toLowerCase().contains('account aggregator')) {
      return;
    }
    try {
      await controller.setSettings(
        settings: InAppWebViewSettings(
          preferredContentMode: UserPreferredContentMode.MOBILE,
          useWideViewPort: true,
          loadWithOverviewMode: true,
          disallowOverScroll: Platform.isIOS ? false : null,
          alwaysBounceVertical: Platform.isIOS ? true : null,
          contentInsetAdjustmentBehavior: Platform.isIOS
              ? ScrollViewContentInsetAdjustmentBehavior.ALWAYS
              : null,
        ),
      );
      debugPrint('[WebView] AA viewport + native settings applied');
    } catch (e) {
      debugPrint('[WebView] AA native settings error: $e');
    }
  }

  Future<void> _injectAccountAggregatorViewportFix(
    InAppWebViewController controller, {
    String? url,
  }) async {
    final sample = url ?? _activeWebViewUrl;
    if (!_isAccountAggregatorUrl(sample) &&
        !widget.title.toLowerCase().contains('account aggregator')) {
      return;
    }
    try {
      await controller.evaluateJavascript(
        source: _kAccountAggregatorViewportFixJs,
      );
    } catch (e) {
      debugPrint('[WebView] AA viewport fix inject error: $e');
    }
  }

  /// DigiLocker step only — freeze viewport while form fields are focused.
  Future<void> _injectDigilockerFreezeJs(InAppWebViewController controller) async {
    if (!_isDigilockerFlow()) return;
    try {
      await controller.evaluateJavascript(source: _kDigilockerFreezeJs);
    } catch (e) {
      debugPrint('[WebView] Error injecting DigiLocker freeze JS: $e');
    }
  }

  /// iOS AA / Proceed-to-eSign: scroll focused Aadhaar/OTP/mobile field above keyboard.
  /// Does not disable scrollIntoView (needed for CAMS/Digio OTP).
  Future<void> _injectAccountAggregatorKeyboardAssist(
    InAppWebViewController controller, {
    String? url,
  }) async {
    if (!_needsIosKeyboardFieldAssist(url)) return;
    try {
      await controller.evaluateJavascript(
        source: _kAccountAggregatorKeyboardAssistJs,
      );
      debugPrint('[WebView] iOS keyboard field assist injected');
    } catch (e) {
      debugPrint('[WebView] iOS keyboard field assist inject error: $e');
    }
  }

  Future<void> _nudgeIosKeyboardFocusedField() async {
    if (!_needsIosKeyboardFieldAssist()) return;
    final controller = _webViewController;
    if (controller == null) return;
    try {
      await controller.evaluateJavascript(
        source:
            'try { if (window.__meonAaNudgeKeyboardField) window.__meonAaNudgeKeyboardField(); } catch (e) {}',
      );
    } catch (_) {}
  }

  bool _isReversePennyDropUrl(String url) {
    final lower = url.toLowerCase();
    // Success callback path is often `/meon_reverse_pennydrop/...` (not `/reverse_pennydrop/`).
    if (lower.contains('meon_reverse_pennydrop') ||
        lower.contains('reverse_pennydrop') ||
        lower.contains('reversepennydrop')) {
      return true;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host.startsWith('rpd.') || host.contains('rpd.meon');
  }

  bool _urlHasRpdCompletionParams(Uri uri) {
    final params = uri.queryParameters;
    final keys = params.keys.map((k) => k.toLowerCase()).toSet();
    final success = params['success']?.toLowerCase().trim();
    // Start URL uses only `tr_id` — do not treat that as completion.
    if (success == 'yes' || success == 'true' || success == '1') return true;
    if (keys.contains('reversepennydrop') || keys.contains('reverse_pennydrop')) {
      return true;
    }
    // Digio/RPD completion often adds `transaction_id` (not the start `tr_id`).
    if (keys.contains('transaction_id')) return true;
    return false;
  }

  String _forceHttpsUrl(String url) {
    if (url.toLowerCase().startsWith('http://')) {
      return 'https://${url.substring('http://'.length)}';
    }
    return url;
  }

  bool _isRpdBackendSuccessCallbackUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('meon_reverse_pennydrop') ||
        (lower.contains('reverse_pennydrop') &&
            (lower.contains('/live') || lower.contains('success=')));
  }

  Future<void> _hitRpdSuccessCallbackHttp(String httpsUrl) async {
    try {
      final token = await StorageService.getAccessToken();
      final headers = <String, String>{
        'Accept': 'text/html,application/json,*/*',
      };
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
        final csrf = BaseAPI.csrfFromJwtAccessToken(token);
        if (csrf != null) headers['X-CSRF-TOKEN'] = csrf;
        final sessionId = BaseAPI.sessionIdFromJwtAccessToken(token);
        if (sessionId != null) headers['Cookie'] = 'session_id=$sessionId';
      }
      final res = await http
          .get(Uri.parse(httpsUrl), headers: headers)
          .timeout(const Duration(seconds: 20));
      debugPrint(
          '[WebView] RPD success callback HTTP ${res.statusCode}: $httpsUrl');
    } catch (e) {
      debugPrint('[WebView] RPD success callback HTTP failed: $e');
    }
  }

  /// After payment, success callback page must load first (backend advances there).
  /// Then return with completion query keys (success, tr_id, …) like other WebView steps
  /// so HomePage can POST get-context with those params for the next step.
  Future<void> _finalizeRpdSuccessNavigation() async {
    if (_redirectHandled || _rpdSuccessHandled) return;
    _rpdSuccessHandled = true;
    _rpdSuccessCallbackPending = false;
    if (!mounted) return;

    _showTransitionLoader('Preparing next step...');
    if (!_completionParams.containsKey('success')) {
      _completionParams['success'] = 'yes';
    }

    final query = _completionParams.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final queryString = query.isEmpty ? '' : '?$query';
    debugPrint(
        '[WebView] RPD success — returning with completion params: $queryString');

    try {
      final store = context.read<AppStore>();
      store.setParams(
        company: widget.company,
        workflowName: widget.workflowName,
      );
      store.setReturningFromWebView(true);
      store.setRpdSuccessReturn(true);
    } catch (e, st) {
      debugPrint('[WebView] RPD finalize error: $e\n$st');
    }

    if (!mounted) return;
    _redirectHandled = true;
    context.go('/${widget.company}/${widget.workflowName}$queryString');
  }

  /// On RPD success callback (incl. cleartext `http://` URLs), commit to backend
  /// then continue KYC. Closing without hitting the callback leaves workflow stuck.
  Future<bool> _tryCompleteRpdFromUrl(String url, {String reason = ''}) async {
    if (_redirectHandled || _rpdSuccessHandled) return true;
    if (!_isReversePennyDropUrl(url)) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || !_urlHasRpdCompletionParams(uri)) return false;

    _completionParams.addAll(uri.queryParameters);
    if (!_completionParams.containsKey('success')) {
      _completionParams['success'] = 'yes';
    }
    try {
      context.read<AppStore>().setRpdSuccessReturn(true);
    } catch (_) {}

    final httpsUrl = _forceHttpsUrl(url);

    // Success page already loading — wait for onLoadStop to finalize.
    if (_rpdSuccessCallbackPending) {
      debugPrint(
          '[WebView] RPD success callback pending ($reason): $httpsUrl');
      return true;
    }

    final currentLower = _currentUrl.toLowerCase();
    final alreadyOnHttpsCallback = currentLower.startsWith('https://') &&
        _isRpdBackendSuccessCallbackUrl(currentLower) &&
        _urlHasRpdCompletionParams(Uri.tryParse(_currentUrl) ?? uri);

    debugPrint(
      '[WebView] RPD success URL detected${reason.isEmpty ? '' : ' ($reason)'}: $url',
    );

    if (!alreadyOnHttpsCallback) {
      _rpdSuccessCallbackPending = true;
      _showTransitionLoader('Confirming payment...');
      final controller = _webViewController;
      if (controller != null && _isRpdBackendSuccessCallbackUrl(httpsUrl)) {
        try {
          debugPrint(
              '[WebView] Loading RPD success callback so backend advances: $httpsUrl');
          await controller.loadUrl(
            urlRequest: URLRequest(url: WebUri(httpsUrl)),
          );
          return true;
        } catch (e) {
          debugPrint('[WebView] RPD success loadUrl failed: $e');
        }
      }
      await _hitRpdSuccessCallbackHttp(httpsUrl);
    }

    await _finalizeRpdSuccessNavigation();
    return true;
  }

  /// True for any Digio gateway page that hosts the UPI/RPD UI inside a popup
  /// (e.g. https://app.digio.in/#/gateway/login/...). This is where the visible
  /// 5-minute countdown timer is rendered.
  bool _isDigioGatewayUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (!host.contains('digio.in')) return false;
    final fragment = uri.fragment.toLowerCase();
    final path = uri.path.toLowerCase();
    return path.contains('/gateway/') || fragment.contains('/gateway/');
  }

  bool get _isReversePennyDropFlow =>
      _isReversePennyDropUrl(widget.url) || _isReversePennyDropUrl(_currentUrl);

  /// Digio eSign flow – hosted on our domain under /digio/cloud-esign/...
  bool _isDigioEsignUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    return (host.contains('meon.co.in') || host.contains('stoxbox.in')) &&
        path.contains('/digio/cloud-esign/');
  }

  bool get _isDigioEsignFlow =>
      _isDigioEsignUrl(widget.url) || _isDigioEsignUrl(_currentUrl);

  /// Flows that need JS window.open popups (Digio bank selection etc.)
  bool get _supportsPopupWindows => _isReversePennyDropFlow || _isDigioEsignFlow;

  /// IPV/FaceFinder flow camera/WebRTC ke liye popup/multiple windows off rakhna safe rahega.
  bool get _enablePopupWindows => _supportsPopupWindows && !_isIpvOrFaceFinderUrl(widget.url);

  void _startReversePennyPolling() {
    if (_reversePennyPollTimer != null) return;
    _reversePennyPollAttempts = 0;
    // Poll every 5 seconds to let the page re-evaluate payment status and redirect when ready
    _reversePennyPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_isReversePennyDropFlow || _redirectHandled || !mounted) {
        _reversePennyPollTimer?.cancel();
        _reversePennyPollTimer = null;
        return;
      }

      if (_reversePennyPollAttempts >= _maxReversePennyPollAttempts) {
        debugPrint('[WebView] Reverse Penny Drop polling: max attempts reached, stopping');
        _reversePennyPollTimer?.cancel();
        _reversePennyPollTimer = null;
        return;
      }
      // Only reload while we're on the reverse_pennydrop page; once we leave it, stop polling.
      if (_isReversePennyDropUrl(_currentUrl)) {
        _reversePennyPollAttempts++;
        debugPrint('[WebView] Reverse Penny Drop polling reload: $_currentUrl');
        // Keep polling silent to avoid toast spam.
        await _reloadWebViewInternal(showToast: false);
      } else {
        _reversePennyPollTimer?.cancel();
        _reversePennyPollTimer = null;
      }
    });
  }

  /// Request permissions BEFORE loading WebView (Android-specific)
  Future<void> _requestPermissionsBeforeLoad() async {
    if (_permissionsRequested) return;
    if (_permissionRequestScheduled) {
      // Allow the already-scheduled request to proceed.
    }
    _permissionsRequested = true;
    _permissionHandlerInFlight = true;

    debugPrint('[WebView] Requesting permissions BEFORE load (Android) for IPV/Face Finder');

    final permissions = [
      Permission.camera,
      Permission.microphone,
      Permission.location,
    ];

    // Important: don't fire multiple permission requests in parallel.
    // permission_handler will throw if a request is already running.
    Map<Permission, PermissionStatus> results;
    try {
      results = await permissions.request();
    } catch (e) {
      debugPrint('[WebView] Permission request failed: $e');
      _permissionsRequested = false;
      return;
    } finally {
      _permissionRequestScheduled = false;
      _permissionHandlerInFlight = false;
    }

    bool allGranted = permissions.every((p) {
      final status = results[p];
      return status == PermissionStatus.granted ||
          status == PermissionStatus.limited;
    });

    if (allGranted) {
      debugPrint('[WebView] All permissions granted before load - WebView will load with camera access');
      // On Android, reload WebView after permissions granted to ensure camera/mic initialize properly
      if (_webViewController != null && !_hasReloadedAfterPermissions) {
        _hasReloadedAfterPermissions = true;
        Future.delayed(const Duration(milliseconds: 300), () {
          debugPrint('[WebView] Reloading WebView after Android permissions granted');
          _webViewController?.reload();
        });
      } else if (!_hasReloadedAfterPermissions) {
        // Controller not ready yet; reload as soon as it's created.
        _pendingReloadAfterPermissions = true;
      }
    } else {
      debugPrint('[WebView] Some permissions denied before load');
      Fluttertoast.showToast(
        msg: 'Camera, microphone & location required for face verification',
        toastLength: Toast.LENGTH_LONG,
        backgroundColor: Colors.orange,
        gravity: ToastGravity.TOP,
      );
    }
  }

  /// Request permissions AFTER WebView loads (iOS or fallback)
  Future<void> _requestPermissionsAndReload() async {
    if (_permissionsRequested) return;
    _permissionsRequested = true;
    _permissionHandlerInFlight = true;

    debugPrint('[WebView] Requesting permissions for IPV/Face Finder');

    final permissions = [
      Permission.camera,
      Permission.microphone,
      Permission.location,
    ];

    // Important: don't fire multiple permission requests in parallel.
    // permission_handler will throw if a request is already running.
    Map<Permission, PermissionStatus> results;
    try {
      results = await permissions.request();
    } catch (e) {
      debugPrint('[WebView] Permission request failed: $e');
      _permissionsRequested = false;
      return;
    } finally {
      _permissionRequestScheduled = false;
      _permissionHandlerInFlight = false;
    }

    bool allGranted = permissions.every((p) {
      final status = results[p];
      return status == PermissionStatus.granted ||
          status == PermissionStatus.limited;
    });

    if (allGranted) {
      debugPrint('[WebView] All permissions granted, reloading WebView');
      Fluttertoast.showToast(
        msg: 'Permissions granted. Reloading...',
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.TOP,
      );
      if (!_hasReloadedAfterPermissions && _webViewController != null) {
        _hasReloadedAfterPermissions = true;
        Future.delayed(const Duration(milliseconds: 500), () {
          _webViewController?.reload();
        });
      }
    } else {
      debugPrint('[WebView] Some permissions denied');
      Fluttertoast.showToast(
        msg: 'Camera, microphone & location required for face verification',
        toastLength: Toast.LENGTH_LONG,
        backgroundColor: Colors.orange,
        gravity: ToastGravity.TOP,
      );
    }
  }

  Future<void> _reloadWebView() async {
    return _reloadWebViewInternal(showToast: true);
  }

  /// Same reload as the AppBar refresh — used by the error overlay Try Again button.
  Future<void> _retryFromErrorOverlay() async {
    final controller = _webViewController;
    if (controller == null) {
      debugPrint('[WebView] Try Again: no WebView controller');
      return;
    }
    _resetDocumentRetryState();
    _cancelLoadTimers();
    if (!mounted) return;
    setState(() {
      _hasError = false;
      _isLoading = true;
      _loadingMessage = 'Loading...';
    });
    _startLoadTimers(url: _currentUrl);
    try {
      final target = _currentUrl.trim();
      if (target.isNotEmpty) {
        debugPrint('[WebView] Try Again: loadUrl $target');
        await controller.loadUrl(urlRequest: URLRequest(url: WebUri(target)));
      } else {
        await _reloadWebViewInternal(showToast: false);
      }
    } catch (e) {
      debugPrint('[WebView] Try Again loadUrl failed: $e — falling back to reload');
      await _reloadWebViewInternal(showToast: false);
    }
  }

  Future<void> _reloadWebViewInternal({required bool showToast}) async {
    try {
      debugPrint('[WebView] Reloading WebView: $_currentUrl');
      await _webViewController?.reload();
      if (showToast) {
        Fluttertoast.showToast(
          msg: 'Page reloaded',
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.TOP,
        );
      }
    } catch (e) {
      debugPrint('[WebView] Error reloading: $e');
    }
  }

  void _showTransitionLoader([String message = 'Preparing next step...']) {
    if (!mounted) return;
    _cancelLoadTimers(resetLoadingMessage: false);
    setState(() {
      _isLoading = true;
      _hasError = false;
      _loadingMessage = message;
    });
  }

  /// One delayed reload for transient JSON bridge pages — not a periodic loop.
  void _scheduleCloudesignRecovery(
    InAppWebViewController controller,
    String urlStr, {
    required String reason,
  }) {
    if (!_usesInAppDocumentAutoRetry(urlStr)) return;
    if (_cloudesignRecoveryPending && _cloudesignRecoveryUrl == urlStr) return;
    if (_cloudesignAutoReloadAttempts >= _maxCloudesignAutoReloadAttempts) {
      _showInAppDocumentRetryAfterFailedRecovery();
      return;
    }

    _cloudesignRecoveryPending = true;
    _cloudesignRecoveryUrl = urlStr;
    _cancelCloudesignRecovery();

    final attempt = _cloudesignAutoReloadAttempts + 1;
    final delay = Duration(seconds: 2 + attempt);
    debugPrint(
        '[WebView] Scheduling document reload in ${delay.inSeconds}s (attempt $attempt/$_maxCloudesignAutoReloadAttempts, $reason)');

    _cloudesignRecoveryTimer = Timer(delay, () async {
      _cloudesignRecoveryPending = false;
      if (!mounted || _redirectHandled) return;
      if (_currentUrl != urlStr || !_usesInAppDocumentAutoRetry(_currentUrl)) {
        return;
      }

      _cloudesignAutoReloadAttempts = attempt;
      debugPrint(
          '[WebView] In-app document reload (attempt $attempt/$_maxCloudesignAutoReloadAttempts, $reason)');
      if (mounted) {
        setState(() {
          _isLoading = true;
          _hasError = false;
          _loadingMessage =
              'Preparing document… ($attempt/$_maxCloudesignAutoReloadAttempts)';
        });
      }
      await _reloadWebViewInternal(showToast: false);
    });
  }

  /// Captures query params from completion/success URLs (e.g. RPD: ?success=yes&transaction_id=..., eSign: ?esign=yes)
  /// so they can be passed to get-context API. Works for any segment with different params.
  void _captureCompletionParamsIfApplicable(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.queryParameters.isEmpty) return;

    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final isWorkflowPath = _isOurWorkflowPath(path);
    final isOurDomain = (host.contains('meon.co.in') || host.contains('stoxbox.in')) &&
        !host.contains('api.') &&
        !host.contains('accounts.');

    // Known completion params that indicate step completion or carry
    // important status for external flows (eSign, RPD, Reverse Penny Drop, AA CAMS, etc.)
    final completionParamKeys = [
      'esign',
      'success',
      'transaction_id',
      'verifycompleted',
      'reversepennydrop',
      'account_aggregator',
      'ecres',
      'resdate',
      'fi',
    ];
    final hasCompletionParams = uri.queryParameters.keys.any((key) => 
        completionParamKeys.contains(key.toLowerCase()));

    // Capture from completion URLs: our domain, has params
    // If workflow path, only capture if it has completion params (e.g. ?esign=yes)
    if (isOurDomain) {
      if (!isWorkflowPath || hasCompletionParams) {
        for (final e in uri.queryParameters.entries) {
          final keyLower = e.key.toLowerCase();
          // Never override routing params (state, client_token, auto) from intermediate domains
          // These should always come from the final workflow URL (bp_flow, etc.)
          if (e.value.isNotEmpty &&
              keyLower != 'state' &&
              keyLower != 'client_token' &&
              keyLower != 'auto') {
            _completionParams[e.key] = e.value;
          }
        }
        if (_completionParams.isNotEmpty) {
          debugPrint('[WebView] Captured completion params: $_completionParams');
        }
      }
    }
  }

  /// Returns true if the URL should be opened outside the WebView (UPI apps, wallets, tel:, mailto:, etc.)
  bool _shouldHandleExternally(String url) {
    const externalSchemes = [
      'upi://',
      'paytmmp://',
      'paytm://',
      // Digio sometimes uses custom "ppe://" scheme for PhonePe.
      // Treat it as external so we can remap to "phonepe://" later.
      'ppe://',
      'phonepe://',
      'gpay://',
      'tez://',
      'google.payments://',
      'googlepay://',
      'bhim://',
      'tel:',
      'mailto:',
      'whatsapp://',
      'intent:',
      'intent://',
    ];

    return externalSchemes.any((scheme) => url.toLowerCase().startsWith(scheme));
  }

  /// Opens supported payment / deep-link URLs in external apps.
  Future<bool> _launchPaymentUri(
    String dataUri, {
    String? packageName,
  }) async {
    final targetPackage = packageName ??
        _packageForPaymentUri(dataUri) ??
        _packageForRpdAppName(_pendingRpdAppName);
    // For PhonePe/Paytm/BHIM: launch NPCI upi://pay?... with setPackage so
    // the wallet opens the amount screen (not just the home dashboard).
    var launchUri = dataUri;
    if (Platform.isAndroid &&
        targetPackage != null &&
        targetPackage != _kGooglePayPackage) {
      final standard = _toStandardUpiPayUri(dataUri);
      if (standard != null) launchUri = standard;
    }
    _lastPaymentTargetPackage = targetPackage;
    _lastPaymentAttemptAt = DateTime.now();
    _paymentLog('launch uri=$launchUri package=$targetPackage');

    if (Platform.isAndroid) {
      if (targetPackage == _kWhatsAppPackage ||
          targetPackage == _kWhatsAppBusinessPackage ||
          (_pendingRpdAppName == 'whatsapp' &&
              launchUri.toLowerCase().startsWith('upi://'))) {
        final ok = await _launchWhatsAppWithUpi(launchUri);
        if (ok) {
          _rpdPaymentLaunchAt = DateTime.now();
          _clearPendingRpdAppTarget();
          return true;
        }
        _paymentLog('failed to open WhatsApp');
        if (mounted) {
          Fluttertoast.showToast(
            msg: 'Could not open WhatsApp. Please install or check the app.',
            gravity: ToastGravity.BOTTOM,
          );
        }
        return false;
      }

      if (await _launchPaymentUriNative(
        dataUri: launchUri,
        packageName: targetPackage,
      )) {
        _paymentLog('opened via native channel: $targetPackage');
        _rpdPaymentLaunchAt = DateTime.now();
        _clearPendingRpdAppTarget();
        return true;
      }

      if (targetPackage == null) {
        if (await _launchPaymentUriNative(
          dataUri: launchUri,
          packageName: null,
        )) {
          _rpdPaymentLaunchAt = DateTime.now();
          _clearPendingRpdAppTarget();
          return true;
        }
      } else {
        _paymentLog('native package launch failed: $targetPackage — trying url_launcher');
      }
    }

    try {
      final launched = await launchUrl(
        Uri.parse(launchUri),
        mode: LaunchMode.externalApplication,
      );
      if (launched) {
        _rpdPaymentLaunchAt = DateTime.now();
        _clearPendingRpdAppTarget();
        return true;
      }
    } catch (e) {
      _paymentLog('generic launch failed: $e');
    }

    if (mounted && targetPackage == _kGooglePayPackage) {
      Fluttertoast.showToast(
        msg: 'Could not open Google Pay. Please install or check the app.',
        gravity: ToastGravity.BOTTOM,
      );
    }
    return false;
  }

  bool _shouldBlockGenericUpiFallback(String url) {
    if (!url.toLowerCase().startsWith('upi://')) return false;
    if (_isRecentRpdPaymentLaunch()) return true;
    final pkg = _lastPaymentTargetPackage;
    final at = _lastPaymentAttemptAt;
    if (pkg == null || at == null) return false;
    if (DateTime.now().difference(at) > const Duration(seconds: 8)) return false;
    return pkg == _kGooglePayPackage ||
        pkg == _kPhonePePackage ||
        pkg == _kPaytmPackage ||
        pkg == _kBhimPackage ||
        pkg == _kWhatsAppPackage ||
        pkg == _kWhatsAppBusinessPackage;
  }

  /// Opens supported payment / deep-link URLs in external apps using url_launcher.
  Future<bool> _handleExternalUrl(String url) async {
    try {
      if (_isRecentRpdPaymentLaunch() &&
          url.toLowerCase().startsWith('upi://')) {
        _paymentLog('Ignoring duplicate generic upi:// after app launch');
        return true;
      }

      // RPD Android UI always navigates to generic upi://; prefer the tapped app link.
      final pendingApp = _pendingRpdAppName;
      url = _resolvePaymentLaunchUrl(url);
      final originalUrl = url;
      final packageOverride = _packageForRpdAppName(pendingApp);

      if (Platform.isAndroid && url.toLowerCase().startsWith('intent:')) {
        if (await _launchIntentUrlNative(url)) {
          _paymentLog('opened via Intent.parseUri');
          _markPaymentAppLaunched(originalUrl);
          return true;
        }

        final parsed = _parseAndroidPaymentIntentUrl(url);
        final packageName =
            parsed?.packageName ?? _extractIntentPackage(url);
        if (parsed != null) {
          final ok = await _launchPaymentUri(
            parsed.dataUri,
            packageName: packageName,
          );
          if (ok) {
            _markPaymentAppLaunched(originalUrl);
            return true;
          }
        }
        return false;
      }

      var finalUrl = url;
      if (finalUrl.toLowerCase().startsWith('ppe://')) {
        finalUrl = 'phonepe://${finalUrl.substring('ppe://'.length)}';
      }

      final lowerUrl = finalUrl.toLowerCase();
      final isPaymentUrl = lowerUrl.startsWith('upi://') ||
          lowerUrl.startsWith('phonepe://') ||
          lowerUrl.startsWith('paytmmp://') ||
          lowerUrl.startsWith('paytm://') ||
          lowerUrl.startsWith('gpay://') ||
          lowerUrl.startsWith('tez://') ||
          lowerUrl.startsWith('bhim://') ||
          lowerUrl.startsWith('whatsapp://') ||
          lowerUrl.startsWith('google.payments://') ||
          lowerUrl.startsWith('googlepay://');

      if (isPaymentUrl) {
        // PhonePe/Paytm custom schemes often only open home. Prefer upi://pay?...
        // + setPackage so the amount screen opens.
        final standardUpi = _toStandardUpiPayUri(finalUrl);
        final preferUpi = Platform.isAndroid &&
            standardUpi != null &&
            packageOverride != null &&
            packageOverride != _kGooglePayPackage;
        final launchDataUri = preferUpi ? standardUpi! : finalUrl;
        if (launchDataUri != finalUrl) {
          _paymentLog('Normalized payment URI $finalUrl -> $launchDataUri');
        }
        final ok = await _launchPaymentUri(
          launchDataUri,
          packageName: packageOverride,
        );
        if (ok) {
          _markPaymentAppLaunched(finalUrl);
          return true;
        }
        return false;
      }

      final uri = Uri.parse(finalUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        _markPaymentAppLaunched(finalUrl);
        return true;
      }

      debugPrint('[WebView] Could not launch URL: $finalUrl');
      return false;
    } catch (e) {
      debugPrint('[WebView] Error opening external URL: $e');
      return false;
    }
  }

  /// Marks that a payment app was launched (for auto-reload on return)
  void _markPaymentAppLaunched(String url) {
    final lower = url.toLowerCase();
    // UPI/payment deep-links can arrive as:
    // - upi://... / phonepe://... / gpay://...
    // - or Android intent://...#Intent;scheme=upi;package=...;end
    final containsUpiScheme = lower.contains('scheme=upi') || lower.startsWith('upi://');
    final containsPhonepeScheme = lower.contains('scheme=phonepe') || lower.startsWith('phonepe://');
    final containsPaytmScheme = lower.contains('scheme=paytm') || lower.startsWith('paytm://');
    final containsPaytmMpScheme = lower.contains('scheme=paytmmp') || lower.startsWith('paytmmp://');
    final containsGpayScheme = lower.contains('scheme=gpay') || lower.startsWith('gpay://') || lower.contains('scheme=tez');
    final containsAnyPaymentScheme = lower.startsWith('upi://') ||
        lower.startsWith('phonepe://') ||
        lower.startsWith('paytmmp://') ||
        lower.startsWith('paytm://') ||
        lower.startsWith('gpay://') ||
        lower.startsWith('tez://') ||
        lower.startsWith('bhim://') ||
        lower.startsWith('googlepay://') ||
        containsUpiScheme ||
        containsPhonepeScheme ||
        containsPaytmScheme ||
        containsPaytmMpScheme ||
        containsGpayScheme ||
        lower.contains('scheme=upi');

    if (!containsAnyPaymentScheme) return;

    if (_isReversePennyDropFlow) {
      _upiAppLaunched = true;
      debugPrint('[WebView] Marked payment app launched (RPD): $url');
    } else {
      // For iOS: mark any payment app launch so we can reload on return
      if (Platform.isIOS) {
        _paymentAppLaunched = true;
      }
    }
  }

  Future<void> _handleRedirectComplete({String? state, String? clientToken, String? auto, bool verifyCompleted = false}) async {
    if (_redirectHandled || !mounted) return;
    _redirectHandled = true;
    if (!mounted) return;
    _showTransitionLoader(
      verifyCompleted ? 'Completing verification...' : 'Preparing next step...',
    );
    
    // When verifyCompleted=true (IPV success), call get-context API directly
    // Don't navigate to route - let API call handle the data loading
    if (verifyCompleted) {
      final queryParams = <String, String>{};
      if (state != null) queryParams['state'] = state;
      queryParams['success'] = 'yes';
      
      final queryString = queryParams.isEmpty
          ? ''
          : '?${queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
      
      debugPrint('[WebView] IPV success - calling get-context API directly: /api/get-context/${widget.company}/${widget.workflowName}$queryString');
      
      try {
        final store = context.read<AppStore>();
        final hasToken = await StorageService.hasAccessToken();
        
        if (hasToken) {
          store.setParams(company: widget.company, workflowName: widget.workflowName);
          await store.fetchWorkflowFieldsWithAuth(
            widget.company,
            widget.workflowName,
            queryString,
          );
          
          if (mounted) {
            if (store.errorWithAuth != null) {
              debugPrint('[WebView] Error after get-context API: ${store.errorWithAuth}');
              Fluttertoast.showToast(
                msg: store.errorWithAuth ?? 'Error loading data',
                gravity: ToastGravity.TOP,
              );
            } else {
              debugPrint('[WebView] get-context API completed successfully - navigating back');
            }
            // Navigate back to home page (without query params since API already called).
            // Set flag BEFORE navigation so the new HomePage's first build shows a loader,
            // not the old step UI.
            context.read<AppStore>().setReturningFromWebView(true);
            context.go('/${widget.company}/${widget.workflowName}');
          }
        } else {
          debugPrint('[WebView] No auth token - navigating with params');
          final query = queryParams.isEmpty
              ? ''
              : '?${queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
          if (mounted) {
            context.read<AppStore>().setReturningFromWebView(true);
            context.go('/${widget.company}/${widget.workflowName}$query');
          }
        }
      } catch (e) {
        debugPrint('[WebView] Exception calling get-context API: $e');
        if (mounted) {
          Fluttertoast.showToast(
            msg: 'Error: ${e.toString()}',
            gravity: ToastGravity.TOP,
          );
          // Fallback: navigate with params
          final fallbackParams = <String, String>{...queryParams};
          _appendDigilockerVerifyIfNeeded(fallbackParams);
          final query = fallbackParams.isEmpty
              ? ''
              : '?${fallbackParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
          context.read<AppStore>().setReturningFromWebView(true);
          context.go('/${widget.company}/${widget.workflowName}$query');
        }
      }
    } else {
      // For other redirects (DigiLocker, ReversePennyDrop, etc.), navigate with all params
      final queryParams = <String, String>{};
      if (state != null) queryParams['state'] = state;
      if (clientToken != null) queryParams['client_token'] = clientToken;
      if (auto != null) queryParams['auto'] = auto;

      // Add completion params (success=yes, transaction_id=..., etc.) from any segment
      // so get-context API knows step is complete and next step can proceed
      queryParams.addAll(_completionParams);
      _appendDigilockerVerifyIfNeeded(queryParams);

      final query = queryParams.isEmpty
          ? ''
          : '?${queryParams.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';

      debugPrint('[WebView] Going back to: /${widget.company}/${widget.workflowName}$query');
      if (mounted) {
        context.read<AppStore>().setReturningFromWebView(true);
        context.go('/${widget.company}/${widget.workflowName}$query');
      }
    }
  }

  Future<void> _onPageFinished(String url) async {
    if (_redirectHandled || _ipvSuccessHandoff) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();

    // Also capture completion params from onLoadStop (in case shouldOverride wasn't called)
    _captureCompletionParamsIfApplicable(url);

    // RPD: success callback page finished loading — backend can advance now.
    if (_rpdSuccessCallbackPending &&
        !_rpdSuccessHandled &&
        _urlHasRpdCompletionParams(uri)) {
      debugPrint(
          '[WebView] RPD success callback page loaded — finalizing navigation');
      await _finalizeRpdSuccessNavigation();
      return;
    }

    // Only update preserved routing params from our main frontend domains
    final isMainFrontendHost = (host.contains('meon.co.in') &&
            !host.contains('digilocker.') &&
            !host.contains('api.') &&
            !host.contains('accounts.')) ||
        host.contains('stoxbox.in') ||
        host.contains('localhost');

    if (isMainFrontendHost) {
      if (uri.queryParameters.containsKey('state')) {
        _preservedState = uri.queryParameters['state'];
      }
      if (uri.queryParameters.containsKey('client_token')) {
        _preservedClientToken = uri.queryParameters['client_token'];
      }
      if (uri.queryParameters.containsKey('auto')) {
        _preservedAuto = uri.queryParameters['auto'];
      }
    }

    final isFrontendUrl = host.contains('stoxbox.in') ||
        (host.contains('meon.co.in') &&
            !host.contains('digilocker.meon.co.in') &&
            !host.contains('api.') &&
            !host.contains('accounts.')) ||
        host.contains('localhost');
    final isWorkflowPath = _isOurWorkflowPath(path);
    final isReversePennyRoute = _isReversePennyDropUrl(url);
    final hasVerifyParam = uri.queryParameters.containsKey('verify');

    final initialUri = Uri.tryParse(widget.url);
    final initialHost = initialUri?.host.toLowerCase() ?? '';
    final initialWasVerifyPage = (initialHost.contains('stoxbox.in') ||
            (initialHost.contains('meon.co.in') &&
                !initialHost.contains('digilocker') &&
                !initialHost.contains('ext-'))) &&
        initialUri?.queryParameters.containsKey('verify') == true;
    final initialWasIpvOrFace = _isIpvOrFaceFinderUrl(widget.url);
    final completionSuccess =
        (_completionParams['success']?.toString().toLowerCase() == 'yes') ||
            (uri.queryParameters['success']?.toLowerCase() == 'yes');

    if (hasVerifyParam) {
      debugPrint('[WebView] Currently on verify page - staying open');
      return;
    }

    // For Reverse Penny Drop, we must keep the WebView open on
    // /reverse_pennydrop/... so the Digio popup can complete.
    // Treat only the plain workflow URL (/company/workflowName) as "clean".
    final isCleanWorkflowUrl =
        isFrontendUrl && isWorkflowPath && !hasVerifyParam && !isReversePennyRoute;

    if (isCleanWorkflowUrl && initialWasVerifyPage) {
      if (!_hasSeenCleanUrl) {
        _hasSeenCleanUrl = true;
        debugPrint('[WebView] Verify page auto-redirected - staying open');
        return;
      } else {
        debugPrint('[WebView] Verify form submitted - closing WebView');
        _showTransitionLoader('Completing verification...');
        await _handleRedirectComplete(
          state: uri.queryParameters['state'] ?? _preservedState,
          clientToken: uri.queryParameters['client_token'] ?? _preservedClientToken,
          auto: uri.queryParameters['auto'] ?? _preservedAuto,
          verifyCompleted: true,
        );
      }
    } else if (isCleanWorkflowUrl && !initialWasVerifyPage) {
      // Face Finder often redirects to /COMPANY/workflow with no query string after
      // putting success=yes on the face-finder URL — treat that as IPV success.
      final asIpvSuccess = initialWasIpvOrFace && completionSuccess;
      debugPrint(asIpvSuccess
          ? '[WebView] Face/IPV return to workflow URL - closing WebView'
          : '[WebView] External flow completed - closing WebView');
      _showTransitionLoader(
          asIpvSuccess ? 'Completing verification...' : 'Preparing next step...');
      await _handleRedirectComplete(
        state: uri.queryParameters['state'] ?? _preservedState,
        clientToken: uri.queryParameters['client_token'] ?? _preservedClientToken,
        auto: uri.queryParameters['auto'] ?? _preservedAuto,
        verifyCompleted: asIpvSuccess,
      );
    }
  }


  /// Injects JavaScript to prevent automatic scroll jumps on input focus.
  /// This keeps the WebView from auto-scrolling when the keyboard opens;
  /// users can still scroll manually.
  Future<void> _injectNoAutoScrollJs(
    InAppWebViewController controller, {
    String? url,
  }) async {
    if (_isDigilockerFlow(url)) {
      await _injectDigilockerFreezeJs(controller);
      return;
    }
    const script = r'''
      (function() {
        try {
          window.addEventListener("focusin", function(e) {
            try {
              if (!e || !e.target) return;
              var el = e.target;
              el.scrollIntoView = function() {};
            } catch (_) {}
          }, true);
        } catch (e) {}
      })();
    ''';
    try {
      await controller.evaluateJavascript(source: script);
    } catch (e) {
      debugPrint('[WebView] Error injecting no-auto-scroll JS: $e');
    }
  }

  Future<void> _applyDigilockerScrollGuards(
    InAppWebViewController controller, {
    String? url,
  }) async {
    if (!_isDigilockerFlow(url)) return;
    await _applyDigilockerWebViewSettings(controller);
    await _injectDigilockerFreezeJs(controller);
  }

  Future<void> _handleBackPressed() async {
    if (_rpdBackLoading) return;

    if (!_isReversePennyDropFlow) {
      if (mounted) {
        context.go('/${widget.company}/${widget.workflowName}');
      }
      return;
    }

    setState(() => _rpdBackLoading = true);
    final store = context.read<AppStore>();
    store.setRpdReturn(true);
    store.setReturningFromWebView(true);

    try {
      debugPrint('[WebView] RPD back — calling position-update (position=11)');
      final posRes = await KycAPI.positionUpdate('11');
      debugPrint('[WebView] position-update response: ${posRes.statusCode}');

      store.setParams(company: widget.company, workflowName: widget.workflowName);
      await store.fetchWorkflowFieldsWithAuth(
        widget.company,
        widget.workflowName,
        '',
        postBody: const {'rpd_return': true},
      );

      if (!mounted) return;
      if (store.errorWithAuth != null) {
        Fluttertoast.showToast(
          msg: store.errorWithAuth ?? 'Error loading data',
          gravity: ToastGravity.TOP,
        );
      }
      context.go('/${widget.company}/${widget.workflowName}');
    } catch (e, st) {
      debugPrint('[WebView] RPD back flow error: $e\n$st');
      if (mounted) {
        Fluttertoast.showToast(
          msg: 'Error navigating back',
          gravity: ToastGravity.TOP,
        );
        context.go('/${widget.company}/${widget.workflowName}');
      }
    } finally {
      if (mounted) setState(() => _rpdBackLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // iOS: shrink scaffold for keyboard on OTP flows (CAMS, Digio). DigiLocker keeps a fixed
    // WebView height to avoid resize + scrollIntoView fighting (Aadhaar/PIN jump).
    return ScaffoldMessenger(
      key: _scaffoldMessengerKey,
      child: PopScope(
        canPop: !_isReversePennyDropFlow,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          unawaited(_handleBackPressed());
        },
        child: Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: _shouldResizeForKeyboard(),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        automaticallyImplyLeading: !_isReversePennyDropFlow,
        leading: _isReversePennyDropFlow
            ? null
            : IconButton(
                icon: _rpdBackLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: KycTheme.primary,
                        ),
                      )
                    : const Icon(Icons.arrow_back, color: KycTheme.textPrimary),
                onPressed:
                    _rpdBackLoading ? null : () => unawaited(_handleBackPressed()),
              ),
        title: Text(
          widget.title,
          style: const TextStyle(
            color: KycTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: KycTheme.textPrimary),
            onPressed: _isLoading ? null : _reloadWebView,
            tooltip: 'Reload',
          ),
          if (_isIpvOrFaceFinderUrl(_currentUrl))
            IconButton(
              icon: const Icon(Icons.camera_alt, color: KycTheme.textPrimary),
              onPressed: () {
                _permissionsRequested = false;
                _requestPermissionsAndReload();
              },
              tooltip: 'Request Permissions',
            ),
        ],
        bottom: _isLoading
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(
                  color: KycTheme.primary,
                  backgroundColor: KycTheme.border,
                ),
              )
            : null,
      ),
      body: SafeArea(
        // AA: full bottom inset — SafeArea + keyboard + CAMS bottom-sheet was clipping first step.
        bottom: !_isAccountAggregatorFlow,
        child: Stack(
          children: [
            // Main WebView
            _ipvPermissionGateActive
                ? const Center(child: CircularProgressIndicator())
                : InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                    initialUserScripts: _initialUserScripts,
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      // eSign pdf.js uses blob: URLs — listen here, save in-page (see _onDownloadStartRequest).
                      useOnDownloadStart: true,
                      // Needed so IPV success return can CANCEL before the website paints.
                      useShouldOverrideUrlLoading: true,
                      // Allow JS popups / window.open only for special flows (Reverse Penny Drop, Digio eSign, etc.)
                      javaScriptCanOpenWindowsAutomatically: _enablePopupWindows,
                      supportMultipleWindows: _enablePopupWindows,
                      mediaPlaybackRequiresUserGesture: false,
                      allowsInlineMediaPlayback: true,
                      useHybridComposition: true,
                      preferredContentMode: _isAccountAggregatorFlow
                          ? UserPreferredContentMode.MOBILE
                          : null,
                      useWideViewPort: _isAccountAggregatorFlow ? true : null,
                      loadWithOverviewMode:
                          _isAccountAggregatorFlow ? true : null,
                      // DigiLocker step: no rubber-band / inset scroll while typing Aadhaar/PIN
                      disallowOverScroll: _isDigilockerFlow(widget.url) ? true : null,
                      alwaysBounceVertical: _isDigilockerFlow(widget.url) ? false : null,
                      alwaysBounceHorizontal: _isDigilockerFlow(widget.url) ? false : null,
                      contentInsetAdjustmentBehavior: _isDigilockerFlow(widget.url)
                          ? ScrollViewContentInsetAdjustmentBehavior.NEVER
                          : (_isAccountAggregatorFlow
                              ? ScrollViewContentInsetAdjustmentBehavior.ALWAYS
                              : null),
                      // Disable pinch-zoom to keep layout stable
                      supportZoom: false,
                      // Android-specific: Enable camera/microphone/location access in WebView
                      allowFileAccess: true,
                      allowFileAccessFromFileURLs: true,
                      allowUniversalAccessFromFileURLs: true,
                      thirdPartyCookiesEnabled: true,
                      // Enable geolocation for IPV/Face Finder (required for location-based verification)
                      geolocationEnabled: true,
                    ),
                    onConsoleMessage: (controller, consoleMessage) {
                      final msg = consoleMessage.message.trim();
                      if (msg.startsWith('[MeonRPD]')) {
                        _paymentLog(msg);
                      }
                      final opening = RegExp(
                        r'^Opening\s+(\w+)\s+link:\s*(.+)$',
                        caseSensitive: false,
                      ).firstMatch(msg);
                      if (opening != null) {
                        final app = opening.group(1) ?? '';
                        final link = opening.group(2)?.trim() ?? '';
                        if (link.contains('://') &&
                            !_isRecentRpdPaymentLaunch()) {
                          unawaited(
                            _openRpdPaymentApp(appName: app, link: link),
                          );
                        } else {
                          _rememberRpdAppTarget(appName: app, link: link);
                        }
                      }
                    },
                    onNavigationResponse: _onNavigationResponse,
                    onDownloadStartRequest: _onDownloadStartRequest,
                    onWebViewCreated: (controller) {
                      _webViewController = controller;
                      controller.addJavaScriptHandler(
                        handlerName: 'rpdOpenPayment',
                        callback: (args) {
                          final app =
                              args.isNotEmpty ? args[0]?.toString() ?? '' : '';
                          final link =
                              args.length > 1 ? args[1]?.toString() ?? '' : '';
                          if (link.contains('://') &&
                              !_isRecentRpdPaymentLaunch()) {
                            unawaited(
                              _openRpdPaymentApp(appName: app, link: link),
                            );
                          }
                          return null;
                        },
                      );
                      // Keep legacy handler name too (older injected scripts).
                      controller.addJavaScriptHandler(
                        handlerName: 'rpdAppLink',
                        callback: (args) {
                          final link =
                              args.isNotEmpty ? args[0]?.toString() ?? '' : '';
                          final app =
                              args.length > 1 ? args[1]?.toString() ?? '' : '';
                          if (link.contains('://') &&
                              !_isRecentRpdPaymentLaunch()) {
                            unawaited(
                              _openRpdPaymentApp(appName: app, link: link),
                            );
                          }
                          return null;
                        },
                      );

                      if (_pendingReloadAfterPermissions &&
                          !_hasReloadedAfterPermissions) {
                        _pendingReloadAfterPermissions = false;
                        _hasReloadedAfterPermissions = true;
                        Future.delayed(const Duration(milliseconds: 300), () {
                          debugPrint(
                              '[WebView] Pending reload after permissions - reloading WebView');
                          _webViewController?.reload();
                        });
                      }
                    },
                    // Handle popup windows (window.open) – important for Reverse Penny Drop / Digio eSign bank flows
                    onCreateWindow: (controller, createWindowAction) async {
                      final popupUri = createWindowAction.request.url;
                      final popupUrl = popupUri?.toString() ?? '';
                      debugPrint('[WebView] onCreateWindow: $popupUrl');

                      if (!_enablePopupWindows) {
                        return false;
                      }

                      // Digio often calls window.open('') / about:blank first.
                      // When a windowId is provided, create an overlay WebView bound to it.
                      if (createWindowAction.windowId != null) {
                        setState(() {
                          _popupWindowId = createWindowAction.windowId;
                        });

                        return true; // popup handled by overlay InAppWebView with windowId
                      }

                      // If there's a real URL but no windowId (rare), open inside same WebView.
                      if (popupUri != null &&
                          popupUrl.isNotEmpty &&
                          popupUrl != 'about:blank') {
                        await _webViewController?.loadUrl(
                          urlRequest: URLRequest(url: popupUri),
                        );
                        return true;
                      }

                      return false;
                    },
                    shouldOverrideUrlLoading: (controller, navigationAction) async {
                      final uri = navigationAction.request.url;
                      if (uri == null) return NavigationActionPolicy.ALLOW;

                      final url = uri.toString();
                      _wvLog('[WebView] Navigation request: $url');

                      // pdf.js blob: save PDF in-page — do NOT navigate (avoids reload/loader).
                      if (_isProceedToEsignFlowContext() &&
                          _isBlobDownloadUrl(url)) {
                        final shouldPerformDownload =
                            navigationAction.shouldPerformDownload ?? false;
                        final hasGesture =
                            await _hasEsignDownloadUserGesture(controller);
                        if (hasGesture ||
                            (Platform.isIOS &&
                                shouldPerformDownload &&
                                _initialPageLoaded)) {
                          if (!hasGesture) {
                            try {
                              await controller.evaluateJavascript(
                                source:
                                    'window.__meonUserGestureForDownload = true;',
                              );
                            } catch (_) {}
                          }
                          debugPrint(
                              '[WebView] Blob PDF download — in-page save, no navigation');
                          _handleEsignPdfDownload(
                            controller,
                            downloadUrl: uri,
                            skipGestureCheck: true,
                          );
                        }
                        return NavigationActionPolicy.CANCEL;
                      }

                      // Block direct PDF navigations on eSign until user taps download.
                      if (_isProceedToEsignFlowContext() &&
                          _looksLikePdfFileNavigation(url) &&
                          !await _hasEsignDownloadUserGesture(controller)) {
                        debugPrint(
                            '[WebView] Blocked auto PDF navigation: $url');
                        return NavigationActionPolicy.CANCEL;
                      }

                      // Always cancel intent: URLs on Android to prevent ERR_UNKNOWN_URL_SCHEME error
                      if (Platform.isAndroid &&
                          url.toLowerCase().startsWith('intent:')) {
                        _wvLog('[WebView] Intent URL detected - handling externally');
                        await _handleExternalUrl(url);
                        return NavigationActionPolicy.CANCEL;
                      }

                      if (_shouldHandleExternally(url)) {
                        // RPD Android navigates to generic upi:// for every app button.
                        // Pull the real tapped app/link from JS before launching.
                        if (_isReversePennyDropFlow &&
                            url.toLowerCase().startsWith('upi://')) {
                          if (_isRecentRpdPaymentLaunch()) {
                            _paymentLog(
                                'Cancel duplicate upi:// after RPD app launch');
                            return NavigationActionPolicy.CANCEL;
                          }
                          await _syncPendingRpdTargetFromJs(controller);
                          final pendingLink = _pendingRpdAppSpecificLink;
                          final pendingApp = _pendingRpdAppName;
                          if (pendingLink != null &&
                              pendingLink.contains('://') &&
                              !pendingLink.toLowerCase().startsWith('upi://')) {
                            await _openRpdPaymentApp(
                              appName: pendingApp ?? '',
                              link: pendingLink,
                            );
                            return NavigationActionPolicy.CANCEL;
                          }
                          if (pendingApp != null && pendingApp.isNotEmpty) {
                            await _openRpdPaymentApp(
                              appName: pendingApp,
                              link: url,
                            );
                            return NavigationActionPolicy.CANCEL;
                          }
                        }

                        final handled = await _handleExternalUrl(url);
                        if (handled) {
                          debugPrint(
                              '[WebView] External URL handled by app, cancelling WebView navigation');
                          return NavigationActionPolicy.CANCEL;
                        }
                        // Don't let WebView try to render upi:// (blank/error page).
                        if (_isPaymentDeepLink(url)) {
                          return NavigationActionPolicy.CANCEL;
                        }
                      }

                      // Capture completion params from success/return URLs (e.g. ?success=yes&transaction_id=...)
                      // Works for RPD, DigiLocker, and other segments - any URL with params before final workflow URL
                      _captureCompletionParamsIfApplicable(url);

                      // IPV/Face success return — never load ekyc website; API only.
                      if (!_redirectHandled &&
                          !_ipvSuccessHandoff &&
                          _isIpvOrFaceSuccessReturnUrl(url)) {
                        final successUri = Uri.tryParse(url);
                        if (successUri != null) {
                          unawaited(_beginIpvSuccessReturn(successUri));
                        }
                        return NavigationActionPolicy.CANCEL;
                      }

                      // Reverse Penny Drop success callback — never load http cleartext page.
                      if (await _tryCompleteRpdFromUrl(
                        url,
                        reason: 'shouldOverrideUrlLoading',
                      )) {
                        return NavigationActionPolicy.CANCEL;
                      }

                      // RPD intermediate http → https (avoids ERR_CLEARTEXT_NOT_PERMITTED).
                      if (_isReversePennyDropUrl(url) &&
                          url.toLowerCase().startsWith('http://')) {
                        final httpsUrl = 'https://${url.substring(7)}';
                        debugPrint(
                            '[WebView] Forcing HTTPS for RPD URL: $httpsUrl');
                        unawaited(controller.loadUrl(
                          urlRequest: URLRequest(url: WebUri(httpsUrl)),
                        ));
                        return NavigationActionPolicy.CANCEL;
                      }

                      return NavigationActionPolicy.ALLOW;
                    },
                    onCloseWindow: (controller) {
                      // Popup window closed – hide overlay
                      if (_popupWindowId != null) {
                        setState(() {
                          _popupWindowId = null;
                        });
                        // For flows that rely on Digio-style popups (Reverse Penny Drop, Digio eSign),
                        // after the popup closes, reload main page so it can fetch updated success state / params.
                        if (_isDigioEsignFlow &&
                            _webViewController != null &&
                            !_redirectHandled &&
                            !_rpdSuccessHandled) {
                          Future.delayed(const Duration(milliseconds: 500),
                              () async {
                            if (!mounted ||
                                _redirectHandled ||
                                _rpdSuccessHandled) return;
                            debugPrint(
                                '[WebView] Popup closed - reloading main page to fetch success state with params');
                            await _webViewController?.reload();
                          });
                        }
                      }
                    },
                    onLoadStart: (controller, url) async {
                      if (url != null &&
                          !_redirectHandled &&
                          !_ipvSuccessHandoff) {
                        final urlStr = url.toString();
                        // Blob URLs are PDF downloads — never treat as a page load.
                        if (_isBlobDownloadUrl(urlStr)) {
                          debugPrint(
                              '[WebView] Ignoring blob onLoadStart (PDF download only)');
                          return;
                        }
                        // Ignore payment-scheme "page starts" — handled externally.
                        if (_isPaymentDeepLink(urlStr)) {
                          _paymentLog('Ignoring payment scheme onLoadStart: $urlStr');
                          return;
                        }
                        setState(() {
                          _isLoading = true;
                          _hasError = false;
                          _currentUrl = urlStr;
                        });
                        _startLoadTimers(url: urlStr);
                        debugPrint('[WebView] Page started: $url');

                        if (_isReversePennyDropUrl(urlStr) ||
                            _isReversePennyDropFlow) {
                          unawaited(_prefetchRpdAppLinks(urlStr));
                          await _injectRpdAppLinkBridge(controller);
                        }

                        if (_isProceedToEsignFlowContext(urlStr)) {
                          await _resetEsignDownloadUserGesture(controller);
                        }
                        if (_isCloudesignDocumentUrl(urlStr)) {
                          _cloudesignInterruptRecoveryUsed = false;
                        }

                        // IPV/Face Finder success: redirect to .../individual?state=...&success=yes
                        // Do not paint the website — stop load + get-context API only.
                        if (_isIpvOrFaceSuccessReturnUrl(urlStr)) {
                          final successUri = Uri.tryParse(urlStr);
                          if (successUri != null) {
                            await _beginIpvSuccessReturn(successUri);
                          }
                          return;
                        }

                        if (await _tryCompleteRpdFromUrl(
                          urlStr,
                          reason: 'onLoadStart',
                        )) {
                          return;
                        }

                        // Request permissions on load (iOS or if Android permissions weren't requested before)
                        if (_isIpvOrFaceFinderUrl(url.toString()) &&
                            !_permissionsRequested &&
                            !_permissionRequestScheduled) {
                          if (Platform.isAndroid) {
                            WidgetsBinding.instance
                                .addPostFrameCallback((_) {
                              _requestPermissionsBeforeLoad();
                            });
                          } else {
                            WidgetsBinding.instance
                                .addPostFrameCallback((_) {
                              _requestPermissionsAndReload();
                            });
                          }
                        }
                      }
                    },
                    onLoadError: (controller, url, code, message) {
                      debugPrint(
                          '[WebView] Load error ($code): $message, url=$url');
                      final errorUrl = url?.toString() ?? '';
                      // Ignore unknown URL scheme errors — these are UPI/intent
                      // deep-links handled externally and are not real page failures.
                      if (code == -10 &&
                          message.contains('net::ERR_UNKNOWN_URL_SCHEME')) {
                        if (_isPaymentDeepLink(errorUrl) &&
                            !_shouldBlockGenericUpiFallback(errorUrl)) {
                          unawaited(_handleExternalUrl(errorUrl));
                        }
                        return;
                      }
                      // RPD success often lands on http://…success=yes and hits cleartext block.
                      if (errorUrl.isNotEmpty) {
                        if (_rpdSuccessCallbackPending && !_rpdSuccessHandled) {
                          debugPrint(
                              '[WebView] RPD success callback load error — HTTP fallback');
                          unawaited((() async {
                            await _hitRpdSuccessCallbackHttp(
                                _forceHttpsUrl(errorUrl));
                            await _finalizeRpdSuccessNavigation();
                          })());
                          return;
                        }
                        unawaited(_tryCompleteRpdFromUrl(
                          errorUrl,
                          reason: 'onLoadError cleartext/success',
                        ).then((handled) {
                          if (!handled) {
                            _surfaceWebViewLoadFailure(
                              errorUrl: errorUrl,
                              code: code,
                              description: message,
                            );
                          }
                        }));
                        return;
                      }
                      _surfaceWebViewLoadFailure(
                        errorUrl: errorUrl,
                        code: code,
                        description: message,
                      );
                    },
                    onReceivedError: (controller, request, error) {
                      // flutter_inappwebview v6 main-frame error handler.
                      if (request.isForMainFrame != true) return;
                      // Ignore custom-scheme deep-links handled externally.
                      final errUrl = request.url.toString();
                      if (_isPaymentDeepLink(errUrl)) {
                        if (!_shouldBlockGenericUpiFallback(errUrl)) {
                          unawaited(_handleExternalUrl(errUrl));
                        }
                        return;
                      }
                      debugPrint(
                          '[WebView] onReceivedError: ${error.description}, url=$errUrl');
                      if (_isCloudesignLoadInterruptError(
                        url: errUrl,
                        code: error.type.toNativeValue(),
                        description: error.description,
                      )) {
                        debugPrint(
                            '[WebView] Cloudesign load interrupted by download policy — keeping inline view');
                        if (!_cloudesignInterruptRecoveryUsed &&
                            !_redirectHandled) {
                          _cloudesignInterruptRecoveryUsed = true;
                          Future.microtask(() => controller.reload());
                        }
                        return;
                      }
                      if (error.type == WebResourceErrorType.CANCELLED) {
                        debugPrint(
                            '[WebView] Ignoring CANCELLED main-frame error: $errUrl');
                        return;
                      }
                      unawaited(_tryCompleteRpdFromUrl(
                        errUrl,
                        reason: 'onReceivedError',
                      ).then((handled) {
                        if (!handled) {
                          _surfaceWebViewLoadFailure(
                            errorUrl: errUrl,
                            code: error.type.toNativeValue(),
                            description: error.description,
                          );
                        }
                      }));
                    },
                    onLoadStop: (controller, url) async {
                      if (url != null) {
                        final urlStr = url.toString();
                        // IPV already handed off to get-context — never hide loader / paint site.
                        if (_redirectHandled || _ipvSuccessHandoff) {
                          debugPrint(
                              '[WebView] Ignoring page finished after redirect handoff: $urlStr');
                          return;
                        }
                        // Stop timeout/hint timers but keep overlay up briefly on eSign/PDF
                        // so pdf.js / canvas can paint (avoids blank flash).
                        _cancelLoadTimers(resetLoadingMessage: false);
                        final heavyDoc = _isEsignPdfHeavyUrl(urlStr);

                        // Hide transient JSON on cloudesign document URLs only (not eSign SPA).
                        if (_isCloudesignDocumentUrl(urlStr)) {
                          final bodyText = await _readMainFrameBodyText(controller);
                          if (_isTransientEsignBridgePayload(urlStr, bodyText)) {
                            debugPrint(
                                '[WebView] Transient eSign/JSON payload detected — keeping loader until retry succeeds');
                            if (!mounted) return;
                            setState(() {
                              _isLoading = true;
                              _hasError = false;
                              _loadingMessage = 'Preparing eSign document...';
                              _currentUrl = urlStr;
                            });
                            _startLoadTimers(url: urlStr, resetMessageOnCancel: false);
                            if (_usesInAppDocumentAutoRetry(urlStr) &&
                                !_redirectHandled) {
                              _scheduleCloudesignRecovery(
                                controller,
                                urlStr,
                                reason: 'transient JSON bridge',
                              );
                            }
                            await _onPageFinished(urlStr);
                            await _applyDigilockerScrollGuards(controller, url: urlStr);
                            if (_shouldInjectNoAutoScrollJs(urlStr)) {
                              await _injectNoAutoScrollJs(controller, url: urlStr);
                            }
                            await _applyAccountAggregatorWebViewSettings(
                              controller,
                              url: urlStr,
                            );
                            await _injectAccountAggregatorViewportFix(
                              controller,
                              url: urlStr,
                            );
                            await _injectAccountAggregatorKeyboardAssist(
                              controller,
                              url: urlStr,
                            );
                            return;
                          }
                        }

                        // Account Aggregator: sometimes backend returns a short "Pretty print"
                        // JSON error page (success:false, error:..., url:"") instead of a valid
                        // next URL. Detect it and do a limited reload so the app can proceed.
                        if (_isAccountAggregatorFlow &&
                            !_redirectHandled &&
                            _aaJsonErrorAutoReloadAttempts <
                                _maxAaJsonErrorAutoReloadAttempts &&
                            _aaJsonErrorAutoReloadUrl != urlStr) {
                          // Prevent raw JSON "Pretty print" page flash: show loader
                          // immediately, then confirm via body text.
                          if (!mounted) return;
                          setState(() {
                            _isLoading = true;
                            _hasError = false;
                            _loadingMessage = 'Preparing...';
                            _currentUrl = urlStr;
                          });

                          final bodyText = await _readMainFrameBodyText(controller);
                          final t = bodyText.trim().toLowerCase();
                          final statusFalse = t.contains('"success":false') ||
                              t.contains('"success": false') ||
                              t.contains('"status":false') ||
                              t.contains('"status": false');
                          final hasError = t.contains('"error"') ||
                              t.contains('argument of type') ||
                              t.contains('nonetype');
                          final urlEmpty = t.contains('"url":""') ||
                              t.contains('"url": ""') ||
                              t.contains('"url":"') ||
                              t.contains('"url": "');

                          if (t.isNotEmpty &&
                              t.length <= 8000 &&
                              statusFalse &&
                              hasError &&
                              urlEmpty) {
                            _aaJsonErrorAutoReloadAttempts++;
                            _aaJsonErrorAutoReloadUrl = urlStr;
                            debugPrint(
                                '[WebView] AA transient JSON error detected — auto-reloading (attempt $_aaJsonErrorAutoReloadAttempts/$_maxAaJsonErrorAutoReloadAttempts)');
                            await _reloadWebViewInternal(showToast: false);
                            return;
                          }
                        }

                        if (heavyDoc && mounted) {
                          setState(() => _loadingMessage = 'Rendering document...');
                          await Future.delayed(const Duration(milliseconds: 1400));
                        }
                        if (!mounted) return;
                        setState(() {
                          _isLoading = false;
                          _hasError = false;
                          _initialPageLoaded = true;
                          _currentUrl = urlStr;
                          _loadingMessage = 'Loading...';
                        });
                        if (_isIpvOrFaceFinderUrl(urlStr)) {
                          _ipvLoadErrorAutoRetryCount = 0;
                        }
                        debugPrint('[WebView] Page finished: $url');

                        // Successful load — stop retries; let the page stay visible.
                        _cancelCloudesignRecovery();
                        _cloudesignRecoveryPending = false;
                        _resetDocumentRetryState();
                        _aaJsonErrorAutoReloadAttempts = 0;
                        _aaJsonErrorAutoReloadUrl = null;

                        if (_isProceedToEsignFlowContext(urlStr)) {
                          await _injectEsignDownloadUserGestureTracker(controller);
                        }

                        // For eSign pages, nudge initial scroll slightly so
                        // important inputs are not hidden under the keyboard.
                        try {
                          final uri = Uri.tryParse(urlStr);
                          if (uri != null) {
                            final host = uri.host.toLowerCase();
                            final isCloudesign = host.contains('cloudesign');
                            final isNsdlEsign = host.contains('esign.egov.proteantech.in') ||
                                host.startsWith('esign.');
                            if (!_esignScrollAdjusted &&
                                (isCloudesign || isNsdlEsign)) {
                              _esignScrollAdjusted = true;
                              await controller.scrollTo(x: 0, y: 260);
                              await controller.evaluateJavascript(
                                source: 'try { window.scrollTo(0, 260); } catch(e) {}',
                              );
                            }
                          }
                        } catch (e) {
                          debugPrint(
                              '[WebView] Error adjusting scroll for eSign: $e');
                        }

                        if (_isIpvOrFaceFinderUrl(urlStr) &&
                            _permissionsRequested &&
                            !_hasReloadedAfterPermissions) {
                          Future.delayed(const Duration(milliseconds: 300),
                              () {
                            if (mounted &&
                                _currentUrl == urlStr &&
                                !_hasReloadedAfterPermissions) {
                              _hasReloadedAfterPermissions = true;
                              debugPrint(
                                  '[WebView] Reloading IPV page after permission grant');
                              controller.reload();
                            }
                          });
                        }

                        await _onPageFinished(urlStr);
                        await _applyDigilockerScrollGuards(controller, url: urlStr);
                        if (_shouldInjectNoAutoScrollJs(urlStr)) {
                          await _injectNoAutoScrollJs(controller, url: urlStr);
                        }
                        await _applyAccountAggregatorWebViewSettings(
                          controller,
                          url: urlStr,
                        );
                        await _injectAccountAggregatorViewportFix(
                          controller,
                          url: urlStr,
                        );
                        await _injectAccountAggregatorKeyboardAssist(
                          controller,
                          url: urlStr,
                        );
                        if (_isReversePennyDropUrl(urlStr)) {
                          if (!_rpdSigningSessionFlagReset) {
                            try {
                              await controller.evaluateJavascript(
                                source:
                                    'try { sessionStorage.removeItem("meon_rpd_signing_reloaded"); } catch(e) {}',
                              );
                            } catch (_) {}
                            _rpdSigningSessionFlagReset = true;
                          }
                          // Force re-inject after SPA paint (versioned bridge is idempotent).
                          try {
                            await controller.evaluateJavascript(
                              source:
                                  'window.__meonRpdFixV4 = false;',
                            );
                          } catch (_) {}
                          await _injectRpdAppLinkBridge(controller);
                          await _injectRpdConsoleSigningReload(controller);
                          await _injectRpdTimerOverride(controller);
                        }

                        // Reverse Penny Drop: completion params in URL → next KYC step.
                        await _tryCompleteRpdFromUrl(
                          urlStr,
                          reason: 'onLoadStop',
                        );
                      }
                    },
                    onPermissionRequest: (controller, request) async {
                      debugPrint(
                          '[WebView] Permission requested (camera/mic): ${request.resources}');
                      return PermissionResponse(
                        resources: request.resources,
                        action: PermissionResponseAction.GRANT,
                      );
                    },
                    onGeolocationPermissionsShowPrompt:
                        (controller, origin) async {
                      debugPrint(
                          '[WebView] Geolocation permission requested for: $origin');
                      if (_permissionsRequested ||
                          _permissionRequestScheduled ||
                          _permissionHandlerInFlight) {
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin,
                          allow: true,
                          retain: true,
                        );
                      }

                      final locationStatus = await Permission.location.status;
                      if (locationStatus.isGranted ||
                          locationStatus.isLimited) {
                        debugPrint(
                            '[WebView] Location permission already granted - allowing geolocation');
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin,
                          allow: true,
                          retain: true,
                        );
                      }

                      debugPrint(
                          '[WebView] Location permission not granted - requesting...');
                      if (_permissionHandlerInFlight) {
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin,
                          allow: true,
                          retain: true,
                        );
                      }

                      _permissionHandlerInFlight = true;
                      try {
                        final result = await Permission.location.request();
                        final granted = result.isGranted || result.isLimited;
                        debugPrint(
                          granted
                              ? '[WebView] Location permission granted - allowing geolocation'
                              : '[WebView] Location permission denied - denying geolocation',
                        );
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin,
                          allow: granted,
                          retain: granted,
                        );
                      } catch (e) {
                        debugPrint(
                            '[WebView] Location permission request failed: $e');
                        return GeolocationPermissionShowPromptResponse(
                          origin: origin,
                          allow: false,
                          retain: false,
                        );
                      } finally {
                        _permissionHandlerInFlight = false;
                      }
                    },
                  ),

            // Popup overlay WebView for reverse_pennydrop (Digio window.open)
            if (_popupWindowId != null)
              Positioned.fill(
                child: Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: FractionallySizedBox(
                    widthFactor: 0.95,
                    heightFactor: 0.9,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: InAppWebView(
                        windowId: _popupWindowId,
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          mediaPlaybackRequiresUserGesture: false,
                          allowsInlineMediaPlayback: true,
                          useHybridComposition: true,
                          supportZoom: false,
                          // Enable geolocation for popup WebView as well
                          geolocationEnabled: true,
                        ),
                        onConsoleMessage: (controller, consoleMessage) {},
                        shouldOverrideUrlLoading:
                            (controller, navigationAction) async {
                          final uri = navigationAction.request.url;
                          if (uri == null) {
                            return NavigationActionPolicy.ALLOW;
                          }
                          final url = uri.toString();
                          _wvLog('[WebView][Popup] Navigation request: $url');
                          
                          // Always cancel intent: URLs on Android to prevent ERR_UNKNOWN_URL_SCHEME error
                          if (Platform.isAndroid && url.toLowerCase().startsWith('intent:')) {
                            _wvLog('[WebView][Popup] Intent URL detected - handling externally');
                            await _handleExternalUrl(url);
                            return NavigationActionPolicy.CANCEL;
                          }
                          
                          if (_shouldHandleExternally(url)) {
                            final handled = await _handleExternalUrl(url);
                            if (handled) {
                              _wvLog(
                                  '[WebView][Popup] External URL handled by app, cancelling WebView navigation');
                              return NavigationActionPolicy.CANCEL;
                            }
                          }

                          // Digio can navigate/complete by updating query params within the popup.
                          _captureCompletionParamsIfApplicable(url);
                          if (await _tryCompleteRpdFromUrl(
                            url,
                            reason: 'popup shouldOverrideUrlLoading',
                          )) {
                            return NavigationActionPolicy.CANCEL;
                          }

                          return NavigationActionPolicy.ALLOW;
                        },
                        onLoadError: (controller, url, code, message) {
                          final errorUrl = url?.toString() ?? '';
                          if (code == -10 &&
                              message.contains('net::ERR_UNKNOWN_URL_SCHEME') &&
                              _isPaymentDeepLink(errorUrl) &&
                              !_shouldBlockGenericUpiFallback(errorUrl)) {
                            unawaited(_handleExternalUrl(errorUrl));
                            return;
                          }
                          _wvLog(
                              '[WebView][Popup] Load error ($code): $message, url=$url');
                        },
                        onLoadStop: (controller, url) async {
                          if (url != null) {
                            final urlStr = url.toString();
                            if (_shouldInjectNoAutoScrollJs(urlStr)) {
                              await _injectNoAutoScrollJs(controller, url: urlStr);
                            }
                            await _applyAccountAggregatorWebViewSettings(
                              controller,
                              url: urlStr,
                            );
                            await _injectAccountAggregatorViewportFix(
                              controller,
                              url: urlStr,
                            );
                            await _injectAccountAggregatorKeyboardAssist(
                              controller,
                              url: urlStr,
                            );

                            if (_isReversePennyDropUrl(urlStr)) {
                              if (!_rpdSigningSessionFlagReset) {
                                try {
                                  await controller.evaluateJavascript(
                                    source:
                                        'try { sessionStorage.removeItem("meon_rpd_signing_reloaded"); } catch(e) {}',
                                  );
                                } catch (_) {}
                                _rpdSigningSessionFlagReset = true;
                              }
                              await _injectRpdConsoleSigningReload(controller);
                              await _injectRpdTimerOverride(controller);
                            }

                            // Digio gateway popup (app.digio.in/#/gateway/...)
                            // hosts the visible 5-min countdown when the user
                            // is entering UPI ID / picking an app, so we need
                            // to inject the override here too.
                            if (_isDigioGatewayUrl(urlStr)) {
                              await _injectRpdTimerOverride(controller);
                            }
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),

            // Full-screen loader overlay — covers WebView until page is ready.
            // AnimatedOpacity fades it out smoothly on first load completion.
            if (_isLoading)
              Positioned.fill(
                child: AnimatedOpacity(
                  opacity: _isLoading ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
            if (_isLoading)
              Positioned.fill(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: KycTheme.primary,
                        ),
                      ),
                      const SizedBox(height: 20),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          _loadingMessage,
                          key: ValueKey(_loadingMessage),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Error overlay — shown on network failure, resource error, or timeout.
            // Sits above the WebView so no partial content is ever visible.
            // Does NOT navigate back to HomePage; user can retry from here.
            if (_hasError)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.white,
                  child: SafeArea(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.wifi_off_rounded,
                              size: 72,
                              color: Colors.grey.shade400,
                            ),
                            const SizedBox(height: 20),
                            Text(
                              _errorMessage,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: Colors.grey.shade700,
                                height: 1.5,
                              ),
                            ),
                            const SizedBox(height: 28),
                            ElevatedButton.icon(
                              icon: const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text(
                                'Try Again',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: KycTheme.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 32, vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                elevation: 0,
                              ),
                              onPressed:
                                  _isLoading ? null : _retryFromErrorOverlay,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      ),
      ),
    );
  }
}
