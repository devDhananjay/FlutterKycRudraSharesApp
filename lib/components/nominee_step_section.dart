import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/utils/conditional_flow.dart';
import 'package:meon_kyc/utils/field_validators.dart';

/// Web-parity nominee step chrome: dashed Add/Remove nominee + optional add-more buttons.
class NomineeStepSection {
  NomineeStepSection._();

  static const String _maxNomineesHint = 'You can add maximum of 10 nominees';

  static Widget _dashedActionCard({
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Material(
      color: const Color(0xFFF8F9FB),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KycTheme.radiusMd),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KycTheme.radiusMd),
        child: CustomPaint(
          painter: _DashedBorderPainter(
            color: const Color(0xFFB8BEC8),
            radius: KycTheme.radiusMd,
          ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
            child: Center(child: child),
          ),
        ),
      ),
    );
  }

  static Widget primaryToggle({
    required bool addingNominee,
    required VoidCallback onAdd,
    required VoidCallback onRemove,
  }) {
    return _dashedActionCard(
      onTap: addingNominee ? onRemove : onAdd,
      child: Text(
        addingNominee ? '− Remove Nominee' : '+ Add Nominee (Optional)',
        style: const TextStyle(
          fontSize: KycTheme.fontSizeBodyLg,
          fontWeight: FontWeight.w700,
          color: KycTheme.primary,
        ),
      ),
    );
  }

  static Widget maxNomineesHint() {
    return const Padding(
      padding: EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        _maxNomineesHint,
        style: TextStyle(
          fontSize: KycTheme.fontSizeCaption,
          color: KycTheme.textSecondary,
        ),
      ),
    );
  }

  /// Landing UI when user has not chosen to add a nominee.
  static Widget optOutLanding({
    required bool checked,
    required VoidCallback onToggle,
    required VoidCallback onDeclarationTap,
  }) {
    return _NomineeOptOutLanding(
      checked: checked,
      onToggle: onToggle,
      onDeclarationTap: onDeclarationTap,
    );
  }

  static Future<void> showOptOutDeclarationDialog(BuildContext context) {
    const bodyStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: Color(0xFF475569),
      height: 1.5,
    );
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: const Color(0x80000000),
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 28),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 360,
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.8,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(top: 4, right: 8),
                          child: Text(
                            'Declaration for Opting-out of Nomination',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: KycTheme.textPrimary,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        icon: const Icon(
                          Icons.close,
                          size: 20,
                          color: KycTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                  const Flexible(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.only(right: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(height: 8),
                          Text(
                            'I hereby confirm that I do not wish to appoint any nominee(s) to my demat account/mutual fund folio at this point of time.',
                            style: bodyStyle,
                          ),
                          SizedBox(height: 12),
                          Text(
                            'I understand that -',
                            style: bodyStyle,
                          ),
                          SizedBox(height: 8),
                          _DeclarationBullet(
                            index: 'i.',
                            text:
                                'The nomination helps to quickly identify the person for transfer of securities to my legal heir(s) by my demise.',
                          ),
                          SizedBox(height: 8),
                          _DeclarationBullet(
                            index: 'ii.',
                            text:
                                'In the absence of a nomination, my legal heir(s) may require the submission of certain additional legal or court-issued documents which may delay the process of transmission of securities to my legal heir(s).',
                          ),
                          SizedBox(height: 8),
                          _DeclarationBullet(
                            index: 'iii.',
                            text:
                                'If no claim is made on the account/folio for a prolonged period after my demise, the holdings may be transferred to Investor Education and Protection Fund Authority (IEPF) in accordance with the applicable regulatory framework.',
                          ),
                          SizedBox(height: 12),
                          Text(
                            'I confirm that I have understood the above implications and that my decision to opt out of nomination is voluntary.',
                            style: bodyStyle,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: KycTheme.buttonEnabledPurple,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 48),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(KycTheme.radiusSm),
                        ),
                      ),
                      child: const Text(
                        'I Understand',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Styled "+ Add Nominee (optional)" for `add_2_nominee` / `add_4_nominee` etc.
  static Widget optionalAddCheckboxButton({
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _dashedActionCard(
        onTap: onTap,
        child: RichText(
          text: TextSpan(
            style: const TextStyle(
              fontSize: KycTheme.fontSizeBodyLg,
              fontWeight: FontWeight.w700,
              color: KycTheme.primary,
            ),
            children: const [
              TextSpan(text: '+ Add Nominee'),
              TextSpan(
                text: ' (optional)',
                style: TextStyle(
                  fontSize: KycTheme.fontSizeCaption,
                  fontWeight: FontWeight.w500,
                  color: KycTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether a field belongs in the nominee block (not toggle / consent / backend).
  static bool isNomineeFormContentField(String name) {
    if (isNomineeAddNomineeDropdownField(name)) return false;
    if (isNomineeOptOutConsentField(name)) return false;
    if (isNomineeBackendOnlyField(name)) return false;
    return true;
  }

  /// Hide styled add checkbox once the user has opened that nominee slot.
  static bool shouldRenderStyledAddCheckbox({
    required String name,
    required Map<String, dynamic> formData,
  }) {
    if (!isNomineeStyledAddCheckboxField(name)) return false;
    return !isCheckboxCheckedValue(formData[name]);
  }
}

class _NomineeOptOutLanding extends StatefulWidget {
  const _NomineeOptOutLanding({
    required this.checked,
    required this.onToggle,
    required this.onDeclarationTap,
  });

  final bool checked;
  final VoidCallback onToggle;
  final VoidCallback onDeclarationTap;

  @override
  State<_NomineeOptOutLanding> createState() => _NomineeOptOutLandingState();
}

class _NomineeOptOutLandingState extends State<_NomineeOptOutLanding> {
  bool _ignoreCardTap = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Add Nominee',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: KycTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Do you want to Add Nominee (Optional)?',
          style: TextStyle(
            fontSize: KycTheme.fontSizeBody,
            fontWeight: FontWeight.w400,
            color: KycTheme.textSecondary,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        Material(
          color: KycTheme.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: KycTheme.border),
          ),
          child: InkWell(
            onTap: () {
              if (_ignoreCardTap) {
                _ignoreCardTap = false;
                return;
              }
              widget.onToggle();
            },
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: IgnorePointer(
                        child: Checkbox(
                          value: widget.checked,
                          onChanged: (_) {},
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                          side: const BorderSide(
                            color: KycTheme.border,
                            width: 1.6,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        const Text(
                          'I am opting out of adding nominee at this time and can add them later (optional). ',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.5,
                            color: Color(0xFF334155),
                          ),
                        ),
                        GestureDetector(
                          onTapDown: (_) => _ignoreCardTap = true,
                          onTap: () {
                            widget.onDeclarationTap();
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _ignoreCardTap = false;
                            });
                          },
                          behavior: HitTestBehavior.opaque,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              'Declaration',
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: KycTheme.primary,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                                decorationColor: KycTheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DeclarationBullet extends StatelessWidget {
  const _DeclarationBullet({
    required this.index,
    required this.text,
  });

  final String index;
  final String text;

  @override
  Widget build(BuildContext context) {
    const bodyStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: Color(0xFF475569),
      height: 1.5,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          child: Text(index, style: bodyStyle),
        ),
        Expanded(
          child: Text(text, style: bodyStyle),
        ),
      ],
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({
    required this.color,
    required this.radius,
  });

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.6, 0.6, size.width - 1.2, size.height - 1.2),
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dashWidth = 6.0;
    const dashSpace = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = distance + dashWidth;
        canvas.drawPath(
          metric.extractPath(distance, end.clamp(0.0, metric.length)),
          paint,
        );
        distance = end + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.radius != radius;
  }
}
