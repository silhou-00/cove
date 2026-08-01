import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../app/session_lock.dart';
import '../../app/theme.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/services/widget_refresh_service.dart';
import '../../domain/services/cosmetics.dart';
import '../app_lock/confirm_pin_sheet.dart';
import '../app_lock/set_pin_sheet.dart';
import '../archive/archive_screen.dart';
import '../shared/equip_sheet.dart';
import 'about_screen.dart';
import 'edit_profile_sheet.dart';

/// Settings (§11) — deliberately minimal. Google Calendar import + export
/// (§9), App lock (§12), Archive, JSON export/import/clear-all, profile
/// editing, theme, first-day-of-week, a global notifications on/off
/// toggle, widget refresh interval, and About are built. Reminder
/// *timing* is set per-item in the create/edit sheet, not here — this
/// toggle is only the kill switch. Daily digest toggle stays logged as a
/// gap in documents/documentation.md rather than built here. Google Drive
/// backup was built and then removed (2026-08-01) — see
/// documents/documentation.md for why.
///
/// Layout follows the design handoff's actual Settings screen (compact
/// profile header, flowing sectioned lists, no boxed cards per row) —
/// General/Data/App Lock/Connections rows pick a value via a bottom
/// sheet (matching Agenda's sort picker), not tap-to-cycle; the earlier
/// build here used its own cycling-card pattern instead of the mockup's.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

