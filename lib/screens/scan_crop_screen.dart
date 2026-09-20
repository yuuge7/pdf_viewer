import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/scan_service.dart';

/// Lets the user place the four corners of the page inside a photo.
///
/// Four free corners rather than a rectangle, because a photo of a document is
/// taken at an angle and the page is a trapezium in the frame. Dragging a
/// rectangle around it would keep the perspective; placing the corners lets
/// [ScanService] flatten it.
class ScanCropScreen extends StatefulWidget {
  final String imagePath;
  final ScanQuad initialQuad;

  const ScanCropScreen({
    super.key,
    required this.imagePath,
    required this.initialQuad,
  });

  /// Returns the chosen quad, or null if the user backed out.
  static Future<ScanQuad?> show(
    BuildContext context, {
    required String imagePath,
    required ScanQuad initialQuad,
  }) {
    return Navigator.of(context).push<ScanQuad>(
      MaterialPageRoute(
        builder: (_) =>
            ScanCropScreen(imagePath: imagePath, initialQuad: initialQuad),
      ),
    );
  }

  @override
  State<ScanCropScreen> createState() => _ScanCropScreenState();
}

class _ScanCropScreenState extends State<ScanCropScreen> {
  /// How close a touch has to land to a corner to grab it. Generous, because
  /// the handles are small and a fingertip is not.
  static const double _grabRadius = 48;

  late ScanQuad _quad;
  Size? _imageSize;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  int? _dragging;
  Offset? _magnifierFocus;
  bool _isDetecting = false;

  @override
  void initState() {
    super.initState();
    _quad = widget.initialQuad;
    _resolveImageSize();
  }

