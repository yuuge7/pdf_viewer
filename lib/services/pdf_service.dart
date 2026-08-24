import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// A freehand stroke expressed in PDF page coordinates (origin top-left of the page).
class DrawStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  const DrawStroke({
    required this.points,
    required this.color,
    required this.width,
  });
}

/// A highlight rectangle expressed in PDF page coordinates (origin top-left of the page).
class HighlightRect {
  final Rect bounds;
  final Color color;
  const HighlightRect({required this.bounds, required this.color});
}

/// Outcome of an edit. Exactly one of [file] / [error] is non-null.
///
/// The previous API returned a bare `File?`, which collapsed "page out of
/// range", "corrupt document" and "disk full" into an indistinguishable null.
/// Callers can now surface the actual reason.
class PdfEditResult {
  final File? file;
  final String? error;

  const PdfEditResult.success(File this.file) : error = null;
  const PdfEditResult.failure(String this.error) : file = null;

  bool get isSuccess => file != null;
}

/// Thrown inside the worker isolate when the requested edit cannot be applied.
class PdfEditException implements Exception {
  final String message;
  const PdfEditException(this.message);
  @override
  String toString() => message;
}

/// Applies annotations to PDF documents.
///
/// All Syncfusion parsing/saving happens inside [Isolate.run] because it is
/// CPU-bound and would otherwise jank the UI on large documents.
///
/// The `render*` methods are pure bytes-in/bytes-out and carry no platform
/// dependencies, so they are directly unit-testable. The `add*` methods wrap
/// them with file IO.
class PdfService {
  /// Minimum squared distance, in PDF units, between two retained stroke points.
  static const double _minPointDistanceSquared = 4.0;

  /// Gap left between the text box and the right page edge, in PDF units.
  static const double _textRightMargin = 8.0;

  static void _requirePageInRange(PdfDocument document, int pageIndex) {
    if (pageIndex < 0 || pageIndex >= document.pages.count) {
      throw PdfEditException(
        'Page ${pageIndex + 1} is outside this document '
        '(${document.pages.count} page(s)).',
      );
    }
  }

  // --- Pure byte-level operations -------------------------------------------

