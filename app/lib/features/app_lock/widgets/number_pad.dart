import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// Shared 0-9 + backspace pad (§12) — used by the lock screen and by
/// Settings' set-PIN/confirm-PIN sheets. [color] is the digit color; the
/// disabled state is the same color at reduced opacity, so callers just
/// pass whatever ink color matches their background (light sheet vs. the
/// lock screen's dark full-bleed background).
class NumberPad extends StatelessWidget {
  const NumberPad({
    super.key,
    required this.enabled,
    required this.onDigit,
    required this.onBackspace,
    this.color,
  });

  final bool enabled;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  // Null picks up the live theme ink color (a `context`-dependent lookup
  // can't be a const constructor default) — callers only pass this
  // explicitly to override it, e.g. the lock screen's fixed dark backdrop.
  final Color? color;

  static const _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['', '0', '⌫'],
  ];

  @override
  Widget build(BuildContext context) {
    final resolvedColor = color ?? context.colors.ink;
    return Column(
      children: [
        for (final row in _rows)
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.s(4)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final key in row)
                  _PadKey(
                    label: key,
                    enabled: enabled && key.isNotEmpty,
                    color: resolvedColor,
                    onTap: key.isEmpty
                        ? null
                        : key == '⌫'
                        ? onBackspace
                        : () => onDigit(key),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PadKey extends StatelessWidget {
  const _PadKey({
    required this.label,
    required this.enabled,
    required this.color,
    required this.onTap,
  });
  final String label;
  final bool enabled;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      // Container below has no color/decoration, so without this the
      // GestureDetector only registers taps on the actual Text glyph
      // pixels (Flutter's default HitTestBehavior.deferToChild), not the
      // full key — most of the visible tap target would silently eat taps.
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: context.s(64),
        height: context.s(64),
        margin: EdgeInsets.symmetric(horizontal: context.s(10)),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: enabled ? color : color.withValues(alpha: 0.2),
            fontSize: context.s(22),
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
