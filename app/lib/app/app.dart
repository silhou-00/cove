import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/services/cosmetics.dart';
import 'providers.dart';
import 'router.dart';
import 'theme.dart';

class CoveApp extends ConsumerStatefulWidget {
  const CoveApp({super.key});

  @override
  ConsumerState<CoveApp> createState() => _CoveAppState();
}

class _CoveAppState extends ConsumerState<CoveApp> {
  StreamSubscription<String>? _notificationTapSubscription;
  StreamSubscription<Uri?>? _widgetTapSubscription;

  @override
  void initState() {
    super.initState();
    _bootstrapNotifications();
    _bootstrapWidgetTaps();
    _bootstrapThemeMode();
    _bootstrapCosmetics();
    _sweepStaleExportFiles();
    // Lazy horizon top-up (§3, Recurrence) instead of a `workmanager` job —
    // occurrences only matter for whatever date range is on screen, and
    // the app has to be open to see it anyway, so this only needs to run
    // once per launch, not in the background.
    ref.read(itemRepositoryProvider).extendRecurrenceHorizons();
    // Overdue XP penalty (§17 addendum) — same lazy on-open pattern as
    // the horizon top-up above; the exact moment doesn't matter, only
    // that it's caught the next time the app is actually opened.
    ref.read(itemRepositoryProvider).applyOverduePenalties();
  }

  /// Notification tap → `/item/[id]` (§7). Covers both the app being
  /// resumed by a tap (the stream) and a cold start caused by one (the
  /// launch-details check).
  Future<void> _bootstrapNotifications() async {
    final service = ref.read(notificationServiceProvider);
    _notificationTapSubscription = service.itemTapped.listen(
      (itemId) => appRouter.go('/item/$itemId'),
      onError: (_) {},
    );
    try {
      final launchItemId = await service.consumeLaunchPayload();
      if (launchItemId != null) appRouter.go('/item/$launchItemId');
    } catch (_) {
      // A cold start's platform channels can still be finishing
      // registration the moment this runs (§12) — a transient failure
      // here must never crash the app; it just means this one launch
      // doesn't deep-link, the same as opening Cove normally.
    }
  }

  /// Home-screen widget taps (§6). `home_widget`'s own launch-intent
  /// mechanism delivers a `cove://` URI here — no OS-level intent-filter
  /// needed. Each widget's root (tapping anywhere that isn't a more
  /// specific row/button) sends its own host-only URI so it lands on that
  /// widget's own page, not just item rows (see each `*WidgetProvider.kt`
  /// for where these are set).
  Future<void> _bootstrapWidgetTaps() async {
    _widgetTapSubscription = HomeWidget.widgetClicked.listen(
      _openFromWidgetUri,
      onError: (_) {},
    );
    _openFromWidgetUri(await _initialWidgetLaunchUri());
  }

  /// A widget tap that cold-starts the app can race `home_widget`'s own
  /// platform-channel registration (§12) — this call can throw once,
  /// intermittently, right after launch, then succeed a moment later.
  /// One retry after a short delay absorbs that instead of surfacing an
  /// error on an otherwise-normal widget tap.
  Future<Uri?> _initialWidgetLaunchUri() async {
    try {
      return await HomeWidget.initiallyLaunchedFromHomeWidget();
    } catch (_) {
      try {
        await Future.delayed(const Duration(milliseconds: 300));
        return await HomeWidget.initiallyLaunchedFromHomeWidget();
      } catch (_) {
        return null;
      }
    }
  }

  void _openFromWidgetUri(Uri? uri) {
    if (uri == null) return;
    switch (uri.host) {
      case 'item':
        if (uri.pathSegments.isNotEmpty) {
          appRouter.go('/item/${uri.pathSegments.last}');
        }
      case 'agenda':
        appRouter.go('/home', extra: (tabIndex: 0, upNext: false));
      case 'upnext':
        appRouter.go('/home', extra: (tabIndex: 0, upNext: true));
      case 'areas':
        appRouter.go('/home', extra: (tabIndex: 2, upNext: false));
    }
  }

  /// Loads the persisted theme mode (§11) into [themeModeProvider] so
  /// `build()` picks it up on the next frame — mirrors the other
  /// `_bootstrap*` methods above (load once at launch, live-update via
  /// the provider afterward, not re-read from storage on every build).
  Future<void> _bootstrapThemeMode() async {
    final saved = await ref.read(settingsRepositoryProvider).getThemeMode();
    final mode = ThemeMode.values.firstWhere(
      (m) => m.name == saved,
      orElse: () => ThemeMode.system,
    );
    if (mounted) ref.read(themeModeProvider.notifier).state = mode;
  }

  /// Seeds the cosmetic-unlock catalog (idempotent) and loads the
  /// persisted accent theme (§17) into [accentThemeIdProvider], mirroring
  /// [_bootstrapThemeMode] above.
  Future<void> _bootstrapCosmetics() async {
    await ref.read(unlockableRepositoryProvider).seedIfEmpty();
    final id = await ref.read(settingsRepositoryProvider).getActiveAccentThemeId();
    if (mounted) ref.read(accentThemeIdProvider.notifier).state = id;
  }

  /// JSON export (§11) writes `cove-export-*.json` to the temp directory
  /// for the share sheet to read, but nothing deletes it afterward — the
  /// share sheet may still be reading it asynchronously right after
  /// `shareXFiles` returns, so deleting immediately post-share risks
  /// breaking an in-flight share. Any such file still around at the
  /// *next* launch is definitely done being shared, so this sweeps them
  /// then instead. Best-effort — a failed sweep just leaves stale files
  /// for next time, nothing depends on this succeeding.
  Future<void> _sweepStaleExportFiles() async {
    try {
      final dir = await getTemporaryDirectory();
      await for (final entity in dir.list()) {
        final name = entity.uri.pathSegments.lastWhere(
          (s) => s.isNotEmpty,
          orElse: () => '',
        );
        if (entity is File && name.startsWith('cove-export-')) {
          await entity.delete();
        }
      }
    } catch (_) {
      // Directory listing/deletion failed — not worth surfacing.
    }
  }

  @override
  void dispose() {
    _notificationTapSubscription?.cancel();
    _widgetTapSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accentId = ref.watch(accentThemeIdProvider);
    final accentOverride = Cosmetics.byIdOrNull(accentId)?.accent;
    return MaterialApp.router(
      title: 'Cove',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(
        context,
        brightness: Brightness.light,
        accentOverride: accentOverride,
      ),
      darkTheme: buildAppTheme(
        context,
        brightness: Brightness.dark,
        accentOverride: accentOverride,
      ),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: appRouter,
    );
  }
}
