import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'package:workmanager/workmanager.dart';

import 'app/app.dart';
import 'app/session_lock.dart';
import 'app/widget_background.dart';
import 'data/db/database.dart';
import 'data/repositories/profile_repository.dart';
import 'features/calendar/offline_export_queue.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // §9, Calendar export "always add" offline retry — the only
  // workmanager job in this app. Registering the dispatcher here is
  // required even though nothing may ever call queueOfflineExport(); it's
  // a no-op until that happens.
  await Workmanager().initialize(calendarExportCallbackDispatcher);
  // Up Next widget's per-row complete-toggle (§6/§17) — must be
  // registered here, not lazily inside `CoveApp`, since a widget tap can
  // invoke `widgetBackgroundCallback` in a fresh isolate that never
  // builds the widget tree at all.
  await HomeWidget.registerInteractivityCallback(widgetBackgroundCallback);
  await _loadSessionLockState();
  runApp(const ProviderScope(child: CoveApp()));
}

/// Populates `SessionLock.instance.enabled` before the widget tree (and
/// with it, `appRouter`'s redirect) is built (§12) — a notification tap
/// or widget tap can trigger navigation within the very first frame, so
/// this can't be left to load lazily inside `CoveApp` without leaving a
/// brief bypass window. Uses its own short-lived `AppDatabase` connection
/// rather than the one `ProviderScope` will construct — the two don't
/// conflict (SQLite allows multiple connections to the same file), and
/// this one closes immediately after the read.
Future<void> _loadSessionLockState() async {
  final db = AppDatabase();
  try {
    final enabled = await ProfileRepository(db).isAppLockEnabled();
    SessionLock.instance.enabled = enabled;
    if (!enabled) SessionLock.instance.unlocked = true;
  } finally {
    await db.close();
  }
}
