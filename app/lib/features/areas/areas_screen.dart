import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/repositories/item_repository.dart';
import '../../domain/services/week_math.dart';
import '../shared/cosmetic_cluster.dart';
import 'area_detail_screen.dart';
import 'area_edit_sheet.dart';

const _monthNames = [
  'JAN',
  'FEB',
  'MAR',
  'APR',
  'MAY',
  'JUN',
  'JUL',
  'AUG',
  'SEP',
  'OCT',
  'NOV',
  'DEC',
];

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

/// The Areas screen (§5): per-area progress and item counts for the
/// current week. Progress formula is §6's written spec, not the design
/// mockup's simplified `done/total` — see `ItemRepository.watchAreaProgress`.
class AreasScreen extends ConsumerWidget {
  const AreasScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = _startOfDay(DateTime.now());
    final firstWeekday =
        ref.watch(firstDayOfWeekProvider).value ?? DateTime.monday;
    final weekStart = startOfWeek(today, firstWeekday);
    final progressAsync = ref.watch(areaProgressProvider(today));

    return Scaffold(
      backgroundColor: context.colors.background,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: context.s(16)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: context.s(8)),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Areas',
                      style: AppTypography.sectionHeader(
                        context,
                      ).copyWith(fontSize: context.s(19)),
                    ),
                  ),
                  const CosmeticCluster(),
                  SizedBox(width: context.s(8)),
                  Text(
                    'WEEK OF ${weekStart.day} ${_monthNames[weekStart.month - 1]}',
                    style: AppTypography.monoLabel(
                      context,
                    ).copyWith(fontSize: context.s(10)),
                  ),
                ],
              ),
              SizedBox(height: context.s(20)),
              Expanded(
                child: progressAsync.when(
                  data: (stats) => ListView(
                    padding: EdgeInsets.only(bottom: context.s(24)),
                    children: [
                      if (stats.isEmpty)
                        Padding(
                          padding: EdgeInsets.only(bottom: context.s(16)),
                          child: Text(
                            'No areas yet.',
                            style: AppTypography.body(context),
                          ),
                        )
                      else ...[
                        for (final stat in stats) _AreaCard(progress: stat),
                        SizedBox(height: context.s(9)),
                      ],
                      const AddAreaTile(),
                    ],
                  ),
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AreaCard extends StatelessWidget {
  const _AreaCard({required this.progress});
  final AreaProgress progress;

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(progress.area.color);
    final hasActivity = progress.hasActivity;
    final pctText = hasActivity ? '${(progress.ratio * 100).round()}%' : '—';
    final note = hasActivity
        ? '${progress.doneThisWeek} OF ${progress.doneThisWeek + progress.openDueThisWeek}'
        : 'NOTHING THIS WEEK';

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AreaDetailScreen(area: progress.area),
        ),
      ),
      child: Container(
        margin: EdgeInsets.only(bottom: context.s(9)),
        padding: EdgeInsets.symmetric(
          horizontal: context.s(14),
          vertical: context.s(13),
        ),
        decoration: BoxDecoration(
          color: context.colors.surface,
          border: Border.all(color: context.colors.border),
          borderRadius: BorderRadius.circular(context.s(16)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: context.s(10),
                  height: context.s(10),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(context.s(3)),
                  ),
                ),
                SizedBox(width: context.s(10)),
                Text(
                  progress.area.name,
                  style: TextStyle(
                    fontFamily: AppTypography.sansFamily,
                    fontSize: context.s(15.5),
                    fontWeight: FontWeight.w600,
                    color: context.colors.ink,
                  ),
                ),
                SizedBox(width: context.s(8)),
                Expanded(
                  child: Text(
                    note,
                    textAlign: TextAlign.right,
                    style: AppTypography.monoLabel(
                      context,
                    ).copyWith(fontSize: context.s(9.5)),
                  ),
                ),
                SizedBox(width: context.s(8)),
                Text(
                  pctText,
                  style: TextStyle(
                    fontFamily: AppTypography.monoFamily,
                    fontSize: context.s(14),
                    color: hasActivity
                        ? context.colors.ink
                        : context.colors.inkDisabled,
                  ),
                ),
              ],
            ),
            SizedBox(height: context.s(10)),
            ClipRRect(
              borderRadius: BorderRadius.circular(context.s(3)),
              child: LinearProgressIndicator(
                value: hasActivity ? progress.ratio : 0,
                minHeight: context.s(5),
                backgroundColor: context.colors.borderFaint,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
