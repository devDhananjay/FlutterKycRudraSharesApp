import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Reusable button that shows inline loading state without blocking the UI.
/// 
/// Usage:
/// ```dart
/// LoadingButton(
///   onPressed: _handleSubmit,
///   isLoading: _submitLoading,
///   label: 'Submit',
///   loadingLabel: 'Submitting...',
/// )
/// ```
class LoadingButton extends StatelessWidget {
  /// Button label when not loading
  final String label;
  
  /// Button label when loading (e.g., "Submitting...", "Processing...", "Verifying...")
  final String? loadingLabel;
  
  /// Whether the button is currently loading
  final bool isLoading;
  
  /// Callback when button is pressed (null when loading or disabled)
  final VoidCallback? onPressed;
  
  /// Custom styling
  final ButtonStyle? style;
  
  /// Button width (default: match parent)
  final double? width;
  
  /// Button height (default: 48)
  final double height;
  
  /// Icon to show before label (optional)
  final IconData? icon;
  
  /// Text style for label
  final TextStyle? textStyle;
  
  /// Loading spinner color (default: white)
  final Color spinnerColor;
  
  const LoadingButton({
    super.key,
    required this.label,
    this.loadingLabel,
    this.isLoading = false,
    this.onPressed,
    this.style,
    this.width,
    this.height = 48,
    this.icon,
    this.textStyle,
    this.spinnerColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: style ??
            ElevatedButton.styleFrom(
              backgroundColor: KycTheme.primary,
              disabledBackgroundColor: KycTheme.primary.withValues(alpha: 0.6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(KycTheme.radiusMd),
              ),
              elevation: 0,
            ),
        child: isLoading
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: spinnerColor,
                    ),
                  ),
                  if (loadingLabel != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      loadingLabel!,
                      style: textStyle ??
                          const TextStyle(
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
                    style: textStyle ??
                        const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Compact version of LoadingButton for inline actions (e.g., "Resend OTP")
class LoadingTextButton extends StatelessWidget {
  final String label;
  final String? loadingLabel;
  final bool isLoading;
  final VoidCallback? onPressed;
  final TextStyle? textStyle;
  final Color? spinnerColor;

  const LoadingTextButton({
    super.key,
    required this.label,
    this.loadingLabel,
    this.isLoading = false,
    this.onPressed,
    this.textStyle,
    this.spinnerColor,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: spinnerColor ?? KycTheme.primary,
            ),
          ),
          if (loadingLabel != null) ...[
            const SizedBox(width: 8),
            Text(
              loadingLabel!,
              style: textStyle ??
                  TextStyle(
                    fontSize: 14,
                    color: KycTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ],
        ],
      );
    }

    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: textStyle ??
            TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: KycTheme.primary,
              decoration: TextDecoration.underline,
            ),
      ),
    );
  }
}