  /// Reads the photo's displayed dimensions.
  ///
  /// Flutter's decoder applies the EXIF orientation, exactly as the renderer's
  /// `bakeOrientation` does, so the corners placed here describe the same
  /// pixels the warp will read.
  void _resolveImageSize() {
    final ImageStream stream = FileImage(File(widget.imagePath))
        .resolve(const ImageConfiguration());
    final ImageStreamListener listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() {
          _imageSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
        });
      },
      onError: (_, _) {
        if (mounted) setState(() => _imageSize = const Size(1, 1));
      },
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  @override
  void dispose() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    super.dispose();
  }

  Future<void> _autoDetect() async {
    setState(() => _isDetecting = true);
    final ScanQuad? detected = await ScanService.detectDocument(
      widget.imagePath,
    );
    if (!mounted) return;
    setState(() {
      _isDetecting = false;
      if (detected != null) _quad = detected;
    });
    if (detected == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('No page edges found — drag the corners instead.'),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size? imageSize = _imageSize;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Adjust corners'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _quad = ScanQuad.full),
            child: const Text('Reset'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_quad),
            child: const Text('Done'),
          ),
        ],
      ),
      body: imageSize == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: LayoutBuilder(
                        builder: (context, constraints) =>
                            _buildCanvas(constraints, imageSize),
                      ),
                    ),
                  ),
                  _buildActions(),
                ],
              ),
            ),
    );
  }

  Widget _buildCanvas(BoxConstraints constraints, Size imageSize) {
    // The photo is letterboxed inside the available box; everything below
    // works in the rectangle it actually occupies, not in the whole canvas.
    final double scale = math.min(
      constraints.maxWidth / imageSize.width,
      constraints.maxHeight / imageSize.height,
    );
    final Size displayed = Size(
      imageSize.width * scale,
      imageSize.height * scale,
    );
    final Offset origin = Offset(
      (constraints.maxWidth - displayed.width) / 2,
      (constraints.maxHeight - displayed.height) / 2,
    );

    Offset toScreen(Offset normalised) => Offset(
      origin.dx + normalised.dx * displayed.width,
      origin.dy + normalised.dy * displayed.height,
    );

    Offset toNormalised(Offset screen) => Offset(
      ((screen.dx - origin.dx) / displayed.width).clamp(0.0, 1.0),
      ((screen.dy - origin.dy) / displayed.height).clamp(0.0, 1.0),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (details) {
        final List<Offset> screenCorners = _quad.corners
            .map(toScreen)
            .toList(growable: false);
        int nearest = 0;
        double best = double.infinity;
        for (int i = 0; i < 4; i++) {
          final double distance =
              (screenCorners[i] - details.localPosition).distance;
          if (distance < best) {
            best = distance;
            nearest = i;
          }
        }
        if (best > _grabRadius) return;
        setState(() {
          _dragging = nearest;
          _magnifierFocus = screenCorners[nearest];
        });
      },
      onPanUpdate: (details) {
        final int? index = _dragging;
        if (index == null) return;
        setState(() {
          _quad = _quad.withCorner(index, toNormalised(details.localPosition));
          _magnifierFocus = toScreen(_quad.corners[index]);
        });
      },
      onPanEnd: (_) => setState(() {
        _dragging = null;
        _magnifierFocus = null;
      }),
      onPanCancel: () => setState(() {
        _dragging = null;
        _magnifierFocus = null;
      }),
      child: Stack(
        children: [
          Positioned.fromRect(
            rect: origin & displayed,
            child: Image.file(
              File(widget.imagePath),
              fit: BoxFit.fill,
              gaplessPlayback: true,
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _QuadPainter(
                corners: _quad.corners.map(toScreen).toList(growable: false),
                activeCorner: _dragging,
                accent: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          if (_magnifierFocus != null) _buildMagnifier(_magnifierFocus!),
          if (_isDetecting)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black38,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  /// Shows the area under the finger, offset so the hand does not cover the
  /// very corner being placed.
  Widget _buildMagnifier(Offset focus) {
    const double size = 110;
    final bool aboveIsBetter = focus.dy > size + 24;
    return Positioned(
      left: focus.dx - size / 2,
      top: aboveIsBetter ? focus.dy - size - 24 : focus.dy + 24,
      child: IgnorePointer(
        child: RawMagnifier(
          size: const Size(size, size),
          magnificationScale: 1.8,
          decoration: MagnifierDecoration(
            shape: const CircleBorder(
              side: BorderSide(color: Colors.white70, width: 2),
            ),
            shadows: const [BoxShadow(color: Colors.black54, blurRadius: 8)],
          ),
          focalPointOffset: Offset(
            0,
            aboveIsBetter ? size / 2 + 24 : -(size / 2 + 24),
          ),
        ),
      ),
    );
  }

  Widget _buildActions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          FilledButton.tonalIcon(
            onPressed: _isDetecting ? null : _autoDetect,
            icon: const Icon(Icons.auto_fix_high_rounded),
            label: const Text('Auto'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(_quad),
            icon: const Icon(Icons.check_rounded),
            label: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}

class _QuadPainter extends CustomPainter {
  final List<Offset> corners;
  final int? activeCorner;
  final Color accent;

  const _QuadPainter({
    required this.corners,
    required this.activeCorner,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Path quad = Path()..addPolygon(corners, true);

    // Dim everything outside the selection: even-odd over the full canvas
    // leaves the quad itself untouched, so the page stays at full brightness.
    final Path scrim = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      quad,
    );
    canvas.drawPath(scrim, Paint()..color = Colors.black.withAlpha(140));

    canvas.drawPath(
      quad,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = accent,
    );

    for (int i = 0; i < corners.length; i++) {
      final bool isActive = i == activeCorner;
      canvas.drawCircle(
        corners[i],
        isActive ? 16 : 12,
        Paint()..color = Colors.white.withAlpha(isActive ? 255 : 210),
      );
      canvas.drawCircle(corners[i], isActive ? 10 : 7, Paint()..color = accent);
    }
  }

  @override
  bool shouldRepaint(covariant _QuadPainter oldDelegate) =>
      oldDelegate.activeCorner != activeCorner ||
      oldDelegate.accent != accent ||
      !_sameCorners(oldDelegate.corners, corners);

  static bool _sameCorners(List<Offset> a, List<Offset> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
