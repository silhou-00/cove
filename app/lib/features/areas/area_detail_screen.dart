import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart' show Area;
import '../../data/db/tables.dart' show ItemStatus;
import '../../data/repositories/item_repository.dart';
import '../agenda/widgets/item_row.dart';
import '../item/item_detail_sheet.dart';
import 'area_edit_sheet.dart';

/// One area's open tasks (§6/§10) — reached by tapping an area card on
/// the Areas screen. Shows open items only, same "what do I still need
/// to do" framing as the rest of the app's lists; done/cancelled/deleted
/// items for this area still live in Archive, same as everywhere else.
class AreaDetailScreen extends ConsumerStatefulWidget {
  const AreaDetailScreen({super.key, required this.area});
  final Area area;

  @override
  ConsumerState<AreaDetailScreen> createState() => _AreaDetailScreenState();
}

class _AreaDetailScreenState extends ConsumerState<AreaDetailScreen> {
  List<ItemWithArea>? _items;
  late Area _area = widget.area;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Opens the same rename/recolor/delete sheet the Areas list and
  /// onboarding use. This screen doesn't watch a live `Area` stream (it
  /// was pushed with a fixed snapshot), so after the sheet closes it
  /// re-fetches by id — `null` means it was deleted, in which case this
  /// screen pops back to the list rather than showing a stale area.
  Future<void> _editArea() async {
    await showAreaEditSheet(context, existing: _area);
    final fresh = await ref.read(areaRepositoryProvider).getById(_area.id);
    if (!mounted) return;
    if (fresh == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _area = fresh);
    }
  }

  Future<void> _load() async {
    final results = await ref
        .read(itemRepositoryProvider)
        .searchItems(areaId: _area.id, status: ItemStatus.open);
    if (mounted) setState(() => _items = results);
  }

  Future<void> _toggle(ItemWithArea iwa) async {
    final repo = ref.read(itemRepositoryProvider);
    if (iwa.occurrenceId != null) {
      await repo.toggleOccurrenceComplete(iwa.occurrenceId!);
    } else {
      await repo.toggleComplete(iwa.item.id);
    }
    await _load();
  }

  Future<void> _archive(ItemWithArea iwa) async {
    await ref.read(itemRepositoryProvider).archiveItem(iwa.item.id);
    await _load();
  }

  Future<void> _open(String itemId) async {
    await showItemDetailSheetAndMaybeExport(context, ref, itemId);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(_area.color);
    final items = _items;
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        elevation: 0,
        iconTheme: IconThemeData(color: context.colors.ink),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: context.s(10),
              height: context.s(10),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(context.s(3)),
              ),
            ),
            SizedBox(width: context.s(8)),
            Text(_area.name, style: AppTypography.sectionHeader(context)),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _editArea,
            icon: Icon(Icons.edit_outlined, color: context.colors.inkMuted),
          ),
        ],
      ),
      body: items == null
          ? const SizedBox.shrink()
          : items.isEmpty
          ? Center(
              child: Text(
                'Nothing open in this area.',
                style: AppTypography.body(context),
              ),
            )
          : ListView.builder(
              padding: EdgeInsets.symmetric(horizontal: context.s(16)),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final iwa = items[i];
                return ItemRow(
                  itemWithArea: iwa,
                  onToggle: () => _toggle(iwa),
                  onArchive: () => _archive(iwa),
                  onTap: () => _open(iwa.item.id),
                );
              },
            ),
    );
  }
}