const _maxImportFileBytes = 20 * 1024 * 1024; // 20MB

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String? _version;
  bool _busy = false;
  bool _appLockEnabled = false;
  bool _calConnected = false;
  String? _calEmail;
  bool _calImportEnabled = false;
  String? _calLastSyncedAt;
  bool _calBusy = false;
  CalendarExportMode _calExportMode = CalendarExportMode.askEachTime;
  bool _notificationsEnabled = true;
  int _widgetRefreshMinutes =
      SettingsRepository.widgetRefreshIntervalDefaultMinutes;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _refreshAppLock();
    _refreshCalendar();
    _refreshNotificationsEnabled();
    _refreshWidgetRefreshInterval();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _version = 'v${info.version}');
  }

  Future<void> _refreshWidgetRefreshInterval() async {
    final minutes = await ref
        .read(settingsRepositoryProvider)
        .getWidgetRefreshIntervalMinutes();
    if (mounted) setState(() => _widgetRefreshMinutes = minutes);
  }

  String _widgetRefreshLabel(int minutes) => '$minutes min';

  /// Only takes effect on Android 12+ (see `widget_refresh_service.dart`)
  /// — the Settings value is still saved either way, so it applies
  /// retroactively if the device is ever updated past API 31.
  Future<void> _pickWidgetRefreshInterval() async {
    final chosen = await _pickOption<int>(
      context,
      title: 'Widget refresh',
      options: const [30, 60, 120],
      current: _widgetRefreshMinutes,
      labelOf: _widgetRefreshLabel,
    );
    if (chosen == null) return;
    await ref
        .read(settingsRepositoryProvider)
        .setWidgetRefreshIntervalMinutes(chosen);
    await setWidgetRefreshIntervalMinutes(chosen);
    if (mounted) setState(() => _widgetRefreshMinutes = chosen);
  }

  Future<void> _refreshNotificationsEnabled() async {
    final enabled = await ref
        .read(settingsRepositoryProvider)
        .getNotificationsEnabled();
    if (mounted) setState(() => _notificationsEnabled = enabled);
  }

  /// Global kill switch (§7/§11) — per-item reminder timing is set on the
  /// task itself now (create/edit sheet), so this just turns delivery on
  /// or off entirely, same shape as the App Lock toggle below.
  Future<void> _onToggleNotifications(bool value) async {
    await ref.read(settingsRepositoryProvider).setNotificationsEnabled(value);
    if (mounted) setState(() => _notificationsEnabled = value);
  }

  String _themeModeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'System',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };

  Future<void> _pickThemeMode() async {
    final chosen = await _pickOption<ThemeMode>(
      context,
      title: 'Theme',
      options: ThemeMode.values,
      current: ref.read(themeModeProvider),
      labelOf: _themeModeLabel,
    );
    if (chosen == null) return;
    await ref.read(settingsRepositoryProvider).setThemeMode(chosen.name);
    ref.read(themeModeProvider.notifier).state = chosen;
  }

  String _firstDayLabel(int weekday) =>
      weekday == DateTime.monday ? 'Monday' : 'Sunday';

  Future<void> _pickFirstDayOfWeek() async {
    final current = ref.read(firstDayOfWeekProvider).value ?? DateTime.monday;
    final chosen = await _pickOption<int>(
      context,
      title: 'First day of week',
      options: const [DateTime.monday, DateTime.sunday],
      current: current,
      labelOf: _firstDayLabel,
    );
    if (chosen == null) return;
    await ref.read(settingsRepositoryProvider).setFirstDayOfWeek(chosen);
    ref.invalidate(firstDayOfWeekProvider);
    if (mounted) setState(() {});
  }

  Future<void> _refreshCalendar() async {
    final repo = ref.read(calendarSyncRepositoryProvider);
    final connected = await repo.isConnected();
    final email = await repo.accountEmail();
    final importEnabled = await repo.isImportEnabled();
    final lastSynced = await repo.lastSyncedAt();
    final exportMode = await ref
        .read(settingsRepositoryProvider)
        .getCalendarExportMode();
    if (!mounted) return;
    setState(() {
      _calConnected = connected;
      _calEmail = (email?.isEmpty ?? true) ? null : email;
      _calImportEnabled = importEnabled;
      _calLastSyncedAt = lastSynced;
      _calExportMode = exportMode;
    });
  }

  /// Picking a mode other than "never" requests the write scope
  /// incrementally the first time it's needed (`ensureExportScope`
  /// no-ops if already granted) rather than at initial connect — same
  /// least-privilege call already made for import's read-only scope.
  Future<void> _setExportMode(CalendarExportMode mode) async {
    if (mode == _calExportMode) return;
    if (mode != CalendarExportMode.never) {
      setState(() => _calBusy = true);
      final granted = await ref
          .read(calendarSyncRepositoryProvider)
          .ensureExportScope();
      if (mounted) setState(() => _calBusy = false);
      if (!granted) {
        if (mounted) {
          _showMessage('Calendar write access is needed for export.');
        }
        return;
      }
    }
    await ref.read(settingsRepositoryProvider).setCalendarExportMode(mode);
    if (mounted) setState(() => _calExportMode = mode);
  }

  Future<void> _calRun(
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    setState(() => _calBusy = true);
    try {
      await action();
      if (successMessage != null && mounted) _showMessage(successMessage);
    } catch (e) {
      if (mounted) _showMessage('Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _calBusy = false);
      await _refreshCalendar();
    }
  }

  /// Not routed through `_calRun` — same reasoning as `_connect()` above.
  Future<void> _calConnect() async {
    setState(() => _calBusy = true);
    try {
      final connected = await ref
          .read(calendarSyncRepositoryProvider)
          .connect();
      if (mounted) {
        _showMessage(
          connected ? 'Connected to Google Calendar.' : 'Sign-in cancelled.',
        );
      }
    } catch (e) {
      if (mounted) _showMessage('Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _calBusy = false);
      await _refreshCalendar();
    }
  }

  Future<void> _calDisconnect() => _calRun(
    () => ref.read(calendarSyncRepositoryProvider).disconnect(),
    successMessage: 'Disconnected.',
  );

  Future<void> _calSyncNow() => _calRun(
    () => ref.read(calendarSyncRepositoryProvider).syncNow(),
    successMessage: 'Synced.',
  );

  Future<void> _calToggleImport(bool value) => _calRun(
    () => ref.read(calendarSyncRepositoryProvider).setImportEnabled(value),
  );

  Future<void> _refreshAppLock() async {
    final enabled = await ref
        .read(profileRepositoryProvider)
        .isAppLockEnabled();
    if (mounted) setState(() => _appLockEnabled = enabled);
  }

  /// Turning on requires setting a PIN first; turning off requires
  /// re-confirming the current PIN/biometric — a picked-up unlocked phone
  /// shouldn't be able to just flip this off (§12).
  Future<void> _onToggleAppLock(bool value) async {
    if (value) {
      final didSet = await showSetPinSheet(context);
      if (didSet && mounted) {
        // Doesn't lock the current session (§12's "checked on cold start,
        // nowhere else" rule) — just makes the *next* cold start require
        // it. See SessionLock's own doc comment.
        SessionLock.instance.setEnabled(true);
        setState(() => _appLockEnabled = true);
      }
    } else {
      final confirmed = await showConfirmPinSheet(
        context,
        reason: 'Confirm PIN to turn off App Lock',
      );
      if (!confirmed || !mounted) return;
      await ref.read(profileRepositoryProvider).disableAppLock();
      SessionLock.instance.setEnabled(false);
      if (mounted) setState(() => _appLockEnabled = false);
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    String? successMessage,
  }) async {
    setState(() => _busy = true);
    try {
      await action();
      if (successMessage != null && mounted) _showMessage(successMessage);
    } catch (e) {
      if (mounted) _showMessage('Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: context.colors.ink,
        behavior: SnackBarBehavior.floating,
        content: Text(message, style: TextStyle(color: context.colors.surface)),
      ),
    );
  }

  Future<void> _exportData() async {
    setState(() => _busy = true);
    try {
      final json = await ref.read(exportRepositoryProvider).exportToJson();
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/cove-export-${DateTime.now().millisecondsSinceEpoch}.json',
      );
      await file.writeAsString(json);
      await Share.shareXFiles([XFile(file.path)], text: 'Cove data export');
    } catch (e) {
      if (mounted) _showMessage('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importData() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;

    // A real Cove export of even a few thousand items is well under 1MB —
    // this just guards against picking an unrelated huge file (renamed
    // extension, wrong file entirely) before it's fully buffered into
    // memory as a String.
    final fileSize = await File(path).length();
    if (!mounted) return;
    if (fileSize > _maxImportFileBytes) {
      _showMessage('That file is too large to be a Cove export.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.colors.surface,
        title: const Text('Import this file?'),
        content: const Text(
          'This replaces all local data on this device. This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Replace local data',
              style: TextStyle(color: context.colors.accent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _run(() async {
      final json = await File(path).readAsString();
      await ref.read(exportRepositoryProvider).importFromJson(json);
    }, successMessage: 'Import complete.');
  }

  Future<void> _clearAllData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: context.colors.surface,
        title: const Text('Clear all data?'),
        content: const Text(
          'This permanently deletes everything on this device — items, areas, '
          'tags, your name — and returns to onboarding. This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              'Delete everything',
              style: TextStyle(color: context.colors.accent),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(exportRepositoryProvider).clearAllData();
      if (mounted) context.go('/onboarding');
    } catch (e) {
      if (mounted) _showMessage('Clear failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editProfile(
    String firstName,
    String? lastName,
    String? avatarPath,
  ) async {
    await showEditProfileSheet(
      context,
      firstName: firstName,
      lastName: lastName,
      avatarPath: avatarPath,
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileProvider).value;
    final profileName = profile == null
        ? ''
        : [
            profile.firstName,
            profile.lastName,
          ].where((p) => p != null && p.isNotEmpty).join(' ');

    return Scaffold(
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: Column(
          children: [
            _SettingsHeader(
              version: _version,
              profileName: profileName,
              avatarPath: profile?.avatarPath,
              onTapProfile: profile == null
                  ? null
                  : () => _editProfile(
                      profile.firstName,
                      profile.lastName,
                      profile.avatarPath,
                    ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  context.s(16),
                  0,
                  context.s(16),
                  context.s(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _SectionHeader('General'),
                    _FlowRow(
                      label: 'First day of week',
                      value: _firstDayLabel(
                        ref.watch(firstDayOfWeekProvider).value ??
                            DateTime.monday,
                      ),
                      onTap: _pickFirstDayOfWeek,
                    ),
                    _FlowRow(
                      label: 'Notifications',
                      trailing: Switch(
                        value: _notificationsEnabled,
                        activeThumbColor: context.colors.accent,
                        onChanged: _onToggleNotifications,
                      ),
                    ),
                    _FlowRow(
                      label: 'Widget refresh',
                      value: _widgetRefreshLabel(_widgetRefreshMinutes),
                      onTap: _pickWidgetRefreshInterval,
                    ),
                    _FlowRow(
                      label: 'Theme',
                      value: _themeModeLabel(ref.watch(themeModeProvider)),
                      onTap: _pickThemeMode,
                      isLast: true,
                    ),
                    SizedBox(height: context.s(22)),
                    const _SectionHeader('Connections · optional'),
                    _ConnectionRow(
                      label: 'Google Calendar',
                      connected: _calConnected,
                      stateText: _calConnected
                          ? (_calEmail ?? 'Connected')
                          : 'Not connected',
                      busy: _calBusy,
                      onTap: _calConnected ? _calDisconnect : _calConnect,
                      isLast: !_calConnected,
                    ),
                    if (!_calConnected) ...[
                      SizedBox(height: context.s(6)),
                      Text(
                        'Connecting lets Cove create and delete events on '
                        'your Google Calendar. You choose how much of that '
                        'it actually does — ask each time, always, or '
                        'never — once connected.',
                        style: AppTypography.secondaryMeta(
                          context,
                        ).copyWith(fontSize: context.s(11.5)),
                      ),
                    ],
                    if (_calConnected) ...[
                      SizedBox(height: context.s(6)),
                      _FlowRow(
                        label: 'Import events',
                        trailing: Switch(
                          value: _calImportEnabled,
                          activeThumbColor: context.colors.accent,
                          onChanged: _calBusy ? null : _calToggleImport,
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: context.s(12)),
                        child: Row(
                          children: [
                            Text(
                              'Export',
                              style: AppTypography.itemTitle(
                                context,
                              ).copyWith(fontSize: context.s(13.5)),
                            ),
                            const Spacer(),
                            for (final mode in CalendarExportMode.values)
                              Padding(
                                padding: EdgeInsets.only(left: context.s(12)),
                                child: _ExportModeOption(
                                  label: switch (mode) {
                                    CalendarExportMode.askEachTime => 'ASK',
                                    CalendarExportMode.alwaysAdd => 'ALWAYS',
                                    CalendarExportMode.never => 'NEVER',
                                  },
                                  active: mode == _calExportMode,
                                  onTap: _calBusy
                                      ? null
                                      : () => _setExportMode(mode),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Text(
                        _calLastSyncedAt != null
                            ? 'Last synced: $_calLastSyncedAt'
                            : 'Not synced yet',
                        style: AppTypography.secondaryMeta(
                          context,
                        ).copyWith(fontSize: context.s(12)),
                      ),
                      SizedBox(height: context.s(10)),
                      _ActionButton(
                        label: 'Sync now',
                        onTap: (_calBusy || !_calImportEnabled)
                            ? null
                            : _calSyncNow,
                      ),
                      SizedBox(height: context.s(14)),
                    ],
                    SizedBox(height: context.s(8)),
                    const _SectionHeader('App Lock'),
                    _FlowRow(
                      label: _appLockEnabled
                          ? 'Locked with a PIN/biometric on launch'
                          : 'Off',
                      trailing: Switch(
                        value: _appLockEnabled,
                        activeThumbColor: context.colors.accent,
                        onChanged: _onToggleAppLock,
                      ),
                      isLast: true,
                    ),
                    SizedBox(height: context.s(22)),
                    const _SectionHeader('Data'),
                    _FlowRow(
                      label: 'Archive',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const ArchiveScreen(),
                        ),
                      ),
                    ),
                    _FlowRow(
                      label: 'Export data',
                      onTap: _busy ? null : _exportData,
                    ),
                    _FlowRow(
                      label: 'Import data',
                      onTap: _busy ? null : _importData,
                    ),
                    _FlowRow(
                      label: 'Clear all data',
                      destructive: true,
                      onTap: _busy ? null : _clearAllData,
                      isLast: true,
                    ),
                    SizedBox(height: context.s(22)),
                    const _SectionHeader('Gamification'),
                    _FlowRow(
                      label: 'Unlocks',
                      value:
                          '${ref.watch(unlockablesProvider).value?.where((u) => u.unlockedAt != null).length ?? 0} of ${Cosmetics.catalog.length}',
                      onTap: () => showEquipSheet(context),
                      isLast: true,
                    ),
                    SizedBox(height: context.s(22)),
                    const _SectionHeader('About'),
                    _FlowRow(
                      label: 'About Cove',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const AboutScreen()),
                      ),
                      isLast: true,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact profile header — avatar initial, name (tap to edit), and the
/// app's local-only status line, matching the design handoff's Settings
/// header instead of a separate boxed "name >" row below a page title.
class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader({
    required this.version,
    required this.profileName,
    required this.onTapProfile,
    this.avatarPath,
  });
  final String? version;
  final String profileName;
  final VoidCallback? onTapProfile;
  final String? avatarPath;

  @override
  Widget build(BuildContext context) {
    final initial = profileName.isNotEmpty ? profileName[0].toUpperCase() : '?';
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.s(16),
        context.s(10),
        context.s(16),
        context.s(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'SETTINGS',
                style: AppTypography.monoLabel(
                  context,
                ).copyWith(letterSpacing: context.s(2)),
              ),
              if (version != null)
                Text(
                  version!,
                  style: AppTypography.monoLabel(
                    context,
                  ).copyWith(color: context.colors.inkFainter),
                ),
            ],
          ),
          SizedBox(height: context.s(13)),
          GestureDetector(
            onTap: onTapProfile,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Container(
                  width: context.s(46),
                  height: context.s(46),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: context.colors.ink,
                    borderRadius: BorderRadius.circular(context.s(14)),
                  ),
                  alignment: Alignment.center,
                  child: avatarPath == null
                      ? Text(
                          initial,
                          style: TextStyle(
                            fontFamily: AppTypography.monoFamily,
                            fontSize: context.s(19),
                            fontWeight: FontWeight.w600,
                            color: context.colors.surface,
                          ),
                        )
                      : Image.file(
                          File(avatarPath!),
                          fit: BoxFit.cover,
                          width: context.s(46),
                          height: context.s(46),
                        ),
                ),
                SizedBox(width: context.s(13)),
                Expanded(
                  child: Text(
                    profileName.isEmpty ? '—' : profileName,
                    style: TextStyle(
                      fontSize: context.s(24),
                      fontWeight: FontWeight.w600,
                      letterSpacing: context.s(-0.6),
                      color: context.colors.ink,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onTapProfile != null)
                  Icon(
                    Icons.chevron_right,
                    size: context.s(20),
                    color: context.colors.inkFaint,
                  ),
              ],
            ),
          ),
          SizedBox(height: context.s(11)),
          Container(
            padding: EdgeInsets.only(top: context.s(9)),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: context.colors.border)),
            ),
            child: Row(
              children: [
                Container(
                  width: context.s(6),
                  height: context.s(6),
                  decoration: BoxDecoration(
                    color: AppColors.areaWork,
                    borderRadius: BorderRadius.circular(context.s(2)),
                  ),
                ),
                SizedBox(width: context.s(8)),
                Text(
                  'OFFLINE FIRST · NO ACCOUNT · NO TELEMETRY',
                  style: AppTypography.monoLabel(context).copyWith(
                    fontSize: context.s(9.5),
                    letterSpacing: context.s(1.2),
                    color: context.colors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: context.s(8)),
      padding: EdgeInsets.only(bottom: context.s(7)),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.border)),
      ),
      child: Text(
        label.toUpperCase(),
        style: AppTypography.monoLabel(
          context,
        ).copyWith(letterSpacing: context.s(1.6)),
      ),
    );
  }
}

/// A flowing settings row — label + trailing value/control, thin bottom
/// border, no enclosing card. [onTap] with no [trailing] shows a chevron
/// (navigates elsewhere or opens a picker); pass [trailing] directly for
/// a `Switch` or similar. [isLast] drops the row's own bottom border
/// since a section-level gap already separates it from what follows.
class _FlowRow extends StatelessWidget {
  const _FlowRow({
    required this.label,
    this.value,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.isLast = false,
  });
  final String label;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: AppTypography.itemTitle(context).copyWith(
              color: destructive ? context.colors.accent : context.colors.ink,
            ),
          ),
        ),
        if (trailing != null)
          trailing!
        else if (value != null)
          Text(
            value!,
            style: AppTypography.mono(context).copyWith(
              fontSize: context.s(11.5),
              color: context.colors.inkMuted,
            ),
          ),
        if (onTap != null && trailing == null) ...[
          SizedBox(width: context.s(4)),
          Icon(
            Icons.chevron_right,
            size: context.s(16),
            color: destructive
                ? context.colors.accent
                : context.colors.inkFaint,
          ),
        ],
      ],
    );
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: context.s(13)),
        decoration: isLast
            ? null
            : BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: context.colors.borderSubtle),
                ),
              ),
        child: row,
      ),
    );
  }
}

