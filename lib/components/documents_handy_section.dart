import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// "Documents to keep Handy" section from Figma (bottom of KYC screens)
class DocumentsHandySection extends StatelessWidget {
  const DocumentsHandySection({super.key});

  static const List<({String label, IconData icon})> _itemsLeft = [
    (label: 'PAN Card', icon: Icons.badge_outlined),
    (label: 'Income Proof', icon: Icons.receipt_long_outlined),
    (label: 'Nominee Proof', icon: Icons.people_outline),
  ];
  static const List<({String label, IconData icon})> _itemsRight = [
    (label: 'Bank Proof', icon: Icons.account_balance_outlined),
    (label: 'Signature', icon: Icons.draw_outlined),
  ];

  Widget _buildDocItem(({String label, IconData icon}) e) {
    return Padding(
      padding: const EdgeInsets.only(bottom: KycTheme.spacingSm),
      child: Row(
        children: [
          Icon(Icons.check_circle, size: 20, color: KycTheme.success),
          const SizedBox(width: KycTheme.spacingSm),
          Text(
            e.label,
            style: TextStyle(
              fontSize: KycTheme.fontSizeBody,
              color: KycTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: KycTheme.spacingXl,
        vertical: KycTheme.spacingLg,
      ),
      decoration: BoxDecoration(
        color: KycTheme.surface,
        borderRadius: BorderRadius.circular(KycTheme.radiusMd),
        border: Border.all(color: KycTheme.border),
        boxShadow: KycTheme.cardShadowSm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Documents to keep Handy',
            style: TextStyle(
              fontSize: KycTheme.fontSizeTitleSm,
              fontWeight: FontWeight.w700,
              color: KycTheme.textPrimary,
            ),
          ),
          const SizedBox(height: KycTheme.spacingMd),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _itemsLeft.map((e) => _buildDocItem(e)).toList(),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _itemsRight.map((e) => _buildDocItem(e)).toList(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
