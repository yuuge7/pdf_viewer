import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Color, Offset, Rect, Size;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'pdf_service.dart';

enum ShapeKind { line, arrow, rectangle, ellipse }

/// A shape dragged out on a page, in the page's own unrotated space
/// (origin top-left).
@immutable
class ShapeMark {
  final ShapeKind kind;
  final Offset start;
  final Offset end;
  final Color color;
  final double width;

  const ShapeMark({
    required this.kind,
    required this.start,
    required this.end,
    required this.color,
    required this.width,
  });
}

enum MarkType {
  highlight('Highlight'),
  underline('Underline'),
  strikethrough('Strikethrough'),
  note('Note');

  final String label;
  const MarkType(this.label);
}

/// An annotation already in the document that the eraser can remove.
@immutable
class PdfMark {
  final int pageIndex;

  /// Position in the page's annotation list, which is what identifies it.
  final int index;

  /// In the page's own unrotated space.
  final Rect bounds;
  final MarkType type;

  /// A note's words; empty for everything else.
  final String text;

  const PdfMark({
    required this.pageIndex,
    required this.index,
    required this.bounds,
    required this.type,
    this.text = '',
  });
}

/// Shapes, notes and the eraser.
///
/// A note is a real PDF annotation, like the text markup `PdfService`
/// writes: the viewer draws those itself, so they can be picked up again
/// and removed. A shape is painted into the page instead. As an annotation
/// it would be invisible here — Android's page renderer skips annotations,
/// and markup and notes only show because the viewer overlays them — and a
/// mark the user cannot see is no mark at all.
class PdfAnnotations {
  static int _channel(double value) => (value * 255.0).round().clamp(0, 255);

  /// The box a note is written with, in points.
  static const Size noteSize = Size(18, 20);

  /// Roughly what the viewer's note icon covers. It draws the icon from the
  /// top-left corner of the note's box and larger than it, so this is what
  /// has to be centred on a tap and what the eraser has to accept taps on.
  static const Size noteIconSize = Size(40, 44);

  static void _requirePage(PdfDocument document, int pageIndex) {
    if (pageIndex < 0 || pageIndex >= document.pages.count) {
      throw PdfEditException(
        'Page ${pageIndex + 1} is outside this document '
        '(${document.pages.count} page(s)).',
      );
    }
  }

