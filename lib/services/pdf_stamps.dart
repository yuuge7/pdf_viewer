import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Color, Offset, Rect, Size;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'flow_renderer.dart';
import 'pdf_service.dart';

/// Where on the page a page number sits.
enum StampPosition {
  topLeft('Top left'),
  topCenter('Top centre'),
  topRight('Top right'),
  bottomLeft('Bottom left'),
  bottomCenter('Bottom centre'),
  bottomRight('Bottom right');

  final String label;
  const StampPosition(this.label);

  bool get isTop => index < 3;

  /// 0 left, 1 centre, 2 right.
  int get column => index % 3;
}

enum PageNumberStyle {
  number('1'),
  numberOfTotal('1 / 12'),
  page('Page 1'),
  pageOfTotal('Page 1 of 12');

  final String sample;
  const PageNumberStyle(this.sample);

  String format(int number, int total) => switch (this) {
    PageNumberStyle.number => '$number',
    PageNumberStyle.numberOfTotal => '$number / $total',
    PageNumberStyle.page => 'Page $number',
    PageNumberStyle.pageOfTotal => 'Page $number of $total',
  };
}

@immutable
class WatermarkOptions {
  final String text;

  /// Points. Zero sizes the text to span the page.
  final double fontSize;
  final Color color;

  /// 0..1.
  final double opacity;

  /// Degrees, anticlockwise as read: 45 runs bottom-left to top-right.
  final double angle;

  /// Repeats the text across the page instead of centring it once.
  final bool tiled;

  /// 0-based pages to mark; null marks every page.
  final List<int>? pages;

  const WatermarkOptions({
    required this.text,
    this.fontSize = 0,
    this.color = const Color(0xFF808080),
    this.opacity = 0.3,
    this.angle = 45,
    this.tiled = false,
    this.pages,
  });
}

@immutable
class PageNumberOptions {
  final PageNumberStyle style;
  final StampPosition position;
  final double fontSize;

  /// Distance from the page edges, in points.
  final double margin;

  /// The number the first numbered page gets.
  final int startAt;
  final Color color;

  /// 0-based pages to number, in order; null numbers every page.
  final List<int>? pages;

  const PageNumberOptions({
    this.style = PageNumberStyle.number,
    this.position = StampPosition.bottomCenter,
    this.fontSize = 11,
    this.margin = 28,
    this.startAt = 1,
    this.color = const Color(0xFF000000),
    this.pages,
  });
}

/// How a document answers being opened.
enum PdfLock {
  /// Opens with no password.
  open,

  /// Needs a password, and none (or the wrong one) was given.
  locked,

  /// Not a PDF Syncfusion can read at all.
  unreadable,
}

/// One line of recognised text, placed where it was seen on the page.
@immutable
class TextLayerLine {
  final String text;

  /// In displayed page space, in points.
  final Rect bounds;

  const TextLayerLine(this.text, this.bounds);
}

/// Document-wide finishing touches: watermark, page numbers, flattening,
/// passwords, and the invisible text behind a scanned page.
///
/// Bytes in, bytes out, all inside [Isolate.run]; `test/pdf_stamps_test.dart`
/// covers them without platform channels.
class PdfStamps {
  /// The size a recognised line is set in: [wanted], on a grid that gets
  /// coarser as it grows. A font object is embedded per size used, so a
  /// page of slightly different line heights must not ask for a hundred.
  static double _layerSize(double wanted) {
    final double size = wanted.clamp(4.0, 96.0);
    final double step = size < 12
        ? 0.5
        : size < 24
        ? 1
        : 2;
    return (size / step).floorToDouble() * step;
  }

  static int _channel(double value) => (value * 255.0).round().clamp(0, 255);

