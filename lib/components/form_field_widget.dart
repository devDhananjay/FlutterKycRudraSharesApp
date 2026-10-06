import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:meon_kyc/components/otp_input.dart';
import 'package:meon_kyc/components/popup_modal.dart';
import 'package:meon_kyc/services/pdf_password_service.dart';
import 'package:meon_kyc/theme/kyc_theme.dart';
import 'package:meon_kyc/utils/conditional_flow.dart';
import 'package:meon_kyc/utils/kyc_date_utils.dart';

// BugFixes: date helpers + select value resolution + date picker use existing API value (dropoff).

class FormFieldWidget extends StatefulWidget {
  final String name;
  final String displayName;
  final String type;
  final List<dynamic>? fileType;
  final dynamic size;
  final bool mandatory;
  final dynamic validation;
  final List<dynamic>? popupAfterSubmit;
  final dynamic value;
  final void Function(String name, dynamic value) onChange;
  final void Function(String name)? onBlur;
  final List<dynamic>? values;
  final bool visible;
  final String? errorField;
  final int? rows;
  final int? cols;
  final String? urlCompany;
  final String? workflowKey;
  final bool disable;
  /// When [validation] is `googleSignIn`, invoked instead of the empty stub.
  final Future<void> Function()? onGoogleSignIn;
  final bool googleSignInLoading;
  /// Full field map from API — used for `date` [minDateType]/[maxDateValue] etc.
  final Map<dynamic, dynamic>? apiFieldMeta;
  /// When true (PAN / detailspan / kradetails steps), date fields show **DD/MM/YYYY** instead of MM/dd/yyyy.
  final bool useDdMmYyyyDateDisplay;

  const FormFieldWidget({
    super.key,
    required this.name,
    required this.displayName,
    required this.type,
    this.fileType,
    this.size,
    this.mandatory = false,
    this.validation,
    this.popupAfterSubmit,
    this.value,
    required this.onChange,
    this.onBlur,
    this.values,
    this.visible = true,
    this.errorField,
    this.rows,
    this.cols,
    this.urlCompany,
    this.workflowKey,
    this.disable = false,
    this.onGoogleSignIn,
    this.googleSignInLoading = false,
    this.apiFieldMeta,
    this.useDdMmYyyyDateDisplay = false,
  });

  @override
  State<FormFieldWidget> createState() => _FormFieldWidgetState();
}

class _FormFieldWidgetState extends State<FormFieldWidget> {
  bool _showPassword = false;
  bool _showPopup = false;
  Map<String, dynamic>? _currentPopup;
  bool _isPdfEncrypted = false;
  String _pdfPassword = '';
  bool _showPdfPassword = false;
  bool _isVerifyingPdf = false;
  String _pdfVerificationError = '';
  File? _encryptedPdfFile;
  String? _fileError;
  /// Signature fields open the digital pad by default (upload still available via Cancel).
  bool _showInlineSignaturePad = false;
  final List<Offset?> _signaturePoints = [];
  bool _signatureSubmitting = false;
  String? _signaturePadError;
  String? _previewPath;
  TextEditingController? _textController;
  TextEditingController? _numberController;
  TextEditingController? _textareaController;
  TextEditingController? _passwordController;
  TextEditingController? _dateController;
  FocusNode? _ddMmYyyyFocusNode;
  bool _applyingDdMmYyyyMask = false;

  static const Locale _ddMmYyyyPickerLocale = Locale('en', 'IN');

  /// Stored value remains ISO `yyyy-MM-dd`; label uses step-specific pattern.
  String _formatDateFieldDisplay(dynamic value) {
    if (value == null) return 'Select date';
    final s = value.toString().trim();
    if (s.isEmpty) return 'Select date';
    final d = widget.useDdMmYyyyDateDisplay
        ? (parseKycDateValueAsDdMmYyyy(value) ?? parseKycDateValue(value))
        : parseKycDateValue(value);
    if (d == null) return s;
    final pattern =
        widget.useDdMmYyyyDateDisplay ? 'dd/MM/yyyy' : 'MM/dd/yyyy';
    return DateFormat(pattern).format(d);
  }

  @override
  void initState() {
    super.initState();
    if (widget.useDdMmYyyyDateDisplay) {
      _ddMmYyyyFocusNode = FocusNode();
      _ddMmYyyyFocusNode!.addListener(_handleDdMmYyyyFocusChange);
    }
    // Signature upload step: show digital signature canvas by default.
    if (_isSignatureField && widget.value is! File) {
      _showInlineSignaturePad = true;
    }
    _initializeControllers();
  }

  void _initializeControllers() {
    var value = widget.value?.toString() ?? '';
    if (widget.type == 'text') {
      if (_isMobileField) {
        final digits = value.replaceAll(RegExp(r'\D'), '');
        value = digits.length > 10 ? digits.substring(0, 10) : digits;
      } else if (_isPanField) {
        value = value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        if (value.length > 10) value = value.substring(0, 10);
      } else if (_isNoSpecialCharacterField) {
        value = value.replaceAll(RegExp(r"[^a-zA-Z\s'\-]"), '');
      } else if (_isTradingExperienceField) {
        value = _normalizeTradingExperienceInput(value);
      } else if (_usesDdMmYyyyManualEntry) {
        value = _formatDdMmYyyyDisplayIfNeeded(value);
      }
      _textController = TextEditingController(text: value);
    } else if (widget.type == 'number') {
      if (_usesDdMmYyyyManualEntry) {
        value = _formatDdMmYyyyDisplayIfNeeded(value);
        _dateController = TextEditingController(text: value);
      } else {
        if (_isTradingExperienceField) {
          value = _normalizeTradingExperienceInput(value);
        }
        _numberController = TextEditingController(text: value);
      }
    } else if (widget.type == 'textarea') {
      _textareaController = TextEditingController(text: value);
    } else if (widget.type == 'password') {
      _passwordController = TextEditingController(text: value);
    } else if (widget.type == 'date' && widget.useDdMmYyyyDateDisplay) {
      value = _formatDdMmYyyyDisplayIfNeeded(value);
      _dateController = TextEditingController(text: value);
    }
  }

  @override
  void didUpdateWidget(FormFieldWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync controllers whenever the coalesced [widget.value] differs from what is shown.
    // IFSC auto-fill updates [formData] programmatically; we must not rely only on
    // `oldWidget.value != widget.value` (e.g. same string identity, or missed rebuild edge cases).
    _syncControllersFromWidgetValue();
  }

