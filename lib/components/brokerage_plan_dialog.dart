import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Brokerage Plan Dialog as per design
class BrokeragePlanDialog extends StatelessWidget {
  final VoidCallback onDone;

  const BrokeragePlanDialog({
    super.key,
    required this.onDone,
  });

  static Future<void> show(BuildContext context, VoidCallback onDone) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => BrokeragePlanDialog(onDone: onDone),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: double.infinity,
              child: Text(
                'Brokerage Plan Name',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: KycTheme.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 20),
            
            // Equities Section
            const Text(
              'Equities - NSE / BSE',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: KycTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            _buildBulletPoint(
              'Delivery',
              '0.3% (Min. 3p per share whichever is higher)',
            ),
            const SizedBox(height: 8),
            _buildBulletPoint(
              'Trading',
              '0.03% (Min. 3p per share whichever is higher)',
            ),
            const SizedBox(height: 20),
            
            // Futures & Options Section
            const Text(
              'NSE - BSE FO/ Commodity/ Currency',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: KycTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            _buildBulletPoint(
              'Futures',
              '0.03% (Min. 3p per share whichever is higher)',
            ),
            const SizedBox(height: 8),
            _buildBulletPoint(
              'Options',
              '30/lot',
            ),
            const SizedBox(height: 32),
            
            // Done Button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  onDone();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: KycTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Done',
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
    );
  }

  Widget _buildBulletPoint(String title, String value) {
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '• ',
            style: TextStyle(
              fontSize: 14,
              color: KycTheme.textPrimary,
              height: 1.5,
            ),
          ),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  fontSize: 14,
                  color: KycTheme.textPrimary,
                  height: 1.5,
                ),
                children: [
                  TextSpan(
                    text: '$title - ',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(
                    text: value,
                    style: const TextStyle(
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
