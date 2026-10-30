import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:meon_kyc/components/no_internet_screen.dart';
import 'package:meon_kyc/services/connectivity_controller.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/utils/assets.dart';

/// Keeps the app mounted and covers it with offline UI when disconnected.
class AppConnectivityGate extends StatefulWidget {
  final Widget child;

  const AppConnectivityGate({super.key, required this.child});

  @override
  State<AppConnectivityGate> createState() => _AppConnectivityGateState();
}

class _AppConnectivityGateState extends State<AppConnectivityGate> {
  bool _retrying = false;

  Future<void> _onRetry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await context.read<ConnectivityController>().recheck();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ConnectivityController>(
      builder: (context, connectivity, _) {
        return Stack(
          children: [
            widget.child,
            if (connectivity.isChecking)
              const Positioned.fill(child: _ConnectivitySplashLoader()),
            if (connectivity.showNoInternet)
              Positioned.fill(
                child: NoInternetScreen(
                  onRetry: _onRetry,
                  isRetrying: _retrying || connectivity.isChecking,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ConnectivitySplashLoader extends StatelessWidget {
  const _ConnectivitySplashLoader();

  @override
  Widget build(BuildContext context) {
    return const Material(
      color: KycTheme.surface,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image(
                image: AssetImage(AppAssets.rudraLogo),
                height: 88,
                fit: BoxFit.contain,
              ),
              SizedBox(height: 28),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: KycTheme.buttonEnabledPurple,
                ),
              ),
              SizedBox(height: 16),
              Text(
                'Setting things up, please wait...',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF475569),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
