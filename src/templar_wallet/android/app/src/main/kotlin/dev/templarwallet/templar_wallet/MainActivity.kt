package dev.templarwallet.templar_wallet

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// A FragmentActivity rather than the plain FlutterActivity: androidx.biometric's
// BiometricPrompt, which biometric_storage drives for the fingerprint vault
// unlock, can only be hosted by one. Otherwise identical.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Seed words and private keys are shown behind FLAG_SECURE: no
        // screenshots, no recents thumbnail, no screen capture while visible.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.templarwallet/screen")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setSecure" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // The app's own page in system Settings — where a camera permission
        // that was denied "don't ask again" can be granted. Flutter has no
        // portable way to open it, and url_launcher cannot reach it.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.templarwallet/system")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openAppSettings" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                Uri.parse("package:$packageName")
                            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
