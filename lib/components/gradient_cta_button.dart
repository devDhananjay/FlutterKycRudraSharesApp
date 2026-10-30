import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Full-width primary CTA with Rudra red→orange gradient (Figma).
class GradientCtaButton extends StatelessWidget {
  final String label;
  final String? loadingLabel;
  final bool isLoading;
  final bool enabled;
  final VoidCallback? onPressed;
  final double height;
  final IconData? icon;

  const GradientCtaButton({
    super.key,
    required this.label,
    this.loadingLabel,
    this.isLoading = false,
    this.enabled = true,
    this.onPressed,
    this.height = 52,
    this.icon,
  });

  bool get _canPress => enabled && !isLoading && onPressed != null;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: _canPress || isLoading ? 1 : 0.55,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _canPress ? onPressed : null,
          borderRadius: BorderRadius.circular(KycTheme.radiusMd),
          child: Ink(
            height: height,
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: _canPress || isLoading
                  ? KycTheme.ctaGradient
                  : const LinearGradient(
                      colors: [
                        KycTheme.buttonDisabledPurple,
                        KycTheme.buttonDisabledPurple,
                      ],
                    ),
              borderRadius: BorderRadius.circular(KycTheme.radiusMd),
            ),
            child: Center(
              child: isLoading
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        if (loadingLabel != null) ...[
                          const SizedBox(width: 12),
                          Text(
                            loadingLabel!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, color: Colors.white, size: 20),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
