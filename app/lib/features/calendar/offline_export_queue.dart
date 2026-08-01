import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

import '../../data/db/database.dart';
import '../../data/db/tables.dart' show ItemStatus;
import '../../data/repositories/calendar_sync_repository.dart';
import '../../data/repositories/settings_repository.dart';

const offlineExportTaskName = 'com.silhou.cove.calendarExportRetry';
const _offlineExportUniqueName = 'calendar-export-retry';

/// Registers the one-off background retry (§9, "always add" mode, and the
/// only `workmanager` job in this app) — fires once connectivity returns,
/// then [runPendingExports] batch-processes every item that couldn't
/// export at save time. `ExistingWorkPolicy.replace` means calling this
/// repeatedly (once per offline save) only ever leaves one retry pending,
/// not a growing pile of scheduled tasks.
Future<void> queueOfflineExport(WidgetRef ref, String itemId) async {
  await Workmanager().registerOneOffTask(
    _offlineExportUniqueName,
    offlineExportTaskName,
    existingWorkPolicy: ExistingWorkPolicy.replace,
    constraints: Constraints(networkType: NetworkType.connected),
  );
}

/// The retry job's actual work (§1: "batched calendar-export retry when
/// connectivity returns"). Runs in a headless background isolate, so it
/// builds its own minimal `AppDatabase`/`CalendarSyncRepository` instead
/// of reusing the app's Riverpod container, and writes
/// `externalCalendarEventId` directly via drift rather than going through
/// `ItemRepository` (which needs `NotificationService`/`TagRepository` —
/// unnecessary weight, and unnecessary plugin-initialization risk in a
/// headless isolate, for a one-column write).
Future<void> runPendingExports() async {
  final db = AppDatabase();
  try {
    final settings = SettingsRepository(db);
    final calendarRepo = CalendarSyncRepository(db, settings);
    if (!(await calendarRepo.isConnected())) return;
    final mode = await settings.getCalendarExportMode();
    if (mode != CalendarExportMode.alwaysAdd) return;

    final pending =
        await (db.select(db.items)..where(
              (i) =>
                  i.externalCalendarEventId.isNull() &
                  i.status.equalsValue(ItemStatus.open) &
                  (i.dueAt.isNotNull() | i.scheduledStart.isNotNull()),
            ))
            .get();

    for (final item in pending) {
      final date = item.scheduledStart ?? item.dueAt!;
      try {
        final eventId = await calendarRepo.exportItem(
          title: item.title,
          notes: item.notes,
          start: date,
        );
        await (db.update(db.items)..where((i) => i.id.equals(item.id))).write(
          ItemsCompanion(externalCalendarEventId: Value(eventId)),
        );
      } catch (_) {
        // One item failing (revoked token, etc.) shouldn't stop the rest
        // of the batch.
      }
    }
  } finally {
    await db.close();
  }
}

/// Registered once via `Workmanager().initialize(...)` in `main()`. Must
/// stay a top-level (or static) function with this annotation — Android
/// invokes it directly as a Dart entry point in the background isolate.
@pragma('vm:entry-point')
void calendarExportCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      if (taskName == offlineExportTaskName) {
        await runPendingExports();
      }
    } catch (_) {
      // Off-contract for BackgroundTaskHandler to let an exception
      // escape — return false instead so the platform side's own
      // retry/backoff policy (configured on registerOneOffTask) applies,
      // rather than however an uncaught isolate error is handled.
      return false;
    }
    return true;
  });
}
