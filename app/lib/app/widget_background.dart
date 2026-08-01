import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/db/database.dart';
import '../data/repositories/item_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/tag_repository.dart';
import '../data/repositories/unlockable_repository.dart';
import '../data/repositories/xp_repository.dart';
import '../data/services/notification_service.dart';

/// Registered once at app startup (`main.dart`) via
/// `HomeWidget.registerInteractivityCallback` — lets a tap on a specific
/// view inside a home-screen widget run Dart code in a background isolate
/// without opening the app UI. Currently only the Up Next widget's
/// per-row complete-toggle circle uses this (`cove://complete?...`); see
/// UpNextWidgetProvider.kt for where the tap is wired up.
///
/// `@pragma('vm:entry-point')` is required — this may run in a fresh
/// isolate spun up purely for this callback, with no guarantee the main
/// app's isolate (or its `ProviderScope`) is alive, so it opens its own
/// short-lived `AppDatabase` connection rather than reaching for any
/// Riverpod provider.
@pragma('vm:entry-point')
Future<void> widgetBackgroundCallback(Uri? uri) async {
  if (uri == null || uri.host != 'complete') return;
  WidgetsFlutterBinding.ensureInitialized();

  final itemId = uri.queryParameters['itemId'];
  if (itemId == null || itemId.isEmpty) return;
  final occurrenceId = uri.queryParameters['occurrenceId'];

  final db = AppDatabase();
  try {
    final settings = SettingsRepository(db);
    final unlockables = UnlockableRepository(db, settings);
    final itemRepo = ItemRepository(
      db,
      NotificationService(settings),
      TagRepository(db),
      XpRepository(db, unlockables),
    );
    if (occurrenceId != null && occurrenceId.isNotEmpty) {
      await itemRepo.toggleOccurrenceComplete(occurrenceId);
    } else {
      await itemRepo.toggleComplete(itemId);
    }
  } finally {
    await db.close();
  }
}