  static PdfColor _pdfColor(int argb) =>
      PdfColor((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);

  static int _argb(Color color) =>
      0xFF000000 |
      (_channel(color.r) << 16) |
      (_channel(color.g) << 8) |
      _channel(color.b);

  /// Maps displayed coordinates onto the page's own, so that what is drawn
  /// next reads upright on a `/Rotate`d page. Returns the displayed size.
  ///
  /// The caller owns the `save`/`restore` around it.
  static Size _enterDisplaySpace(PdfGraphics graphics, PdfPage page) {
    final Size own = page.size;
    switch (page.rotation.index) {
      case 1:
        graphics.translateTransform(0, own.height);
        graphics.rotateTransform(-90);
        return own.flipped;
      case 2:
        graphics.translateTransform(own.width, own.height);
        graphics.rotateTransform(180);
        return own;
      case 3:
        graphics.translateTransform(own.width, 0);
        graphics.rotateTransform(90);
        return own.flipped;
      default:
        return own;
    }
  }

  static List<int> _pagesOf(PdfDocument document, List<int>? pages) {
    final int count = document.pages.count;
    if (pages == null) return [for (int i = 0; i < count; i++) i];
    for (final int index in pages) {
      if (index < 0 || index >= count) {
        throw PdfEditException(
          'Page ${index + 1} is outside this document ($count page(s)).',
        );
      }
    }
    return pages;
  }

  /// Writes [options] `.text` across the chosen pages, set in [font] (a
  /// TrueType file) so letters outside Western Europe survive.
  static Future<Uint8List> renderWatermark(
    Uint8List bytes,
    WatermarkOptions options,
    Uint8List font,
  ) {
    final int color = _argb(options.color);
    final String raw = options.text.trim();
    final double opacity = options.opacity.clamp(0.02, 1.0);
    final double angle = options.angle;
    final double fixedSize = options.fontSize;
    final bool tiled = options.tiled;
    final List<int>? pages = options.pages;

    return Isolate.run(() async {
      if (raw.isEmpty) {
        throw const PdfEditException('Enter the watermark text.');
      }
      final FlowFace face = FlowFace(font, const []);
      final String text = face.drawable(raw);
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        final PdfBrush brush = PdfSolidBrush(_pdfColor(color));
        for (final int index in _pagesOf(document, pages)) {
          final PdfPage page = document.pages[index];
          final PdfGraphics graphics = page.graphics;
          graphics.save();
          final Size display = _enterDisplaySpace(graphics, page);
          graphics.setTransparency(opacity);

          double size = fixedSize;
          if (size <= 0) {
            // As large as fits along the direction it runs in.
            final double radians = angle * math.pi / 180;
            final double run = math.min(
              display.width / math.max(0.2, math.cos(radians).abs()),
              display.height / math.max(0.2, math.sin(radians).abs()),
            );
            final double unit = face.measure(text, 100) / 100;
            size = unit <= 0 ? 48 : (run * (tiled ? 0.28 : 0.72) / unit);
            size = size.clamp(8.0, 220.0);
          }
          final double width = face.measure(text, size);
          final double height = size * (face.ascent + face.descent);
          final PdfFont pdfFont = face.at(size);

          void drawAt(Offset centre) {
            graphics.save();
            graphics.translateTransform(centre.dx, centre.dy);
            // Clockwise in y-down space, hence the sign.
            graphics.rotateTransform(-angle);
            graphics.drawString(
              text,
              pdfFont,
              brush: brush,
              bounds: Rect.fromLTWH(-width / 2, -height / 2, 0, 0),
            );
            graphics.restore();
          }

          if (!tiled) {
            drawAt(display.center(Offset.zero));
          } else {
            final double stepX = width + size * 2;
            final double stepY = math.max(height * 4, size * 5);
            int row = 0;
            for (double y = stepY / 2; y < display.height + stepY; y += stepY) {
              final double shift = row.isOdd ? stepX / 2 : 0;
              for (
                double x = -stepX / 2 + shift;
                x < display.width + stepX;
                x += stepX
              ) {
                drawAt(Offset(x, y));
              }
              row++;
            }
          }
          graphics.restore();
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Numbers the chosen pages in the order given.
  static Future<Uint8List> renderPageNumbers(
    Uint8List bytes,
    PageNumberOptions options,
    Uint8List font,
  ) {
    final int color = _argb(options.color);
    final PageNumberStyle style = options.style;
    final StampPosition position = options.position;
    final double size = options.fontSize.clamp(5.0, 72.0);
    final double margin = math.max(0, options.margin);
    final int startAt = options.startAt;
    final List<int>? pages = options.pages;

    return Isolate.run(() async {
      final FlowFace face = FlowFace(font, const []);
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        final List<int> targets = _pagesOf(document, pages);
        final int total = startAt + targets.length - 1;
        final PdfBrush brush = PdfSolidBrush(_pdfColor(color));
        final PdfFont pdfFont = face.at(size);
        final double height = size * (face.ascent + face.descent);
        for (int n = 0; n < targets.length; n++) {
          final PdfPage page = document.pages[targets[n]];
          final PdfGraphics graphics = page.graphics;
          final String label = style.format(startAt + n, total);
          final double width = face.measure(label, size);
          graphics.save();
          final Size display = _enterDisplaySpace(graphics, page);
          final double x = switch (position.column) {
            0 => margin,
            1 => (display.width - width) / 2,
            _ => display.width - margin - width,
          };
          final double y = position.isTop
              ? margin
              : display.height - margin - height;
          graphics.drawString(
            label,
            pdfFont,
            brush: brush,
            bounds: Rect.fromLTWH(x, y, 0, 0),
          );
          graphics.restore();
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Burns annotations and form fields into the pages, so they look the
  /// same everywhere and can no longer be changed.
  static Future<Uint8List> renderFlatten(Uint8List bytes) {
    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        for (int i = 0; i < document.pages.count; i++) {
          final PdfAnnotationCollection annotations =
              document.pages[i].annotations;
          if (annotations.count > 0) annotations.flattenAllAnnotations();
        }
        if (hasFormFields(document)) document.form.flattenAllFields();
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Whether [document] has anything to fill in.
  static bool hasFormFields(PdfDocument document) {
    try {
      return document.form.fields.count > 0;
    } catch (_) {
      return false;
    }
  }

  /// What can be flattened: annotations and form fields, counted.
  static Future<(int annotations, int fields)> countInteractive(
    Uint8List bytes,
  ) {
    return Isolate.run(() {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        int annotations = 0;
        for (int i = 0; i < document.pages.count; i++) {
          annotations += document.pages[i].annotations.count;
        }
        final int fields = hasFormFields(document)
            ? document.form.fields.count
            : 0;
        return (annotations, fields);
      } finally {
        document.dispose();
      }
    });
  }

  /// Encrypts the document (AES-256) so it asks for [password] to open.
  static Future<Uint8List> renderProtect(Uint8List bytes, String password) {
    return Isolate.run(() async {
      if (password.isEmpty) {
        throw const PdfEditException('Enter a password.');
      }
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        // Encryption rewrites every stream; an incremental save would leave
        // the unencrypted original in front of it.
        document.fileStructure.incrementalUpdate = false;
        final PdfSecurity security = document.security;
        security.algorithm = PdfEncryptionAlgorithm.aesx256Bit;
        security.userPassword = password;
        security.ownerPassword = password;
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Rewrites a protected document without its password.
  ///
  /// Throws a [PdfEditException] when [password] does not open it.
  static Future<Uint8List> renderUnlock(Uint8List bytes, String password) {
    return Isolate.run(() async {
      final PdfDocument document;
      try {
        document = PdfDocument(inputBytes: bytes, password: password);
      } catch (_) {
        throw const PdfEditException('That password does not open this PDF.');
      }
      try {
        document.fileStructure.incrementalUpdate = false;
        document.security.userPassword = '';
        document.security.ownerPassword = '';
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Whether [bytes] opens, with [password] if one is given.
  static Future<PdfLock> probe(Uint8List bytes, {String? password}) {
    return Isolate.run(() {
      try {
        final PdfDocument document = PdfDocument(
          inputBytes: bytes,
          password: password,
        );
        try {
          // Forces the page tree to be read, which is where a wrong key
          // shows on files whose header parsed.
          document.pages.count;
        } finally {
          document.dispose();
        }
        return PdfLock.open;
      } catch (e) {
        final String message = e.toString().toLowerCase();
        return message.contains('password') || message.contains('encrypt')
            ? PdfLock.locked
            : PdfLock.unreadable;
      }
    });
  }

  /// A new document of [count] empty pages of [size] points.
  static Future<Uint8List> renderBlank(Size size, int count) {
    return Isolate.run(() async {
      final PdfDocument document = PdfDocument();
      try {
        for (int i = 0; i < math.max(1, count); i++) {
          // One section per page, orientation before size: page settings on
          // the document itself are frozen and re-sorted to its orientation.
          final PdfSection section = document.sections!.add();
          section.pageSettings.margins.all = 0;
          section.pageSettings.orientation = size.width > size.height
              ? PdfPageOrientation.landscape
              : PdfPageOrientation.portrait;
          section.pageSettings.size = size;
          section.pages.add();
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Lays recognised text invisibly over the pages it was read from, which
  /// is what makes a scan searchable and selectable.
  ///
  /// [lines] is keyed by 0-based page index. Each line is set at the
  /// listed size that best spans its box, so a selection sits on the words
  /// it stands for.
  static Future<Uint8List> renderTextLayer(
    Uint8List bytes,
    Map<int, List<TextLayerLine>> lines,
    Uint8List font,
  ) {
    return Isolate.run(() async {
      final FlowFace face = FlowFace(font, const []);
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        final PdfBrush brush = PdfSolidBrush(PdfColor(0, 0, 0));
        final int count = document.pages.count;
        for (final MapEntry<int, List<TextLayerLine>> entry in lines.entries) {
          if (entry.key < 0 || entry.key >= count || entry.value.isEmpty) {
            continue;
          }
          final PdfPage page = document.pages[entry.key];
          final PdfGraphics graphics = page.graphics;
          graphics.save();
          _enterDisplaySpace(graphics, page);
          graphics.setTransparency(0);
          for (final TextLayerLine line in entry.value) {
            final String text = face.drawable(line.text).trim();
            if (text.isEmpty || line.bounds.width <= 0) continue;
            // Sized to span the box, but never much taller than it: a short
            // word in a wide box is a misread box, not giant text. Spacing
            // the letters or the words out to fit instead would be exact,
            // but Syncfusion then writes each piece separately and the
            // spaces between them are gone from search and copy.
            final double byWidth =
                10 * line.bounds.width / math.max(1, face.measure(text, 10));
            final double byHeight =
                line.bounds.height / (face.ascent + face.descent);
            final double size = _layerSize(math.min(byWidth, byHeight * 1.3));
            graphics.drawString(
              text,
              face.at(size),
              brush: brush,
              bounds: Rect.fromLTWH(line.bounds.left, line.bounds.top, 0, 0),
            );
          }
          graphics.restore();
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }
}
