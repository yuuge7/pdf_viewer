import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/image_engine.dart';
import '../services/pdf_tools.dart';
import '../services/scan_service.dart';
import '../widgets/export_sheet.dart';
import 'scan_crop_screen.dart';

enum _Tool {
  crop('Crop', Icons.crop_rotate_rounded),
  adjust('Adjust', Icons.tune_rounded),
  looks('Filters', Icons.auto_awesome_outlined),
  draw('Draw', Icons.brush_outlined),
  text('Text', Icons.title_rounded),
  hide('Hide', Icons.blur_on_rounded),
  cutout('Cut out', Icons.content_cut_rounded);

  final String label;
  final IconData icon;
  const _Tool(this.label, this.icon);
}

enum _Pen {
  pen('Pen', Icons.edit_rounded),
  marker('Marker', Icons.brush_rounded),
  line('Line', Icons.horizontal_rule_rounded),
  arrow('Arrow', Icons.north_east_rounded),
  rectangle('Rectangle', Icons.crop_square_rounded),
  ellipse('Ellipse', Icons.circle_outlined);

  final String label;
  final IconData icon;
  const _Pen(this.label, this.icon);
}

enum _MaskShape {
  none('No mask'),
  rounded('Rounded corners'),
  ellipse('Circle');

  final String label;
  const _MaskShape(this.label);
}

/// Something drawn on the picture, in the picture's own pixels, so that it
/// stays put when the picture is turned or cropped around it.
sealed class _Layer {
  const _Layer();
  void paint(Canvas canvas);
}

class _Stroke extends _Layer {
  final _Pen kind;
  final List<Offset> points;
  final Color color;
  final double width;

  const _Stroke(this.kind, this.points, this.color, this.width);

  @override
  void paint(Canvas canvas) {
    if (points.isEmpty) return;
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = kind == _Pen.marker ? width * 3 : width
      ..color = kind == _Pen.marker ? color.withValues(alpha: 0.4) : color;
    final Offset a = points.first, b = points.last;
    switch (kind) {
      case _Pen.pen || _Pen.marker:
        if (points.length == 1) {
          canvas.drawCircle(a, paint.strokeWidth / 2, Paint()..color = paint.color);
          return;
        }
        final Path path = Path()..moveTo(a.dx, a.dy);
        for (final Offset p in points.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, paint);
      case _Pen.line:
        canvas.drawLine(a, b, paint);
      case _Pen.arrow:
        final double length = (b - a).distance;
        if (length < 1) return;
        final Offset along = (b - a) / length;
        final Offset across = Offset(-along.dy, along.dx);
        final double head = math.min(length, width * 4.5);
        final Offset base = b - along * head;
        canvas.drawLine(a, b - along * head * 0.6, paint);
        canvas.drawPath(
          Path()
            ..moveTo(b.dx, b.dy)
            ..lineTo(
              (base + across * head * 0.5).dx,
              (base + across * head * 0.5).dy,
            )
            ..lineTo(
              (base - across * head * 0.5).dx,
              (base - across * head * 0.5).dy,
            )
            ..close(),
          Paint()..color = color,
        );
      case _Pen.rectangle:
        canvas.drawRect(Rect.fromPoints(a, b), paint);
      case _Pen.ellipse:
        canvas.drawOval(Rect.fromPoints(a, b), paint);
    }
  }
}

class _Label extends _Layer {
  final String text;
  final Offset center;

  /// Font size in the picture's pixels.
  final double size;
  final Color color;
  final double opacity;

  /// Repeated over the whole picture, as a watermark.
  final bool tiled;

  /// The picture's size, which a tiled label has to cover.
  final Size bounds;

  const _Label({
    required this.text,
    required this.center,
    required this.size,
    required this.color,
    required this.bounds,
    this.opacity = 1,
    this.tiled = false,
  });

  _Label copyWith({
    Offset? center,
    double? size,
    Color? color,
    double? opacity,
    bool? tiled,
  }) => _Label(
    text: text,
    center: center ?? this.center,
    size: size ?? this.size,
    color: color ?? this.color,
    bounds: bounds,
    opacity: opacity ?? this.opacity,
    tiled: tiled ?? this.tiled,
  );

  TextPainter _layout() => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w600,
        color: color.withValues(alpha: opacity),
        shadows: tiled || opacity < 1
            ? null
            : [
                // Legible over light and dark alike.
                Shadow(
                  color: const Color(0x66000000),
                  blurRadius: size * 0.08,
                  offset: Offset(0, size * 0.03),
                ),
              ],
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout();

  /// Where the label sits, for picking it up again.
  Rect get rect {
    final TextPainter painter = _layout();
    final Rect r = Rect.fromCenter(
      center: center,
      width: painter.width,
      height: painter.height,
    );
    painter.dispose();
    return r;
  }

  @override
  void paint(Canvas canvas) {
    final TextPainter painter = _layout();
    if (!tiled) {
      painter.paint(
        canvas,
        center - Offset(painter.width / 2, painter.height / 2),
      );
      painter.dispose();
      return;
    }
    final double stepX = painter.width + size * 2;
    final double stepY = painter.height * 3.2;
    final double reach = bounds.longestSide * 1.5;
    canvas.save();
    canvas.clipRect(Offset.zero & bounds);
    canvas.translate(bounds.width / 2, bounds.height / 2);
    canvas.rotate(-math.pi / 6);
    int row = 0;
    for (double y = -reach; y < reach; y += stepY, row++) {
      for (double x = -reach + (row.isOdd ? stepX / 2 : 0); x < reach; x += stepX) {
        painter.paint(canvas, Offset(x, y));
      }
    }
    canvas.restore();
    painter.dispose();
  }
}

/// Everything about the picture at one moment, for undo.
class _Snapshot {
  final Uint8List pixels;
  final int width;
  final int height;
  final bool hasAlpha;
  final Adjustments adjust;
  final int look;
  final int turns;
  final double straighten;
  final Rect crop;
  final _MaskShape mask;
  final List<_Layer> layers;

  const _Snapshot({
    required this.pixels,
    required this.width,
    required this.height,
    required this.hasAlpha,
    required this.adjust,
    required this.look,
    required this.turns,
    required this.straighten,
    required this.crop,
    required this.mask,
    required this.layers,
  });
}

