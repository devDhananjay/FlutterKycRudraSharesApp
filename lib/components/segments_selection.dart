import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Trading segments selection UI as per design.
/// BugFixes: grid shows only NSE/BSE cash, FO, SLBM, MF (no MTF / currency columns) —
/// submit payload matches via [HomePage] `_prepareFormData` (mtf/currency false).
///
/// UX: when user toggles NSE FO / BSE FO from OFF -> ON, show a one-time
/// reminder modal listing the financial documents required to enable FO.
///
/// Brokerage Plan: optional to view — Next is never blocked on brokerage click.
class SegmentsSelection extends StatefulWidget {
  final Map<String, dynamic> formData;
  final void Function(String name, dynamic value) onChange;
  final VoidCallback? onViewBrokeragePlan;
  final VoidCallback? onSubmit;
  final bool submitLoading;
  /// Whether the user has viewed/selected the brokerage plan
  final bool hasBrokeragePlanSelected;

  const SegmentsSelection({
    super.key,
    required this.formData,
    required this.onChange,
    this.onViewBrokeragePlan,
    this.onSubmit,
    this.submitLoading = false,
    this.hasBrokeragePlanSelected = false,
  });

  @override
  State<SegmentsSelection> createState() => _SegmentsSelectionState();
}

class _SegmentsSelectionState extends State<SegmentsSelection> {
  static const Set<String> _foKeys = {'nse_fo', 'bse_fo'};
  /// Mandatory segments (live parity): always on, user cannot untick.
  static const Set<String> _lockedSegmentKeys = {
    'nse_cash',
    'bse_cash',
    'mf',
  };
  /// Always off; user cannot select.
  /// Keep for when NSE SLBM checkbox is re-enabled in the UI below.
  static const Set<String> _disabledOffSegmentKeys = {
    // 'nse_slbm',
  };
  static const _linkBlue = Color(0xFF2563EB);

  bool _getValue(String key) {
    final val = widget.formData[key];
    if (val == null) return false;
    if (val is bool) return val;
    final str = val.toString().toLowerCase();
    return str == 'true' || str == '1' || str == 'yes';
  }

  bool _coerceBool(dynamic value) {
    if (value is bool) return value;
    if (value == null) return false;
    final str = value.toString().toLowerCase();
    return str == 'true' || str == '1' || str == 'yes';
  }

  void _handleSegmentChange(String name, dynamic value) {
    if (_disabledOffSegmentKeys.contains(name)) {
      return;
    }
    if (_lockedSegmentKeys.contains(name) && !_coerceBool(value)) {
      return;
    }
    final wasEnabled = _getValue(name);
    final willEnable = _coerceBool(value);

    // NSE FO / BSE FO: show reminder first; tick only after user taps OK.
    if (_foKeys.contains(name) && !wasEnabled && willEnable) {
      _promptFoEnable(name);
      return;
    }

    widget.onChange(name, value);
  }

  Future<void> _promptFoEnable(String name) async {
    final confirmed = await _showFoFinancialDocsModal();
    if (!mounted || confirmed != true) return;
    // Apply after dialog closes so we don't notify during the pop frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onChange(name, true);
    });
  }

  Future<bool?> _showFoFinancialDocsModal() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Please upload any one of the following financial '
                  'documents (required only if selected):',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: KycTheme.textPrimary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                const _FoDocBullet(text: 'Last 6 months bank statement'),
                const _FoDocBullet(
                    text: 'Latest Income Tax Return (ITR) acknowledgement'),
                const _FoDocBullet(
                    text: 'Form 16 or salary slips for the last 3 months'),
                const _FoDocBullet(text: 'CA-certified Net Worth Certificate'),
                const _FoDocBullet(text: 'Latest Demat Holding Statement'),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: KycTheme.buttonEnabledPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'OK',
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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    const segmentRows = <List<_CheckboxItem>>[
      [
        _CheckboxItem(label: 'NSE CASH', key: 'nse_cash'),
        _CheckboxItem(label: 'BSE CASH', key: 'bse_cash'),
      ],
      [
        _CheckboxItem(label: 'NSE FO', key: 'nse_fo'),
        _CheckboxItem(label: 'BSE FO', key: 'bse_fo'),
      ],
      [
        // TODO: uncomment to show NSE SLBM again
        // _CheckboxItem(label: 'NSE SLBM', key: 'nse_slbm'),
        _CheckboxItem(label: 'MF', key: 'mf'),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: Text(
            'Select Your Preferred\nSegments',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: KycTheme.textPrimary,
              height: 1.25,
            ),
          ),
        ),
        const SizedBox(height: 24),
        ...segmentRows.map((pair) {
          Widget buildItem(_CheckboxItem item) {
            return _buildCheckbox(
              label: item.label,
              value: _lockedSegmentKeys.contains(item.key)
                  ? true
                  : _disabledOffSegmentKeys.contains(item.key)
                      ? false
                      : _getValue(item.key),
              locked: _lockedSegmentKeys.contains(item.key) ||
                  _disabledOffSegmentKeys.contains(item.key),
              onChanged: (v) => _handleSegmentChange(item.key, v),
            );
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: buildItem(pair[0])),
                const SizedBox(width: 16),
                Expanded(
                  child: pair.length > 1
                      ? buildItem(pair[1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: 8),
        if (widget.onViewBrokeragePlan != null) ...[
          Center(
            child: TextButton(
              onPressed: widget.onViewBrokeragePlan,
              style: TextButton.styleFrom(
                foregroundColor: _linkBlue,
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'View Brokerage Plan',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  decoration: TextDecoration.underline,
                  decorationColor: _linkBlue,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Brokerage plan applied (optional to view)',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: KycTheme.success,
              ),
            ),
          ),
          const SizedBox(height: 24),
        ] else
          const SizedBox(height: 16),

        if (widget.onSubmit != null)
          ElevatedButton(
            onPressed: widget.submitLoading ? null : widget.onSubmit,
            style: ElevatedButton.styleFrom(
              backgroundColor: KycTheme.primary,
              disabledBackgroundColor: KycTheme.primary.withValues(alpha: 0.5),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: widget.submitLoading
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(width: 12),
                      Text(
                        'Processing...',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  )
                : const Text(
                    'Next',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
      ],
    );
  }

  Widget _buildCheckbox({
    required String label,
    required bool value,
    required void Function(bool) onChanged,
    bool locked = false,
  }) {
    // Locked segments: non-interactive, but look the same as normal checkboxes
    // (no greyed-out / disabled styling).
    return InkWell(
      onTap: locked ? null : () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: value ? KycTheme.buttonEnabledPurple : Colors.transparent,
              border: Border.all(
                color: KycTheme.buttonEnabledPurple,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: value
                ? const Icon(
                    Icons.check,
                    size: 12,
                    color: Colors.white,
                  )
                : null,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: KycTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckboxItem {
  final String label;
  final String key;

  const _CheckboxItem({required this.label, required this.key});
}

class _FoDocBullet extends StatelessWidget {
  final String text;
  const _FoDocBullet({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7, right: 10, left: 4),
            child: SizedBox(
              width: 5,
              height: 5,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: KycTheme.textPrimary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: KycTheme.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