  /// Draws [shapes] onto [pageIndex] (0-based).
  static Future<Uint8List> renderShapes(
    Uint8List bytes,
    int pageIndex,
    List<ShapeMark> shapes,
  ) {
    // Plain numbers only across the isolate boundary.
    final List<List<double>> plain = [
      for (final ShapeMark s in shapes)
        [
          s.kind.index.toDouble(),
          s.start.dx,
          s.start.dy,
          s.end.dx,
          s.end.dy,
          _channel(s.color.r).toDouble(),
          _channel(s.color.g).toDouble(),
          _channel(s.color.b).toDouble(),
          s.width,
        ],
    ];

    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        _requirePage(document, pageIndex);
        final PdfGraphics graphics = document.pages[pageIndex].graphics;
        for (final List<double> s in plain) {
          final ShapeKind kind = ShapeKind.values[s[0].toInt()];
          final Offset start = Offset(s[1], s[2]);
          final Offset end = Offset(s[3], s[4]);
          final PdfColor color = PdfColor(
            s[5].toInt(),
            s[6].toInt(),
            s[7].toInt(),
          );
          final double width = s[8];
          final PdfPen pen = PdfPen(color, width: width)
            ..lineCap = PdfLineCap.round
            ..lineJoin = PdfLineJoin.round;
          // Anything shorter is a slip of the finger, not a shape.
          final double length = (end - start).distance;
          final Rect bounds = Rect.fromPoints(start, end);
          switch (kind) {
            case ShapeKind.line:
              if (length < 2) continue;
              graphics.drawLine(pen, start, end);
            case ShapeKind.arrow:
              if (length < 2) continue;
              final Offset along = (end - start) / length;
              final Offset across = Offset(-along.dy, along.dx);
              final double head = math.min(
                length,
                math.max(9.0, width * 4),
              );
              final Offset base = end - along * head;
              // The shaft stops inside the head, or its round cap pokes out
              // of the point.
              graphics.drawLine(pen, start, end - along * head * 0.6);
              graphics.drawPolygon(
                [
                  end,
                  base + across * head * 0.45,
                  base - across * head * 0.45,
                ],
                brush: PdfSolidBrush(color),
              );
            case ShapeKind.rectangle:
              if (bounds.width < 2 || bounds.height < 2) continue;
              graphics.drawRectangle(pen: pen, bounds: bounds);
            case ShapeKind.ellipse:
              if (bounds.width < 2 || bounds.height < 2) continue;
              graphics.drawEllipse(bounds, pen: pen);
          }
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Pins a note reading [text] at [position] (unrotated page space).
  static Future<Uint8List> renderNote(
    Uint8List bytes,
    int pageIndex,
    Offset position,
    String text, {
    Color color = const Color(0xFFFFD60A),
  }) {
    final int r = _channel(color.r);
    final int g = _channel(color.g);
    final int b = _channel(color.b);

    return Isolate.run(() async {
      if (text.trim().isEmpty) {
        throw const PdfEditException('A note needs some text.');
      }
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        _requirePage(document, pageIndex);
        document.pages[pageIndex].annotations.add(
          PdfPopupAnnotation(
            Offset(
                  math.max(0, position.dx - noteIconSize.width / 2),
                  math.max(0, position.dy - noteIconSize.height / 2),
                ) &
                noteSize,
            text.trim(),
            color: PdfColor(r, g, b),
            icon: PdfPopupIcon.note,
            subject: 'Note',
            setAppearance: true,
          ),
        );
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Every annotation the eraser can take away, in page order.
  static Future<List<PdfMark>> list(Uint8List bytes) {
    return Isolate.run(() {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        final List<PdfMark> marks = [];
        for (int p = 0; p < document.pages.count; p++) {
          final PdfAnnotationCollection annotations =
              document.pages[p].annotations;
          for (int i = 0; i < annotations.count; i++) {
            final PdfAnnotation annotation;
            final Rect bounds;
            try {
              annotation = annotations[i];
              bounds = annotation.bounds;
            } catch (_) {
              continue;
            }
            final MarkType? type = _typeOf(annotation);
            if (type == null || bounds.isEmpty) continue;
            marks.add(
              PdfMark(
                pageIndex: p,
                index: i,
                bounds: bounds,
                type: type,
                text: type == MarkType.note ? annotation.text : '',
              ),
            );
          }
        }
        return marks;
      } finally {
        document.dispose();
      }
    });
  }

  /// Null for what must be left alone: links and form fields are part of
  /// the document, not marks someone made on it, and annotations of other
  /// kinds are not drawn here, so there would be nothing to tap.
  static MarkType? _typeOf(PdfAnnotation annotation) {
    if (annotation is PdfTextMarkupAnnotation) {
      return switch (annotation.textMarkupAnnotationType) {
        PdfTextMarkupAnnotationType.underline => MarkType.underline,
        PdfTextMarkupAnnotationType.strikethrough => MarkType.strikethrough,
        _ => MarkType.highlight,
      };
    }
    if (annotation is PdfPopupAnnotation) return MarkType.note;
    return null;
  }

  /// Removes the annotation at [index] in [pageIndex]'s list, as [list]
  /// reported it.
  static Future<Uint8List> renderRemove(
    Uint8List bytes,
    int pageIndex,
    int index,
  ) {
    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        _requirePage(document, pageIndex);
        final PdfAnnotationCollection annotations =
            document.pages[pageIndex].annotations;
        if (index < 0 || index >= annotations.count) {
          throw const PdfEditException('That annotation is no longer there.');
        }
        annotations.remove(annotations[index]);
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  // --- File-level operations ------------------------------------------------

  static Future<PdfEditResult> addShapes(
    File file,
    int pageIndex,
    List<ShapeMark> shapes,
  ) => PdfService.edit(
    file,
    'add the shape',
    (bytes) => renderShapes(bytes, pageIndex, shapes),
  );

  static Future<PdfEditResult> addNote(
    File file,
    int pageIndex,
    Offset position,
    String text,
  ) => PdfService.edit(
    file,
    'add the note',
    (bytes) => renderNote(bytes, pageIndex, position, text),
  );

  static Future<PdfEditResult> remove(File file, PdfMark mark) =>
      PdfService.edit(
        file,
        'remove the annotation',
        (bytes) => renderRemove(bytes, mark.pageIndex, mark.index),
      );
}
