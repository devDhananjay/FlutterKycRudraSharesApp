import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Note box from Figma (e.g. Aadhaar linking note on Start your KYC / OTP screens)
class KycNoteBox extends StatelessWidget {
  final String text;
  final String? linkText;
  final VoidCallback? onLinkTap;

  const KycNoteBox({
    super.key,
    required this.text,
    this.linkText,
    this.onLinkTap,
  });

  /// Default Aadhaar note from Figma
  static const String aadhaarNote =
      'Note: Online account opening requires your number to be linked with Aadhaar. '
      'You can check if your mobile number is linked to Aadhaar here. '
      'If your mobile number isn\'t linked to Aadhaar, please open your account offline.';

  @override
  Widget build(BuildContext context) {
    final hasLink = linkText != null && onLinkTap != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(KycTheme.spacingLg),
      decoration: BoxDecoration(
        color: KycTheme.primary.withOpacity(0.06),
        borderRadius: BorderRadius.circular(KycTheme.radiusMd),
        border: Border.all(color: KycTheme.primary.withOpacity(0.2)),
      ),
      child: hasLink
          ? RichText(
              text: TextSpan(
                style: TextStyle(
                  fontSize: KycTheme.fontSizeBody,
                  color: KycTheme.textPrimary,
                  height: 1.4,
                ),
                children: [
                  TextSpan(text: text),
                  TextSpan(
                    text: ' $linkText',
                    style: const TextStyle(
                      color: KycTheme.primary,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: TapGestureRecognizer()..onTap = onLinkTap,
                  ),
                ],
              ),
            )
          : Text(
              text,
              style: TextStyle(
                fontSize: KycTheme.fontSizeBody,
                color: KycTheme.textPrimary,
                height: 1.4,
              ),
            ),
    );
  }
}
