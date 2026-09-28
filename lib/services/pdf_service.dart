import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'pdf_page_geometry.dart';

/// How a text-markup annotation is drawn over its rectangle.
enum MarkupKind { highlight, underline, strikethrough }

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
  final MarkupKind kind;
  const HighlightRect({
    required this.bounds,
    required this.color,
    this.kind = MarkupKind.highlight,
  });
}

/// Standard paper sizes offered by page setup, in points, portrait.
enum PaperSize {
  a4(Size(595.28, 841.89), 'A4'),
  a5(Size(419.53, 595.28), 'A5'),
  letter(Size(612, 792), 'Letter'),
  legal(Size(612, 1008), 'Legal');

  final Size portrait;
  final String label;
  const PaperSize(this.portrait, this.label);
}

enum SetupOrientation { auto, portrait, landscape }

/// Re-lays a page onto a new sheet: the page's content, as currently
/// displayed, is scaled to fit inside [margin] and centred.
@immutable
class PageSetup {
  final PaperSize paper;
  final SetupOrientation orientation;
  final double margin;

  const PageSetup({
    required this.paper,
    this.orientation = SetupOrientation.auto,
    this.margin = 0,
  });

  /// The sheet for content that displays at [display].
  Size sheetFor(Size display) {
    final bool landscape = switch (orientation) {
      SetupOrientation.auto => display.width > display.height,
      SetupOrientation.portrait => false,
      SetupOrientation.landscape => true,
    };
    final Size p = paper.portrait;
    return landscape ? Size(p.height, p.width) : p;
  }
}

/// Where one page of a rebuilt document comes from.
sealed class PageSource {
  const PageSource();
}

/// A page of the document being rebuilt, by its index in that document.
class OriginalPageSource extends PageSource {
  final int index;
  const OriginalPageSource(this.index);
}

/// A page borrowed from another PDF on disk.
class ForeignPageSource extends PageSource {
  final String path;
  final int index;
  const ForeignPageSource(this.path, this.index);
}

/// An empty page of [size] points.
class BlankPageSource extends PageSource {
  final Size size;
  const BlankPageSource(this.size);
}

/// A page made from an encoded image.
class ImagePageSource extends PageSource {
  final Uint8List bytes;
  const ImagePageSource(this.bytes);
}

/// One page of a rebuilt document: where it comes from, how many clockwise
/// quarter turns to add on top of its own rotation, and an optional re-layout
/// onto a different sheet.
@immutable
class PageSpec {
  final PageSource source;
  final int quarterTurns;
  final PageSetup? setup;

  const PageSpec(this.source, {this.quarterTurns = 0, this.setup});

