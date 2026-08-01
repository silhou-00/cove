import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../data/repositories/item_repository.dart';

String pad2(int n) => n < 10 ? '0$n' : '$n';

/// `23:59` is the parser's own end-of-day sentinel for a due date typed
/// with no explicit time — shown as "—" rather than a misleadingly precise
/// clock time (matches the design's "Water plants" row).
String? dueTimeLabel(DateTime dueAt) {
  if (dueAt.hour == 23 && dueAt.minute == 59) return null;
  return '${pad2(dueAt.hour)}:${pad2(dueAt.minute)}';
}

String timeLabel(DateTime t) => '${pad2(t.hour)}:${pad2(t.minute)}';

/// One row shared by the Scheduled, Due-today, and Up Next lists (§5).
/// Tapping the row (anywhere but the circle) opens the Item Detail sheet;
/// the circle keeps its own tap target for the immediate complete toggle —
/// nesting the two `GestureDetector`s is safe since Flutter's gesture
/// arena resolves taps to whichever is deepest at that point.
///
/// Swipe-right completes (same action as the circle); swipe-left archives
/// (§4) — both leave the row's list naturally, since a completed/archived
/// item is excluded from every active view already. For a row backed by a
/// recurring `Occurrence`, swipe-left archives the whole template series,
/// same as tapping the row opens the template's Item Detail, not a
/// per-occurrence one — there's no "cancel just this instance" concept.
class ItemRow extends StatelessWidget {
  const ItemRow({
    super.key,
    required this.itemWithArea,
    required this.onToggle,
    this.onTap,
    this.onArchive,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
    this.leading,
    this.trailing,
  });

  final ItemWithArea itemWithArea;
  final VoidCallback onToggle;
  final VoidCallback? onTap;
  final VoidCallback? onArchive;

  /// Long-press enters/extends multi-select (§4, bulk actions).
  final VoidCallback? onLongPress;

  /// Whether the *list* is currently in multi-select mode — swaps the
  /// trailing complete-circle for a selection checkbox on every row, not
  /// just this one, and suspends swipe-to-complete/archive while active.
  final bool selectionMode;

  /// Whether *this* row is selected, only meaningful when [selectionMode].
  final bool selected;

  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final item = itemWithArea.item;
    final done = item.status.name == 'done';
    final areaColor = itemWithArea.area != null
        ? colorFromHex(itemWithArea.area!.color)
        : context.colors.inkDisabled;

    final row = GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: context.s(10)),
        decoration: BoxDecoration(
          color: selected
              ? context.colors.accent.withValues(alpha: 0.08)
              : null,
          border: Border(
            bottom: BorderSide(color: context.colors.borderSubtle),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leading != null) ...[leading!, SizedBox(width: context.s(12))],
            Container(
              width: context.s(2),
              margin: EdgeInsets.only(top: context.s(2)),
              decoration: BoxDecoration(color: areaColor),
            ),
            SizedBox(width: context.s(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.shortTitle ?? item.title,
                    style: AppTypography.itemTitle(context).copyWith(
                      color: done
                          ? context.colors.inkDisabled
                          : context.colors.ink,
                      decoration: done
                          ? TextDecoration.lineThrough
                          : TextDecoration.none,
                    ),
                  ),
                  SizedBox(height: context.s(4)),
                  Text(
                    [
                      if (itemWithArea.area != null)
                        itemWithArea.area!.name.toUpperCase(),
                      if (item.priority != null)
                        item.priority!.name.toUpperCase(),
                    ].join(' · '),
                    style: AppTypography.monoLabel(context).copyWith(
                      fontSize: context.s(9.5),
                      letterSpacing: context.s(0.6),
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[SizedBox(width: context.s(8)), trailing!],
            SizedBox(width: context.s(8)),
            GestureDetector(
              onTap: selectionMode ? onTap : onToggle,
              child: Container(
                width: context.s(22),
                height: context.s(22),
                margin: EdgeInsets.only(top: context.s(2)),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (selectionMode ? selected : done)
                      ? context.colors.ink
                      : Colors.transparent,
                  border: Border.all(
                    color: (selectionMode ? selected : done)
                        ? context.colors.ink
                        : context.colors.inkDisabled,
                    width: 1.5,
                  ),
                ),
                alignment: Alignment.center,
                child: (selectionMode ? selected : done)
                    ? Icon(
                        Icons.check,
                        size: context.s(12),
                        color: context.colors.surface,
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
    );

    if (onArchive == null || selectionMode) return row;

    return Dismissible(
      key: ValueKey(itemWithArea.occurrenceId ?? item.id),
      background: Container(
        color: context.colors.ink,
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.symmetric(horizontal: context.s(16)),
        child: Icon(
          Icons.check,
          color: context.colors.surface,
          size: context.s(20),
        ),
      ),
      secondaryBackground: Container(
        color: context.colors.accent,
        alignment: Alignment.centerRight,
        padding: EdgeInsets.symmetric(horizontal: context.s(16)),
        child: Icon(
          Icons.archive_outlined,
          color: context.colors.surface,
          size: context.s(20),
        ),
      ),
      onDismissed: (direction) {
        if (direction == DismissDirection.startToEnd) {
          onToggle();
        } else {
          onArchive!();
        }
      },
      child: row,
    );
  }
}
