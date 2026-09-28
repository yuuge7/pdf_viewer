import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/signature_store.dart';

/// Lets the user pick a saved signature or draw a new one. Returns the
/// signature as a transparent PNG, or null.
class SignatureSheet extends StatefulWidget {
  const SignatureSheet({super.key});

  static Future<Uint8List?> show(BuildContext context) {
    return showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const SignatureSheet(),
    );
  }

  @override
  State<SignatureSheet> createState() => _SignatureSheetState();
}

class _SignatureSheetState extends State<SignatureSheet> {
  List<File>? _saved;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final List<File> saved = await SignatureStore.list();
    if (mounted) setState(() => _saved = saved);
  }

  Future<void> _createNew() async {
    final Uint8List? png = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const SignaturePadScreen(),
      ),
    );
    if (png == null || !mounted) return;
    await SignatureStore.save(png);
    if (mounted) Navigator.of(context).pop(png);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<File>? saved = _saved;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Signature',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            if (saved == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (saved.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: GridView.builder(
                  shrinkWrap: true,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 200,
                    childAspectRatio: 2.2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                  ),
                  itemCount: saved.length,
                  itemBuilder: (context, i) => _tile(theme, saved[i]),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _createNew,
              icon: const Icon(Icons.gesture_rounded),
              label: const Text('Draw a new signature'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(ThemeData theme, File file) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          final Uint8List bytes = await file.readAsBytes();
          if (mounted) Navigator.of(context).pop(bytes);
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Image.file(file, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 18),
                color: Colors.black54,
                tooltip: 'Delete signature',
                onPressed: () async {
                  await SignatureStore.delete(file);
                  await _refresh();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A blank card to sign on. Returns a transparent PNG cropped to the ink.
class SignaturePadScreen extends StatefulWidget {
  const SignaturePadScreen({super.key});

  @override
  State<SignaturePadScreen> createState() => _SignaturePadScreenState();
}

class _Stroke {
  final List<Offset> points;
  final Color color;
  final double width;
  _Stroke(this.points, this.color, this.width);
}

class _SignaturePadScreenState extends State<SignaturePadScreen> {
  final List<_Stroke> _strokes = [];
  Color _color = const Color(0xFF111111);
  double _width = 3.5;
  bool _saving = false;

  static const List<Color> _inks = [
    Color(0xFF111111),
    Color(0xFF1E40AF),
    Color(0xFFB91C1C),
  ];

  Future<void> _save() async {
    if (_strokes.isEmpty) return;
    setState(() => _saving = true);
    try {
      final Uint8List? png = await _renderPng();
      if (!mounted) return;
      Navigator.of(context).pop(png);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Draws the strokes at 3x into an image just big enough to hold them.
  Future<Uint8List?> _renderPng() async {
    double left = double.infinity, top = double.infinity;
    double right = -double.infinity, bottom = -double.infinity;
    for (final _Stroke stroke in _strokes) {
      for (final Offset p in stroke.points) {
        left = math.min(left, p.dx - stroke.width);
        top = math.min(top, p.dy - stroke.width);
        right = math.max(right, p.dx + stroke.width);
        bottom = math.max(bottom, p.dy + stroke.width);
      }
    }
    final Rect bounds = Rect.fromLTRB(left, top, right, bottom).inflate(4);
    const double scale = 3;
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.scale(scale);
    canvas.translate(-bounds.left, -bounds.top);
    _SignaturePainter.paintStrokes(canvas, _strokes);
    final ui.Image image = await recorder.endRecording().toImage(
      (bounds.width * scale).ceil(),
      (bounds.height * scale).ceil(),
    );
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    image.dispose();
    return data?.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Draw your signature'),
        actions: [
          IconButton(
            tooltip: 'Undo stroke',
            icon: const Icon(Icons.undo_rounded),
            onPressed: _strokes.isEmpty
                ? null
                : () => setState(_strokes.removeLast),
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _strokes.isEmpty ? null : () => setState(_strokes.clear),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: Colors.white,
                    child: GestureDetector(
                      onPanStart: (d) => setState(
                        () => _strokes.add(
                          _Stroke([d.localPosition], _color, _width),
                        ),
                      ),
                      onPanUpdate: (d) => setState(
                        () => _strokes.last.points.add(d.localPosition),
                      ),
                      child: CustomPaint(
                        painter: _SignaturePainter(_strokes),
                        child: Stack(
                          children: [
                            Positioned(
                              left: 32,
                              right: 32,
                              bottom: 64,
                              child: Container(height: 1, color: Colors.black26),
                            ),
                            if (_strokes.isEmpty)
                              const Positioned(
                                left: 32,
                                bottom: 72,
                                child: Text(
                                  'Sign here',
                                  style: TextStyle(color: Colors.black38),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  for (final Color ink in _inks)
                    GestureDetector(
                      onTap: () => setState(() => _color = ink),
                      child: Container(
                        margin: const EdgeInsets.only(right: 10),
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: ink,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _color == ink
                                ? theme.colorScheme.primary
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: Slider(
                      value: _width,
                      min: 1.5,
                      max: 8,
                      onChanged: (v) => setState(() => _width = v),
                    ),
                  ),
                  FilledButton(
                    onPressed: _strokes.isEmpty || _saving ? null : _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final List<_Stroke> strokes;
  _SignaturePainter(this.strokes);

  /// Smooths each stroke with quadratic curves through the midpoints of its
  /// samples, so fast pen movement does not come out as a polygon.
  static void paintStrokes(Canvas canvas, List<_Stroke> strokes) {
    for (final _Stroke stroke in strokes) {
      final Paint paint = Paint()
        ..color = stroke.color
        ..strokeWidth = stroke.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true;
      final List<Offset> p = stroke.points;
      if (p.length == 1) {
        canvas.drawCircle(p.first, stroke.width / 2, paint..style = PaintingStyle.fill);
        continue;
      }
      final Path path = Path()..moveTo(p.first.dx, p.first.dy);
      for (int i = 1; i < p.length - 1; i++) {
        final Offset mid = Offset.lerp(p[i], p[i + 1], 0.5)!;
        path.quadraticBezierTo(p[i].dx, p[i].dy, mid.dx, mid.dy);
      }
      path.lineTo(p.last.dx, p.last.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) => paintStrokes(canvas, strokes);

  // Strokes are mutated in place, so there is nothing reliable to compare.
  @override
  bool shouldRepaint(covariant _SignaturePainter oldDelegate) => true;
}
