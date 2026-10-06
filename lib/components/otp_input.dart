import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';

/// Single OTP input field (used for mobile_otp to prevent overflow)
class OtpInput extends StatefulWidget {
  final int length;
  final void Function(String value)? onComplete;
  final void Function(String value)? onChanged;

  const OtpInput({
    super.key,
    this.length = 6,
    this.onComplete,
    this.onChanged,
  });

  @override
  State<OtpInput> createState() => _OtpInputState();
}

class _OtpInputState extends State<OtpInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length > widget.length) {
      _controller.value = TextEditingValue(
        text: digits.substring(0, widget.length),
        selection: TextSelection.collapsed(offset: widget.length),
      );
    } else {
      _controller.value = TextEditingValue(
        text: digits,
        selection: TextSelection.collapsed(offset: digits.length),
      );
    }
    final finalValue = _controller.text;
    widget.onChanged?.call(finalValue);
    // Removed minimum length condition - onComplete fires whenever there's any input
    if (finalValue.isNotEmpty) {
      widget.onComplete?.call(finalValue);
    }
  }

  @override
Widget build(BuildContext context) {
  return TextField(
    controller: _controller,
    focusNode: _focusNode,
    keyboardType: TextInputType.number,
    textAlign: TextAlign.center,
    maxLength: widget.length,
    inputFormatters: [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(widget.length),
    ],
    onChanged: _onChanged,
    decoration: InputDecoration(
      isDense: true, // Add this - reduces internal padding
      counterText: '',
      contentPadding: const EdgeInsets.symmetric(vertical: 15, horizontal: 12),
      filled: true,
      fillColor: KycTheme.surface,
      hintText: 'Enter OTP',
      hintStyle: const TextStyle(
        color: KycTheme.textSecondary,
        fontSize: 15,
        letterSpacing: 0,
      ),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: KycTheme.border, width: 1.5),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: KycTheme.primary, width: 2),
      ),
    ),
    style: const TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      color: KycTheme.textPrimary,
      letterSpacing: 8,
    ),
  );
}

  // @override
  // Widget build(BuildContext context) {
  //   return TextField(
  //     controller: _controller,
  //     focusNode: _focusNode,
  //     keyboardType: TextInputType.number,
  //     textAlign: TextAlign.center,
  //     textAlignVertical: TextAlignVertical.center, // Center text vertically
  //     maxLength: widget.length,
  //     inputFormatters: [
  //       FilteringTextInputFormatter.digitsOnly,
  //       LengthLimitingTextInputFormatter(widget.length),
  //     ],
  //     onChanged: _onChanged,
  //     decoration: InputDecoration(
  //       counterText: '',
  //       contentPadding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14), // Proper padding for centering
  //       filled: true,
  //       fillColor: KycTheme.surface,
  //       hintText: 'Enter OTP',
  //       hintStyle: TextStyle(
  //         color: KycTheme.textSecondary,
  //         fontSize: 14,
  //       ),
  //       border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
  //       enabledBorder: OutlineInputBorder(
  //         borderRadius: BorderRadius.circular(12),
  //         borderSide: const BorderSide(color: KycTheme.border, width: 1.5),
  //       ),
  //       focusedBorder: OutlineInputBorder(
  //         borderRadius: BorderRadius.circular(12),
  //         borderSide: const BorderSide(color: KycTheme.primary, width: 2),
  //       ),
  //     ),
  //     style: const TextStyle(
  //       fontSize: 24,
  //       fontWeight: FontWeight.w600,
  //       color: KycTheme.textPrimary,
  //       letterSpacing: 8,
  //       height: 1.0, // Normal height for text
  //     ),
  //   );
  // }

  
}

/// Six separate OTP boxes (used for email_otp per Figma)
class OtpInputSixBoxes extends StatefulWidget {
  final int length;
  final void Function(String value)? onComplete;
  final void Function(String value)? onChanged;

  const OtpInputSixBoxes({
    super.key,
    this.length = 6,
    this.onComplete,
    this.onChanged,
  });

  @override
  State<OtpInputSixBoxes> createState() => _OtpInputSixBoxesState();
}

class _OtpInputSixBoxesState extends State<OtpInputSixBoxes> {
  final List<FocusNode> _focusNodes = [];
  final List<TextEditingController> _controllers = [];

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < widget.length; i++) {
      _focusNodes.add(FocusNode());
      _controllers.add(TextEditingController());
    }
  }

  @override
  void dispose() {
    for (final n in _focusNodes) n.dispose();
    for (final c in _controllers) c.dispose();
    super.dispose();
  }

  String get _value {
    final s = _controllers.map((c) => c.text).join();
    return s.length > widget.length ? s.substring(0, widget.length) : s;
  }

  void _notifyChange() {
    final full = _value;
    widget.onChanged?.call(full);
    if (full.length == widget.length) {
      widget.onComplete?.call(full);
    }
  }

  void _onChanged(int index, String v) {
    if (v.length > 1) {
      final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.isNotEmpty) {
        for (var i = 0; i < widget.length && (index + i) < widget.length && i < digits.length; i++) {
          _controllers[index + i].text = digits[i];
        }
        final lastIndex = (index + digits.length - 1).clamp(0, widget.length - 1);
        _focusNodes[lastIndex].requestFocus();
        _notifyChange();
        return;
      }
      v = v[v.length - 1];
    }
    _controllers[index].text = v;
    _controllers[index].selection = TextSelection.collapsed(offset: v.length);
    _notifyChange();
    if (v.isNotEmpty && index < widget.length - 1) {
      _focusNodes[index + 1].requestFocus();
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.backspace) {
      return KeyEventResult.ignored;
    }
    final i = _focusNodes.indexOf(node);
    if (i < 0) return KeyEventResult.ignored;
    if (_controllers[i].text.isEmpty && i > 0) {
      _controllers[i - 1].clear();
      _focusNodes[i - 1].requestFocus();
      _notifyChange();
      return KeyEventResult.handled;
    }
    if (_controllers[i].text.isNotEmpty) {
      _controllers[i].clear();
      _notifyChange();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(widget.length, (i) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(left: i > 0 ? 6.0 : 0, right: i < widget.length - 1 ? 6.0 : 0),
            child: SizedBox(
              height: 50,
              child: Focus(
                onKeyEvent: _onKeyEvent,
                focusNode: _focusNodes[i],
                child: TextField(
                  controller: _controllers[i],
                  focusNode: _focusNodes[i],
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  maxLength: 1,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (v) => _onChanged(i, v),
                  decoration: InputDecoration(
                    counterText: '',
                    contentPadding: EdgeInsets.zero,
                    filled: true,
                    fillColor: KycTheme.surface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: KycTheme.border, width: 1.5),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: KycTheme.primary, width: 2),
                    ),
                  ),
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: KycTheme.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}
