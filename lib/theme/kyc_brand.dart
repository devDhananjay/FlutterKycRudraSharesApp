import 'package:meon_kyc/config/env_config.dart';

/// Multi-client branding for the shared KYC app (BP Wealth, Rudra, …).
///
/// Route `/:company/...` and [EnvConfig.companyName] drive which skin is active.
class KycBrand {
  KycBrand._();

  static String _company =
      EnvConfig.companyName.toLowerCase().trim();

  static String get company => _company;

  static void setCompany(String? company) {
    final next = (company ?? EnvConfig.companyName).toLowerCase().trim();
    if (next.isEmpty) return;
    _company = next;
  }

  static bool get isRudra => _company == 'rudra';

  static bool get isBpWealth =>
      _company == 'bpwealth' || _company == 'bp_wealth';

  /// Display name for chrome / dialogs.
  static String get displayName {
    if (isRudra) return 'Rudra Shares';
    if (isBpWealth) return 'BP Wealth';
    return 'KYC';
  }

  static String get appTitle {
    if (isRudra) return 'Rudra Shares KYC';
    if (isBpWealth) return 'BP Wealth KYC';
    return 'Meon KYC';
  }
}
