import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../domain/services/cosmetics.dart';
import 'pixel_sprite.dart';

/// The cosmetic-unlock equip sheet (§17, design handoff's `openEquip`/
/// `closeEquip`) — a modal bottom sheet, not a pushed screen. Both the
/// header cluster (any of Agenda/Up Next/Calendar/Areas) and Settings'
/// "Unlocks" row open this same sheet, so equipping from either updates
/// the shared set everywhere at once.
Future<void> showEquipSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _EquipSheet(),
  );
}

class _EquipSheet extends ConsumerWidget {
  const _EquipSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlockables = ref.watch(unlockablesProvider).value;
    final slots =
        ref.watch(equippedSlotsProvider).value ?? const [null, null, null];
    final accentId = ref.watch(accentThemeIdProvider);
    final unlockedCount =
        unlockables?.where((u) => u.unlockedAt != null).length ?? 0;

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: context.colors.background,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(context.s(20)),
            ),
          ),
          child: unlockables == null
              ? const SizedBox.shrink()
              : ListView(
                  controller: scrollController,
                  padding: EdgeInsets.symmetric(
                    horizontal: context.s(16),
                    vertical: context.s(16),
                  ),
                  children: [
                    Center(
                      child: Container(
                        width: context.s(36),
                        height: context.s(4),
                        decoration: BoxDecoration(
                          color: context.colors.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    SizedBox(height: context.s(16)),
                    Text('Unlocks', style: AppTypography.sectionHeader(context)),
                    SizedBox(height: context.s(4)),
                    Text(
                      '$unlockedCount of ${Cosmetics.catalog.length} unlocked · cosmetic only, nothing gates function',
                      style: AppTypography.body(context),
                    ),
                    SizedBox(height: context.s(18)),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        for (var i = 0; i < 3; i++)
                          _SlotPill(
                            slotIndex: i + 1,
                            sheet: Cosmetics.byIdOrNull(slots[i])?.sheet,
                          ),
                      ],
                    ),
                    SizedBox(height: context.s(20)),
                    for (final def in Cosmetics.catalog)
                      _UnlockCard(
                        def: def,
                        unlockedAt: unlockables
                            .firstWhere((u) => u.id == def.id)
                            .unlockedAt,
                        equipped: switch (def.type) {
                          CosmeticType.accentTheme => accentId == def.id,
                          CosmeticType.widgetSkin => false,
                          CosmeticType.pet ||
                          CosmeticType.furniture => slots.contains(def.id),
                        },
                      ),
                  ],
                ),
        );
      },
    );
  }
}

/// One of the three equip slots — tapping cycles it to the next unlocked
/// pet/furniture item (`UnlockableRepository.cycleSlot`). Flexible: any
/// slot can hold either a pet or a furniture item.
class _SlotPill extends ConsumerWidget {
  const _SlotPill({required this.slotIndex, required this.sheet});
  final int slotIndex;
  final String? sheet;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cellSize = context.s(5);
    final side = cellSize * 10;
    return GestureDetector(
      onTap: () => ref.read(unlockableRepositoryProvider).cycleSlot(slotIndex),
      child: Container(
        width: side + context.s(12),
        height: side + context.s(12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: context.colors.surface,
          border: Border.all(color: context.colors.border),
          borderRadius: BorderRadius.circular(context.s(10)),
        ),
        child: sheet == null
            ? Icon(
                Icons.add,
                color: context.colors.inkFaint,
                size: context.s(18),
              )
            : PixelSprite(sheet: sheet!, cellSize: cellSize),
      ),
    );
  }
}

class _UnlockCard extends ConsumerWidget {
  const _UnlockCard({
    required this.def,
    required this.unlockedAt,
    required this.equipped,
  });

  final CosmeticDef def;
  final DateTime? unlockedAt;
  final bool equipped;

  String get _typeLabel => switch (def.type) {
    CosmeticType.accentTheme => 'ACCENT THEME',
    CosmeticType.widgetSkin => 'WIDGET SKIN',
    CosmeticType.pet => 'PET',
    CosmeticType.furniture => 'FURNITURE',
  };

  /// Pet/furniture cards equip into slot 1 — the slot pills above are the
  /// way to target slots 2/3, so a card tap doesn't need a slot picker.
  Future<void> _equip(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(unlockableRepositoryProvider);
    switch (def.type) {
      case CosmeticType.accentTheme:
        await repo.equipAccent(def.id);
        ref.read(accentThemeIdProvider.notifier).state = def.id;
      case CosmeticType.widgetSkin:
        await repo.equipWidgetSkin(def.id);
      case CosmeticType.pet:
      case CosmeticType.furniture:
        await repo.equipToSlotOne(def.id);
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: context.colors.ink,
        behavior: SnackBarBehavior.floating,
        content: Text(
          'Equipped · ${def.name}',
          style: TextStyle(color: context.colors.surface),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = unlockedAt == null;
    return Opacity(
      opacity: locked ? 0.4 : 1,
      child: GestureDetector(
        onTap: locked ? null : () => _equip(context, ref),
        child: Container(
          margin: EdgeInsets.only(bottom: context.s(10)),
          padding: EdgeInsets.all(context.s(12)),
          decoration: BoxDecoration(
            color: locked ? Colors.transparent : context.colors.surface,
            border: Border.all(
              color: locked ? context.colors.borderFaint : context.colors.border,
            ),
            borderRadius: BorderRadius.circular(context.s(12)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: context.s(30),
                height: context.s(30),
                child: Center(child: _preview(context)),
              ),
              SizedBox(width: context.s(12)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      def.name,
                      style: AppTypography.itemTitle(context).copyWith(
                        fontWeight: equipped ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    Text(
                      locked ? 'LV ${def.unlockLevel}' : _typeLabel,
                      style: AppTypography.monoLabel(context).copyWith(
                        color: equipped && !locked
                            ? context.colors.accent
                            : context.colors.inkFaint,
                      ),
                    ),
                  ],
                ),
              ),
              if (equipped && !locked)
                Text(
                  'EQUIPPED',
                  style: AppTypography.monoLabel(
                    context,
                  ).copyWith(color: context.colors.accent),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _preview(BuildContext context) {
    if (def.sheet != null) {
      return PixelSprite(sheet: def.sheet!, cellSize: context.s(3));
    }
    if (def.type == CosmeticType.accentTheme && def.accent != null) {
      return Container(
        width: context.s(20),
        height: context.s(20),
        decoration: BoxDecoration(
          color: def.accent,
          borderRadius: BorderRadius.circular(context.s(5)),
        ),
      );
    }
    return Icon(
      Icons.widgets_outlined,
      color: context.colors.inkMuted,
      size: context.s(20),
    );
  }
}
