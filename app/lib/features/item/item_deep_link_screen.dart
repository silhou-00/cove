import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import 'item_detail_sheet.dart';

/// Where a notification tap or widget tap lands (§7/§6: `cove://item/[id]`).
/// Renders the same `ItemDetailSheet` content used for in-app row taps, as
/// a full page instead of a modal — a deep-linked cold start has no screen
/// to show behind a sheet. `ItemDetailSheet` keeps its own drag-handle bar
/// and 90%-height cap even here (a minor cosmetic mismatch outside a real
/// sheet), traded for not duplicating the whole form.
class ItemDeepLinkScreen extends StatelessWidget {
  const ItemDeepLinkScreen({super.key, required this.itemId});

  final String itemId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.background,
      appBar: AppBar(
        backgroundColor: context.colors.background,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: context.colors.ink),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
      ),
      body: ItemDetailSheet(itemId: itemId),
    );
  }
}
