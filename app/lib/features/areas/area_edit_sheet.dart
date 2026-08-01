import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/database.dart' show Area;

/// Add (`existing == null`) or edit an area: rename, recolor, delete (§10).
/// Shared by onboarding's area-management step and the in-app Areas
/// screen — `AreaRepository.createArea`/`rename`/`recolor`/`deleteArea`
/// already covered both use cases, this was just onboarding-only UI
/// before the Areas screen had its own way to add one.
Future<void> showAreaEditSheet(BuildContext context, {Area? existing}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(context.s(24))),
    ),
    builder: (_) => _AreaEditSheet(existing: existing),
  );
}

class AddAreaTile extends StatelessWidget {
  const AddAreaTile({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showAreaEditSheet(context),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.s(15),
          vertical: context.s(13),
        ),
        decoration: BoxDecoration(
          border: Border.all(color: context.colors.accent),
          borderRadius: BorderRadius.circular(context.s(14)),
        ),
        child: Row(
          children: [
            Icon(Icons.add, size: context.s(20), color: context.colors.accent),
            SizedBox(width: context.s(10)),
            Text(
              'Add area',
              style: AppTypography.itemTitle(context).copyWith(
                fontWeight: FontWeight.w500,
                color: context.colors.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AreaEditSheet extends ConsumerStatefulWidget {
  const _AreaEditSheet({required this.existing});
  final Area? existing;

  @override
  ConsumerState<_AreaEditSheet> createState() => _AreaEditSheetState();
}

class _AreaEditSheetState extends ConsumerState<_AreaEditSheet> {
  late final TextEditingController _nameController;
  late String _colorHex;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existing?.name ?? '');
    _colorHex = widget.existing?.color ?? areaColorOptions.first.hex;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final repo = ref.read(areaRepositoryProvider);
    final existing = widget.existing;
    if (existing != null) {
      await repo.rename(existing.id, name);
      await repo.recolor(existing.id, _colorHex);
    } else {
      await repo.createArea(name: name, color: _colorHex);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    await ref.read(areaRepositoryProvider).deleteArea(existing.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.existing == null;
    return Padding(
      padding: EdgeInsets.only(
        left: context.s(16),
        right: context.s(16),
        top: context.s(12),
        bottom:
            MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).padding.bottom +
            context.s(18),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: context.s(36),
              height: context.s(4),
              margin: EdgeInsets.only(bottom: context.s(16)),
              decoration: BoxDecoration(
                color: context.colors.border,
                borderRadius: BorderRadius.circular(context.s(2)),
              ),
            ),
          ),
          Text(
            isNew ? 'Add area' : 'Edit area',
            style: AppTypography.sectionHeader(context),
          ),
          SizedBox(height: context.s(18)),
          Text('NAME', style: AppTypography.monoLabel(context)),
          SizedBox(height: context.s(8)),
          TextField(
            controller: _nameController,
            autofocus: isNew,
            style: TextStyle(
              fontFamily: AppTypography.sansFamily,
              fontSize: context.s(17),
              color: context.colors.ink,
            ),
            decoration: InputDecoration(
              isDense: true,
              border: UnderlineInputBorder(
                borderSide: BorderSide(color: context.colors.ink, width: 1.5),
              ),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: context.colors.ink, width: 1.5),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: context.colors.ink, width: 1.5),
              ),
            ),
          ),
          SizedBox(height: context.s(18)),
          Text('COLOR', style: AppTypography.monoLabel(context)),
          SizedBox(height: context.s(8)),
          Wrap(
            spacing: context.s(10),
            runSpacing: context.s(10),
            children: [
              for (final option in areaColorOptions)
                GestureDetector(
                  onTap: () => setState(() => _colorHex = option.hex),
                  child: Container(
                    width: context.s(32),
                    height: context.s(32),
                    decoration: BoxDecoration(
                      color: option.color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _colorHex == option.hex
                            ? context.colors.ink
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(height: context.s(22)),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _save,
                  child: Container(
                    height: context.s(48),
                    decoration: BoxDecoration(
                      color: context.colors.ink,
                      borderRadius: BorderRadius.circular(context.s(15)),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Save',
                      style: AppTypography.button(
                        context,
                      ).copyWith(color: context.colors.surface),
                    ),
                  ),
                ),
              ),
              if (!isNew) ...[
                SizedBox(width: context.s(10)),
                GestureDetector(
                  onTap: _delete,
                  child: Container(
                    width: context.s(48),
                    height: context.s(48),
                    decoration: BoxDecoration(
                      border: Border.all(color: context.colors.border),
                      borderRadius: BorderRadius.circular(context.s(15)),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.delete_outline,
                      size: context.s(18),
                      color: context.colors.accent,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
