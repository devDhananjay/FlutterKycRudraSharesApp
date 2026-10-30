/// Environment configuration for API URLs and default workflow
class EnvConfig {
  static const String apiUrlLocal = 'https://live.meon.co.in';
  static const String apiUrl = 'https://live.meon.co.in';
  static const String ssoSecretKey = 'IBZmvgxvGUHgxNVpoXoK1c3fFVL76P0j';

  /// LeadSquared proxy — post-SSO lead capture (Meon live API).
  static const String leadSquaredCaptureUrl =
      'https://ekyc.stoxbox.in/leadsquared_api/bp';

  /// Default company and workflow (static for now)
  static const String companyName = 'rudra';
  static const String workflowName = 'in_app'; //'app_test'; individual


  static String get baseUrl {
    // In Flutter you can use kDebugMode or Platform to detect environment
    return apiUrl;
  }
}