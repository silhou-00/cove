import 'package:flutter/material.dart';

/// Recreates `documents/icon/cove-icon-1024.svg` as a painted widget rather
/// than pulling in an SVG-rendering package for one simple pixel-grid
/// icon — it's just 10 rectangles on a 12×12 grid, the same technique the
/// design prototype itself used (a boxShadow pixel sprite).
class CoveIcon extends StatelessWidget {
  const CoveIcon({super.key, required this.size, this.monochrome = false});

  final double size;
  final bool monochrome;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _CoveIconPainter(monochrome: monochrome)),
    );
  }
}

typedef _Cell = (int row, int col, int width);

class _CoveIconPainter extends CustomPainter {
  _CoveIconPainter({required this.monochrome});

  final bool monochrome;

  static const _bg = Color(0xFFA4543A);
  static const _cream = Color(0xFFF4F1EB);
  static const _gold = Color(0xFFE8C88A);

  static const _creamCells = <_Cell>[
    (2, 2, 8),
    (3, 2, 2),
    (4, 2, 2),
    (5, 2, 2),
    (6, 2, 2),
    (7, 2, 2),
    (8, 2, 8),
  ];

  static const _goldCells = <_Cell>[(3, 4, 6), (4, 5, 4), (5, 6, 2)];

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 12;
    if (!monochrome) {
      final radius = Radius.circular(size.width * 0.22);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, radius),
        Paint()..color = _bg,
      );
    }
    for (final (row, col, width) in _creamCells) {
      _paintCell(
        canvas,
        unit,
        row,
        col,
        width,
        monochrome ? Colors.white : _cream,
      );
    }
    for (final (row, col, width) in _goldCells) {
      _paintCell(
        canvas,
        unit,
        row,
        col,
        width,
        monochrome ? Colors.white : _gold,
      );
    }
  }

  void _paintCell(
    Canvas canvas,
    double unit,
    int row,
    int col,
    int width,
    Color color,
  ) {
    canvas.drawRect(
      Rect.fromLTWH(col * unit, row * unit, width * unit, unit),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _CoveIconPainter oldDelegate) =>
      oldDelegate.monochrome != monochrome;
}
