import 'package:flutter/foundation.dart';

/// Session-level App Lock state (§12) — separate from `Profile.
/// appLockEnabled` (the persisted setting). `enabled` is read once at
/// startup (see `main.dart`, before `runApp`) and mirrors that setting;
/// `unlocked` starts false and flips true only after a successful
/// PIN/biometric check, or immediately if App Lock is off (there's
/// nothing to unlock).
///
/// `appRouter`'s `redirect` reads this on every navigation — not just
/// splash's one-time check — because a notification tap or home-screen
/// widget tap calls `appRouter.go(...)` directly and bypasses splash
/// entirely. Without this, App Lock protected nothing for either path.
class SessionLock extends ChangeNotifier {
  SessionLock._();
  static final instance = SessionLock._();

  bool enabled = false;
  bool unlocked = false;

  /// Called once at startup with the real persisted value, and again
  /// from Settings whenever the user toggles App Lock. Turning it on
  /// mid-session doesn't retroactively lock the current session (matches
  /// the existing "checked on cold start, nowhere else" rule) — only a
  /// future cold start will see `enabled: true` before anything's
  /// unlocked. Turning it off immediately stops the redirect from firing.
  void setEnabled(bool value) {
    enabled = value;
    notifyListeners();
  }

  void unlock() {
    unlocked = true;
    notifyListeners();
  }
}
