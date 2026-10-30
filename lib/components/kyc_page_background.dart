import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Figma Light-Mode wash: soft peach gradient + faint concentric rings.
class KycPageBackground extends StatelessWidget {
  final Widget child;

  const KycPageBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: KycTheme.pageGradient),
      child: CustomPaint(
        painter: _ConcentricCirclesPainter(),
        child: child,
      ),
    );
  }
}

class _ConcentricCirclesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..color = const Color(0xFFE8D5C8).withValues(alpha: 0.55);

    // Rings rise from bottom-center like Figma.
    final center = Offset(size.width * 0.5, size.height * 1.05);
    for (var i = 1; i <= 8; i++) {
      canvas.drawCircle(center, size.width * (0.22 * i), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
