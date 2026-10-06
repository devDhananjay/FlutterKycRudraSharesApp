import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/components/documents_handy_section.dart';
import 'package:meon_kyc/components/kyc_stepper_bar.dart';
import 'package:meon_kyc/utils/assets.dart';

/// KYC screen layout from Figma: logo, optional stepper, content, documents section
class KycLayout extends StatelessWidget {
  final Widget child;
  final String? title;
  final List<String>? stepperSteps;
  final int? stepperIndex;
  final Widget? leading;
  final Widget? trailing;
  final bool showDocumentsSection;
  final bool skipScaffold; // When true, skip Scaffold/SafeArea (for nested use)

  const KycLayout({
    super.key,
    required this.child,
    this.title,
    this.stepperSteps,
    this.stepperIndex,
    this.leading,
    this.trailing,
    this.showDocumentsSection = true,
    this.skipScaffold = false,
  });

  /// Builds the page title section.
  /// Special handling for the "Start your KYC" hero title from Figma:
  /// first line bold 24, second line subtitle 14.
  Widget _buildTitleSection() {
    if (title == null) return const SizedBox.shrink();

    final rawTitle = title!.trim();
    final lower = rawTitle.toLowerCase();

    final hasStartKyc = lower.contains('start your kyc');
    final hasPickupCopy = lower.contains('pickup where you left off');

    if (hasStartKyc && hasPickupCopy) {
      // Split into two lines: "Start your KYC" + "or pickup where you left off" (Figma)
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'Start your KYC',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: KycTheme.textPrimary,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'or pickup where you left off',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: KycTheme.textSecondary,
            ),
          ),
        ],
      );
    }

    // Default single-line title for all other pages
    return const Text(
      '',
      // This placeholder will be replaced below; kept here to satisfy const usage.
    );
  }

  Widget _buildContent() {
    if (skipScaffold) {
      // When skipping scaffold, return scrollable content directly (no Expanded)
      // This prevents overflow when used inside Expanded widget
      final isFirstStep = title != null &&
          title!.toLowerCase().contains('start your kyc') &&
          title!.toLowerCase().contains('pickup where you left off');
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          KycTheme.spacingXl,
          KycTheme.spacingLg,
          KycTheme.spacingXl,
          isFirstStep ? KycTheme.spacing3xl : KycTheme.spacingLg,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isFirstStep) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        AppAssets.stoxboxLogo,
                        height: 88,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
              if (title != null) ...[
                const SizedBox(height: 20),
                if (title != null && title!
                    .toLowerCase()
                    .contains('start your kyc') &&
                    title!
                        .toLowerCase()
                        .contains('pickup where you left off'))
                  _buildTitleSection()
                else
                  Text(
                    title!,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: KycTheme.textPrimary,
                    ),
                  ),
                const SizedBox(height: 16),
              ],
              child,
              if (showDocumentsSection) ...[
                const SizedBox(height: 24),
                const DocumentsHandySection(),
              ],
            ],
          ),
        ),
      );
    }
    
    // Default: full layout with Expanded
    return Column(
      children: [
        // Top bar: minimal header (logout/back aligned right)
        _buildTopBar(null),
        // --- Stepper (hidden temporarily) ---
        // Uncomment when re-enabling stepper via stepperSteps / stepperIndex props.
        // if (stepperSteps != null)
        //   KycStepperBar(
        //     steps: stepperSteps!,
        //     currentIndex: stepperIndex ?? 0,
        //   ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: KycTheme.spacingXl,
              vertical: KycTheme.spacingLg,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (title != null) ...[
                    if (title != null && title!
                        .toLowerCase()
                        .contains('start your kyc') &&
                        title!
                            .toLowerCase()
                            .contains('pickup where you left off'))
                      _buildTitleSection()
                    else
                      Text(
                        title!,
                        style: const TextStyle(
                          fontSize: KycTheme.fontSizeTitle,
                          fontWeight: FontWeight.w700,
                          color: KycTheme.textPrimary,
                        ),
                      ),
                    const SizedBox(height: KycTheme.spacingSm),
                  ],
                  child,
                  if (showDocumentsSection) ...[
                    const SizedBox(height: KycTheme.spacing2xl),
                    const DocumentsHandySection(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent();
    
    if (skipScaffold) {
      // When skipping scaffold, just return content (for nested use)
      return content;
    }
    
    // Default: wrap in Scaffold and SafeArea
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: KycTheme.statusBar,
      child: Scaffold(
        backgroundColor: KycTheme.background,
        body: SafeArea(
          child: content,
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext? context) {
    // If nothing to show, avoid taking vertical space
    if (leading == null && trailing == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KycTheme.spacingXl,
        KycTheme.spacingSm,
        KycTheme.spacingXl,
        KycTheme.spacingXs,
      ),
      child: Row(
        children: [
          if (leading != null) leading!,
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

