import 'package:flutter/services.dart';

const _channel = MethodChannel('com.silhou.cove/widget_refresh');

/// Widget refresh interval (§11) — swaps the native widgets'
/// `updatePeriodMillis` between 30/60/120-min presets via
/// `AppWidgetManager.updateAppWidgetProviderInfo` (Android 12+ only; see
/// `MainActivity.kt`). Best-effort, same rule as every other platform
/// channel in this app (§12) — a missing channel (unit tests) or an
/// unsupported Android version must never block or crash the caller.
Future<void> setWidgetRefreshIntervalMinutes(int minutes) async {
  try {
    await _channel.invokeMethod('setRefreshIntervalMinutes', {
      'minutes': minutes,
    });
  } catch (_) {
    // No platform channel available, or unsupported Android version.
  }
}