/// Edits a picture: crop, turn and straighten it, fix its perspective,
/// adjust it, give it a look, draw and write on it, hide parts of it, cut
/// out its background, and save a copy.
///
/// Nothing touches the file that was opened. Adjustments, the crop and
/// what is drawn are kept as intent and applied when the picture is shown
/// or saved; only the steps that rework pixels (perspective, hiding, cutting
/// out) replace the working copy, and undo keeps the one before.
class ImageEditorScreen extends StatefulWidget {
  final String path;
  final String name;

  const ImageEditorScreen({super.key, required this.path, required this.name});

  static Future<void> open(
    BuildContext context, {
    required String path,
    required String name,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageEditorScreen(path: path, name: name),
      ),
    );
  }

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  /// Longest edge the picture is worked on at. Large enough to print, small
  /// enough that one copy of the pixels is tens of megabytes, not hundreds.
  static const int _workEdge = 2200;
  static const int _previewEdge = 900;
  static const int _maxUndo = 14;

  /// How many different working copies undo may hold on to.
  static const int _maxCopies = 4;
  static const Rect _fullCrop = Rect.fromLTWH(0, 0, 1, 1);

  static const List<Color> _colors = [
    Color(0xFFE53935), Color(0xFFFB8C00), Color(0xFFFDD835), Color(0xFF43A047), //
    Color(0xFF1E88E5), Color(0xFF8E24AA), Color(0xFFFFFFFF), Color(0xFF000000),
  ];

  static const Map<String, double?> _aspects = {
    'Free': null,
    '1:1': 1,
    '4:3': 4 / 3,
    '3:4': 3 / 4,
    '16:9': 16 / 9,
    '9:16': 9 / 16,
  };

  // The working copy: straight (not premultiplied) RGBA.
  Uint8List _pixels = Uint8List(0);
  int _w = 0;
  int _h = 0;
  bool _hasAlpha = false;

  // A small copy for the screen, and that copy with the adjustments on.
  Uint8List _small = Uint8List(0);
  int _sw = 0;
  int _sh = 0;
  ui.Image? _shown;
  List<ui.Image> _lookThumbs = const [];
  int _serial = 0;

  Adjustments _adjust = Adjustments.none;
  int _look = 0;
  int _turns = 0;
  double _straighten = 0;
  Rect _crop = _fullCrop;
  _MaskShape _mask = _MaskShape.none;
  List<_Layer> _layers = const [];

  _Tool _tool = _Tool.adjust;
  AdjustKind _kind = AdjustKind.brightness;
  String _aspect = 'Free';
  _Pen _pen = _Pen.pen;
  Color _color = _colors.first;
  double _penSize = 0.008;
  bool _pixelate = false;
  double _tolerance = 0.25;
  int? _selectedLabel;

  // A gesture in progress.
  _Stroke? _drawing;
  Rect? _hiding;
  int? _cropHandle;
  Offset? _dragLast;

  final List<_Snapshot> _undo = [];
  final List<_Snapshot> _redo = [];
  List<(String, String)> _exif = const [];
  bool _busy = true;
  String? _error;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _shown?.dispose();
    for (final ui.Image thumb in _lookThumbs) {
      thumb.dispose();
    }
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // --- Pixels -----------------------------------------------------------------

  Future<void> _load() async {
    try {
      final Uint8List bytes = await File(widget.path).readAsBytes();
      _exif = ImageEngine.readExif(bytes);
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        bytes,
      );
      final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
        buffer,
      );
      final int longest = math.max(descriptor.width, descriptor.height);
      final ui.Codec codec = await descriptor.instantiateCodec(
        // Only one side: the decoder turns the picture upright after
        // scaling, and the other side follows whichever way that goes.
        targetWidth: longest > _workEdge
            ? (descriptor.width * _workEdge / longest).round()
            : null,
      );
      final ui.Image image = (await codec.getNextFrame()).image;
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      final int w = image.width, h = image.height;
      image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
      if (data == null) throw const FormatException('unreadable');
      final Uint8List pixels = data.buffer.asUint8List();
      bool alpha = false;
      for (int at = 3; at < pixels.length; at += 4 * 97) {
        if (pixels[at] != 255) {
          alpha = true;
          break;
        }
      }
      await _setBase(pixels, w, h, alpha);
    } catch (e) {
      debugPrint('Could not open picture: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'This picture could not be opened.';
      });
    }
  }

  static Future<ui.Image> _toImage(Uint8List straight, int w, int h, bool alpha) {
    final Completer<ui.Image> done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      alpha ? ImageEngine.premultiplied(straight) : straight,
      w,
      h,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  /// Replaces the working copy and everything derived from it.
  Future<void> _setBase(Uint8List pixels, int w, int h, bool alpha) async {
    final double scale = math.min(1, _previewEdge / math.max(w, h));
    final int sw = math.max(1, (w * scale).round());
    final int sh = math.max(1, (h * scale).round());
    final Uint8List small = await _Work.downscale(pixels, w, h, sw, sh);
    if (!mounted) return;
    _pixels = pixels;
    _w = w;
    _h = h;
    _hasAlpha = alpha;
    _small = small;
    _sw = sw;
    _sh = sh;
    await _refreshShown();
    if (mounted) setState(() => _busy = false);
    unawaited(_refreshThumbs());
  }

  /// Re-applies the adjustments to the small copy. Results that arrive
  /// after a newer request has gone out are dropped.
  Future<void> _refreshShown() async {
    final int serial = ++_serial;
    final Uint8List small = _small;
    final int sw = _sw, sh = _sh;
    final Adjustments adjust = _adjust;
    final PhotoLook look = photoLooks[_look];
    final bool alpha = _hasAlpha;
    final Uint8List adjusted = adjust.isNeutral && _look == 0
        ? small
        : await _Work.apply(small, sw, sh, adjust, look);
    if (serial != _serial || !mounted) return;
    final ui.Image image = await _toImage(adjusted, sw, sh, alpha);
    if (serial != _serial || !mounted) {
      image.dispose();
      return;
    }
    final ui.Image? old = _shown;
    setState(() => _shown = image);
    old?.dispose();
  }

  Future<void> _refreshThumbs() async {
    final Uint8List small = _small;
    final int sw = _sw, sh = _sh;
    const int edge = 96;
    final double scale = math.min(1, edge / math.max(sw, sh));
    final int tw = math.max(1, (sw * scale).round());
    final int th = math.max(1, (sh * scale).round());
    final List<Uint8List> raw = await _Work.looks(small, sw, sh, tw, th);
    final List<ui.Image> thumbs = [
      for (final Uint8List px in raw) await _toImage(px, tw, th, _hasAlpha),
    ];
    if (!mounted || small != _small) {
      for (final ui.Image thumb in thumbs) {
        thumb.dispose();
      }
      return;
    }
    final List<ui.Image> old = _lookThumbs;
    setState(() => _lookThumbs = thumbs);
    for (final ui.Image thumb in old) {
      thumb.dispose();
    }
  }

  // --- Geometry ---------------------------------------------------------------

  /// The picture's size once turned, before the crop.
  Size get _frame => _turns.isOdd
      ? Size(_h.toDouble(), _w.toDouble())
      : Size(_w.toDouble(), _h.toDouble());

  Rect get _cropPx => Rect.fromLTRB(
    _crop.left * _frame.width,
    _crop.top * _frame.height,
    _crop.right * _frame.width,
    _crop.bottom * _frame.height,
  );

  /// Maps the picture's own pixels into the turned frame.
  Matrix4 _frameMatrix() {
    final Size frame = _frame;
    final double angle = _straighten * math.pi / 180;
    // Straightening turns the picture inside its frame; it is enlarged by
    // just enough that no empty corner shows.
    final double aspect = math.max(
      frame.width / frame.height,
      frame.height / frame.width,
    );
    final double cover = math.cos(angle.abs()) + math.sin(angle.abs()) * aspect;
    return Matrix4.identity()
      ..translateByDouble(frame.width / 2, frame.height / 2, 0, 1)
      ..rotateZ(_turns * math.pi / 2 + angle)
      ..scaleByDouble(cover, cover, 1, 1)
      ..translateByDouble(-_w / 2, -_h / 2, 0, 1);
  }

  /// Maps the picture's own pixels into the cropped result.
  Matrix4 _outMatrix() {
    final Rect crop = _cropPx;
    return Matrix4.translationValues(-crop.left, -crop.top, 0)
      ..multiply(_frameMatrix());
  }

  bool get _showsWholeFrame => _tool == _Tool.crop;

  Size get _viewSize => _showsWholeFrame ? _frame : _cropPx.size;

  Matrix4 get _viewMatrix => _showsWholeFrame ? _frameMatrix() : _outMatrix();

  /// How the view is fitted into a box of [size]: scale, then offset.
  (double, Offset) _fit(Size size) {
    final Size view = _viewSize;
    const double pad = 16;
    final double scale = math.min(
      (size.width - pad * 2) / view.width,
      (size.height - pad * 2) / view.height,
    );
    return (
      scale,
      Offset(
        (size.width - view.width * scale) / 2,
        (size.height - view.height * scale) / 2,
      ),
    );
  }

  Size _box = Size.zero;

  /// A point of the preview, in view pixels.
  Offset _toView(Offset local) {
    final (double scale, Offset origin) = _fit(_box);
    return (local - origin) / scale;
  }

  /// A point of the preview, in the picture's own pixels.
  Offset _toBase(Offset local) => MatrixUtils.transformPoint(
    Matrix4.inverted(_viewMatrix),
    _toView(local),
  );

  bool get _isPlain =>
      _turns == 0 &&
      _straighten == 0 &&
      _crop == _fullCrop &&
      _mask == _MaskShape.none &&
      _layers.isEmpty &&
      _adjust.isNeutral &&
      _look == 0;

  // --- History ----------------------------------------------------------------

  _Snapshot _snapshot() => _Snapshot(
    pixels: _pixels,
    width: _w,
    height: _h,
    hasAlpha: _hasAlpha,
    adjust: _adjust,
    look: _look,
    turns: _turns,
    straighten: _straighten,
    crop: _crop,
    mask: _mask,
    layers: _layers,
  );

  void _remember() {
    _undo.add(_snapshot());
    if (_undo.length > _maxUndo) _undo.removeAt(0);
    // Most steps share one copy of the pixels; the ones that rework them
    // each keep their own, and a few of those is all a phone can hold.
    while (_undo.map((s) => identityHashCode(s.pixels)).toSet().length >
        _maxCopies) {
      _undo.removeAt(0);
    }
    _redo.clear();
    _dirty = true;
  }

  Future<void> _restore(List<_Snapshot> from, List<_Snapshot> to) async {
    if (from.isEmpty || _busy) return;
    final _Snapshot s = from.removeLast();
    to.add(_snapshot());
    final bool newBase = !identical(s.pixels, _pixels);
    setState(() {
      _adjust = s.adjust;
      _look = s.look;
      _turns = s.turns;
      _straighten = s.straighten;
      _crop = s.crop;
      _mask = s.mask;
      _layers = s.layers;
      _selectedLabel = null;
      if (newBase) _busy = true;
    });
    if (newBase) {
      await _setBase(s.pixels, s.width, s.height, s.hasAlpha);
    } else {
      await _refreshShown();
    }
  }

  // --- Rendering the result ---------------------------------------------------

  void _paintPicture(Canvas canvas, ui.Image image, {required bool cropped}) {
    canvas.save();
    if (cropped && _mask != _MaskShape.none) {
      final Rect out = Offset.zero & _cropPx.size;
      canvas.clipPath(
        Path()..addRRect(
          RRect.fromRectAndRadius(
            out,
            _mask == _MaskShape.ellipse
                ? Radius.elliptical(out.width / 2, out.height / 2)
                : Radius.circular(out.shortestSide * 0.12),
          ),
        ),
      );
    }
    canvas.transform((cropped ? _outMatrix() : _frameMatrix()).storage);
    final double toBase = _w / image.width;
    canvas.save();
    canvas.scale(toBase);
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    for (final _Layer layer in _layers) {
      layer.paint(canvas);
    }
    _drawing?.paint(canvas);
    canvas.restore();
  }

  /// The edited picture at [scale] of its working size, as straight RGBA.
  Future<(Uint8List, int, int)> _render({double scale = 1}) async {
    final Uint8List pixels = _pixels;
    final int w = _w, h = _h;
    final Adjustments adjust = _adjust;
    final PhotoLook look = photoLooks[_look];
    final Uint8List adjusted = adjust.isNeutral && _look == 0
        ? pixels
        : await _Work.apply(pixels, w, h, adjust, look);
    final ui.Image image = await _toImage(adjusted, w, h, _hasAlpha);
    final Size out = _cropPx.size * scale;
    final int ow = math.max(1, out.width.round());
    final int oh = math.max(1, out.height.round());
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.scale(scale);
    _paintPicture(canvas, image, cropped: true);
    final ui.Picture picture = recorder.endRecording();
    final ui.Image result = await picture.toImage(ow, oh);
    final ByteData? data = await result.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    picture.dispose();
    image.dispose();
    result.dispose();
    if (data == null) throw const FormatException('The picture did not render.');
    return (data.buffer.asUint8List(), ow, oh);
  }

  /// Makes the picture as it now looks the new working copy, so that a step
  /// which reworks pixels has a plain rectangle of them to work on.
  Future<void> _flatten() async {
    if (_isPlain) return;
    final (Uint8List px, int w, int h) = await _render();
    final bool alpha = _hasAlpha || _mask != _MaskShape.none;
    _adjust = Adjustments.none;
    _look = 0;
    _turns = 0;
    _straighten = 0;
    _crop = _fullCrop;
    _mask = _MaskShape.none;
    _layers = const [];
    _selectedLabel = null;
    await _setBase(px, w, h, alpha);
  }

  /// Runs a step that replaces the working copy.
  Future<void> _rework(
    String failure,
    Future<(Uint8List, int, int, bool)?> Function() step,
  ) async {
    if (_busy) return;
    _remember();
    setState(() => _busy = true);
    try {
      await _flatten();
      final (Uint8List, int, int, bool)? result = await step();
      if (result != null) {
        await _setBase(result.$1, result.$2, result.$3, result.$4);
      }
    } catch (e) {
      _message('$failure: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- Tools ------------------------------------------------------------------

  void _setAspect(String name) {
    final double? aspect = _aspects[name];
    _remember();
    setState(() {
      _aspect = name;
      if (aspect == null) return;
      // The largest rectangle of that shape, centred in what is selected.
      final Size frame = _frame;
      final Rect now = _cropPx;
      double w = now.width, h = now.width / aspect;
      if (h > now.height) {
        h = now.height;
        w = h * aspect;
      }
      final Rect next = Rect.fromCenter(center: now.center, width: w, height: h);
      _crop = Rect.fromLTRB(
        next.left / frame.width,
        next.top / frame.height,
        next.right / frame.width,
        next.bottom / frame.height,
      );
    });
  }

  void _turn(int quarters) {
    _remember();
    setState(() {
      _turns = ((_turns + quarters) % 4 + 4) % 4;
      // The crop was a rectangle of the old frame; start again from all.
      _crop = _fullCrop;
      _aspect = 'Free';
    });
  }

  Future<void> _flipHorizontally() => _rework('Could not flip', () async {
    return (await _Work.flip(_pixels, _w, _h), _w, _h, _hasAlpha);
  });

  Future<void> _perspective() async {
    if (_busy) return;
    _remember();
    setState(() => _busy = true);
    try {
      await _flatten();
      final Directory scratch = await PdfTools.newOutbox();
      final File source = File('${scratch.path}/perspective.jpg');
      await source.writeAsBytes(
        await _Work.encode(_pixels, _w, _h, false, 95),
        flush: true,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      final ScanQuad? quad = await ScanCropScreen.show(
        context,
        imagePath: source.path,
        initialQuad: ScanQuad.full,
      );
      if (quad == null || !mounted) return;
      setState(() => _busy = true);
      final Uint8List? jpeg = await ScanService.render(
        ScanPage(sourcePath: source.path, quad: quad, filter: ScanFilter.original),
        maxEdge: _workEdge,
      );
      if (jpeg == null) throw const FormatException('could not be straightened');
      final ui.Codec codec = await ui.instantiateImageCodec(jpeg);
      final ui.Image image = (await codec.getNextFrame()).image;
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      final int nw = image.width, nh = image.height;
      image.dispose();
      codec.dispose();
      if (data == null) throw const FormatException('could not be read back');
      await _setBase(data.buffer.asUint8List(), nw, nh, false);
    } catch (e) {
      _message('Could not fix the perspective: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _hide(Rect viewRect) => _rework('Could not hide that', () async {
    // After flattening, the view and the picture are the same rectangle.
    final Uint8List px = Uint8List.fromList(_pixels);
    final int w = _w, h = _h;
    final int l = viewRect.left.floor(), t = viewRect.top.floor();
    final int r = viewRect.right.ceil(), b = viewRect.bottom.ceil();
    final int strength = math.max(6, math.max(w, h) ~/ 60);
    final Uint8List out = await _Work.hide(
      px,
      w,
      h,
      Rect.fromLTRB(l.toDouble(), t.toDouble(), r.toDouble(), b.toDouble()),
      _pixelate,
      strength,
    );
    return (out, w, h, _hasAlpha);
  });

  Future<void> _cutOut() => _rework('Could not cut out the background', () async {
    final Uint8List px = Uint8List.fromList(_pixels);
    final int w = _w, h = _h;
    final (Uint8List, double) result = await _Work.cutOut(px, w, h, _tolerance);
    if (result.$2 < 0.005) {
      _message(
        'No plain background was found around the edges. Try a higher '
        'tolerance.',
      );
      return null;
    }
    if (result.$2 > 0.97) {
      _message('That would remove almost everything. Try a lower tolerance.');
      return null;
    }
    return (result.$1, w, h, true);
  });

  Future<void> _addText() async {
    final TextEditingController controller = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add text'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    _remember();
    final Size view = _viewSize;
    final Offset center = MatrixUtils.transformPoint(
      Matrix4.inverted(_viewMatrix),
      view.center(Offset.zero),
    );
    setState(() {
      _layers = [
        ..._layers,
        _Label(
          text: text.trim(),
          center: center,
          size: math.max(_w, _h) * 0.06,
          color: _color,
          bounds: Size(_w.toDouble(), _h.toDouble()),
        ),
      ];
      _selectedLabel = _layers.length - 1;
    });
  }

  _Label? get _label {
    final int? index = _selectedLabel;
    if (index == null || index >= _layers.length) return null;
    final _Layer layer = _layers[index];
    return layer is _Label ? layer : null;
  }

  void _editLabel(_Label Function(_Label) change, {bool remember = true}) {
    final int? index = _selectedLabel;
    final _Label? label = _label;
    if (index == null || label == null) return;
    if (remember) _remember();
    setState(() {
      _layers = [
        for (int i = 0; i < _layers.length; i++)
          if (i == index) change(label) else _layers[i],
      ];
    });
  }

  // --- Gestures ---------------------------------------------------------------

  void _onPanStart(DragStartDetails details) {
    if (_busy || _shown == null) return;
    final Offset local = details.localPosition;
    switch (_tool) {
      case _Tool.crop:
        final Rect crop = _cropPx;
        final (double scale, Offset _) = _fit(_box);
        final Offset p = _toView(local);
        final List<Offset> corners = [
          crop.topLeft,
          crop.topRight,
          crop.bottomRight,
          crop.bottomLeft,
        ];
        _cropHandle = null;
        double best = 36 / scale;
        for (int i = 0; i < 4; i++) {
          final double d = (corners[i] - p).distance;
          if (d < best) {
            best = d;
            _cropHandle = i;
          }
        }
        // Anywhere else inside it moves the whole rectangle.
        if (_cropHandle == null && crop.contains(p)) _cropHandle = 4;
        if (_cropHandle != null) _remember();
        _dragLast = p;
      case _Tool.draw:
        _remember();
        setState(() {
          _drawing = _Stroke(
            _pen,
            [_toBase(local)],
            _color,
            math.max(_w, _h) * _penSize,
          );
        });
      case _Tool.text:
        // Pick up the label under the finger, the topmost first.
        final Offset p = _toBase(local);
        int? hit;
        for (int i = _layers.length - 1; i >= 0; i--) {
          final _Layer layer = _layers[i];
          if (layer is _Label &&
              !layer.tiled &&
              layer.rect.inflate(layer.size * 0.4).contains(p)) {
            hit = i;
            break;
          }
        }
        if (hit != null) _remember();
        setState(() => _selectedLabel = hit ?? _selectedLabel);
        _dragLast = hit == null ? null : p;
      case _Tool.hide:
        final Offset p = _toView(local);
        setState(() => _hiding = Rect.fromPoints(p, p));
        _dragLast = p;
      case _Tool.adjust || _Tool.looks || _Tool.cutout:
        break;
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final Offset local = details.localPosition;
    switch (_tool) {
      case _Tool.crop:
        final int? handle = _cropHandle;
        final Offset? last = _dragLast;
        if (handle == null || last == null) return;
        final Offset p = _toView(local);
        _dragCrop(handle, p, p - last);
        _dragLast = p;
      case _Tool.draw:
        final _Stroke? stroke = _drawing;
        if (stroke == null) return;
        final Offset p = _toBase(local);
        setState(() {
          _drawing = _Stroke(
            stroke.kind,
            stroke.kind == _Pen.pen || stroke.kind == _Pen.marker
                ? [...stroke.points, p]
                : [stroke.points.first, p],
            stroke.color,
            stroke.width,
          );
        });
      case _Tool.text:
        final Offset? last = _dragLast;
        if (last == null) return;
        final Offset p = _toBase(local);
        _editLabel((l) => l.copyWith(center: l.center + (p - last)), remember: false);
        _dragLast = p;
      case _Tool.hide:
        final Rect? hiding = _hiding;
        final Offset? start = _dragLast;
        if (hiding == null || start == null) return;
        setState(() => _hiding = Rect.fromPoints(start, _toView(local)));
      case _Tool.adjust || _Tool.looks || _Tool.cutout:
        break;
    }
  }

  void _onPanEnd(DragEndDetails details) {
    switch (_tool) {
      case _Tool.draw:
        final _Stroke? stroke = _drawing;
        if (stroke == null) return;
        setState(() {
          _layers = [..._layers, stroke];
          _drawing = null;
        });
      case _Tool.hide:
        final Rect? hiding = _hiding;
        setState(() => _hiding = null);
        if (hiding == null) return;
        final Rect inside = hiding.intersect(Offset.zero & _viewSize);
        if (inside.width < 8 || inside.height < 8) return;
        // The view is the cropped result; flattening makes that the picture.
        _hide(inside);
      case _Tool.crop || _Tool.text:
        _cropHandle = null;
        _dragLast = null;
      case _Tool.adjust || _Tool.looks || _Tool.cutout:
        break;
    }
  }

  void _dragCrop(int handle, Offset p, Offset delta) {
    final Size frame = _frame;
    final double? aspect = _aspects[_aspect];
    Rect crop = _cropPx;
    const double minSide = 48;
    if (handle == 4) {
      final Offset shift = Offset(
        delta.dx.clamp(-crop.left, frame.width - crop.right),
        delta.dy.clamp(-crop.top, frame.height - crop.bottom),
      );
      crop = crop.shift(shift);
    } else {
      // The corner opposite the one being dragged stays where it is.
      final Offset anchor = [
        crop.bottomRight,
        crop.bottomLeft,
        crop.topLeft,
        crop.topRight,
      ][handle];
      final Offset corner = Offset(
        p.dx.clamp(0.0, frame.width),
        p.dy.clamp(0.0, frame.height),
      );
      double w = math.max(minSide, (corner.dx - anchor.dx).abs());
      double h = math.max(minSide, (corner.dy - anchor.dy).abs());
      if (aspect != null) {
        if (w / h > aspect) {
          w = h * aspect;
        } else {
          h = w / aspect;
        }
      }
      final double signX = handle == 0 || handle == 3 ? -1 : 1;
      final double signY = handle == 0 || handle == 1 ? -1 : 1;
      crop = Rect.fromPoints(
        anchor,
        anchor + Offset(w * signX, h * signY),
      ).intersect(Offset.zero & frame);
    }
    setState(() {
      _crop = Rect.fromLTRB(
        crop.left / frame.width,
        crop.top / frame.height,
        crop.right / frame.width,
        crop.bottom / frame.height,
      );
    });
  }

  // --- Saving -----------------------------------------------------------------

  Future<void> _export() async {
    final bool transparent = _hasAlpha || _mask != _MaskShape.none;
    final Size out = _cropPx.size;
    final _ExportChoice? choice = await showModalBottomSheet<_ExportChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ExportSheet(size: out, transparent: transparent),
    );
    if (choice == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final (Uint8List px, int w, int h) = await _render(scale: choice.scale);
      final bool png = choice.png;
      final Uint8List bytes = await _Work.encode(px, w, h, png, choice.quality);
      final Directory outbox = await PdfTools.newOutbox();
      final String base = PdfTools.safeFileName(
        '${PdfTools.baseNameOf(widget.name)}_edited',
      );
      final File file = File('${outbox.path}/$base.${png ? 'png' : 'jpg'}');
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return;
      setState(() => _busy = false);
      await ExportSheet.show(
        context,
        files: [file],
        mimeType: png ? 'image/png' : 'image/jpeg',
        title: 'Picture ready',
        note: _exif.isEmpty
            ? null
            : 'The copy carries no camera or location data.',
      );
      _dirty = false;
    } catch (e) {
      _message('Could not save the picture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showInfo() {
    final ThemeData theme = Theme.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            children: [
              Text(
                widget.name,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              _infoRow(theme, 'Working size', '$_w × $_h px'),
              for (final (String label, String value) in _exif)
                _infoRow(theme, label, value),
              const SizedBox(height: 12),
              Text(
                _exif.isEmpty
                    ? 'This picture carries no camera data.'
                    : ImageEngine.hasLocation(_exif)
                    ? 'This picture says where it was taken. A copy saved '
                          'from here leaves that, and the rest of the camera '
                          'data, out.'
                    : 'A copy saved from here leaves the camera data out.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(ThemeData theme, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
      ],
    ),
  );

  Future<void> _onBack() async {
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final bool? leave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard your edits?'),
        content: const Text('The edited picture has not been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.of(context).pop();
  }

  // --- Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ui.Image? shown = _shown;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: false,
          titleSpacing: 0,
          title: Text(
            widget.name,
            style: const TextStyle(fontSize: 18),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.undo_rounded),
              tooltip: 'Undo',
              onPressed: _busy || _undo.isEmpty
                  ? null
                  : () => _restore(_undo, _redo),
            ),
            IconButton(
              icon: const Icon(Icons.redo_rounded),
              tooltip: 'Redo',
              onPressed: _busy || _redo.isEmpty
                  ? null
                  : () => _restore(_redo, _undo),
            ),
            IconButton(
              icon: const Icon(Icons.info_outline_rounded),
              tooltip: 'Picture details',
              onPressed: shown == null ? null : _showInfo,
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 12),
              child: FilledButton(
                onPressed: _busy || shown == null ? null : _export,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
        body: _error != null
            ? Center(child: Text(_error!))
            : Column(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              _box = constraints.biggest;
                              if (shown == null) return const SizedBox.shrink();
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanStart: _onPanStart,
                                onPanUpdate: _onPanUpdate,
                                onPanEnd: _onPanEnd,
                                child: CustomPaint(
                                  size: Size.infinite,
                                  painter: _PreviewPainter(this, shown),
                                ),
                              );
                            },
                          ),
                        ),
                        if (_busy)
                          const Positioned.fill(
                            child: ColoredBox(
                              color: Colors.black38,
                              child: Center(child: CircularProgressIndicator()),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (shown != null) ...[
                    Material(
                      color: theme.colorScheme.surfaceContainerHigh,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                        child: _buildPanel(theme),
                      ),
                    ),
                    _buildToolBar(theme),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildToolBar(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              for (final _Tool tool in _Tool.values)
                InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: _busy
                      ? null
                      : () => setState(() {
                          _tool = tool;
                          _hiding = null;
                        }),
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 70),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: tool == _tool
                          ? theme.colorScheme.secondaryContainer
                          : null,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(tool.icon, size: 24),
                        const SizedBox(height: 4),
                        Text(tool.label, style: theme.textTheme.labelSmall),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _colorRow(Color selected, ValueChanged<Color> onPick) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final Color color in _colors)
        Semantics(
          button: true,
          selected: color == selected,
          label: 'Colour',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () => onPick(color),
            child: Container(
              margin: const EdgeInsets.all(4),
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: color == selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline,
                  width: color == selected ? 3 : 1,
                ),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _buildPanel(ThemeData theme) {
    switch (_tool) {
      case _Tool.crop:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final String name in _aspects.keys)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(name),
                        selected: _aspect == name,
                        showCheckmark: false,
                        onSelected: (_) => _setAspect(name),
                      ),
                    ),
                ],
              ),
            ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.rotate_left_rounded),
                  tooltip: 'Turn left',
                  onPressed: () => _turn(-1),
                ),
                IconButton(
                  icon: const Icon(Icons.rotate_right_rounded),
                  tooltip: 'Turn right',
                  onPressed: () => _turn(1),
                ),
                IconButton(
                  icon: const Icon(Icons.flip_rounded),
                  tooltip: 'Flip',
                  onPressed: _flipHorizontally,
                ),
                IconButton(
                  icon: const Icon(Icons.filter_tilt_shift_rounded),
                  tooltip: 'Fix perspective',
                  onPressed: _perspective,
                ),
                PopupMenuButton<_MaskShape>(
                  tooltip: 'Shape',
                  icon: const Icon(Icons.rounded_corner_rounded),
                  onSelected: (mask) {
                    _remember();
                    setState(() => _mask = mask);
                  },
                  itemBuilder: (_) => [
                    for (final _MaskShape mask in _MaskShape.values)
                      CheckedPopupMenuItem(
                        value: mask,
                        checked: mask == _mask,
                        child: Text(mask.label),
                      ),
                  ],
                ),
                Expanded(
                  child: Slider(
                    value: _straighten,
                    min: -30,
                    max: 30,
                    label: '${_straighten.round()}°',
                    divisions: 60,
                    onChangeStart: (_) => _remember(),
                    onChanged: (v) => setState(() => _straighten = v),
                  ),
                ),
              ],
            ),
          ],
        );
      case _Tool.adjust:
        final double value = _adjust[_kind];
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final AdjustKind kind in AdjustKind.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        // A dot marks the ones that have been moved.
                        avatar: _adjust[kind] == 0
                            ? null
                            : Icon(
                                Icons.circle,
                                size: 8,
                                color: theme.colorScheme.primary,
                              ),
                        label: Text(kind.label),
                        selected: _kind == kind,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _kind = kind),
                      ),
                    ),
                ],
              ),
            ),
            Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    '${(value * 100).round()}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: value,
                    min: _kind.oneSided ? 0 : -1,
                    max: 1,
                    onChangeStart: (_) => _remember(),
                    onChanged: (v) {
                      setState(() => _adjust = _adjust.withValue(_kind, v));
                      _refreshShown();
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.restart_alt_rounded),
                  tooltip: 'Reset ${_kind.label.toLowerCase()}',
                  onPressed: value == 0
                      ? null
                      : () {
                          _remember();
                          setState(
                            () => _adjust = _adjust.withValue(_kind, 0),
                          );
                          _refreshShown();
                        },
                ),
              ],
            ),
          ],
        );
      case _Tool.looks:
        return SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: photoLooks.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final bool selected = index == _look;
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  if (selected) return;
                  _remember();
                  setState(() => _look = index);
                  _refreshShown();
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          width: selected ? 3 : 1,
                        ),
                      ),
                      child: index < _lookThumbs.length
                          ? RawImage(
                              image: _lookThumbs[index],
                              fit: BoxFit.cover,
                            )
                          : null,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      photoLooks[index].name,
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              );
            },
          ),
        );
      case _Tool.draw:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final _Pen pen in _Pen.values)
                    IconButton(
                      icon: Icon(pen.icon),
                      tooltip: pen.label,
                      isSelected: pen == _pen,
                      style: IconButton.styleFrom(
                        backgroundColor: pen == _pen
                            ? theme.colorScheme.secondaryContainer
                            : null,
                      ),
                      onPressed: () => setState(() => _pen = pen),
                    ),
                  const SizedBox(width: 8),
                  _colorRow(_color, (c) => setState(() => _color = c)),
                ],
              ),
            ),
            Row(
              children: [
                const Text('Size'),
                Expanded(
                  child: Slider(
                    value: _penSize,
                    min: 0.002,
                    max: 0.03,
                    onChanged: (v) => setState(() => _penSize = v),
                  ),
                ),
              ],
            ),
          ],
        );
      case _Tool.text:
        final _Label? label = _label;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  FilledButton.tonalIcon(
                    onPressed: _addText,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add text'),
                  ),
                  const SizedBox(width: 8),
                  _colorRow(label?.color ?? _color, (c) {
                    setState(() => _color = c);
                    _editLabel((l) => l.copyWith(color: c));
                  }),
                  if (label != null) ...[
                    FilterChip(
                      label: const Text('Repeat'),
                      tooltip: 'Repeat across the picture, as a watermark',
                      selected: label.tiled,
                      onSelected: (on) => _editLabel(
                        (l) => l.copyWith(
                          tiled: on,
                          // A watermark is small and faint by nature.
                          size: on ? math.max(_w, _h) * 0.03 : l.size,
                          opacity: on ? 0.3 : 1,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded),
                      tooltip: 'Remove this text',
                      onPressed: () {
                        final int? index = _selectedLabel;
                        if (index == null) return;
                        _remember();
                        setState(() {
                          _layers = [
                            for (int i = 0; i < _layers.length; i++)
                              if (i != index) _layers[i],
                          ];
                          _selectedLabel = null;
                        });
                      },
                    ),
                  ],
                ],
              ),
            ),
            if (label != null)
              Row(
                children: [
                  const Text('Size'),
                  Expanded(
                    child: Slider(
                      value: (label.size / math.max(_w, _h)).clamp(0.01, 0.25),
                      min: 0.01,
                      max: 0.25,
                      onChangeStart: (_) => _remember(),
                      onChanged: (v) => _editLabel(
                        (l) => l.copyWith(size: v * math.max(_w, _h)),
                        remember: false,
                      ),
                    ),
                  ),
                  const Text('Opacity'),
                  Expanded(
                    child: Slider(
                      value: label.opacity,
                      min: 0.1,
                      max: 1,
                      onChangeStart: (_) => _remember(),
                      onChanged: (v) => _editLabel(
                        (l) => l.copyWith(opacity: v),
                        remember: false,
                      ),
                    ),
                  ),
                ],
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Drag a text to move it.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        );
      case _Tool.hide:
        return Row(
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Blur')),
                ButtonSegment(value: true, label: Text('Pixelate')),
              ],
              selected: {_pixelate},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _pixelate = s.single),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Drag over what should not be readable.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        );
      case _Tool.cutout:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Tolerance'),
                Expanded(
                  child: Slider(
                    value: _tolerance,
                    min: 0.05,
                    max: 0.8,
                    onChanged: (v) => setState(() => _tolerance = v),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: _busy ? null : _cutOut,
                  child: const Text('Remove'),
                ),
              ],
            ),
            Text(
              'Clears a plain background reaching in from the edges. It goes '
              'by colour, so it suits an object on a backdrop, not a person '
              'in a room.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        );
    }
  }
}

