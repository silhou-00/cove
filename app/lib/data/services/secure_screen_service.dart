import 'package:flutter/services.dart';

const _channel = MethodChannel('com.silhou.cove/secure_screen');

/// FLAG_SECURE (§12) — blocks screenshots/screen-recording/recent-apps
/// thumbnail capture while a PIN-entry screen is visible; called with
/// `true` on mount and `false` on unmount by the lock screen, the
/// disable-App-Lock re-confirmation sheet, and the set-PIN sheet.
/// Best-effort, same rule as every other platform channel in this app
/// (§12) — a missing channel (unit/widget tests) must never block or
/// crash the caller.
Future<void> setSecureScreen(bool secure) async {
  try {
    await _channel.invokeMethod('setSecure', {'secure': secure});
  } catch (_) {
    // No platform channel available.
  }
}
