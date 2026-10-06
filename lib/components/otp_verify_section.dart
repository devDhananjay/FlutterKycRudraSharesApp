import 'dart:async';
import 'package:flutter/material.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/components/otp_input.dart';
import 'package:meon_kyc/components/loading_button.dart';

/// OTP verify block: instruction + Edit, OTP input, resend cooldown, Verify.
/// API `otpExpiry.time` = resend wait in seconds (e.g. "180" → 3 min). `expiryTime` is ignored in UI.
class OtpVerifySection extends StatefulWidget {
  /// Minimum OTP digits required to enable Verify (email & phone both)
  static const int minOtpLength = 6;

  /// e.g. "We have sent you an OTP via sms on +91 9291929192"
  final String sentToText;
  final VoidCallback? onEdit;
  final void Function(String otp) onVerify;
  final VoidCallback? onResendOtp;
  /// OTP config from API: {time, isExpiryEnabled, ...} — only [time] drives resend countdown.
  final Map<String, dynamic>? otpExpiry;
  final bool verifyLoading;
  final bool resendLoading;
  final int otpLength;
  /// When true, show 6 separate OTP boxes (email_otp); when false, single field (mobile_otp)
  final bool useSixBoxes;

  const OtpVerifySection({
    super.key,
    required this.sentToText,
    this.onEdit,
    required this.onVerify,
    this.onResendOtp,
    this.otpExpiry,
    this.verifyLoading = false,
    this.resendLoading = false,
    this.otpLength = 6,
    this.useSixBoxes = false,
  });

  @override
  State<OtpVerifySection> createState() => _OtpVerifySectionState();
}

class _OtpVerifySectionState extends State<OtpVerifySection> {
  String _otp = '';
  int _resendCooldownRemaining = 0;
  Timer? _resendTimer;
  bool _resendCooldownEnabled = false;

  @override
  void initState() {
    super.initState();
    _initializeResendCooldown();
  }

  void _initializeResendCooldown() {
    _resendTimer?.cancel();
    _resendCooldownRemaining = 0;
    _resendCooldownEnabled = false;

    final expiry = widget.otpExpiry;
    if (expiry == null) return;
    if (expiry['isExpiryEnabled'] == false) return;

    final resendSec = int.tryParse(expiry['time']?.toString() ?? '0') ?? 0;
    if (resendSec <= 0) return;

    _resendCooldownEnabled = true;
    _resendCooldownRemaining = resendSec;
    _startResendCooldownTimer();
  }

