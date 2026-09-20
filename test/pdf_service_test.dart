import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_viewer/services/pdf_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Builds a document whose pages each contain their own marker text, so tests
/// can prove which page an edit actually landed on.
Future<Uint8List> buildDocument(int pageCount) async {
  final PdfDocument document = PdfDocument();
  for (int i = 0; i < pageCount; i++) {
    document.pages.add().graphics.drawString(
      'MARKER${i + 1}',
      PdfStandardFont(PdfFontFamily.helvetica, 20),
      bounds: const Rect.fromLTWH(40, 40, 300, 40),
    );
  }
  final bytes = Uint8List.fromList(await document.save());
  document.dispose();
  return bytes;
}

String textOnPage(Uint8List bytes, int pageIndex) {
  final PdfDocument document = PdfDocument(inputBytes: bytes);
  try {
    return PdfTextExtractor(document)
        .extractText(startPageIndex: pageIndex, endPageIndex: pageIndex);
  } finally {
    document.dispose();
  }
}

int annotationCountOnPage(Uint8List bytes, int pageIndex) {
  final PdfDocument document = PdfDocument(inputBytes: bytes);
  try {
    return document.pages[pageIndex].annotations.count;
  } finally {
    document.dispose();
  }
}

PdfPageRotateAngle rotationOfPage(Uint8List bytes, int pageIndex) {
  final PdfDocument document = PdfDocument(inputBytes: bytes);
  try {
    return document.pages[pageIndex].rotation;
  } finally {
    document.dispose();
  }
}

int pageCountOf(Uint8List bytes) {
  final PdfDocument document = PdfDocument(inputBytes: bytes);
  try {
    return document.pages.count;
  } finally {
    document.dispose();
  }
}

Size pageSizeOf(Uint8List bytes, int pageIndex) {
  final PdfDocument document = PdfDocument(inputBytes: bytes);
  try {
    return document.pages[pageIndex].size;
  } finally {
    document.dispose();
  }
}

/// A small JPEG of known proportions, standing in for a rendered scan.
Uint8List jpegOf(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 200, 200));
  return img.encodeJpg(image);
}