  PageSpec copyWith({int? quarterTurns, PageSetup? setup, bool clearSetup = false}) =>
      PageSpec(
        source,
        quarterTurns: quarterTurns ?? this.quarterTurns,
        setup: clearSetup ? null : (setup ?? this.setup),
      );
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
    final List<Rect> rects = highlights
        .map((h) => h.bounds)
        .toList(growable: false);
    final List<MarkupKind> kinds = highlights
        .map((h) => h.kind)
        .toList(growable: false);

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
            switch (kinds[i]) {
              MarkupKind.highlight => 'Highlight',
              MarkupKind.underline => 'Underline',
              MarkupKind.strikethrough => 'Strikethrough',
            },
            PdfColor(colors[i].r, colors[i].g, colors[i].b),
          );
          annotation.textMarkupAnnotationType = switch (kinds[i]) {
            MarkupKind.highlight => PdfTextMarkupAnnotationType.highlight,
            MarkupKind.underline => PdfTextMarkupAnnotationType.underline,
            MarkupKind.strikethrough =>
              PdfTextMarkupAnnotationType.strikethrough,
          };
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

          final PdfPen pen =
              PdfPen(
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

  /// Turns [pageIndices] by [quarterTurns] clockwise quarter turns.
  ///
  /// Rotation is recorded in the page's `/Rotate` entry rather than by
  /// redrawing anything, so it is lossless and costs nothing but a re-save.
  static Future<Uint8List> renderRotatePages(
    Uint8List bytes,
    List<int> pageIndices,
    int quarterTurns,
  ) {
    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        for (final int pageIndex in pageIndices) {
          _requirePageInRange(document, pageIndex);
        }
        for (final int pageIndex in pageIndices) {
          final PdfPage page = document.pages[pageIndex];
          final int turns =
              (((page.rotation.index + quarterTurns) % 4) + 4) % 4;
          page.rotation = PdfPageRotateAngle.values[turns];
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Removes [pageIndices] from the document.
  static Future<Uint8List> renderDeletePages(
    Uint8List bytes,
    List<int> pageIndices,
  ) {
    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        for (final int pageIndex in pageIndices) {
          _requirePageInRange(document, pageIndex);
        }
        final Set<int> unique = pageIndices.toSet();
        if (unique.length >= document.pages.count) {
          throw const PdfEditException(
            'A document must keep at least one page.',
          );
        }
        // Descending, so removing one page does not shift the index of the
        // next one still to be removed.
        final List<int> ordered = unique.toList()
          ..sort((a, b) => b.compareTo(a));
        for (final int pageIndex in ordered) {
          document.pages.removeAt(pageIndex);
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Appends [images] as new pages, each sized to its own aspect ratio.
  static Future<Uint8List> renderAppendImages(
    Uint8List bytes,
    List<Uint8List> images,
  ) {
    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        if (images.isEmpty) {
          throw const PdfEditException('No pages to add.');
        }
        for (final Uint8List imageBytes in images) {
          final PdfBitmap bitmap = PdfBitmap(imageBytes);
          const double longEdge = 842.0;
          final double scale =
              longEdge /
              (bitmap.width > bitmap.height ? bitmap.width : bitmap.height);
          final Size sheet = Size(bitmap.width * scale, bitmap.height * scale);
          // `insert` with an explicit size rather than `add`: page settings on
          // a document are frozen once it has a page and are normalised to its
          // orientation, so added pages would inherit the original document's
          // size and margins instead of matching the image.
          final PdfPage page = document.pages.insert(
            document.pages.count,
            sheet,
            PdfMargins()..all = 0,
          );
          page.graphics.drawImage(
            bitmap,
            Rect.fromLTWH(0, 0, sheet.width, sheet.height),
          );
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Draws [imageBytes] into [bounds] (unrotated page space) on [pageIndex].
  ///
  /// [counterTurns] is how many quarter turns anticlockwise to turn the pixels
  /// first. The viewer shows a `/Rotate`d page already turned, so an image
  /// placed upright on screen has to be written turned the other way or it
  /// comes out on its side.
  static Future<Uint8List> renderImageStamp(
    Uint8List bytes,
    int pageIndex,
    Uint8List imageBytes,
    Rect bounds,
    int counterTurns,
  ) {
    return Isolate.run(() async {
      if (bounds.width <= 0 || bounds.height <= 0) {
        throw const PdfEditException('The image has no area on the page.');
      }
      final Uint8List prepared = _prepareStampImage(imageBytes, counterTurns);
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        _requirePageInRange(document, pageIndex);
        document.pages[pageIndex].graphics.drawImage(
          PdfBitmap(prepared),
          bounds,
        );
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Replaces a line of text: paints over [lineBounds] (unrotated page space,
  /// as reported by text extraction) and writes [text] in its place.
  ///
  /// PDF has no editable text, and Syncfusion offers no redaction, so the old
  /// glyphs are covered rather than removed. They stay in the file and are
  /// still found by copy, search and extraction.
  static Future<Uint8List> renderReplaceText(
    Uint8List bytes,
    int pageIndex,
    Rect lineBounds,
    String text,
    double fontSize, {
    String fontName = '',
    bool bold = false,
    bool italic = false,
    Color color = Colors.black,
  }) {
    final int r = _channel(color.r);
    final int g = _channel(color.g);
    final int b = _channel(color.b);

    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        _requirePageInRange(document, pageIndex);
        final PdfPage page = document.pages[pageIndex];
        final PdfGraphics graphics = page.graphics;
        final Size unrotated = page.size;
        final int turns = page.rotation.index;

        // Text runs along the long side of its line. On a /Rotate'd page that
        // is either the page's own space (text drawn plainly, shown turned)
        // or the displayed space (content drawn counter-turned, so it reads
        // upright). Write the replacement in whichever space the line runs
        // horizontally, or it comes out at right angles to the original.
        Rect target = lineBounds;
        Size space = unrotated;
        graphics.save();
        if (turns != 0) {
          final Rect display = rotatePageRect(
            lineBounds,
            unrotated,
            PdfPageTurn.values[turns],
          );
          if (display.width >= display.height) {
            target = display;
            space = turns.isOdd ? unrotated.flipped : unrotated;
            // Maps displayed coordinates onto the page's own; the inverse of
            // the viewer's clockwise /Rotate.
            switch (turns) {
              case 1:
                graphics.translateTransform(0, unrotated.height);
                graphics.rotateTransform(-90);
              case 2:
                graphics.translateTransform(unrotated.width, unrotated.height);
                graphics.rotateTransform(180);
              case 3:
                graphics.translateTransform(unrotated.width, 0);
                graphics.rotateTransform(90);
            }
          }
        }

        graphics.drawRectangle(
          brush: PdfSolidBrush(PdfColor(255, 255, 255)),
          bounds: target.inflate(1),
        );
        if (text.trim().isNotEmpty) {
          final double size = fontSize > 0 ? fontSize : target.height;
          final List<PdfFontStyle> styles = [
            if (bold) PdfFontStyle.bold,
            if (italic) PdfFontStyle.italic,
          ];
          final PdfFont font = PdfStandardFont(
            _familyFor(fontName),
            size,
            multiStyle: styles.isEmpty ? null : styles,
          );
          final double available =
              space.width - target.left - _textRightMargin;
          // Extracted bounds start at the top of the glyphs, while drawString
          // positions the top of the line box, which sits a little higher.
          graphics.drawString(
            text,
            font,
            bounds: Rect.fromLTWH(
              target.left,
              target.top - size * 0.18,
              math.max(available, target.width),
              0,
            ),
            brush: PdfSolidBrush(PdfColor(r, g, b)),
          );
        }
        graphics.restore();
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Rebuilds the document so that its pages are exactly [specs], in order.
  ///
  /// Syncfusion can insert and remove pages but not move them, so a page that
  /// changes position is redrawn from a template of itself. That keeps how it
  /// looks — annotations are flattened into it first — but not its links or
  /// form fields. To keep that loss as small as possible, the longest run of
  /// original pages already in their final relative order is left in place
  /// untouched, and only the rest are redrawn.
  ///
  /// [foreign] holds the bytes of every document a [ForeignPageSource] names.
  static Future<Uint8List> renderLayout(
    Uint8List bytes,
    List<PageSpec> specs,
    Map<String, Uint8List> foreign,
  ) {
    return Isolate.run(() => _layoutInIsolate(bytes, specs, foreign));
  }

  /// One document per group of 0-based page indices.
  ///
  /// Pages are removed rather than copied, so every part keeps its pages
  /// exactly as they were, links and all.
  static Future<List<Uint8List>> renderSplit(
    Uint8List bytes,
    List<List<int>> groups,
  ) {
    return Isolate.run(() async {
      final List<Uint8List> results = [];
      for (final List<int> group in groups) {
        final PdfDocument document = PdfDocument(inputBytes: bytes);
        try {
          final Set<int> keep = group.toSet();
          for (final int index in keep) {
            _requirePageInRange(document, index);
          }
          if (keep.isEmpty) {
            throw const PdfEditException('A part came out with no pages.');
          }
          for (int i = document.pages.count - 1; i >= 0; i--) {
            if (!keep.contains(i)) document.pages.removeAt(i);
          }
          // A full rewrite, or every part drags the whole original along as
          // the base of an incremental update.
          document.fileStructure.incrementalUpdate = false;
          results.add(Uint8List.fromList(await document.save()));
        } finally {
          document.dispose();
        }
      }
      return results;
    });
  }

  /// Joins [documents] end to end.
  ///
  /// The first document is kept as it is; pages of the rest are redrawn from
  /// templates, with the same trade-off as [renderLayout].
  static Future<Uint8List> renderMerge(List<Uint8List> documents) {
    return Isolate.run(() => _mergeInIsolate(documents));
  }

  /// Re-saves [bytes] as a full rewrite with maximum stream compression and a
  /// compressed cross-reference stream. Lossless; how much it saves depends
  /// entirely on how wastefully the original was written.
  static Future<Uint8List> renderCompact(Uint8List bytes) {
    return Isolate.run(() async {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        document.fileStructure.incrementalUpdate = false;
        document.compressionLevel = PdfCompressionLevel.best;
        document.fileStructure.crossReferenceType =
            PdfCrossReferenceType.crossReferenceStream;
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Builds a document with one page per image, page `i` sized [sheets]`[i]`
  /// points with its image stretched over it. Used to rebuild a rasterised
  /// document at its original page sizes.
  ///
  /// The sizes are passed rather than derived from the pixels and a dpi,
  /// because the renderer shrinks oversized pages to fit its memory budget,
  /// and a derived size would shrink the paper with them.
  static Future<Uint8List> renderImagePages(
    List<Uint8List> images,
    List<Size> sheets,
  ) {
    return Isolate.run(() async {
      if (images.isEmpty) throw const PdfEditException('No pages to build.');
      if (sheets.length != images.length) {
        throw const PdfEditException('Every page needs a size.');
      }
      final PdfDocument document = PdfDocument();
      try {
        document.compressionLevel = PdfCompressionLevel.best;
        for (int i = 0; i < images.length; i++) {
          final PdfBitmap bitmap = PdfBitmap(images[i]);
          final Size sheet = sheets[i];
          // One section per page, orientation before size: see appendImages.
          final PdfSection section = document.sections!.add();
          section.pageSettings.margins.all = 0;
          section.pageSettings.orientation = sheet.width > sheet.height
              ? PdfPageOrientation.landscape
              : PdfPageOrientation.portrait;
          section.pageSettings.size = sheet;
          section.pages.add().graphics.drawImage(bitmap, Offset.zero & sheet);
        }
        return Uint8List.fromList(await document.save());
      } finally {
        document.dispose();
      }
    });
  }

  /// Re-encodes a photo upright and no longer than [maxEdge]: JPEG, or PNG
  /// when it has transparency to keep (a logo).
  ///
  /// Cameras record orientation in EXIF rather than turning the pixels, and
  /// `image_picker` carries that tag through its resize untouched. PDF has no
  /// notion of EXIF, so an unbaked portrait photo lands on its side.
  static Future<Uint8List> normalizePhoto(
    Uint8List bytes, {
    int maxEdge = 2400,
  }) {
    return Isolate.run(() {
      img.Image? decoded;
      try {
        decoded = img.decodeImage(bytes);
      } catch (_) {
        decoded = null;
      }
      if (decoded == null) {
        throw const PdfEditException('This image format is not supported.');
      }
      img.Image image = img.bakeOrientation(decoded);
      if (math.max(image.width, image.height) > maxEdge) {
        image = image.width >= image.height
            ? img.copyResize(image, width: maxEdge)
            : img.copyResize(image, height: maxEdge);
      }
      return image.numChannels == 4
          ? img.encodePng(image)
          : img.encodeJpg(image, quality: 88);
    });
  }

  /// Indices into [values] of a longest strictly increasing subsequence.
  static List<int> longestIncreasingRun(List<int> values) {
    final List<int> tails = [];
    final List<int> parent = List<int>.filled(values.length, -1);
    for (int i = 0; i < values.length; i++) {
      int lo = 0;
      int hi = tails.length;
      while (lo < hi) {
        final int mid = (lo + hi) >> 1;
        if (values[tails[mid]] < values[i]) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      if (lo > 0) parent[i] = tails[lo - 1];
      if (lo == tails.length) {
        tails.add(i);
      } else {
        tails[lo] = i;
      }
    }
    final List<int> run = [];
    for (int k = tails.isEmpty ? -1 : tails.last; k >= 0; k = parent[k]) {
      run.add(k);
    }
    return run.reversed.toList(growable: false);
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

  static Future<PdfEditResult> rotatePages(
    File file,
    List<int> pageIndices,
    int quarterTurns,
  ) {
    return _edit(
      file,
      'rotate',
      (bytes) => renderRotatePages(bytes, pageIndices, quarterTurns),
    );
  }

  static Future<PdfEditResult> deletePages(File file, List<int> pageIndices) {
    return _edit(
      file,
      'delete pages',
      (bytes) => renderDeletePages(bytes, pageIndices),
    );
  }

  static Future<PdfEditResult> appendImages(File file, List<Uint8List> images) {
    return _edit(
      file,
      'add pages',
      (bytes) => renderAppendImages(bytes, images),
    );
  }

  static Future<PdfEditResult> addImage(
    File file,
    int pageIndex,
    Uint8List image,
    Rect bounds, {
    int counterTurns = 0,
  }) {
    return _edit(
      file,
      'add the image',
      (bytes) =>
          renderImageStamp(bytes, pageIndex, image, bounds, counterTurns),
    );
  }

  static Future<PdfEditResult> replaceText(
    File file,
    int pageIndex,
    Rect lineBounds,
    String text,
    double fontSize, {
    String fontName = '',
    bool bold = false,
    bool italic = false,
    Color color = Colors.black,
  }) {
    return _edit(
      file,
      'edit the text',
      (bytes) => renderReplaceText(
        bytes,
        pageIndex,
        lineBounds,
        text,
        fontSize,
        fontName: fontName,
        bold: bold,
        italic: italic,
        color: color,
      ),
    );
  }

  /// Rebuilds [file] as [specs]; see [renderLayout].
  static Future<PdfEditResult> applyLayout(File file, List<PageSpec> specs) {
    return _edit(file, 'rearrange pages', (bytes) async {
      return renderLayout(bytes, specs, await readForeignSources(specs));
    });
  }

  /// Loads every other document [specs] borrow pages from, keyed by path.
  static Future<Map<String, Uint8List>> readForeignSources(
    List<PageSpec> specs,
  ) async {
    final Map<String, Uint8List> foreign = {};
    for (final PageSpec spec in specs) {
      final PageSource source = spec.source;
      if (source is ForeignPageSource && !foreign.containsKey(source.path)) {
        foreign[source.path] = await File(source.path).readAsBytes();
      }
    }
    return foreign;
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

  /// The standard font closest to an embedded one, by name. Only the three
  /// base-14 families are available without embedding a font file.
  static PdfFontFamily _familyFor(String fontName) {
    final String name = fontName.toLowerCase();
    if (name.contains('courier') ||
        name.contains('mono') ||
        name.contains('consol')) {
      return PdfFontFamily.courier;
    }
    if (name.contains('times') ||
        name.contains('serif') && !name.contains('sans') ||
        name.contains('georgia') ||
        name.contains('cambria') ||
        name.contains('garamond')) {
      return PdfFontFamily.timesRoman;
    }
    return PdfFontFamily.helvetica;
  }

  /// Decodes, bounds and turns an image for stamping, then re-encodes it in a
  /// form `PdfBitmap` reads: PNG where there is transparency to keep (a
  /// signature), JPEG otherwise.
  static Uint8List _prepareStampImage(Uint8List bytes, int counterTurns) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      // Truncated or unrecognised data trips range errors in the decoders
      // rather than returning null.
      decoded = null;
    }
    if (decoded == null) {
      throw const PdfEditException('This image format is not supported.');
    }
    img.Image image = img.bakeOrientation(decoded);
    const int maxEdge = 2000;
    final int longest = math.max(image.width, image.height);
    if (longest > maxEdge) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxEdge)
          : img.copyResize(image, height: maxEdge);
    }
    final int turns = counterTurns % 4;
    // copyRotate turns clockwise.
    if (turns != 0) image = img.copyRotate(image, angle: -90 * turns);
    return image.numChannels == 4
        ? img.encodePng(image)
        : img.encodeJpg(image, quality: 90);
  }
}

// --- Page layout ------------------------------------------------------------

/// Everything needed to redraw one existing page somewhere else.
class _PageContent {
  final PdfTemplate template;
  final Size size;
  final PdfPageRotateAngle rotation;

  const _PageContent(this.template, this.size, this.rotation);

  factory _PageContent.of(PdfPage page) {
    try {
      // A template carries the page's content stream only. Flattening first
      // is what brings highlights, ink and stamps along with it.
      page.annotations.flattenAllAnnotations();
    } catch (_) {
      // Annotations the library cannot flatten are dropped, not fatal.
    }
    final PdfTemplate template = page.createTemplate();
    final Size size = template.size.isEmpty ? page.size : template.size;
    return _PageContent(template, size, page.rotation);
  }
}

PdfPageRotateAngle _turned(PdfPageRotateAngle rotation, int quarterTurns) =>
    PdfPageRotateAngle.values[(((rotation.index + quarterTurns) % 4) + 4) % 4];

/// The rectangle content displaying at [display] occupies on [sheet] once it
/// is scaled to fit inside [margin] and centred.
Rect _fitOnSheet(Size sheet, Size display, double margin) {
  final double availableWidth = math.max(1, sheet.width - margin * 2);
  final double availableHeight = math.max(1, sheet.height - margin * 2);
  final double scale = math.min(
    availableWidth / display.width,
    availableHeight / display.height,
  );
  final Size fitted = display * scale;
  return Rect.fromLTWH(
    (sheet.width - fitted.width) / 2,
    (sheet.height - fitted.height) / 2,
    fitted.width,
    fitted.height,
  );
}

/// Draws content whose own, unrotated size is [natural] into [target] as it
/// looks after [turns] clockwise quarter turns.
///
/// [draw] receives the size to draw at, from the origin, in the turned
/// coordinate system. Syncfusion's `rotateTransform` turns clockwise in its
/// top-left, y-down page space.
void _drawTurned(
  PdfGraphics graphics,
  int turns,
  Rect target,
  Size natural,
  void Function(Size size) draw,
) {
  final bool swapped = turns.isOdd;
  final double scale =
      target.width / (swapped ? natural.height : natural.width);
  final double w = natural.width * scale;
  final double h = natural.height * scale;
  graphics.save();
  switch (turns % 4) {
    case 1:
      graphics.translateTransform(target.left + h, target.top);
      graphics.rotateTransform(90);
    case 2:
      graphics.translateTransform(target.left + w, target.top + h);
      graphics.rotateTransform(180);
    case 3:
      graphics.translateTransform(target.left, target.top + w);
      graphics.rotateTransform(270);
    default:
      graphics.translateTransform(target.left, target.top);
  }
  draw(Size(w, h));
  graphics.restore();
}

Future<Uint8List> _layoutInIsolate(
  Uint8List bytes,
  List<PageSpec> specs,
  Map<String, Uint8List> foreignBytes,
) async {
  if (specs.isEmpty) {
    throw const PdfEditException('A document must keep at least one page.');
  }
  final PdfDocument document = PdfDocument(inputBytes: bytes);
  final Map<String, PdfDocument> foreign = {};
  PdfDocument? clone;
  try {
    final int count = document.pages.count;
    for (final PageSpec spec in specs) {
      final PageSource source = spec.source;
      if (source is OriginalPageSource &&
          (source.index < 0 || source.index >= count)) {
        throw PdfEditException(
          'Page ${source.index + 1} is outside this document '
          '($count page(s)).',
        );
      }
    }

    // Original pages that can stay where they are: first occurrences with no
    // re-layout, reduced to the longest run already in increasing order.
    final List<int> candidates = [];
    final Set<int> seen = {};
    for (int i = 0; i < specs.length; i++) {
      final PageSource source = specs[i].source;
      if (source is OriginalPageSource &&
          specs[i].setup == null &&
          seen.add(source.index)) {
        candidates.add(i);
      }
    }
    int originalIndexAt(int specIndex) =>
        (specs[specIndex].source as OriginalPageSource).index;
    final Set<int> keptSpecs = PdfService.longestIncreasingRun(
      candidates.map(originalIndexAt).toList(growable: false),
    ).map((k) => candidates[k]).toSet();
    final Set<int> keptOriginals = keptSpecs.map(originalIndexAt).toSet();

    // Templates have to be taken while every original page is still there.
    // Taking one flattens the page's annotations, which is harmless for a
    // page about to be removed but not for one that stays; a second copy of a
    // kept page is taken from a separate parse of the file instead.
    final Map<int, _PageContent> moved = {};
    for (int i = 0; i < specs.length; i++) {
      if (keptSpecs.contains(i)) continue;
      final PageSource source = specs[i].source;
      if (source is OriginalPageSource && !moved.containsKey(source.index)) {
        final PdfDocument from = keptOriginals.contains(source.index)
            ? (clone ??= PdfDocument(inputBytes: bytes))
            : document;
        moved[source.index] = _PageContent.of(from.pages[source.index]);
      }
    }

    PdfDocument foreignDocument(String path) {
      return foreign.putIfAbsent(path, () {
        final Uint8List? data = foreignBytes[path];
        if (data == null) {
          throw const PdfEditException('A document to insert was not found.');
        }
        final PdfDocument loaded = PdfDocument(inputBytes: data);
        try {
          // Fields are widgets tied to the other document's form; flattening
          // keeps what they show.
          loaded.form.flattenAllFields();
        } catch (_) {
          // No form, or one the library cannot flatten.
        }
        return loaded;
      });
    }

    final PdfMargins noMargins = PdfMargins()..all = 0;

    /// Inserts the page [spec] describes at [index] and returns the rotation
    /// it should end up with.
    PdfPageRotateAngle insertPage(int index, PageSpec spec) {
      final PageSource source = spec.source;
      final PageSetup? setup = spec.setup;
      final _PageContent content;
      switch (source) {
        case OriginalPageSource():
          content = moved[source.index]!;
        case ForeignPageSource():
          final PdfDocument other = foreignDocument(source.path);
          if (source.index < 0 || source.index >= other.pages.count) {
            throw const PdfEditException(
              'A page to insert is outside its document.',
            );
          }
          content = _PageContent.of(other.pages[source.index]);
        case BlankPageSource():
          final int turns = spec.quarterTurns % 4;
          if (setup == null) {
            document.pages.insert(index, source.size, noMargins);
            return _turned(PdfPageRotateAngle.rotateAngle0, turns);
          }
          final Size display = turns.isOdd
              ? source.size.flipped
              : source.size;
          document.pages.insert(index, setup.sheetFor(display), noMargins);
          return PdfPageRotateAngle.rotateAngle0;
        case ImagePageSource():
          final PdfBitmap bitmap = PdfBitmap(source.bytes);
          final double k =
              842.0 / math.max(bitmap.width, bitmap.height).toDouble();
          final Size natural = Size(bitmap.width * k, bitmap.height * k);
          final int turns = spec.quarterTurns % 4;
          if (setup == null) {
            document.pages
                .insert(index, natural, noMargins)
                .graphics
                .drawImage(bitmap, Offset.zero & natural);
            return _turned(PdfPageRotateAngle.rotateAngle0, turns);
          }
          final Size display = turns.isOdd ? natural.flipped : natural;
          final Size sheet = setup.sheetFor(display);
          final PdfPage page = document.pages.insert(index, sheet, noMargins);
          _drawTurned(
            page.graphics,
            turns,
            _fitOnSheet(sheet, display, setup.margin),
            natural,
            (size) => page.graphics.drawImage(bitmap, Offset.zero & size),
          );
          return PdfPageRotateAngle.rotateAngle0;
      }

      final int turns = (content.rotation.index + spec.quarterTurns) % 4;
      if (setup == null) {
        document.pages
            .insert(index, content.size, noMargins)
            .graphics
            .drawPdfTemplate(content.template, Offset.zero, content.size);
        return PdfPageRotateAngle.values[turns];
      }
      final Size display = turns.isOdd ? content.size.flipped : content.size;
      final Size sheet = setup.sheetFor(display);
      final PdfPage page = document.pages.insert(index, sheet, noMargins);
      _drawTurned(
        page.graphics,
        turns,
        _fitOnSheet(sheet, display, setup.margin),
        content.size,
        (size) =>
            page.graphics.drawPdfTemplate(content.template, Offset.zero, size),
      );
      return PdfPageRotateAngle.rotateAngle0;
    }

    // Mirrors the document while it is rebuilt: an original page index, or -1
    // for a page inserted in this pass. Pages are only removed at the end, so
    // the document is never empty along the way.
    final List<int> model = List<int>.generate(count, (i) => i);
    bool isDoomed(int entry) => entry >= 0 && !keptOriginals.contains(entry);
    final Map<int, PdfPageRotateAngle> lateRotations = {};

    int position = 0;
    for (int i = 0; i < specs.length; i++) {
      while (position < model.length && isDoomed(model[position])) {
        position++;
      }
      final PageSpec spec = specs[i];
      if (keptSpecs.contains(i)) {
        if (model[position] != originalIndexAt(i)) {
          throw StateError('Page layout lost track of page ${i + 1}.');
        }
        final PdfPage page = document.pages[position];
        page.rotation = _turned(page.rotation, spec.quarterTurns);
      } else {
        final PdfPageRotateAngle rotation = insertPage(position, spec);
        model.insert(position, -1);
        if (rotation != PdfPageRotateAngle.rotateAngle0) {
          lateRotations[i] = rotation;
        }
      }
      position++;
    }
    for (int i = model.length - 1; i >= 0; i--) {
      if (isDoomed(model[i])) document.pages.removeAt(i);
    }

    // A new page's final index is its position in [specs].
    return await _saveWithRotations(document, lateRotations);
  } finally {
    document.dispose();
    clone?.dispose();
    for (final PdfDocument other in foreign.values) {
      other.dispose();
    }
  }
}

Future<Uint8List> _mergeInIsolate(List<Uint8List> documents) async {
  if (documents.length < 2) {
    throw const PdfEditException('Pick at least two documents to merge.');
  }
  final PdfDocument base = PdfDocument(inputBytes: documents.first);
  final List<PdfDocument> others = [];
  try {
    final PdfMargins noMargins = PdfMargins()..all = 0;
    final Map<int, PdfPageRotateAngle> lateRotations = {};
    for (final Uint8List data in documents.skip(1)) {
      final PdfDocument other = PdfDocument(inputBytes: data);
      others.add(other);
      try {
        other.form.flattenAllFields();
      } catch (_) {
        // No form, or one the library cannot flatten.
      }
      for (int i = 0; i < other.pages.count; i++) {
        final _PageContent content = _PageContent.of(other.pages[i]);
        final int index = base.pages.count;
        base.pages
            .insert(index, content.size, noMargins)
            .graphics
            .drawPdfTemplate(content.template, Offset.zero, content.size);
        if (content.rotation != PdfPageRotateAngle.rotateAngle0) {
          lateRotations[index] = content.rotation;
        }
      }
    }
    return await _saveWithRotations(base, lateRotations);
  } finally {
    base.dispose();
    for (final PdfDocument other in others) {
      other.dispose();
    }
  }
}

/// Saves [document] as a full rewrite, then applies [rotations] (final page
/// index to angle).
///
/// The rewrite matters: an incremental save keeps every removed page's data
/// in the file underneath the update. And a page inserted into a loaded
/// document ignores its rotation setter until the document has been written
/// and read back, so new pages are turned in a second pass.
Future<Uint8List> _saveWithRotations(
  PdfDocument document,
  Map<int, PdfPageRotateAngle> rotations,
) async {
  document.fileStructure.incrementalUpdate = false;
  final Uint8List firstPass = Uint8List.fromList(await document.save());
  if (rotations.isEmpty) return firstPass;
  final PdfDocument reloaded = PdfDocument(inputBytes: firstPass);
  try {
    rotations.forEach((index, rotation) {
      reloaded.pages[index].rotation = rotation;
    });
    return Uint8List.fromList(await reloaded.save());
  } finally {
    reloaded.dispose();
  }
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
