import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/theme.dart';

/// About (§11) — version number + a short "what's built so far" list.
/// The changelog entries below describe real shipped capabilities, not
/// placeholder content — kept short and high-level rather than a
/// commit-by-commit log.
const _changelog = [
  'Google Calendar import, Settings profile/reminder/theme controls',
  'App lock (biometric/PIN), JSON export/import, Archive',
  'Bulk actions, drag-reorder, sort, swipe gestures',
  'Item Detail screen, tags, search and filters',
  'Recurring items (daily/weekly/weekday rules)',
  'Agenda, Up Next, Calendar, Areas, home-screen widgets',
  'Google Drive backup and restore',
];

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String? _version;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _version = '${info.version}+${info.buildNumber}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        elevation: 0,
        title: Text('About', style: AppTypography.sectionHeader(context)),
      ),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.s(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: context.s(8)),
              Text(
                'cove',
                style: AppTypography.wordmark(
                  context,
                ).copyWith(color: context.colors.ink, fontSize: context.s(30)),
              ),
              SizedBox(height: context.s(6)),
              Text(
                _version != null ? 'Version $_version' : 'Version —',
                style: AppTypography.mono(context),
              ),
              SizedBox(height: context.s(24)),
              Text(
                'CHANGELOG',
                style: AppTypography.monoLabel(
                  context,
                ).copyWith(letterSpacing: context.s(1.6)),
              ),
              SizedBox(height: context.s(10)),
              for (final entry in _changelog)
                Padding(
                  padding: EdgeInsets.only(bottom: context.s(10)),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '— ',
                        style: AppTypography.body(
                          context,
                        ).copyWith(color: context.colors.accent),
                      ),
                      Expanded(
                        child: Text(entry, style: AppTypography.body(context)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