/// The pixel work, each piece run in its own isolate.
///
/// Kept out of the screen's state on purpose: a closure made inside one of
/// its methods carries the state along with it, and the state cannot cross
/// into an isolate.
class _Work {
  static Future<Uint8List> downscale(
    Uint8List px,
    int w,
    int h,
    int outW,
    int outH,
  ) => Isolate.run(() => ImageEngine.downscale(px, w, h, outW, outH));

  static Future<Uint8List> apply(
    Uint8List px,
    int w,
    int h,
    Adjustments adjust,
    PhotoLook look,
  ) => Isolate.run(() => ImageEngine.apply(px, w, h, adjust, filter: look));

  /// Every look applied to a thumbnail of [px].
  static Future<List<Uint8List>> looks(
    Uint8List px,
    int w,
    int h,
    int outW,
    int outH,
  ) => Isolate.run(() {
    final Uint8List tiny = ImageEngine.downscale(px, w, h, outW, outH);
    return [
      for (final PhotoLook look in photoLooks)
        ImageEngine.apply(tiny, outW, outH, Adjustments.none, filter: look),
    ];
  });

  static Future<Uint8List> flip(Uint8List px, int w, int h) => Isolate.run(() {
    final Uint8List out = Uint8List(px.length);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int from = (y * w + x) * 4, to = (y * w + (w - 1 - x)) * 4;
        out[to] = px[from];
        out[to + 1] = px[from + 1];
        out[to + 2] = px[from + 2];
        out[to + 3] = px[from + 3];
      }
    }
    return out;
  });

  static Future<Uint8List> encode(
    Uint8List px,
    int w,
    int h,
    bool png,
    int quality,
  ) => Isolate.run(
    () => ImageEngine.encode(px, w, h, png: png, quality: quality),
  );

  static Future<Uint8List> hide(
    Uint8List px,
    int w,
    int h,
    Rect area,
    bool pixelate,
    int strength,
  ) {
    final int l = area.left.round(), t = area.top.round();
    final int r = area.right.round(), b = area.bottom.round();
    return Isolate.run(() {
      if (pixelate) {
        ImageEngine.pixelate(px, w, h, l, t, r, b, strength);
      } else {
        ImageEngine.blur(px, w, h, l, t, r, b, strength);
      }
      return px;
    });
  }

  static Future<(Uint8List, double)> cutOut(
    Uint8List px,
    int w,
    int h,
    double tolerance,
  ) => Isolate.run(() {
    final double removed = ImageEngine.removeBackground(
      px,
      w,
      h,
      tolerance: tolerance,
    );
    return (px, removed);
  });
}

