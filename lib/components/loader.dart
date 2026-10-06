import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Lightweight, non-intrusive loader for necessary loading states
/// (e.g., initial data fetch, get-context API calls)
/// 
/// Design Goals:
/// - Minimal visual blocking
/// - Uses app theme colors
/// - Clear, friendly messaging
/// - Smooth animations
class Loader extends StatelessWidget {
  final String message;
  /// When true, shows a simpler inline loader without the white card
  final bool minimal;

  const Loader({
    super.key, 
    this.message = 'Loading your data...',
    this.minimal = false,
  });

  @override
  Widget build(BuildContext context) {
    if (minimal) {
      // Minimal version: just spinner + text, no card, less intrusive
      return Container(
        color: KycTheme.background,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: KycTheme.primary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: KycTheme.textSecondary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Standard version: with subtle card for important loading states
    return Container(
      // Very transparent background so users can see content behind
      color: KycTheme.background.withValues(alpha: 0.95),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
          margin: const EdgeInsets.symmetric(horizontal: 32),
          constraints: const BoxConstraints(maxWidth: 280),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Spinner with theme color
              SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                  strokeWidth: 3.5,
                  color: KycTheme.primary,
                ),
              ),
              const SizedBox(height: 18),
              // Friendly message
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: KycTheme.textPrimary,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
