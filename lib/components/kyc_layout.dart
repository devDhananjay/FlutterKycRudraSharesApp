import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/components/documents_handy_section.dart';
import 'package:meon_kyc/utils/assets.dart';

/// KYC screen layout — Rudra Figma: peach wash, brand hero, content, documents.
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

  bool get _isStartKycHero {
    if (title == null) return false;
    final lower = title!.toLowerCase();
    return lower.contains('start your kyc');
  }

  /// Builds the page title section.
  Widget _buildTitleSection() {
    if (title == null) return const SizedBox.shrink();

    final rawTitle = title!.trim();
    final lower = rawTitle.toLowerCase();
    final hasStartKyc = lower.contains('start your kyc');

    if (hasStartKyc) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: const [
          Text(
            'Start your KYC',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: KycTheme.textPrimary,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Fast-track your 100% paperless Demat & Trading account opening in under 5 minutes.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: KycTheme.textSecondary,
              height: 1.4,
            ),
          ),
        ],
      );
    }

    return Text(
      rawTitle,
      style: const TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: KycTheme.textPrimary,
      ),
    );
  }

  Widget _buildBrandMark() {
    return Image.asset(
      AppAssets.rudraLogo,
      height: 88,
      fit: BoxFit.contain,
      errorBuilder: (_, __, ___) => const _RudraBrandFallback(),
    );
  }

  Widget _buildContent() {
    if (skipScaffold) {
      final isFirstStep = _isStartKycHero;
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
                const SizedBox(height: 12),
                Center(child: _buildBrandMark()),
                const SizedBox(height: 36),
              ],
              if (title != null) ...[
                if (!isFirstStep) const SizedBox(height: 12),
                _buildTitleSection(),
                SizedBox(height: isFirstStep ? 28 : 16),
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

    return Column(
      children: [
        _buildTopBar(),
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
                    _buildTitleSection(),
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
      return content;
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: KycTheme.statusBar,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
          decoration: const BoxDecoration(gradient: KycTheme.pageGradient),
          child: SafeArea(child: content),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
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

class _RudraBrandFallback extends StatelessWidget {
  const _RudraBrandFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [KycTheme.brandGold, Color(0xFFF5C542)],
        ),
        boxShadow: KycTheme.cardShadowSm,
      ),
      child: const Icon(Icons.spa_rounded, color: Colors.white, size: 32),
    );
  }
}