  void _syncControllersFromWidgetValue() {
    if (widget.useDdMmYyyyDateDisplay &&
        _ddMmYyyyFocusNode?.hasFocus == true) {
      return;
    }
    final newValue = widget.value?.toString() ?? '';
    if (widget.type == 'text' && _textController != null) {
      var textValue = newValue;
      if (_isMobileField) {
        final digits = newValue.replaceAll(RegExp(r'\D'), '');
        textValue = digits.length > 10 ? digits.substring(0, 10) : digits;
      } else if (_isPanField) {
        textValue = newValue.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        if (textValue.length > 10) textValue = textValue.substring(0, 10);
      } else if (_isNoSpecialCharacterField) {
        textValue = newValue.replaceAll(RegExp(r"[^a-zA-Z\s'\-]"), '');
      } else if (_isTradingExperienceField) {
        textValue = _normalizeTradingExperienceInput(newValue);
      } else if (_usesDdMmYyyyManualEntry) {
        textValue = _formatDdMmYyyyDisplayIfNeeded(newValue);
      }
      if (_textController!.text != textValue) {
        _setControllerTextAfterBuild(_textController!, textValue);
      }
    } else if (widget.type == 'number' && _numberController != null) {
      var textValue = newValue;
      if (_isMobileField) {
        final digits = newValue.replaceAll(RegExp(r'\D'), '');
        textValue = digits.length > 10 ? digits.substring(0, 10) : digits;
      } else if (_isTradingExperienceField) {
        textValue = _normalizeTradingExperienceInput(newValue);
      }
      if (_numberController!.text != textValue) {
        _setControllerTextAfterBuild(_numberController!, textValue);
      }
    } else if (widget.type == 'number' &&
        _usesDdMmYyyyManualEntry &&
        _dateController != null) {
      var dateValue = _formatDdMmYyyyDisplayIfNeeded(newValue);
      if (_dateController!.text != dateValue) {
        _setControllerTextAfterBuild(_dateController!, dateValue);
      }
    } else if (widget.type == 'textarea' && _textareaController != null) {
      if (_textareaController!.text != newValue) {
        _setControllerTextAfterBuild(_textareaController!, newValue);
      }
    } else if (widget.type == 'password' && _passwordController != null) {
      if (_passwordController!.text != newValue) {
        _setControllerTextAfterBuild(_passwordController!, newValue);
      }
    } else if (widget.type == 'date' &&
        widget.useDdMmYyyyDateDisplay &&
        _dateController != null) {
      var dateValue = _formatDdMmYyyyDisplayIfNeeded(newValue);
      if (_dateController!.text != dateValue) {
        _setControllerTextAfterBuild(_dateController!, dateValue);
      }
    }
  }