  void _startResendCooldownTimer() {
    _resendTimer?.cancel();
    if (_resendCooldownRemaining <= 0) return;
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_resendCooldownRemaining <= 1) {
          _resendCooldownRemaining = 0;
          _resendTimer?.cancel();
        } else {
          _resendCooldownRemaining--;
        }
      });
    });
  }

  @override
  void didUpdateWidget(OtpVerifySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.otpExpiry != widget.otpExpiry) {
      _initializeResendCooldown();
    }
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    super.dispose();
  }

  static String _formatMmSs(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  bool get _canResend =>
      widget.onResendOtp != null &&
      (!_resendCooldownEnabled || _resendCooldownRemaining == 0);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                widget.sentToText,
                style: TextStyle(
                  fontSize: 14,
                  color: KycTheme.textPrimary,
                ),
              ),
            ),
            if (widget.onEdit != null)
              GestureDetector(
                onTap: widget.onEdit,
                child: Text(
                  'Edit',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: KycTheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (widget.useSixBoxes)
          OtpInputSixBoxes(
            length: widget.otpLength,
            onChanged: (v) => setState(() => _otp = v),
            onComplete: (v) => setState(() => _otp = v),
          )
        else
          OtpInput(
            length: widget.otpLength,
            onChanged: (v) => setState(() => _otp = v),
            onComplete: (v) => setState(() => _otp = v),
          ),
        const SizedBox(height: 16),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              "Didn't receive OTP? ",
              style: TextStyle(
                fontSize: 13,
                color: KycTheme.textSecondary,
              ),
            ),
            if (widget.resendLoading)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: KycTheme.primary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Resending...',
                    style: TextStyle(
                      fontSize: 13,
                      color: KycTheme.textSecondary,
                    ),
                  ),
                ],
              )
            else if (_resendCooldownRemaining > 0)
              Text(
                'Resend OTP in ${_formatMmSs(_resendCooldownRemaining)}',
                style: TextStyle(
                  fontSize: 13,
                  color: KycTheme.textSecondary,
                ),
              )
            else if (_canResend)
              GestureDetector(
                onTap: widget.onResendOtp,
                child: Text(
                  'Resend OTP',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: KycTheme.primary,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
        LoadingButton(
          onPressed: _otp.length < OtpVerifySection.minOtpLength
              ? null
              : () => widget.onVerify(_otp),
          isLoading: widget.verifyLoading,
          label: 'Verify',
          loadingLabel: 'Verifying...',
          width: double.infinity,
          height: 54,
          style: ElevatedButton.styleFrom(
            backgroundColor: KycTheme.primary,
            disabledBackgroundColor: KycTheme.primary.withValues(alpha: 0.5),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }
}

/// Resend OTP link + 3 min cooldown (nominee opt-out uses normal form + this bar).
class OtpResendControls extends StatefulWidget {
  final Map<String, dynamic>? otpExpiry;
  final VoidCallback? onResendOtp;
  final bool resendLoading;

  const OtpResendControls({
    super.key,
    this.otpExpiry,
    this.onResendOtp,
    this.resendLoading = false,
  });

  @override
  State<OtpResendControls> createState() => _OtpResendControlsState();
}

class _OtpResendControlsState extends State<OtpResendControls> {
  int _resendCooldownRemaining = 0;
  Timer? _resendTimer;
  bool _resendCooldownEnabled = false;

  @override
  void initState() {
    super.initState();
    _initializeResendCooldown();
  }

  void _initializeResendCooldown() {
    _resendTimer?.cancel();
    _resendCooldownRemaining = 0;
    _resendCooldownEnabled = false;

    final expiry = widget.otpExpiry;
    if (expiry == null || expiry['isExpiryEnabled'] == false) return;

    final resendSec = int.tryParse(expiry['time']?.toString() ?? '0') ?? 0;
    if (resendSec <= 0) return;

    _resendCooldownEnabled = true;
    _resendCooldownRemaining = resendSec;
    _startResendCooldownTimer();
  }

  void _startResendCooldownTimer() {
    _resendTimer?.cancel();
    if (_resendCooldownRemaining <= 0) return;
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_resendCooldownRemaining <= 1) {
          _resendCooldownRemaining = 0;
          _resendTimer?.cancel();
        } else {
          _resendCooldownRemaining--;
        }
      });
    });
  }

  @override
  void didUpdateWidget(OtpResendControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.otpExpiry != widget.otpExpiry) {
      _initializeResendCooldown();
    }
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    super.dispose();
  }

  static String _formatMmSs(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  bool get _canResend =>
      widget.onResendOtp != null &&
      (!_resendCooldownEnabled || _resendCooldownRemaining == 0);

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          "Didn't receive OTP? ",
          style: TextStyle(fontSize: 13, color: KycTheme.textSecondary),
        ),
        if (widget.resendLoading)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: KycTheme.primary,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'Resending...',
                style: TextStyle(fontSize: 13, color: KycTheme.textSecondary),
              ),
            ],
          )
        else if (_resendCooldownRemaining > 0)
          Text(
            'Resend OTP in ${_formatMmSs(_resendCooldownRemaining)}',
            style: TextStyle(fontSize: 13, color: KycTheme.textSecondary),
          )
        else if (_canResend)
          GestureDetector(
            onTap: widget.onResendOtp,
            child: Text(
              'Resend OTP',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: KycTheme.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
      ],
    );
  }
}
