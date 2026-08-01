package com.silhou.cove

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

private const val _channelName = "com.silhou.cove/widget_refresh"
private const val _secureScreenChannelName = "com.silhou.cove/secure_screen"

// local_auth's BiometricPrompt integration requires a FragmentActivity
// (§12, App lock) — plain FlutterActivity doesn't support it.
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, _channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "setRefreshIntervalMinutes") {
                    val minutes = call.argument<Int>("minutes") ?: 30
                    setWidgetRefreshInterval(minutes)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, _secureScreenChannelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    val secure = call.argument<Boolean>("secure") ?: false
                    setSecureScreen(secure)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    /**
     * FLAG_SECURE (§12) — blocks screenshots, screen recording, and the
     * recent-apps thumbnail while a PIN-entry screen (lock screen,
     * disable-App-Lock re-confirmation, set-PIN sheet) is on screen.
     * Flutter toggles this on when one mounts and off when it unmounts,
     * rather than it being set once for the whole app, so the rest of
     * the app's content stays normally screenshot-able.
     */
    private fun setSecureScreen(secure: Boolean) {
        if (secure) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    /**
     * Widget refresh interval (§11) — swaps which pre-declared XML
     * variant (`up_next_widget_info[_60|_120].xml`, etc.) is active for
     * each widget's `updatePeriodMillis`, via
     * `AppWidgetManager.updateAppWidgetProviderInfo`, which takes an
     * `"@xml/name"` resource-reference string (not a resolved resource
     * ID — confirmed against the actual android.jar stub, since this
     * isn't the signature most docs describe). Android 12+ (API 31)
     * only; below that this silently no-ops and the widgets stay on
     * their fixed 30-min default, matching this app's existing
     * best-effort platform-feature pattern (a missing/unsupported
     * platform capability never blocks or crashes anything).
     */
    private fun setWidgetRefreshInterval(minutes: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return
        val suffix = when (minutes) {
            60 -> "_60"
            120 -> "_120"
            else -> ""
        }
        val manager = AppWidgetManager.getInstance(this)
        val widgets = listOf(
            Pair(UpNextWidgetProvider::class.java, "up_next_widget_info"),
            Pair(AgendaWidgetProvider::class.java, "agenda_widget_info"),
            Pair(AreasWidgetProvider::class.java, "areas_widget_info"),
        )
        for ((cls, baseName) in widgets) {
            manager.updateAppWidgetProviderInfo(
                ComponentName(this, cls),
                "@xml/$baseName$suffix",
            )
        }
    }
}