  /// Avoid FormFieldState.didChange → setState during an active build.
  void _setControllerTextAfterBuild(TextEditingController controller, String text) {
    void apply() {
      if (!mounted) return;
      if (controller.text != text) {
        controller.text = text;
      }
    }

    final phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      apply();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    }
  }

  @override
  void dispose() {
    _textController?.dispose();
    _numberController?.dispose();
    _textareaController?.dispose();
    _passwordController?.dispose();
    _dateController?.dispose();
    _ddMmYyyyFocusNode?.removeListener(_handleDdMmYyyyFocusChange);
    _ddMmYyyyFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    Widget field;
    // API may send `radioButton` (camelCase) after dropping dropdowns — treat as radio.
    switch (widget.type.toLowerCase()) {
      case 'text':
        field = _buildText();
        break;
      case 'number':
        field = _buildNumber();
        break;
      case 'textarea':
        field = _buildTextArea();
        break;
      case 'password':
        field = _buildPassword();
        break;
      case 'select':
      case 'dropdown':
        // Workflow now sends yes/no style choices as `select` (dropdowns removed).
        // Short binary options → radio row; longer lists still use dropdown.
        final selectOpts = widget.values ?? [];
        final asRadio = selectOpts.length == 2 &&
            selectOpts.every((o) => o.toString().trim().length <= 8);
        field = asRadio ? _buildRadio() : _buildSelect();
        break;
      case 'date':
        field = _buildDate();
        break;
      case 'checkbox':
        field = _buildCheckbox();
        break;
      case 'radio':
      case 'radiobutton':
        field = _buildRadio();
        break;
      case 'button':
        field = _buildButton();
        break;
      case 'file':
        field = _buildFile();
        break;
      case 'otp':
        field = _buildOtp();
        break;
      default:
        field = _buildText();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field,
        if (widget.errorField != null && widget.errorField!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    widget.errorField!,
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700),
                    softWrap: true,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: KycTheme.textPrimary,
            height: 1.35,
          ),
          children: [
            TextSpan(text: text),
            if (widget.mandatory)
              TextSpan(
                text: ' *',
                style: TextStyle(
                  color: Colors.red.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget? _getFieldIcon() {
    final name = widget.name.toLowerCase();
    final type = widget.type.toLowerCase();
    final validation = widget.validation?.toString().toLowerCase() ?? '';
    
    // Email fields
    if (name.contains('email') || validation == 'email') {
      return const Icon(Icons.email_outlined, color: KycTheme.textSecondary);
    }
    // Phone/Mobile fields
    if (name.contains('phone') || name.contains('mobile') || validation == 'mobile') {
      return const Icon(Icons.phone_outlined, color: KycTheme.textSecondary);
    }
    // Date fields
    if (type == 'date') {
      return const Icon(Icons.calendar_today_outlined, color: KycTheme.textSecondary);
    }
    // OTP fields
    if (type == 'otp' || name.contains('otp') || validation == 'otp') {
      return const Icon(Icons.lock_outline, color: KycTheme.textSecondary);
    }
    // Password fields
    if (type == 'password') {
      return const Icon(Icons.lock_outline, color: KycTheme.textSecondary);
    }
    // Number fields — `numbers_outlined` renders like "#" on some devices/fonts; no prefix icon.
    if (type == 'number' || validation == 'number') {
      return null;
    }
    // File upload fields
    if (type == 'file') {
      return const Icon(Icons.upload_file_outlined, color: KycTheme.textSecondary);
    }
    return null;
  }

  bool get _isMobileField {
    final name = widget.name.toLowerCase();
    final validation = widget.validation?.toString().toLowerCase() ?? '';
    return validation == 'mobile' ||
        name == 'mobile' ||
        name == 'mobile_number' ||
        name == 'phone';
  }

  bool get _isPanField {
    final v = widget.validation?.toString().toLowerCase() ?? '';
    if (v == 'pan') return true;
    final n = widget.name.toLowerCase();
    return n == 'pan_number' || n == 'temp_pan_no' || n == 'pan_no';
  }

  bool get _isTradingExperienceField {
    final n = widget.name.toLowerCase().replaceAll(RegExp(r'[\s_-]+'), '');
    final dn = widget.displayName.toLowerCase();
    return n.contains('tradingexperience') ||
        (dn.contains('trading') && dn.contains('experience'));
  }

  String _normalizeTradingExperienceInput(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    return digits.length > 2 ? digits.substring(0, 2) : digits;
  }

  bool get _isNoSpecialCharacterField {
    final v = widget.validation?.toString().toLowerCase().trim() ?? '';
    return v == 'nospecialcharacter';
  }

  bool get _isDobLikeField {
    final n = widget.name.toLowerCase();
    final dn = widget.displayName.toLowerCase();
    return n.contains('dob') ||
        n.contains('date_of_birth') ||
        n.contains('birth_date') ||
        dn.contains('date of birth') ||
        dn.contains('dob');
  }

  bool get _isDateLikeField {
    if (widget.type == 'date') return true;
    final n = widget.name.toLowerCase();
    final dn = widget.displayName.toLowerCase();
    final v = widget.validation?.toString().toLowerCase() ?? '';
    return n.contains('date') || dn.contains('date') || v == 'date' || v == 'dob';
  }

  bool get _usesDdMmYyyyManualEntry {
    if (!widget.useDdMmYyyyDateDisplay) return false;
    if (widget.type == 'date') return true;
    return _isDobLikeField || _isDateLikeField;
  }

  TextEditingController? get _activeDdMmYyyyController =>
      _dateController ?? _textController;

  void _onDdMmYyyyChanged(String value) {
    if (_applyingDdMmYyyyMask) return;
    final controller = _activeDdMmYyyyController;
    if (controller == null) return;
    final formatted = formatDdMmYyyyTyping(value);
    if (formatted == controller.text) return;
    _applyingDdMmYyyyMask = true;
    controller.value = TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
    _applyingDdMmYyyyMask = false;
  }

  /// UI shows `dd/MM/yyyy`; form/API keeps ISO `yyyy-MM-dd` (same as before).
  void _handleDdMmYyyyFocusChange() {
    if (!mounted || _ddMmYyyyFocusNode?.hasFocus != false) return;
    _commitDdMmYyyyToFormData();
  }

  void _commitDdMmYyyyToFormData() {
    final controller = _dateController ?? _textController;
    if (controller == null) return;
    final raw = controller.text.trim();
    if (raw.isEmpty) {
      widget.onChange(widget.name, '');
    } else {
      final d = parseKycDateValueAsDdMmYyyy(raw) ?? parseKycDateValue(raw);
      if (d != null) {
        final iso =
            '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        widget.onChange(widget.name, iso);
        final display = DateFormat('dd/MM/yyyy').format(d);
        if (controller.text != display) {
          _setControllerTextAfterBuild(controller, display);
        }
      } else {
        widget.onChange(widget.name, raw);
      }
    }
    widget.onBlur?.call(widget.name);
  }

  Future<void> _pickDdMmYyyyDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final bounds = widget.apiFieldMeta != null
        ? kycDobPickerBoundsFromField(widget.apiFieldMeta!)
        : null;
    final first = bounds?.first ?? DateTime(1900, 1, 1);
    final last = bounds?.last ?? today;
    final existing = parseKycDateValueAsDdMmYyyy(widget.value) ??
        parseKycDateValue(widget.value);
    var initial = existing ?? last;
    if (initial.isAfter(last)) initial = last;
    if (initial.isBefore(first)) initial = first;
    final d = await showDdMmYyyyDatePickerDialog(
      context: context,
      initial: initial,
      first: first,
      last: last,
      title: widget.displayName,
      fieldMeta: widget.apiFieldMeta,
    );
    if (d == null || !mounted) return;
    final iso =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final display = DateFormat('dd/MM/yyyy').format(d);
    widget.onChange(widget.name, iso);
    final controller = _dateController ?? _textController;
    if (controller != null) {
      _setControllerTextAfterBuild(controller, display);
    }
    widget.onBlur?.call(widget.name);
  }

  String _formatDdMmYyyyDisplayIfNeeded(String raw) {
    if (!widget.useDdMmYyyyDateDisplay || raw.trim().isEmpty) return raw;
    if (!_usesDdMmYyyyManualEntry) return raw;
    final d = parseKycDateValueAsDdMmYyyy(raw) ?? parseKycDateValue(raw);
    if (d == null) return formatDdMmYyyyTyping(raw);
    return DateFormat('dd/MM/yyyy').format(d);
  }

  static final BorderRadius _fieldBorderRadius =
      BorderRadius.circular(KycTheme.radiusMd);

  OutlineInputBorder _outlineFieldBorder({Color? color, double width = 1}) {
    return OutlineInputBorder(
      borderRadius: _fieldBorderRadius,
      borderSide: BorderSide(color: color ?? KycTheme.border, width: width),
    );
  }

  /// Matches app [InputDecorationTheme] — disabled/read-only fields keep the same
  /// visual styling as editable fields (same fill, border, label colors). Editability
  /// is controlled at the form-control level (`readOnly` / `enabled`), not via colors.
  InputDecoration _fieldInputDecoration({
    String? hintText,
    Widget? prefixIcon,
    Widget? prefix,
    Widget? suffixIcon,
    String? counterText,
    bool alignLabelWithHint = false,
  }) {
    return InputDecoration(
      hintText: hintText,
      prefixIcon: prefixIcon,
      prefix: prefix,
      suffixIcon: suffixIcon,
      counterText: counterText,
      alignLabelWithHint: alignLabelWithHint,
      filled: true,
      fillColor: KycTheme.surface,
      border: _outlineFieldBorder(),
      enabledBorder: _outlineFieldBorder(),
      focusedBorder: _outlineFieldBorder(color: KycTheme.primary, width: 2),
      disabledBorder: _outlineFieldBorder(),
      errorBorder: _outlineFieldBorder(color: Colors.red),
      focusedErrorBorder: _outlineFieldBorder(color: Colors.red, width: 2),
    );
  }

  /// Disabled `TextFormField`s lose their text color via the Material theme;
  /// force the regular primary text color so read-only fields look identical
  /// to editable ones (DigiLocker, KRA review, etc.).
  static const TextStyle _kFieldTextStyle = TextStyle(
    fontSize: 16,
    color: KycTheme.textPrimary,
    height: 1.35,
  );

  static const double _kSelectFieldHeight = 52.0;

  /// Label is shown above the field; long copy must not repeat inside the box.
  bool _selectHasLongLabelAbove() => widget.displayName.trim().length > 48;

  /// KRA continue dropdown: full question as label above, `--Select--` inside the box.
  bool _selectUsesPlaceholderInsideBox() {
    if (_selectHasLongLabelAbove()) return true;
    return kraDetailsContinueWithKraChoiceField({
      'name': widget.name,
      'displayName': widget.displayName,
    });
  }

  /// Closed dropdown hint when no value is selected yet (label above stays [displayName]).
  String _selectClosedHint() {
    if (_selectUsesPlaceholderInsideBox()) return '--Select--';
    return widget.displayName;
  }

  int _selectMenuTextMaxLines(String text) {
    final len = text.trim().length;
    if (len <= 48) return 1;
    if (len <= 96) return 2;
    return 3;
  }

  double _selectMenuItemHeight(String text) {
    final lines = _selectMenuTextMaxLines(text);
    if (lines <= 1) return _kSelectFieldHeight;
    return 26.0 * lines + 16.0;
  }

  Widget _selectDropdownText(
    String text, {
    int maxLines = 1,
    Color? color,
  }) {
    return Text(
      text,
      style: _kFieldTextStyle.copyWith(
        color: color ?? KycTheme.textPrimary,
        height: 1.3,
      ),
      maxLines: maxLines,
      softWrap: true,
      overflow: TextOverflow.clip,
      textAlign: TextAlign.start,
    );
  }

  /// Vertically centered closed-state row (hint or selected value).
  Widget _selectClosedFieldChild(
    String text, {
    Color? color,
    int maxLines = 1,
  }) {
    return SizedBox(
      width: double.infinity,
      height: _kSelectFieldHeight,
      child: Center(
        child: Align(
          alignment: Alignment.centerLeft,
          child: _selectDropdownText(
            text,
            maxLines: maxLines,
            color: color,
          ),
        ),
      ),
    );
  }

  Widget _buildText() {
    if (_textController == null) {
      String raw = widget.value?.toString() ?? '';
      if (_isMobileField) {
        final digits = raw.replaceAll(RegExp(r'\D'), '');
        raw = digits.length > 10 ? digits.substring(0, 10) : digits;
      } else if (_isPanField) {
        raw = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
        if (raw.length > 10) raw = raw.substring(0, 10);
      } else if (_isNoSpecialCharacterField) {
        raw = raw.replaceAll(RegExp(r"[^a-zA-Z\s'\-]"), '');
      } else if (_isTradingExperienceField) {
        raw = _normalizeTradingExperienceInput(raw);
      } else if (_usesDdMmYyyyManualEntry) {
        raw = _formatDdMmYyyyDisplayIfNeeded(raw);
      }
      _textController = TextEditingController(text: raw);
    }
    if (_usesDdMmYyyyManualEntry) {
      return _buildDdMmYyyyManualField(_textController!);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        TextFormField(
          controller: _textController,
          enabled: !widget.disable,
          readOnly: widget.disable,
          showCursor: !widget.disable,
          scrollPhysics: const NeverScrollableScrollPhysics(),
          style: _kFieldTextStyle,
          keyboardType: _isMobileField || _isTradingExperienceField
              ? TextInputType.number
              : TextInputType.text,
          textCapitalization:
              _isPanField ? TextCapitalization.characters : TextCapitalization.none,
          maxLength: _isMobileField
              ? 10
              : (_isPanField
                  ? 10
                  : (_isTradingExperienceField ? 2 : null)),
          inputFormatters: _isMobileField
              ? [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ]
              : _isPanField
                  ? [
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')),
                      LengthLimitingTextInputFormatter(10),
                    ]
                  : _isTradingExperienceField
                      ? [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(2),
                        ]
                  : _isNoSpecialCharacterField
                      ? [
                          FilteringTextInputFormatter.allow(
                            RegExp(r"[a-zA-Z\s'\-]"),
                          ),
                        ]
                      : null,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: _fieldInputDecoration(
            hintText: _isMobileField ? 'Enter Mobile number *' : '${widget.displayName}',
            prefixIcon: _isMobileField ? null : _getFieldIcon(),
            prefix: _isMobileField
                ? Padding(
                    padding: const EdgeInsets.only(left: 16, right: 12),
                    child: Text(
                      '+91',
                      style: TextStyle(
                        fontSize: 16,
                        color: KycTheme.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                : null,
            counterText: (_isMobileField ||
                    _isPanField ||
                    _isNoSpecialCharacterField ||
                    _isTradingExperienceField)
                ? ''
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildNumber() {
    if (_usesDdMmYyyyManualEntry) {
      if (_dateController == null) {
        var raw = widget.value?.toString() ?? '';
        raw = _formatDdMmYyyyDisplayIfNeeded(raw);
        _dateController = TextEditingController(text: raw);
      }
      return _buildDdMmYyyyManualField(_dateController!);
    }
    if (_numberController == null) {
      String raw = widget.value?.toString() ?? '';
      if (_isMobileField) {
        final digits = raw.replaceAll(RegExp(r'\D'), '');
        raw = digits.length > 10 ? digits.substring(0, 10) : digits;
      } else if (_isTradingExperienceField) {
        raw = _normalizeTradingExperienceInput(raw);
      }
      _numberController = TextEditingController(text: raw);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        TextFormField(
          controller: _numberController,
          enabled: !widget.disable,
          readOnly: widget.disable,
          showCursor: !widget.disable,
          style: _kFieldTextStyle,
          keyboardType: TextInputType.number,
          maxLength: _isMobileField
              ? 10
              : (_isTradingExperienceField ? 2 : null),
          inputFormatters: _isMobileField
              ? [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(10),
                ]
              : _isTradingExperienceField
                  ? [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(2),
                    ]
                  : null,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: _fieldInputDecoration(
            hintText: _isMobileField ? 'Enter Mobile number *' : '${widget.displayName}',
            prefixIcon: _getFieldIcon(),
            counterText: (_isMobileField || _isTradingExperienceField) ? '' : null,
          ),
        ),
      ],
    );
  }

  Widget _buildTextArea() {
    if (_textareaController == null) {
      _textareaController = TextEditingController(text: widget.value?.toString() ?? '');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        TextFormField(
          controller: _textareaController,
          enabled: !widget.disable,
          readOnly: widget.disable,
          showCursor: !widget.disable,
          style: _kFieldTextStyle,
          maxLines: widget.rows ?? 3,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: _fieldInputDecoration(
            hintText: '${widget.displayName}',
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }

  Widget _buildPassword() {
    if (_passwordController == null) {
      _passwordController = TextEditingController(text: widget.value?.toString() ?? '');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        TextFormField(
          controller: _passwordController,
          obscureText: !_showPassword,
          style: _kFieldTextStyle,
          onChanged: (v) => widget.onChange(widget.name, v),
          decoration: _fieldInputDecoration(
            hintText: '${widget.displayName}',
            prefixIcon: _getFieldIcon(),
            suffixIcon: IconButton(
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showPassword = !_showPassword),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSelect() {
    final rawOptions = widget.values ?? [];

    /// API may send plain strings or `{label, value}` maps. Dropdown values must be unique.
    List<MapEntry<String, String>> _normalizedSelectEntries(List<dynamic> opts) {
      final seenLower = <String>{};
      final out = <MapEntry<String, String>>[];
      for (final e in opts) {
        String value;
        String label;
        if (e is Map) {
          final m = Map<String, dynamic>.from(e as Map);
          label = (m['label'] ??
                  m['displayName'] ??
                  m['text'] ??
                  m['value'] ??
                  '')
              .toString()
              .trim();
          value = (m['value'] ?? m['label'] ?? label).toString().trim();
          if (value.isEmpty && label.isNotEmpty) value = label;
          if (label.isEmpty) label = value;
        } else {
          final s = e.toString().trim();
          value = s;
          label = s;
        }
        if (value.isEmpty) continue;
        final dedupeKey = value.toLowerCase();
        if (seenLower.contains(dedupeKey)) continue;
        seenLower.add(dedupeKey);
        out.add(MapEntry(value, label));
      }
      return out;
    }

    /// Match stored form / API value to exactly one option [MapEntry.key] (dropdown value).
    String? _resolveSelectValue(String? raw, List<MapEntry<String, String>> entries) {
      if (raw == null || raw.trim().isEmpty) return null;
      final t = raw.trim();
      for (final e in entries) {
        if (e.key == t || e.value == t) return e.key;
      }
      final tl = t.toLowerCase();
      for (final e in entries) {
        if (e.key.toLowerCase() == tl || e.value.toLowerCase() == tl) return e.key;
      }
      return null;
    }

    final entries = _normalizedSelectEntries(rawOptions);
    final currentRaw = widget.value?.toString();
    final resolvedValue = _resolveSelectValue(currentRaw, entries);
    final isValidValue = resolvedValue != null;

    final longLabelAbove = _selectHasLongLabelAbove();
    final closedHint = _selectClosedHint();
    var longestMenuLabel = widget.displayName;
    for (final e in entries) {
      if (e.value.length > longestMenuLabel.length) {
        longestMenuLabel = e.value;
      }
    }
    final menuItemHeight = _selectMenuItemHeight(longestMenuLabel);
    final menuMaxLines = _selectMenuTextMaxLines(longestMenuLabel);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        DropdownButtonFormField<String>(
          value: isValidValue ? resolvedValue : null,
          decoration: _fieldInputDecoration().copyWith(
            contentPadding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
            constraints: const BoxConstraints(minHeight: _kSelectFieldHeight),
          ),
          hint: _selectClosedFieldChild(
            closedHint,
            color: KycTheme.textSecondary,
            maxLines: _selectMenuTextMaxLines(closedHint),
          ),
          isExpanded: true,
          style: _kFieldTextStyle,
          iconEnabledColor: KycTheme.textSecondary,
          iconDisabledColor: KycTheme.textSecondary,
          itemHeight: menuItemHeight,
          items: entries
              .map(
                (e) => DropdownMenuItem<String>(
                  value: e.key,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _selectDropdownText(
                        e.value,
                        maxLines: menuMaxLines,
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
          selectedItemBuilder: (ctx) => entries
              .map(
                (e) => _selectClosedFieldChild(
                  e.value,
                  maxLines: _selectMenuTextMaxLines(e.value),
                ),
              )
              .toList(),
          onChanged: widget.disable
              ? null
              : (v) => widget.onChange(widget.name, v ?? ''),
        ),
      ],
    );
  }

  Widget _buildDate() {
    if (widget.useDdMmYyyyDateDisplay) {
      if (_dateController == null) {
        var raw = widget.value?.toString() ?? '';
        raw = _formatDdMmYyyyDisplayIfNeeded(raw);
        _dateController = TextEditingController(text: raw);
      }
      return _buildDdMmYyyyManualField(_dateController!);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        InkWell(
          onTap: widget.disable
              ? null
              : () async {
                  final now = DateTime.now();
                  final today = DateTime(now.year, now.month, now.day);
                  final bounds = widget.apiFieldMeta != null
                      ? kycDobPickerBoundsFromField(widget.apiFieldMeta!)
                      : null;
                  final first = bounds?.first ?? DateTime(1900, 1, 1);
                  final last = bounds?.last ?? today;
                  final existing = parseKycDateValue(widget.value);
                  var initial = existing ?? last;
                  if (initial.isAfter(last)) initial = last;
                  if (initial.isBefore(first)) initial = first;
                  final ddMmLocale = widget.useDdMmYyyyDateDisplay
                      ? _ddMmYyyyPickerLocale
                      : null;
                  final d = await showDatePicker(
                    context: context,
                    initialDate: initial,
                    firstDate: first,
                    lastDate: last,
                    locale: ddMmLocale,
                    builder: ddMmLocale == null
                        ? null
                        : (context, child) => Localizations.override(
                              context: context,
                              locale: ddMmLocale,
                              child: child!,
                            ),
                  );
                  if (d != null) {
                    // API payload stays `yyyy-MM-dd`; only UI shows dd/MM/yyyy.
                    widget.onChange(widget.name, d.toIso8601String().split('T')[0]);
                    widget.onBlur?.call(widget.name);
                  }
                },
          child: InputDecorator(
            decoration: _fieldInputDecoration(prefixIcon: _getFieldIcon()),
            child: Text(
              _formatDateFieldDisplay(widget.value),
              style: TextStyle(
                color: widget.value != null &&
                        widget.value.toString().trim().isNotEmpty
                    ? KycTheme.textPrimary
                    : Colors.grey,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDdMmYyyyManualField(TextEditingController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        TextFormField(
          controller: controller,
          focusNode: _ddMmYyyyFocusNode,
          enabled: !widget.disable,
          readOnly: widget.disable,
          showCursor: !widget.disable,
          scrollPhysics: const NeverScrollableScrollPhysics(),
          style: _kFieldTextStyle,
          keyboardType: TextInputType.text,
          inputFormatters: ddMmYyyyKeyboardFormatters,
          onChanged: _onDdMmYyyyChanged,
          onEditingComplete: _commitDdMmYyyyToFormData,
          onTapOutside: (_) => _commitDdMmYyyyToFormData(),
          decoration: _fieldInputDecoration(
            hintText: 'DD/MM/YYYY',
            prefixIcon: _getFieldIcon(),
            suffixIcon: widget.disable
                ? null
                : IconButton(
                    icon: const Icon(
                      Icons.calendar_today_outlined,
                      color: KycTheme.textSecondary,
                    ),
                    onPressed: _pickDdMmYyyyDate,
                  ),
            counterText: '',
          ),
        ),
      ],
    );
  }

  Widget _buildCheckbox() {
    final checked = isCheckboxCheckedValue(widget.value);
    return Row(
      children: [
        Checkbox(
          value: checked,
          onChanged: widget.disable
              ? null
              : (v) => widget.onChange(widget.name, v ?? false),
        ),
        Expanded(
          child: GestureDetector(
            onTap: widget.disable
                ? null
                : () => widget.onChange(widget.name, !checked),
            child: _buildLabel(widget.displayName),
          ),
        ),
      ],
    );
  }

  Widget _buildRadio() {
    final options = widget.values ?? [];
    // Short Yes/No style → one row; longer option lists wrap without overflow.
    final compactRow = options.length == 2 &&
        options.every((o) => o.toString().trim().length <= 4);

    Widget optionChip(dynamic opt) {
      final label = opt.toString();
      return InkWell(
        onTap: widget.disable
            ? null
            : () => widget.onChange(widget.name, label),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Radio<String>(
                value: label,
                groupValue: widget.value?.toString(),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                onChanged: widget.disable
                    ? null
                    : (v) => widget.onChange(widget.name, v ?? ''),
              ),
              Text(label, style: const TextStyle(fontSize: 15)),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        const SizedBox(height: 4),
        if (compactRow)
          Row(
            children: [
              for (final opt in options)
                Expanded(child: optionChip(opt)),
            ],
          )
        else
          Wrap(
            spacing: 4,
            runSpacing: 0,
            children: [for (final opt in options) optionChip(opt)],
          ),
      ],
    );
  }

  Widget _buildButton() {
    if (widget.validation == 'googleSignIn') {
      final loading = widget.googleSignInLoading;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLabel(widget.displayName),
          OutlinedButton.icon(
            onPressed: widget.disable || loading
                ? null
                : () async {
                    if (widget.onGoogleSignIn != null) {
                      await widget.onGoogleSignIn!();
                    }
                  },
            icon: const Icon(Icons.g_mobiledata),
            label: Text(loading ? 'Signing in...' : 'Sign In with Google'),
          ),
        ],
      );
    }
    return TextButton(
      onPressed: () {
        final popups = widget.popupAfterSubmit ?? [];
        if (popups.isNotEmpty) {
          final popup = popups.cast<dynamic>().firstWhere(
            (p) => p is Map && p['fieldName'] == widget.name,
            orElse: () => popups.first,
          );
          final popupData = popup is Map ? Map<String, dynamic>.from(popup as Map) : <String, dynamic>{};
          showGeneralDialog(
            context: context,
            barrierDismissible: true,
            barrierLabel: '',
            barrierColor: Colors.black54,
            pageBuilder: (ctx, _, __) => PopupModal(
              popupData: popupData,
              onClose: () => Navigator.of(ctx).pop(),
              onSelect: (v) {
                widget.onChange(widget.name, v);
                Navigator.of(ctx).pop();
              },
              fieldName: widget.name,
            ),
          );
        }
      },
      child: Text('${widget.displayName}${widget.mandatory ? ' *' : ''}'),
    );
  }

  String _getAcceptedTypes() {
    if (widget.fileType == null || widget.fileType!.isEmpty) return '*';
    return widget.fileType!
        .map((ft) => ft is Map ? '.${ft['value'] ?? ''}' : '.$ft')
        .join(',');
  }

  Future<void> _handleFileSelection(File file) async {
    final maxBytes = (int.tryParse(widget.size?.toString() ?? '10') ?? 10) * 1024 * 1024;
    if (await file.length() > maxBytes) {
      setState(() => _fileError = 'File size must be less than ${widget.size}MB');
      return;
    }
    if (widget.fileType != null && widget.fileType!.isNotEmpty) {
      final ext = file.path.split('.').last.toLowerCase();
      final allowed = widget.fileType!
          .map((ft) => (ft is Map ? ft['value'] : ft).toString().toLowerCase())
          .toList();
      if (!allowed.contains(ext)) {
        setState(() => _fileError = 'Invalid file type. Allowed: ${allowed.join(", ")}');
        return;
      }
    }

    // Non-PDF: accept as before.
    if (!PdfPasswordService.isPdfFile(file)) {
      _clearPdfPasswordState(clearPassFormKey: true);
      setState(() => _fileError = null);
      widget.onChange(widget.name, file);
      return;
    }

    final workflowKey = widget.workflowKey?.trim() ?? '';
    if (workflowKey.isEmpty) {
      debugPrint(
        '[FormField] PDF picked but workflowKey missing — cannot run pdfPassCheck',
      );
      setState(() {
        _fileError =
            'Unable to verify PDF password protection. Please try again.';
        _isVerifyingPdf = false;
        _isPdfEncrypted = false;
        _encryptedPdfFile = null;
      });
      return;
    }

    debugPrint(
      '[FormField] PDF password check start field=${widget.name} workflowKey=$workflowKey',
    );

    setState(() {
      _fileError = null;
      _isVerifyingPdf = true;
      _pdfVerificationError = '';
      _isPdfEncrypted = false;
      _encryptedPdfFile = null;
      _pdfPassword = '';
    });

    final check = await PdfPasswordService.checkEncrypted(
      file: file,
      workflowKey: workflowKey,
      urlCompany: widget.urlCompany,
    );

    if (!mounted) return;

    // Explicit corrupt PDF — block.
    if (check.status == PdfPasswordCheckStatus.corrupted) {
      setState(() {
        _isVerifyingPdf = false;
        _fileError = check.message.isNotEmpty
            ? check.message
            : 'Your file is corrupted. Please upload a valid file.';
        _isPdfEncrypted = false;
        _encryptedPdfFile = null;
      });
      return;
    }

    // Check API flaked (403/429/HTML WAF) — do not block non-password PDFs.
    // If the file is actually encrypted, backend will still reject on submit.
    if (check.status == PdfPasswordCheckStatus.error) {
      debugPrint(
        '[FormField] PDF check failed (${check.message}) — accepting file as not encrypted',
      );
      setState(() {
        _isVerifyingPdf = false;
        _isPdfEncrypted = false;
        _encryptedPdfFile = null;
        _pdfPassword = '';
        _pdfVerificationError = '';
        _fileError = null;
      });
      widget.onChange('${widget.name}_pass', null);
      widget.onChange(widget.name, file);
      return;
    }

    if (check.status == PdfPasswordCheckStatus.encrypted) {
      setState(() {
        _isVerifyingPdf = false;
        _isPdfEncrypted = true;
        _encryptedPdfFile = file;
        _pdfPassword = '';
        _pdfVerificationError = '';
        _fileError = null;
      });
      // Do not accept into formData until password is verified.
      return;
    }

    // Not encrypted — accept file and clear any previous password key.
    setState(() {
      _isVerifyingPdf = false;
      _isPdfEncrypted = false;
      _encryptedPdfFile = null;
      _pdfPassword = '';
      _pdfVerificationError = '';
      _fileError = null;
    });
    widget.onChange('${widget.name}_pass', null);
    widget.onChange(widget.name, file);
  }

  void _clearPdfPasswordState({bool clearPassFormKey = false}) {
    _isPdfEncrypted = false;
    _encryptedPdfFile = null;
    _pdfPassword = '';
    _showPdfPassword = false;
    _pdfVerificationError = '';
    _isVerifyingPdf = false;
    if (clearPassFormKey) {
      widget.onChange('${widget.name}_pass', null);
    }
  }

  Future<void> _verifyPendingPdfPassword() async {
    final file = _encryptedPdfFile;
    final workflowKey = widget.workflowKey?.trim() ?? '';
    if (file == null || workflowKey.isEmpty) return;

    // Web note: blank password allowed via a space.
    final password = _pdfPassword.isEmpty ? ' ' : _pdfPassword;

    setState(() {
      _isVerifyingPdf = true;
      _pdfVerificationError = '';
    });

    final result = await PdfPasswordService.verifyPassword(
      file: file,
      password: password,
      workflowKey: workflowKey,
    );

    if (!mounted) return;

    if (!result.success) {
      setState(() {
        _isVerifyingPdf = false;
        _pdfVerificationError = result.message.isNotEmpty
            ? result.message
            : 'Incorrect password. Please try again.';
      });
      return;
    }

    setState(() {
      _isVerifyingPdf = false;
      _isPdfEncrypted = false;
      _encryptedPdfFile = null;
      _pdfVerificationError = '';
      _fileError = null;
    });
    widget.onChange('${widget.name}_pass', password);
    widget.onChange(widget.name, file);
  }

  void _removeSelectedOrPendingFile() {
    setState(() {
      // After remove, signature fields return to digital pad (default mode).
      _showInlineSignaturePad = _isSignatureField;
      _clearPdfPasswordState();
      _fileError = null;
      _signaturePoints.clear();
      _signaturePadError = null;
    });
    widget.onChange('${widget.name}_pass', null);
    widget.onChange(widget.name, null);
  }

  bool get _isSignatureField {
    final n = widget.name.toLowerCase();
    final d = widget.displayName.toLowerCase();
    return n.contains('signature') || d.contains('signature');
  }

  static const double _signatureCanvasHeight = 260;
  Size _signatureDrawSize = Size.zero;

  Offset _clampSignaturePoint(Offset point, Size drawSize) {
    return Offset(
      point.dx.clamp(0.0, drawSize.width),
      point.dy.clamp(0.0, drawSize.height),
    );
  }

  Future<File?> _buildSignatureFileFromPoints(Size drawSize) async {
    if (!drawSize.width.isFinite ||
        !drawSize.height.isFinite ||
        drawSize.width <= 0 ||
        drawSize.height <= 0) {
      return null;
    }
    if (!_signaturePoints.any((p) => p != null)) return null;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & drawSize,
      Paint()..color = Colors.white,
    );

    final strokePaint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var i = 0; i < _signaturePoints.length - 1; i++) {
      final p1 = _signaturePoints[i];
      final p2 = _signaturePoints[i + 1];
      if (p1 != null && p2 != null) {
        canvas.drawLine(p1, p2, strokePaint);
      }
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      drawSize.width.ceil(),
      drawSize.height.ceil(),
    );
    final pngBytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (pngBytes == null) return null;

    final file = File(
      '${Directory.systemTemp.path}/digital_signature_${DateTime.now().millisecondsSinceEpoch}.png',
    );
    await file.writeAsBytes(pngBytes.buffer.asUint8List(), flush: true);
    return file;
  }

  Widget _buildInlineSignaturePad() {
    return SizedBox(
      width: double.infinity,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(
            color: _fileError != null ? Colors.red : Colors.grey.shade400,
            width: 2,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
          borderRadius: BorderRadius.circular(12),
          color: Colors.grey.shade50,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Draw your signature in the box below.',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: _signatureCanvasHeight,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final drawSize = Size(
                        constraints.maxWidth,
                        constraints.maxHeight,
                      );
                      _signatureDrawSize = drawSize;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanStart: widget.disable
                            ? null
                            : (details) {
                                setState(() {
                                  _signaturePadError = null;
                                  _signaturePoints.add(
                                    _clampSignaturePoint(
                                      details.localPosition,
                                      drawSize,
                                    ),
                                  );
                                });
                              },
                        onPanUpdate: widget.disable
                            ? null
                            : (details) {
                                setState(() {
                                  _signaturePoints.add(
                                    _clampSignaturePoint(
                                      details.localPosition,
                                      drawSize,
                                    ),
                                  );
                                });
                              },
                        onPanEnd: widget.disable
                            ? null
                            : (_) {
                                setState(() => _signaturePoints.add(null));
                              },
                        child: CustomPaint(
                          painter: _SignaturePainter(points: _signaturePoints),
                          size: drawSize,
                          child: _signaturePoints.isEmpty
                              ? Center(
                                  child: Text(
                                    'Sign here',
                                    style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontSize: 16,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            if (_signaturePadError != null) ...[
              const SizedBox(height: 8),
              Text(
                _signaturePadError!,
                style: TextStyle(color: Colors.red.shade700, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton(
                  onPressed: widget.disable || _signatureSubmitting
                      ? null
                      : () {
                          setState(() {
                            _showInlineSignaturePad = false;
                            _signaturePoints.clear();
                            _signaturePadError = null;
                          });
                        },
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                OutlinedButton(
                  onPressed: widget.disable || _signatureSubmitting
                      ? null
                      : () {
                          setState(() {
                            _signaturePoints.clear();
                            _signaturePadError = null;
                          });
                        },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: KycTheme.primary),
                    foregroundColor: KycTheme.primary,
                  ),
                  child: const Text('Clear'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: widget.disable || _signatureSubmitting
                      ? null
                      : () async {
                          if (!_signaturePoints.any((p) => p != null)) {
                            setState(() {
                              _signaturePadError =
                                  'Please draw your signature first.';
                            });
                            return;
                          }
                          setState(() {
                            _signatureSubmitting = true;
                            _signaturePadError = null;
                          });
                          final file = await _buildSignatureFileFromPoints(
                            _signatureDrawSize,
                          );
                          if (!mounted) return;
                          if (file == null) {
                            setState(() {
                              _signatureSubmitting = false;
                              _signaturePadError =
                                  'Unable to capture signature. Please try again.';
                            });
                            return;
                          }
                          setState(() {
                            _showInlineSignaturePad = false;
                            _signatureSubmitting = false;
                            _signaturePoints.clear();
                          });
                          await _handleFileSelection(file);
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: KycTheme.primary,
                    foregroundColor: Colors.white,
                  ),
                  child: _signatureSubmitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Confirm'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool _isImageFile(File file) {
    final ext = file.path.split('.').last.toLowerCase();
    return ext == 'jpg' || ext == 'jpeg' || ext == 'png' || ext == 'gif' || ext == 'webp';
  }

  Widget _buildSelectedFilePreview(File file) {
    if (_isImageFile(file)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          file,
          height: 180,
          width: double.infinity,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Icon(
            Icons.broken_image_outlined,
            size: 48,
            color: Colors.grey.shade600,
          ),
        ),
      );
    }

    return Column(
      children: [
        Icon(Icons.insert_drive_file, size: 48, color: Colors.blue.shade600),
        const SizedBox(height: 8),
        Text(
          file.path.split('/').last,
          style: const TextStyle(fontWeight: FontWeight.w500),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildFile() {
    final hasFile = widget.value != null && widget.value is File;
    final pendingEncrypted = _isPdfEncrypted && _encryptedPdfFile != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        if (widget.fileType != null || widget.size != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '${widget.fileType != null ? "Allowed: ${(widget.fileType!).map((ft) => ft is Map ? ft['label'] : ft).join(', ')}" : ''}${widget.size != null ? ' • Max: ${widget.size}MB' : ''}',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
        if (_isSignatureField && _showInlineSignaturePad)
          _buildInlineSignaturePad()
        else
          InkWell(
            onTap: widget.disable ||
                    _isVerifyingPdf ||
                    hasFile ||
                    pendingEncrypted
                ? null
                : () async {
                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.any,
                    );
                    if (result != null && result.files.single.path != null) {
                      await _handleFileSelection(
                        File(result.files.single.path!),
                      );
                    }
                  },
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                border: Border.all(
                  color: _fileError != null ? Colors.red : Colors.grey.shade400,
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignInside,
                ),
                borderRadius: BorderRadius.circular(12),
                color: Colors.grey.shade50,
              ),
              child: _isVerifyingPdf && !pendingEncrypted
                  ? const Column(
                      children: [
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                        SizedBox(height: 12),
                        Text('Checking PDF...'),
                      ],
                    )
                  : hasFile
                      ? Column(
                          children: [
                            _buildSelectedFilePreview(widget.value as File),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: _removeSelectedOrPendingFile,
                              child: const Text('Remove'),
                            ),
                          ],
                        )
                      : pendingEncrypted
                          ? Column(
                              children: [
                                _buildSelectedFilePreview(_encryptedPdfFile!),
                                const SizedBox(height: 8),
                                Text(
                                  'Password protected PDF',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.orange.shade800,
                                  ),
                                ),
                                TextButton(
                                  onPressed: _removeSelectedOrPendingFile,
                                  child: const Text('Remove'),
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                Icon(Icons.cloud_upload,
                                    size: 48, color: Colors.grey.shade600),
                                const SizedBox(height: 8),
                                const Text('Tap to browse or drop file'),
                              ],
                            ),
            ),
          ),
        if (pendingEncrypted) ...[
          const SizedBox(height: 12),
          TextField(
            obscureText: !_showPdfPassword,
            enabled: !_isVerifyingPdf && !widget.disable,
            onChanged: (v) => setState(() {
              _pdfPassword = v;
              _pdfVerificationError = '';
            }),
            decoration: InputDecoration(
              labelText: 'Enter Password',
              hintText: 'Enter Password',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              errorText: _pdfVerificationError.isEmpty
                  ? null
                  : _pdfVerificationError,
              suffixIcon: IconButton(
                icon: Icon(
                  _showPdfPassword ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () =>
                    setState(() => _showPdfPassword = !_showPdfPassword),
              ),
            ),
            onSubmitted: (_) {
              if (!_isVerifyingPdf) _verifyPendingPdfPassword();
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Note: If your document isn\'t password protected, you can simply leave the password field blank by entering a space.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: (_isVerifyingPdf || widget.disable)
                  ? null
                  : _verifyPendingPdfPassword,
              style: ElevatedButton.styleFrom(
                backgroundColor: KycTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: _isVerifyingPdf
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Verify Password'),
            ),
          ),
        ],
        if (_fileError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_fileError!, style: TextStyle(color: Colors.red.shade700, fontSize: 12)),
          ),
        if (_isSignatureField && !_showInlineSignaturePad) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: widget.disable || hasFile || pendingEncrypted
                  ? null
                  : () {
                      setState(() {
                        _showInlineSignaturePad = true;
                        _signaturePoints.clear();
                        _signaturePadError = null;
                      });
                    },
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                side: const BorderSide(color: KycTheme.primary),
                foregroundColor: KycTheme.primary,
              ),
              child: const Text('Digital Signature'),
            ),
          ),
        ],
      ],
    );
  }

  /// OTP field – design: 6 square boxes, sirf user OTP dalega
  Widget _buildOtp() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabel(widget.displayName),
        const SizedBox(height: 12),
        OtpInput(
          length: 6,
          onChanged: (v) => widget.onChange(widget.name, v),
          onComplete: (v) => widget.onChange(widget.name, v),
        ),
      ],
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<Offset?> points;

  const _SignaturePainter({required this.points});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (var i = 0; i < points.length - 1; i++) {
      final p1 = points[i];
      final p2 = points[i + 1];
      if (p1 != null && p2 != null) {
        canvas.drawLine(p1, p2, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) =>
      oldDelegate.points != points;
}

/// Calendar-icon modal for DD/MM/YYYY steps — normal keyboard + auto `/` (UI only).
Future<DateTime?> showDdMmYyyyDatePickerDialog({
  required BuildContext context,
  required DateTime initial,
  required DateTime first,
  required DateTime last,
  required String title,
  Map<dynamic, dynamic>? fieldMeta,
}) {
  return showDialog<DateTime>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _DdMmYyyyDatePickerDialog(
      initial: initial,
      first: first,
      last: last,
      title: title,
      fieldMeta: fieldMeta,
    ),
  );
}

class _DdMmYyyyDatePickerDialog extends StatefulWidget {
  final DateTime initial;
  final DateTime first;
  final DateTime last;
  final String title;
  final Map<dynamic, dynamic>? fieldMeta;

  const _DdMmYyyyDatePickerDialog({
    required this.initial,
    required this.first,
    required this.last,
    required this.title,
    this.fieldMeta,
  });

  @override
  State<_DdMmYyyyDatePickerDialog> createState() =>
      _DdMmYyyyDatePickerDialogState();
}

class _DdMmYyyyDatePickerDialogState extends State<_DdMmYyyyDatePickerDialog> {
  static const Locale _pickerLocale = Locale('en', 'IN');

  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late DateTime _selectedDate;
  bool _applyingMask = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedDate = widget.initial;
    _controller = TextEditingController(
      text: DateFormat('dd/MM/yyyy').format(widget.initial),
    );
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    if (_applyingMask) return;
    final formatted = formatDdMmYyyyTyping(value);
    if (formatted != _controller.text) {
      _applyingMask = true;
      _controller.value = TextEditingValue(
        text: formatted,
        selection: TextSelection.collapsed(offset: formatted.length),
      );
      _applyingMask = false;
    }
    DateTime? parsed;
    final d = parseKycDateValueAsDdMmYyyy(formatted) ?? parseKycDateValue(formatted);
    if (d != null) {
      parsed = DateTime(d.year, d.month, d.day);
    }
    setState(() {
      _error = null;
      if (parsed != null &&
          !parsed.isBefore(widget.first) &&
          !parsed.isAfter(widget.last)) {
        _selectedDate = parsed;
      }
    });
  }

  void _onCalendarDateChanged(DateTime picked) {
    setState(() {
      _selectedDate = picked;
      _controller.text = DateFormat('dd/MM/yyyy').format(picked);
      _error = null;
    });
  }

  void _confirm() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Please enter a date');
      return;
    }
    final d = parseKycDateValueAsDdMmYyyy(raw) ?? parseKycDateValue(raw);
    if (d == null) {
      setState(() => _error = 'Enter date as DD/MM/YYYY');
      return;
    }
    final picked = DateTime(d.year, d.month, d.day);
    if (picked.isBefore(widget.first) || picked.isAfter(widget.last)) {
      final meta = widget.fieldMeta;
      if (meta != null) {
        final msg = validateDobAgainstFieldBounds(meta, raw);
        if (msg != null) {
          setState(() => _error = msg);
          return;
        }
      }
      setState(
        () => _error =
            'Date must be between ${DateFormat('dd/MM/yyyy').format(widget.first)} and '
            '${DateFormat('dd/MM/yyyy').format(widget.last)}',
      );
      return;
    }
    Navigator.of(context).pop(picked);
  }

  @override
  Widget build(BuildContext context) {
    final dialogWidth = MediaQuery.sizeOf(context).width * 0.92;
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(KycTheme.radiusMd),
      ),
      title: Text(
        widget.title,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: KycTheme.textPrimary,
        ),
      ),
      content: SizedBox(
        width: dialogWidth.clamp(280.0, 400.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _controller,
                focusNode: _focusNode,
                keyboardType: TextInputType.text,
                inputFormatters: ddMmYyyyKeyboardFormatters,
                onChanged: _onTextChanged,
                onFieldSubmitted: (_) => _confirm(),
                style: const TextStyle(
                  fontSize: 16,
                  color: KycTheme.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: 'DD/MM/YYYY',
                  prefixIcon: const Icon(
                    Icons.edit_calendar_outlined,
                    color: KycTheme.textSecondary,
                  ),
                  errorText: _error,
                  filled: true,
                  fillColor: KycTheme.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(KycTheme.radiusMd),
                    borderSide: const BorderSide(color: KycTheme.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(KycTheme.radiusMd),
                    borderSide: const BorderSide(color: KycTheme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(KycTheme.radiusMd),
                    borderSide:
                        const BorderSide(color: KycTheme.primary, width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Localizations.override(
                context: context,
                locale: _pickerLocale,
                child: Theme(
                  data: Theme.of(context).copyWith(
                    colorScheme: Theme.of(context).colorScheme.copyWith(
                          primary: KycTheme.primary,
                          onPrimary: Colors.white,
                        ),
                  ),
                  child: CalendarDatePicker(
                    key: ValueKey<String>(
                      '${_selectedDate.year}-${_selectedDate.month}-${_selectedDate.day}',
                    ),
                    initialDate: _selectedDate,
                    firstDate: widget.first,
                    lastDate: widget.last,
                    onDateChanged: _onCalendarDateChanged,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _confirm,
          style: FilledButton.styleFrom(
            backgroundColor: KycTheme.primary,
          ),
          child: const Text('OK'),
        ),
      ],
    );
  }
}
