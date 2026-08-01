import 'package:flutter/material.dart';

import '../../domain/services/cosmetics.dart';

/// Renders a [PixelSprites] sheet at a given cell size (§17 "loft build":
/// the same 10×10 sheet renders at 2px/cell in list headers, 3px/cell in
/// unlock cards, 5px/cell in equip slots — only [cellSize] changes).
class PixelSprite extends StatelessWidget {
  const PixelSprite({super.key, required this.sheet, required this.cellSize});

  final String sheet;
  final double cellSize;

  @override
  Widget build(BuildContext context) {
    final rows = PixelSprites.sheets[sheet];
    final palette = PixelSprites.palettes[sheet];
    if (rows == null || palette == null) return const SizedBox.shrink();
    final side = rows.first.length * cellSize;
    return SizedBox(
      width: side,
      height: rows.length * cellSize,
      child: CustomPaint(
        painter: _PixelSpritePainter(rows: rows, palette: palette, cellSize: cellSize),
      ),
    );
  }
}

class _PixelSpritePainter extends CustomPainter {
  const _PixelSpritePainter({
    required this.rows,
    required this.palette,
    required this.cellSize,
  });

  final List<String> rows;
  final Map<String, Color> palette;
  final double cellSize;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (var r = 0; r < rows.length; r++) {
      final row = rows[r];
      for (var c = 0; c < row.length; c++) {
        final color = palette[row[c]];
        if (color == null) continue;
        paint.color = color;
        canvas.drawRect(
          Rect.fromLTWH(c * cellSize, r * cellSize, cellSize, cellSize),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _PixelSpritePainter oldDelegate) =>
      oldDelegate.rows != rows ||
      oldDelegate.palette != palette ||
      oldDelegate.cellSize != cellSize;
}
