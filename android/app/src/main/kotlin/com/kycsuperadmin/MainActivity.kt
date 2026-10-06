package com.kycsuperadmin

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val paymentChannel = "com.kycsuperadmin/payment"
    private val simPhoneChannel = "com.kycsuperadmin/sim_phone"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, paymentChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchIntentUrl" -> {
                        val intentUrl = call.argument<String>("intentUrl")
                        if (intentUrl.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(launchParsedIntentUrl(intentUrl))
                    }
                    "launchUpi" -> {
                        val dataUri = call.argument<String>("dataUri")
                        val packageName = call.argument<String>("packageName")
                        if (dataUri.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        result.success(launchPaymentDataUri(dataUri, packageName))
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, simPhoneChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSimPhoneNumbers" -> {
                        try {
                            result.success(getSimPhoneNumbers())
                        } catch (e: SecurityException) {
                            result.error("PERMISSION", e.message, null)
                        } catch (e: Exception) {
                            result.error("ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasPhoneReadPermission(): Boolean {
        val phoneState = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_PHONE_STATE,
        ) == PackageManager.PERMISSION_GRANTED
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return phoneState
        val phoneNumbers = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_PHONE_NUMBERS,
        ) == PackageManager.PERMISSION_GRANTED
        return phoneState || phoneNumbers
    }

    private fun getSimPhoneNumbers(): List<Map<String, Any?>> {
        if (!hasPhoneReadPermission()) return emptyList()

        val out = mutableListOf<Map<String, Any?>>()
        val seen = linkedSetOf<String>()
        val sm = getSystemService(TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
            ?: return emptyList()

        val subs = try {
            sm.activeSubscriptionInfoList
        } catch (_: SecurityException) {
            null
        } ?: emptyList()

        for (info in subs) {
            val subId = info.subscriptionId
            var number = ""
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                try {
                    number = sm.getPhoneNumber(subId)?.trim().orEmpty()
                } catch (_: Exception) {
                    number = ""
                }
            }
            if (number.isBlank()) {
                number = info.number?.trim().orEmpty()
            }
            if (number.isBlank() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                try {
                    val tm = getSystemService(TELEPHONY_SERVICE) as? TelephonyManager
                    val forSub = tm?.createForSubscriptionId(subId)
                    number = forSub?.line1Number?.trim().orEmpty()
                } catch (_: Exception) {
                    number = ""
                }
            }
            if (number.isBlank()) continue
            if (!seen.add(number)) continue
            out.add(
                mapOf(
                    "phoneNumber" to number,
                    "carrierName" to (info.carrierName?.toString() ?: ""),
                    "slotIndex" to info.simSlotIndex,
                    "subscriptionId" to subId,
                ),
            )
        }

        // Fallback: default telephony line1Number when subscription list had no MSISDN.
        if (out.isEmpty()) {
            try {
                val tm = getSystemService(TELEPHONY_SERVICE) as? TelephonyManager
                val line1 = tm?.line1Number?.trim().orEmpty()
                if (line1.isNotBlank()) {
                    out.add(
                        mapOf(
                            "phoneNumber" to line1,
                            "carrierName" to (tm?.networkOperatorName ?: ""),
                            "slotIndex" to 0,
                            "subscriptionId" to -1,
                        ),
                    )
                }
            } catch (_: Exception) {
                // ignore
            }
        }
        return out
    }

    /** Chrome-style handling for `intent:upi://pay?...#Intent;package=...;end`. */
    private fun launchParsedIntentUrl(intentUrl: String): Boolean {
        return try {
            val intent = Intent.parseUri(intentUrl, Intent.URI_INTENT_SCHEME)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun launchPaymentDataUri(dataUri: String, packageName: String?): Boolean {
        val candidates = buildPaymentUriCandidates(dataUri, packageName)
        val gpayPackage = "com.google.android.apps.nbu.paisa.user"
        val whatsappPackages = listOf("com.whatsapp", "com.whatsapp.w4b")
        val upiPackages = listOf(
            gpayPackage,
            "com.phonepe.app",
            "net.one97.paytm",
            "in.org.npci.upiapp",
            "com.whatsapp",
            "com.whatsapp.w4b",
        )

        // Explicit package: ALWAYS try standard upi://pay?... first.
        // Custom phonepe:// / paytm:// schemes often only open the app home
        // without the amount/payment screen.
        if (!packageName.isNullOrBlank()) {
            for (candidate in candidates) {
                if (candidate.startsWith("upi://", ignoreCase = true)) {
                    if (tryLaunch(candidate, packageName)) return true
                }
            }
            for (candidate in candidates) {
                if (tryLaunch(candidate, packageName)) return true
            }
            // Older Google Pay package on some devices.
            if (packageName == gpayPackage) {
                for (candidate in candidates) {
                    if (tryLaunch(candidate, "com.google.android.apps.walletnfcrel")) return true
                }
            }
            // WhatsApp / WhatsApp Business both may handle UPI.
            if (packageName in whatsappPackages) {
                for (waPkg in whatsappPackages) {
                    for (candidate in candidates) {
                        if (candidate.startsWith("upi://", ignoreCase = true) &&
                            tryLaunch(candidate, waPkg)
                        ) {
                            return true
                        }
                    }
                }
            }
            return false
        }

        // App-specific schemes (tez/gpay) — launch without package first.
        for (candidate in candidates) {
            val lower = candidate.lowercase()
            if (lower.startsWith("tez://") || lower.startsWith("gpay://") || lower.startsWith("googlepay://")) {
                if (tryLaunch(candidate, null)) return true
            }
        }

        // Generic upi:// when no target package was requested.
        for (candidate in candidates) {
            if (candidate.lowercase().startsWith("upi://") && tryLaunch(candidate, null)) {
                return true
            }
        }
        // No default handler — try known UPI apps, then a chooser.
        for (candidate in candidates) {
            if (!candidate.lowercase().startsWith("upi://")) continue
            for (pkg in upiPackages) {
                if (tryLaunch(candidate, pkg)) return true
            }
            if (tryLaunchChooser(candidate)) return true
        }

        return false
    }

    private fun tryLaunch(dataUri: String, packageName: String?): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(dataUri))
            if (!packageName.isNullOrBlank()) {
                intent.setPackage(packageName)
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun tryLaunchChooser(dataUri: String): Boolean {
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(dataUri))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(Intent.createChooser(intent, "Pay with UPI"))
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Convert phonepe://upi/pay?... / paytmmp://pay?... / gpay://upi/pay?...
     * into standard NPCI upi://pay?... so wallets open the amount screen.
     */
    private fun toStandardUpiPayUri(dataUri: String): String? {
        if (dataUri.startsWith("upi://", ignoreCase = true)) return dataUri
        val payIdx = dataUri.indexOf("pay?", ignoreCase = true)
        if (payIdx < 0) return null
        return "upi://${dataUri.substring(payIdx)}"
    }

    private fun buildPaymentUriCandidates(
        dataUri: String,
        packageName: String?,
    ): List<String> {
        // Prefer NPCI upi:// first — custom schemes are fallbacks only.
        val uris = linkedSetOf<String>()
        val standard = toStandardUpiPayUri(dataUri)
        if (standard != null) uris.add(standard)
        uris.add(dataUri)

        val gpayPackage = "com.google.android.apps.nbu.paisa.user"
        val isGpay = packageName == gpayPackage ||
            dataUri.lowercase().let {
                it.startsWith("tez://") || it.startsWith("gpay://") || it.startsWith("googlepay://")
            }

        if (isGpay) {
            val upi = standard ?: dataUri
            if (upi.startsWith("upi://pay", ignoreCase = true)) {
                val suffix = upi.substring("upi://".length) // pay?ver=...
                uris.add("tez://upi/$suffix")
                uris.add("tez://$suffix")
                uris.add("gpay://upi/$suffix")
                uris.add("gpay://$suffix")
                uris.add("googlepay://upi/$suffix")
                uris.add("googlepay://$suffix")
            }
        } else if (packageName != null) {
            val path = stripPaymentScheme(standard ?: dataUri)
            if (path != null) {
                when {
                    packageName.contains("phonepe") -> {
                        // Fallbacks only — upi:// is tried first above.
                        uris.add("phonepe://$path")
                        if (path.startsWith("upi/pay", ignoreCase = true)) {
                            uris.add("phonepe://${path.removePrefix("upi/")}")
                        } else if (path.startsWith("pay", ignoreCase = true)) {
                            uris.add("phonepe://$path")
                        }
                    }
                    packageName.contains("paytm") -> {
                        uris.add("paytmmp://$path")
                        uris.add("paytm://$path")
                        if (path.startsWith("upi/pay", ignoreCase = true)) {
                            val payPath = path.removePrefix("upi/")
                            uris.add("paytmmp://$payPath")
                            uris.add("paytm://$payPath")
                        } else if (path.startsWith("pay", ignoreCase = true)) {
                            uris.add("paytmmp://$path")
                            uris.add("paytm://$path")
                        }
                    }
                    packageName.contains("npci") || packageName.contains("upiapp") -> {
                        uris.add("bhim://$path")
                        if (path.startsWith("upi/pay", ignoreCase = true)) {
                            uris.add("bhim://${path.removePrefix("upi/")}")
                        }
                    }
                }
            }
        }
        return uris.toList()
    }

    private fun stripPaymentScheme(uri: String): String? {
        val idx = uri.indexOf("://")
        if (idx < 0) return null
        return uri.substring(idx + 3)
    }
}
