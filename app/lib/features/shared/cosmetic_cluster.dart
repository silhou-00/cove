import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../data/db/tables.dart' show UnlockableType;
import '../../domain/services/cosmetics.dart';
import 'equip_sheet.dart';
import 'pixel_sprite.dart';

/// The three-slot cosmetic cluster (§17) — shown next to the title in
/// Agenda/Up Next/Calendar/Areas' header rows. Tapping it opens the equip
/// sheet (`openEquip` in the design handoff), same as tapping Settings'
/// "Unlocks" row — cycling a slot happens inside that sheet, not directly
/// on the header. Hidden entirely until at least one pet/furniture unlock
/// exists (level 4, the earliest one in the catalog), so it doesn't show
/// three empty placeholders to a brand-new user.
class CosmeticCluster extends ConsumerWidget {
  const CosmeticCluster({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unlockables = ref.watch(unlockablesProvider).value;
    final slots = ref.watch(equippedSlotsProvider).value;
    if (unlockables == null || slots == null) return const SizedBox.shrink();
    final anySlottableUnlocked = unlockables.any(
      (u) =>
          u.unlockedAt != null &&
          (u.type == UnlockableType.pet || u.type == UnlockableType.furniture),
    );
    if (!anySlottableUnlocked) return const SizedBox.shrink();

    final cellSize = context.s(2);
    return GestureDetector(
      onTap: () => showEquipSheet(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) SizedBox(width: context.s(4)),
            _Slot(sheet: Cosmetics.byIdOrNull(slots[i])?.sheet, cellSize: cellSize),
          ],
        ],
      ),
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({required this.sheet, required this.cellSize});

  final String? sheet;
  final double cellSize;

  @override
  Widget build(BuildContext context) {
    final side = cellSize * 10;
    return Container(
      width: side,
      height: side,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: sheet == null
            ? Border.all(color: context.colors.border, width: 1)
            : null,
        borderRadius: BorderRadius.circular(context.s(3)),
      ),
      child: sheet == null ? null : PixelSprite(sheet: sheet!, cellSize: cellSize),
    );
  }
}
