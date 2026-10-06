/// SSO mobile/email — static for now; replace when host app passes credentials.
class SsoCredentials {
  final String mobileNumber;
  final String email;

  const SsoCredentials({
    required this.mobileNumber,
    required this.email,
  });
}

/// Static SSO credentials (change here or wire from host app later).
const SsoCredentials kSsoStaticCredentials = SsoCredentials(
  mobileNumber: '9411441937',
  email: 'dhananjay@meon.co.in',
);

SsoCredentials resolveSsoCredentials() => kSsoStaticCredentials;

/// Hide "securely encrypted" footer on host-app onboarding screens.
const bool kHideOnboardingFormFooter = true;