  /// Draws [text] at [position] (PDF page coordinates) on [pageIndex] (0-based).
  static Future<Uint8List> renderTextAnnotation(
    Uint8List bytes,
    int pageIndex,
    String text,
    Offset position,
    Color color,
    double fontSize,
  ) {
    // Decompose the colour before entering the isolate.
    final int r = _channel(color.r);
    final int g = _channel(color.g);
    final int b = _channel(color.b);

    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        _requirePageInRange(document, pageIndex);
        final PdfPage page = document.pages[pageIndex];
        final PdfFont font = PdfStandardFont(PdfFontFamily.helvetica, fontSize);

        // Lay the text out into the space actually left on the page instead of
        // a hardcoded 500pt box, which clipped text drawn near the right edge.
        // Height is left at 0 so Syncfusion grows the box and long strings wrap
        // instead of disappearing.
        final double available =
            page.getClientSize().width - position.dx - _textRightMargin;
        final double boxWidth = available > font.size ? available : font.size;

        page.graphics.drawString(
          text,
          font,
          bounds: Rect.fromLTWH(
            position.dx,
            position.dy - (fontSize / 2),
            boxWidth,
            0,
          ),
          brush: PdfSolidBrush(PdfColor(r, g, b)),
        );
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Adds [highlights] (PDF page coordinates) to [pageIndex] (0-based).
  static Future<Uint8List> renderHighlightAnnotation(
    Uint8List bytes,
    int pageIndex,
    List<HighlightRect> highlights,
  ) {
    final List<_Rgb> colors = highlights
        .map(
          (h) => _Rgb(
            _channel(h.color.r),
            _channel(h.color.g),
            _channel(h.color.b),
          ),
        )
        .toList(growable: false);
    final List<Rect> rects =
        highlights.map((h) => h.bounds).toList(growable: false);

    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        _requirePageInRange(document, pageIndex);
        final PdfPage page = document.pages[pageIndex];

        for (int i = 0; i < rects.length; i++) {
          final Rect bounds = rects[i];
          // A zero-area rect produces an invisible annotation that still bloats
          // the file; skip it.
          if (bounds.width <= 0 || bounds.height <= 0) continue;
          final PdfTextMarkupAnnotation annotation = PdfTextMarkupAnnotation(
            bounds,
            'Highlight',
            PdfColor(colors[i].r, colors[i].g, colors[i].b),
          );
          annotation.textMarkupAnnotationType =
              PdfTextMarkupAnnotationType.highlight;
          page.annotations.add(annotation);
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Adds [strokes] (PDF page coordinates) to [pageIndex] (0-based).
  static Future<Uint8List> renderDrawAnnotation(
    Uint8List bytes,
    int pageIndex,
    List<DrawStroke> strokes,
  ) {
    final List<_PlainStroke> plain = strokes
        .map(
          (s) => _PlainStroke(
            points: s.points,
            r: _channel(s.color.r),
            g: _channel(s.color.g),
            b: _channel(s.color.b),
            width: s.width,
          ),
        )
        .toList(growable: false);

    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        _requirePageInRange(document, pageIndex);
        final PdfPage page = document.pages[pageIndex];

        for (final _PlainStroke stroke in plain) {
          if (stroke.points.length < 2) continue;

          final List<Offset> simplified = simplifyStroke(stroke.points);
          if (simplified.length < 2) continue;

          final PdfPen pen = PdfPen(
            PdfColor(stroke.r, stroke.g, stroke.b),
            width: stroke.width,
          )
            ..lineCap = PdfLineCap.round
            ..lineJoin = PdfLineJoin.round;

          final PdfPath path = PdfPath();
          for (int i = 0; i < simplified.length - 1; i++) {
            path.addLine(simplified[i], simplified[i + 1]);
          }
          page.graphics.drawPath(path, pen: pen);
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Drops points closer than 2 PDF units to the previously kept point.
  ///
  /// Dense paths crash the native Android `PdfRenderer` when the resulting file
  /// is re-opened, so this is a correctness guard, not just an optimisation.
  /// The first and last points are always preserved so the stroke keeps its
  /// exact endpoints.
  static List<Offset> simplifyStroke(List<Offset> points) {
    if (points.length < 3) return List<Offset>.of(points);

    final List<Offset> simplified = <Offset>[points.first];
    Offset last = points.first;
    for (int i = 1; i < points.length - 1; i++) {
      final double dx = points[i].dx - last.dx;
      final double dy = points[i].dy - last.dy;
      if ((dx * dx + dy * dy) > _minPointDistanceSquared) {
        simplified.add(points[i]);
        last = points[i];
      }
    }
    simplified.add(points.last);
    return simplified;
  }

  // --- File-level operations ------------------------------------------------

  static Future<PdfEditResult> addTextAnnotation(
    File file,
    int pageIndex,
    String text,
    Offset position,
    Color color,
    double fontSize,
  ) {
    return _edit(
      file,
      'add text',
      (bytes) => renderTextAnnotation(
        bytes,
        pageIndex,
        text,
        position,
        color,
        fontSize,
      ),
    );
  }

  static Future<PdfEditResult> addHighlightAnnotation(
    File file,
    int pageIndex,
    List<HighlightRect> highlights,
  ) {
    return _edit(
      file,
      'highlight',
      (bytes) => renderHighlightAnnotation(bytes, pageIndex, highlights),
    );
  }

  static Future<PdfEditResult> addDrawAnnotation(
    File file,
    int pageIndex,
    List<DrawStroke> strokes,
  ) {
    return _edit(
      file,
      'draw',
      (bytes) => renderDrawAnnotation(bytes, pageIndex, strokes),
    );
  }

  /// Reads [file], applies [render], and writes the result to a fresh file in
  /// the app documents directory. The source file is never modified.
  static Future<PdfEditResult> _edit(
    File file,
    String operation,
    Future<Uint8List> Function(Uint8List bytes) render,
  ) async {
    try {
      final Uint8List bytes = await file.readAsBytes();
      final Uint8List saved = await render(bytes);

      final Directory directory = await getApplicationDocumentsDirectory();
      final File newFile = File(
        '${directory.path}/edited_${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      await newFile.writeAsBytes(saved, flush: true);
      return PdfEditResult.success(newFile);
    } on PdfEditException catch (e) {
      debugPrint('Could not $operation: $e');
      return PdfEditResult.failure(e.message);
    } catch (e) {
      debugPrint('Could not $operation: $e');
      return PdfEditResult.failure('Could not $operation: $e');
    }
  }

  /// Converts a 0..1 colour channel to 0..255.
  static int _channel(double value) => (value * 255.0).round().clamp(0, 255);
}

class _Rgb {
  final int r;
  final int g;
  final int b;
  const _Rgb(this.r, this.g, this.b);
}

class _PlainStroke {
  final List<Offset> points;
  final int r;
  final int g;
  final int b;
  final double width;
  const _PlainStroke({
    required this.points,
    required this.r,
    required this.g,
    required this.b,
    required this.width,
  });
}