/// Draws the picture as edited so far, and whatever the tool in hand lays
/// over it.
class _PreviewPainter extends CustomPainter {
  final _ImageEditorScreenState state;
  final ui.Image image;

  _PreviewPainter(this.state, this.image);

  @override
  void paint(Canvas canvas, Size size) {
    final (double scale, Offset origin) = state._fit(size);
    final Size view = state._viewSize;
    final bool whole = state._showsWholeFrame;
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale);

    if (state._hasAlpha || state._mask != _MaskShape.none) {
      _checker(canvas, Offset.zero & view, 14 / scale);
    }
    canvas.save();
    canvas.clipRect(Offset.zero & view);
    state._paintPicture(canvas, image, cropped: !whole);
    canvas.restore();

    if (whole) _paintCrop(canvas, view, scale);

    final Rect? hiding = state._hiding;
    if (hiding != null) {
      canvas.drawRect(hiding, Paint()..color = const Color(0x55000000));
      canvas.drawRect(
        hiding,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / scale
          ..color = const Color(0xFFFFFFFF),
      );
    }

    final _Label? label = state._tool == _Tool.text ? state._label : null;
    if (label != null && !label.tiled) {
      // The selected text, outlined where it sits in the view.
      final Matrix4 m = state._viewMatrix;
      final Rect r = label.rect.inflate(label.size * 0.15);
      final Path outline = Path()
        ..addPolygon([
          MatrixUtils.transformPoint(m, r.topLeft),
          MatrixUtils.transformPoint(m, r.topRight),
          MatrixUtils.transformPoint(m, r.bottomRight),
          MatrixUtils.transformPoint(m, r.bottomLeft),
        ], true);
      canvas.drawPath(
        outline,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 / scale
          ..color = const Color(0xFFFFFFFF),
      );
    }
    canvas.restore();
  }

  void _paintCrop(Canvas canvas, Size frame, double scale) {
    final Rect crop = state._cropPx;
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & frame),
        Path()..addRect(crop),
      ),
      Paint()..color = const Color(0x99000000),
    );
    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 / scale
      ..color = const Color(0xFFFFFFFF);
    canvas.drawRect(crop, line);
    // Thirds, to compose by.
    final Paint third = Paint()
      ..strokeWidth = 0.8 / scale
      ..color = const Color(0x88FFFFFF);
    for (int i = 1; i < 3; i++) {
      final double x = crop.left + crop.width * i / 3;
      final double y = crop.top + crop.height * i / 3;
      canvas.drawLine(Offset(x, crop.top), Offset(x, crop.bottom), third);
      canvas.drawLine(Offset(crop.left, y), Offset(crop.right, y), third);
    }
    final Paint handle = Paint()..color = const Color(0xFFFFFFFF);
    for (final Offset corner in [
      crop.topLeft,
      crop.topRight,
      crop.bottomRight,
      crop.bottomLeft,
    ]) {
      canvas.drawCircle(corner, 9 / scale, handle);
    }
  }

  static void _checker(Canvas canvas, Rect area, double cell) {
    canvas.save();
    canvas.clipRect(area);
    canvas.drawRect(area, Paint()..color = const Color(0xFFFFFFFF));
    final Paint dark = Paint()..color = const Color(0xFFD0D0D0);
    int row = 0;
    for (double y = area.top; y < area.bottom; y += cell, row++) {
      for (double x = area.left + (row.isOdd ? cell : 0);
          x < area.right;
          x += cell * 2) {
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), dark);
      }
    }
    canvas.restore();
  }

  // Everything it draws lives in the state, which rebuilds it on change.
  @override
  bool shouldRepaint(covariant _PreviewPainter old) => true;
}

