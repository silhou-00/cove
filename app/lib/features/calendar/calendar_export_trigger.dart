import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart' show Item;
import '../../data/db/tables.dart' show ItemStatus;
import '../../domain/services/calendar_export_decision.dart';
import 'offline_export_queue.dart';

Future<bool> _isOnline() async {
  final result = await Connectivity().checkConnectivity();
  return !result.contains(ConnectivityResult.none);
}

/// Runs the §9 save-time export decision for [item] and carries it out —
/// called from both the quick-add sheet and Item Detail's save path so
/// the ask/always-add/never behavior can't drift between the two. A
/// no-op for items with no due/scheduled date or that aren't open (Item
/// Detail is also reachable from Archive, where "Save" shouldn't push a
/// done/cancelled/deleted item onto a calendar) — safe to call
/// unconditionally after every create/update.
Future<void> maybeExportToCalendar(
  BuildContext context,
  WidgetRef ref,
  Item item,
) async {
  if (item.status != ItemStatus.open) return;
  final date = item.scheduledStart ?? item.dueAt;
  if (date == null) return;

  final calendarRepo = ref.read(calendarSyncRepositoryProvider);
  final connected = await calendarRepo.isConnected();
  if (!connected) return;
  final mode = await ref
      .read(settingsRepositoryProvider)
      .getCalendarExportMode();
  final online = await _isOnline();

  final action = decideExportAction(
    connected: connected,
    exportMode: mode,
    hasDate: true,
    alreadyExported: item.externalCalendarEventId != null,
    online: online,
  );

  switch (action) {
    case ExportAction.none:
      return;
    case ExportAction.prompt:
      if (context.mounted) _showExportPrompt(context, ref, item, date);
    case ExportAction.autoExport:
      await exportItemNow(ref, item, date);
    case ExportAction.queueForLater:
      await queueOfflineExport(ref, item.id);
  }
}

void _showExportPrompt(
  BuildContext context,
  WidgetRef ref,
  Item item,
  DateTime date,
) {
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      backgroundColor: context.colors.ink,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 5),
      content: Text(
        "Add '${item.title}' to Google Calendar?",
        style: TextStyle(color: context.colors.surface),
      ),
      action: SnackBarAction(
        label: 'ADD',
        textColor: const Color(0xFFCFC7B8),
        onPressed: () => exportItemNow(ref, item, date),
      ),
    ),
  );
}

/// The actual push — shared by the auto-export path, the prompt's "Add"
/// action, and Item Detail's manual toggle. Best-effort, same rule as
/// every other Google network call in this app (§12): a failed export
/// never blocks or crashes whatever it followed.
Future<void> exportItemNow(WidgetRef ref, Item item, DateTime date) async {
  try {
    final eventId = await ref
        .read(calendarSyncRepositoryProvider)
        .exportItem(title: item.title, notes: item.notes, start: date);
    await ref
        .read(itemRepositoryProvider)
        .setExternalCalendarEventId(item.id, eventId);
  } catch (_) {
    // Offline mid-flight, token expired, etc. — the item just stays
    // un-exported; nothing else in the app depends on this succeeding.
  }
}
