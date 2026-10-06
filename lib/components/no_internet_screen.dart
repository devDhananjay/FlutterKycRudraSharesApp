import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/utils/assets.dart';

/// Full-screen offline UI (STOXBOX splash style).
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
      color: KycTheme.surface,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 48),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.asset(
                  AppAssets.stoxboxLogo,
                  height: 96,
                  fit: BoxFit.contain,
                ),
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
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: isRetrying ? null : onRetry,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: KycTheme.buttonEnabledPurple,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: KycTheme.buttonDisabledPurple,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: 0,
                        ),
                        child: isRetrying
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : const Text(
                                'Retry',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  'BP Equities Pvt Ltd (SEBI Regn No: INZ000176730, BSE: 6744, NSE: 90309). '
                  'Copyright © 2023 BP Group. All rights reserved.',
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
    );
  }
}
