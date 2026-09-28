import 'dart:typed_data';

import 'package:flutter/material.dart';

/// An image floating over the viewer while the user positions it: drag the
/// body to move it, drag the corner handle to resize it.
///
/// Only the box itself takes touches, so the page underneath can still be
/// scrolled into place around it.
class PlacementBox extends StatelessWidget {
  /// Where the image sits, in the viewer's screen space.
  final Rect rect;
  final Uint8List bytes;
  final ValueChanged<Offset> onMove;
  final ValueChanged<Offset> onResize;

  const PlacementBox({
    super.key,
    required this.rect,
    required this.bytes,
    required this.onMove,
    required this.onResize,
  });

  /// Room around the image for the handle, which would otherwise hang
  /// outside the box and miss half its touches.
  static const double _pad = 16;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Positioned.fromRect(
      rect: rect.inflate(_pad),
      child: Stack(
        children: [
          Positioned.fill(
            left: _pad,
            top: _pad,
            right: _pad,
            bottom: _pad,
            child: GestureDetector(
              onPanUpdate: (d) => onMove(d.delta),
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border.all(color: colors.primary, width: 1.5),
                ),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.fill,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              onPanUpdate: (d) => onResize(d.delta),
              child: Container(
                width: _pad * 2,
                height: _pad * 2,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 4),
                  ],
                ),
                child: Icon(
                  Icons.open_in_full_rounded,
                  size: 16,
                  color: colors.onPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
