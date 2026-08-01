import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/tables.dart' show ItemStatus;
import '../../data/repositories/item_repository.dart';
import '../item/item_detail_sheet.dart';

String _pad2(int n) => n < 10 ? '0$n' : '$n';

String _archivedDateLabel(DateTime? d) {
  if (d == null) return '';
  const months = [
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
  return '${d.day} ${months[d.month - 1]} ${d.year} · ${_pad2(d.hour)}:${_pad2(d.minute)}';
}

/// Archive (§4) — done/cancelled/deleted items, reachable from Settings.
/// Reuses `ItemDetailSheet` for viewing/restoring — it already swaps to
/// Restore/Delete-permanently actions once it sees a non-open status.
class ArchiveScreen extends ConsumerStatefulWidget {
  const ArchiveScreen({super.key});

  @override
  ConsumerState<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends ConsumerState<ArchiveScreen> {
  ItemStatus? _filter;

  @override
  Widget build(BuildContext context) {
    final items =
        ref.watch(archivedItemsProvider(_filter)).value ??
        const <ItemWithArea>[];

    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        elevation: 0,
        title: Text('Archive', style: AppTypography.sectionHeader(context)),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: context.s(16),
              vertical: context.s(10),
            ),
            child: Wrap(
              spacing: context.s(6),
              children: [
                _FilterChip(
                  label: 'All',
                  active: _filter == null,
                  onTap: () => setState(() => _filter = null),
                ),
                _FilterChip(
                  label: 'Done',
                  active: _filter == ItemStatus.done,
                  onTap: () => setState(() => _filter = ItemStatus.done),
                ),
                _FilterChip(
                  label: 'Cancelled',
                  active: _filter == ItemStatus.cancelled,
                  onTap: () => setState(() => _filter = ItemStatus.cancelled),
                ),
                _FilterChip(
                  label: 'Deleted',
                  active: _filter == ItemStatus.deleted,
                  onTap: () => setState(() => _filter = ItemStatus.deleted),
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Text(
                      'Nothing archived yet.',
                      style: AppTypography.body(context),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.symmetric(horizontal: context.s(16)),
                    itemCount: items.length,
                    itemBuilder: (context, i) =>
                        _ArchivedRow(itemWithArea: items[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.s(11),
          vertical: context.s(7),
        ),
        decoration: BoxDecoration(
          color: active ? context.colors.ink : context.colors.surface,
          border: Border.all(
            color: active ? context.colors.ink : context.colors.border,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: AppTypography.monoLabel(context).copyWith(
            fontSize: context.s(10),
            color: active ? context.colors.surface : context.colors.inkMuted,
          ),
        ),
      ),
    );
  }
}

class _ArchivedRow extends StatelessWidget {
  const _ArchivedRow({required this.itemWithArea});
  final ItemWithArea itemWithArea;

  @override
  Widget build(BuildContext context) {
    final item = itemWithArea.item;
    final badge = switch (item.status) {
      ItemStatus.done => '✓',
      ItemStatus.cancelled => '⊘',
      ItemStatus.deleted => '🗑',
      ItemStatus.open => '',
    };
    return GestureDetector(
      onTap: () => showItemDetailSheet(context, item.id),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: context.s(10)),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: context.colors.borderSubtle),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: context.s(22),
              child: Text(badge, style: TextStyle(fontSize: context.s(13))),
            ),
            SizedBox(width: context.s(10)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.shortTitle ?? item.title,
                    style: AppTypography.itemTitle(context).copyWith(
                      color: context.colors.inkDisabled,
                      decoration: TextDecoration.lineThrough,
                    ),
                  ),
                  SizedBox(height: context.s(4)),
                  Text(
                    [
                      if (itemWithArea.area != null)
                        itemWithArea.area!.name.toUpperCase(),
                      _archivedDateLabel(item.archivedAt),
                    ].join(' · '),
                    style: AppTypography.monoLabel(context).copyWith(
                      fontSize: context.s(9.5),
                      letterSpacing: context.s(0.6),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