/// The Drive/Calendar "dot + state + Connect/Disconnect" row shared by
/// both connections — matches the design handoff's single-line
/// connection row instead of a full bordered card per service.
class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({
    required this.label,
    required this.connected,
    required this.stateText,
    required this.busy,
    required this.onTap,
    this.isLast = false,
  });
  final String label;
  final bool connected;
  final String stateText;
  final bool busy;
  final VoidCallback? onTap;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: context.s(11)),
      decoration: isLast
          ? null
          : BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.colors.borderSubtle),
              ),
            ),
      child: Row(
        children: [
          Container(
            width: context.s(7),
            height: context.s(7),
            decoration: BoxDecoration(
              color: connected
                  ? AppColors.areaWork
                  : context.colors.inkDisabled,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: context.s(9)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTypography.itemTitle(context)),
                Text(
                  stateText,
                  style: AppTypography.secondaryMeta(
                    context,
                  ).copyWith(fontSize: context.s(11.5)),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: busy ? null : onTap,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.s(13),
                vertical: context.s(6),
              ),
              decoration: BoxDecoration(
                border: Border.all(color: context.colors.ink),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                connected ? 'Disconnect' : 'Connect',
                style: TextStyle(
                  fontSize: context.s(12.5),
                  fontWeight: FontWeight.w500,
                  color: context.colors.ink,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One of the 3 inline Export-mode picks (ask/always/never) — always
/// shown together, tapped directly, matching the design handoff's own
/// segmented-label pattern instead of a tap-to-cycle single value.
class _ExportModeOption extends StatelessWidget {
  const _ExportModeOption({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.only(bottom: context.s(3)),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              width: 2,
              color: active ? context.colors.accent : Colors.transparent,
            ),
          ),
        ),
        child: Text(
          label,
          style: AppTypography.monoLabel(context).copyWith(
            fontSize: context.s(10),
            color: active ? context.colors.ink : context.colors.inkMuted,
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: context.s(9)),
        decoration: BoxDecoration(
          color: onTap == null
              ? context.colors.borderFaint
              : context.colors.ink,
          borderRadius: BorderRadius.circular(context.s(10)),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: context.s(12.5),
            fontWeight: FontWeight.w500,
            color: onTap == null
                ? context.colors.inkDisabled
                : context.colors.surface,
          ),
        ),
      ),
    );
  }
}


/// Shared bottom-sheet picker for General's rows (Theme, first day of
/// week, default reminder, widget refresh) — a scrollable list of every
/// option with a checkmark on the current one, tap to pick. Matches
/// `agenda_screen.dart`'s `_pickSort` pattern instead of the previous
/// tap-to-cycle-in-place row.
Future<T?> _pickOption<T>(
  BuildContext context, {
  required String title,
  required List<T> options,
  required T current,
  required String Function(T) labelOf,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: context.colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(context.s(24))),
    ),
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.all(context.s(16)),
            child: Text(title, style: AppTypography.sectionHeader(context)),
          ),
          for (final option in options)
            ListTile(
              title: Text(labelOf(option)),
              trailing: option == current
                  ? Icon(Icons.check, color: context.colors.accent)
                  : null,
              onTap: () => Navigator.of(context).pop(option),
            ),
          SizedBox(height: context.s(8)),
        ],
      ),
    ),
  );
}
