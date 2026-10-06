import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class SimPhoneOption {
  const SimPhoneOption({
    required this.phoneNumber,
    required this.displayNumber,
    this.carrierName,
    this.slotIndex,
  });

  final String phoneNumber;
  final String displayNumber;
  final String? carrierName;
  final int? slotIndex;
}

/// Android SIM helpers for the mobile step.
///
/// Uses SubscriptionManager line numbers (custom in-app picker — no Google Hint).
class SimPhoneService {
  SimPhoneService._();

  static const _channel = MethodChannel('com.kycsuperadmin/sim_phone');

  /// List via READ_PHONE_* (often empty on Indian carriers if not provisioned).
  static Future<List<SimPhoneOption>> fetchSimPhoneNumbers() async {
    if (kIsWeb || !Platform.isAndroid) return const [];

    final status = await Permission.phone.request();
    if (!status.isGranted) {
      debugPrint('[SimPhone] READ_PHONE permission denied: $status');
      return const [];
    }

    try {
      final raw =
          await _channel.invokeMethod<List<dynamic>>('getSimPhoneNumbers');
      if (raw == null) return const [];

      final out = <SimPhoneOption>[];
      final seen = <String>{};
      for (final item in raw) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final digits = normalizeIndianMobile(map['phoneNumber']?.toString());
        if (digits == null || !seen.add(digits)) continue;
        final carrier = map['carrierName']?.toString().trim();
        final slot = map['slotIndex'];
        out.add(
          SimPhoneOption(
            phoneNumber: digits,
            displayNumber: digits,
            carrierName: (carrier == null || carrier.isEmpty) ? null : carrier,
            slotIndex: slot is int ? slot : int.tryParse(slot?.toString() ?? ''),
          ),
        );
      }
      debugPrint('[SimPhone] SubscriptionManager found ${out.length} number(s)');
      return out;
    } on PlatformException catch (e) {
      debugPrint('[SimPhone] PlatformException: ${e.code} ${e.message}');
      return const [];
    } catch (e) {
      debugPrint('[SimPhone] Error: $e');
      return const [];
    }
  }

  /// Returns 10-digit Indian mobile, or null if not usable.
  static String? normalizeIndianMobile(String? raw) {
    if (raw == null) return null;
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return null;
    if (digits.startsWith('91') && digits.length >= 12) {
      digits = digits.substring(digits.length - 10);
    } else if (digits.startsWith('0') && digits.length >= 11) {
      digits = digits.substring(digits.length - 10);
    } else if (digits.length > 10) {
      digits = digits.substring(digits.length - 10);
    }
    if (digits.length != 10) return null;
    if (!RegExp(r'^[6-9]\d{9}$').hasMatch(digits)) return null;
    return digits;
  }
}