class _ExportChoice {
  final bool png;
  final int quality;
  final double scale;
  const _ExportChoice(this.png, this.quality, this.scale);
}

/// Format, quality and size of the copy to save.
class _ExportSheet extends StatefulWidget {
  final Size size;
  final bool transparent;
  const _ExportSheet({required this.size, required this.transparent});

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  late bool _png = widget.transparent;
  double _quality = 90;
  double _scale = 1;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int w = (widget.size.width * _scale).round();
    final int h = (widget.size.height * _scale).round();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Save a copy',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('JPEG')),
                ButtonSegment(value: true, label: Text('PNG')),
              ],
              selected: {_png},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _png = s.single),
            ),
            const SizedBox(height: 8),
            Text(
              _png
                  ? 'Lossless, and keeps transparency. Larger files.'
                  : widget.transparent
                  ? 'Smaller files. Transparent parts become white.'
                  : 'Smaller files, right for photographs.',
              style: theme.textTheme.bodySmall,
            ),
            if (!_png) ...[
              const SizedBox(height: 12),
              Text('Quality ${_quality.round()}'),
              Slider(
                value: _quality,
                min: 40,
                max: 100,
                divisions: 12,
                onChanged: (v) => setState(() => _quality = v),
              ),
            ],
            const SizedBox(height: 12),
            Text('Size  $w × $h px'),
            Slider(
              value: _scale,
              min: 0.1,
              max: 1,
              divisions: 18,
              onChanged: (v) => setState(() => _scale = v),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => Navigator.of(
                context,
              ).pop(_ExportChoice(_png, _quality.round(), _scale)),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