void main() {
  group('renderTextAnnotation', () {
    test('writes text to the page index it was given, 0-based', () async {
      final source = await buildDocument(3);
      final edited = await PdfService.renderTextAnnotation(
        source,
        1,
        'INSERTED',
        const Offset(60, 300),
        Colors.red,
        24,
      );

      expect(textOnPage(edited, 1), contains('INSERTED'));
      expect(textOnPage(edited, 0), isNot(contains('INSERTED')));
      expect(textOnPage(edited, 2), isNot(contains('INSERTED')));
      // The page's own content survives.
      expect(textOnPage(edited, 1), contains('MARKER2'));
    });

    test('can write to the last page', () async {
      // The old code passed a 1-based page number straight through, so the
      // final page always failed with an out-of-range index.
      final source = await buildDocument(3);
      final edited = await PdfService.renderTextAnnotation(
        source,
        2,
        'LASTPAGE',
        const Offset(60, 300),
        Colors.black,
        18,
      );
      expect(textOnPage(edited, 2), contains('LASTPAGE'));
    });

    test('rejects a page index past the end', () async {
      final source = await buildDocument(2);
      expect(
        () => PdfService.renderTextAnnotation(
          source,
          2,
          'x',
          Offset.zero,
          Colors.black,
          12,
        ),
        throwsA(isA<PdfEditException>()),
      );
    });

    test('rejects a negative page index', () async {
      // A tap outside any page reports pageNumber -1; that used to become a
      // silent no-op rather than a reported failure.
      final source = await buildDocument(2);
      expect(
        () => PdfService.renderTextAnnotation(
          source,
          -1,
          'x',
          Offset.zero,
          Colors.black,
          12,
        ),
        throwsA(isA<PdfEditException>()),
      );
    });

    test(
      'keeps text drawn near the right edge instead of clipping it',
      () async {
        final source = await buildDocument(1);
        final edited = await PdfService.renderTextAnnotation(
          source,
          0,
          'EDGE',
          const Offset(500, 300),
          Colors.black,
          12,
        );
        expect(textOnPage(edited, 0), contains('EDGE'));
      },
    );
  });

  group('renderHighlightAnnotation', () {
    test('adds one annotation per rect, on the requested page', () async {
      final source = await buildDocument(3);
      final edited = await PdfService.renderHighlightAnnotation(
        source,
        1,
        const [
          HighlightRect(
            bounds: Rect.fromLTRB(50, 50, 200, 70),
            color: Colors.yellow,
          ),
          HighlightRect(
            bounds: Rect.fromLTRB(50, 90, 200, 110),
            color: Colors.green,
          ),
        ],
      );

      expect(annotationCountOnPage(edited, 1), 2);
      expect(annotationCountOnPage(edited, 0), 0);
      expect(annotationCountOnPage(edited, 2), 0);
    });

    test('skips zero-area rects', () async {
      final source = await buildDocument(1);
      final edited = await PdfService.renderHighlightAnnotation(
        source,
        0,
        const [
          HighlightRect(
            bounds: Rect.fromLTRB(50, 50, 50, 50),
            color: Colors.yellow,
          ),
          HighlightRect(
            bounds: Rect.fromLTRB(10, 10, 100, 30),
            color: Colors.yellow,
          ),
        ],
      );
      expect(annotationCountOnPage(edited, 0), 1);
    });

    test('rejects an out-of-range page', () async {
      final source = await buildDocument(1);
      expect(
        () => PdfService.renderHighlightAnnotation(source, 5, const [
          HighlightRect(
            bounds: Rect.fromLTRB(0, 0, 10, 10),
            color: Colors.yellow,
          ),
        ]),
        throwsA(isA<PdfEditException>()),
      );
    });
  });

  group('renderDrawAnnotation', () {
    test('produces a document that still parses and grows in size', () async {
      final source = await buildDocument(2);
      final edited = await PdfService.renderDrawAnnotation(source, 1, [
        DrawStroke(
          points: List.generate(60, (i) => Offset(50.0 + i * 3, 100.0 + i)),
          color: Colors.blue,
          width: 3,
        ),
      ]);

      expect(edited.length, greaterThan(source.length));
      // Content is intact and nothing leaked onto the other page.
      expect(textOnPage(edited, 1), contains('MARKER2'));
      expect(textOnPage(edited, 0), contains('MARKER1'));
    });

    test('ignores strokes with fewer than two points', () async {
      final source = await buildDocument(1);
      final edited = await PdfService.renderDrawAnnotation(source, 0, [
        DrawStroke(
          points: const [Offset(10, 10)],
          color: Colors.blue,
          width: 2,
        ),
      ]);
      expect(() => textOnPage(edited, 0), returnsNormally);
    });

    test('rejects an out-of-range page', () async {
      final source = await buildDocument(1);
      expect(
        () => PdfService.renderDrawAnnotation(source, 3, [
          DrawStroke(
            points: const [Offset(0, 0), Offset(10, 10)],
            color: Colors.blue,
            width: 1,
          ),
        ]),
        throwsA(isA<PdfEditException>()),
      );
    });
  });

  group('simplifyStroke', () {
    test('drops points closer than the threshold', () {
      // 100 points 0.5pt apart collapse to far fewer.
      final dense = List.generate(100, (i) => Offset(i * 0.5, 0));
      final simplified = PdfService.simplifyStroke(dense);
      expect(simplified.length, lessThan(dense.length));
      expect(simplified.length, greaterThan(1));
    });

    test('always preserves the exact endpoints', () {
      final dense = List.generate(100, (i) => Offset(i * 0.5, 0));
      final simplified = PdfService.simplifyStroke(dense);
      expect(simplified.first, dense.first);
      expect(simplified.last, dense.last);
    });

    test('keeps points that are far apart', () {
      const sparse = [Offset(0, 0), Offset(50, 0), Offset(100, 0)];
      expect(PdfService.simplifyStroke(sparse), sparse);
    });

    test('passes very short strokes through unchanged', () {
      const two = [Offset(0, 0), Offset(0.1, 0)];
      expect(PdfService.simplifyStroke(two), two);
      expect(PdfService.simplifyStroke(const []), isEmpty);
    });

    test('never returns a single point for a multi-point stroke', () {
      // A stroke drawn almost in place must still yield a drawable line
      // rather than collapsing to nothing.
      final tiny = List.generate(20, (i) => Offset(i * 0.01, 0));
      expect(PdfService.simplifyStroke(tiny).length, greaterThanOrEqualTo(2));
    });
  });

  group('renderRotatePages', () {
    test('turns only the pages it was given', () async {
      final source = await buildDocument(3);
      final edited = await PdfService.renderRotatePages(source, [1], 1);

      expect(rotationOfPage(edited, 0), PdfPageRotateAngle.rotateAngle0);
      expect(rotationOfPage(edited, 1), PdfPageRotateAngle.rotateAngle90);
      expect(rotationOfPage(edited, 2), PdfPageRotateAngle.rotateAngle0);
    });

    test('accumulates on top of the rotation already there', () async {
      final source = await buildDocument(1);
      final once = await PdfService.renderRotatePages(source, [0], 1);
      final twice = await PdfService.renderRotatePages(once, [0], 1);

      expect(rotationOfPage(twice, 0), PdfPageRotateAngle.rotateAngle180);
    });

    test('wraps back round rather than running off the end', () async {
      Uint8List bytes = await buildDocument(1);
      for (int i = 0; i < 4; i++) {
        bytes = await PdfService.renderRotatePages(bytes, [0], 1);
      }

      expect(rotationOfPage(bytes, 0), PdfPageRotateAngle.rotateAngle0);
    });

    test('rejects an out-of-range page before changing anything', () async {
      final source = await buildDocument(2);

      await expectLater(
        PdfService.renderRotatePages(source, [0, 5], 1),
        throwsA(isA<PdfEditException>()),
      );
    });
  });

  group('renderDeletePages', () {
    test('removes the requested pages and keeps the rest in order', () async {
      final source = await buildDocument(4);
      final edited = await PdfService.renderDeletePages(source, [0, 2]);

      expect(pageCountOf(edited), 2);
      expect(textOnPage(edited, 0), contains('MARKER2'));
      expect(textOnPage(edited, 1), contains('MARKER4'));
    });

    test('handles indices given out of order', () async {
      final source = await buildDocument(4);
      final edited = await PdfService.renderDeletePages(source, [3, 1]);

      expect(pageCountOf(edited), 2);
      expect(textOnPage(edited, 0), contains('MARKER1'));
      expect(textOnPage(edited, 1), contains('MARKER3'));
    });

    test('ignores a repeated index rather than deleting twice', () async {
      final source = await buildDocument(3);
      final edited = await PdfService.renderDeletePages(source, [1, 1]);

      expect(pageCountOf(edited), 2);
      expect(textOnPage(edited, 0), contains('MARKER1'));
      expect(textOnPage(edited, 1), contains('MARKER3'));
    });

    test('refuses to empty the document', () async {
      final source = await buildDocument(2);

      await expectLater(
        PdfService.renderDeletePages(source, [0, 1]),
        throwsA(isA<PdfEditException>()),
      );
    });

    test('rejects an out-of-range page', () async {
      final source = await buildDocument(2);

      await expectLater(
        PdfService.renderDeletePages(source, [7]),
        throwsA(isA<PdfEditException>()),
      );
    });
  });

  group('renderAppendImages', () {
    test('adds one page per image, after the existing ones', () async {
      final source = await buildDocument(2);
      final edited = await PdfService.renderAppendImages(source, [
        jpegOf(200, 300),
        jpegOf(300, 200),
      ]);

      expect(pageCountOf(edited), 4);
      expect(textOnPage(edited, 0), contains('MARKER1'));
      expect(textOnPage(edited, 1), contains('MARKER2'));
    });

    test('shapes each added page to its own image', () async {
      // A4 pages in, one portrait and one landscape scan appended: each added
      // page has to take the proportions of its image rather than inheriting
      // the document's.
      final source = await buildDocument(1);
      final edited = await PdfService.renderAppendImages(source, [
        jpegOf(200, 400),
        jpegOf(400, 200),
      ]);

      final Size portrait = pageSizeOf(edited, 1);
      final Size landscape = pageSizeOf(edited, 2);
      expect(portrait.height / portrait.width, closeTo(2.0, 0.05));
      expect(landscape.width / landscape.height, closeTo(2.0, 0.05));
    });

    test('rejects an empty batch', () async {
      final source = await buildDocument(1);

      await expectLater(
        PdfService.renderAppendImages(source, []),
        throwsA(isA<PdfEditException>()),
      );
    });
  });

  group('edits are non-destructive', () {
    test('the source bytes are left untouched', () async {
      final source = await buildDocument(2);
      final before = Uint8List.fromList(source);

      await PdfService.renderTextAnnotation(
        source,
        0,
        'NEW',
        const Offset(50, 50),
        Colors.red,
        14,
      );

      expect(source, before);
      expect(textOnPage(source, 0), isNot(contains('NEW')));
    });
  });
}
