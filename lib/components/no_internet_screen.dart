import 'package:flutter/material.dart';
import 'package:meon_kyc/components/gradient_cta_button.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/utils/assets.dart';

/// Full-screen offline UI (Rudra peach wash).
class NoInternetScreen extends StatelessWidget {
  final VoidCallback onRetry;
  final bool isRetrying;

  const NoInternetScreen({
    super.key,
    required this.onRetry,
    this.isRetrying = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: const BoxDecoration(gradient: KycTheme.pageGradient),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 48),
                Image.asset(
                  AppAssets.rudraLogo,
                  height: 88,
                  fit: BoxFit.contain,
                ),
                const Spacer(),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: KycTheme.cardShadow,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Low internet connection.\nKindly retry',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey.shade700,
                          height: 1.45,
                        ),
                      ),
                      const SizedBox(height: 24),
                      GradientCtaButton(
                        label: 'Retry',
                        isLoading: isRetrying,
                        onPressed: onRetry,
                        height: 48,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'Rudra Shares. For support with your KYC, please retry when online.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.35,
                      color: Colors.grey.shade700.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  isRetrying
                      ? 'Checking connection, please wait...'
                      : 'Setting things up, please wait...',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade800.withValues(alpha: 0.9),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
