import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/services/pdf_annotations.dart';
import 'package:pdf_viewer/services/pdf_service.dart';
import 'package:pdf_viewer/services/pdf_stamps.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

final Uint8List roboto = File(
  'assets/fonts/Roboto-Regular.ttf',
).readAsBytesSync();

Future<Uint8List> buildDocument(
  int pageCount, {
  PdfPageRotateAngle rotation = PdfPageRotateAngle.rotateAngle0,
}) async {
  final PdfDocument document = PdfDocument();
  document.pageSettings.rotate = rotation;
  for (int i = 0; i < pageCount; i++) {
    document.pages.add().graphics.drawString(
      'MARKER${i + 1}',
      PdfStandardFont(PdfFontFamily.helvetica, 20),
      bounds: const Rect.fromLTWH(40, 40, 300, 40),
    );
  }
  final Uint8List bytes = Uint8List.fromList(await document.save());
  document.dispose();
  return bytes;
}

T withDocument<T>(Uint8List bytes, T Function(PdfDocument) read) {
  final PdfDocument document = PdfDocument(inputBytes: bytes);
  try {
    return read(document);
  } finally {
    document.dispose();
  }
}

String textOnPage(Uint8List bytes, int pageIndex) => withDocument(
  bytes,
  (d) => PdfTextExtractor(
    d,
  ).extractText(startPageIndex: pageIndex, endPageIndex: pageIndex),
);

List<TextLine> linesOnPage(Uint8List bytes, int pageIndex) => withDocument(
  bytes,
  (d) => PdfTextExtractor(
    d,
  ).extractTextLines(startPageIndex: pageIndex, endPageIndex: pageIndex),
);

void main() {
  group('watermark', () {
    test('marks every page by default', () async {
      final Uint8List out = await PdfStamps.renderWatermark(
        await buildDocument(3),
        const WatermarkOptions(text: 'DRAFT'),
        roboto,
      );
      for (int i = 0; i < 3; i++) {
        expect(textOnPage(out, i), contains('DRAFT'));
        expect(textOnPage(out, i), contains('MARKER${i + 1}'));
      }
    });

    test('marks only the pages asked for', () async {
      final Uint8List out = await PdfStamps.renderWatermark(
        await buildDocument(3),
        const WatermarkOptions(text: 'DRAFT', pages: [1], tiled: true),
        roboto,
      );
      expect(textOnPage(out, 0), isNot(contains('DRAFT')));
      expect(textOnPage(out, 1), contains('DRAFT'));
      expect(textOnPage(out, 2), isNot(contains('DRAFT')));
    });

    test('keeps letters the standard fonts lack, and spaces as spaces', () async {
      final String word = 'CONFIDEN${String.fromCharCode(0x21A)}IAL';
      final Uint8List out = await PdfStamps.renderWatermark(
        await buildDocument(1),
        WatermarkOptions(text: '$word COPY', angle: 0),
        roboto,
      );
      expect(textOnPage(out, 0), contains('$word COPY'));
    });

    test('refuses empty text and pages past the end', () async {
      final Uint8List source = await buildDocument(1);
      await expectLater(
        PdfStamps.renderWatermark(
          source,
          const WatermarkOptions(text: '  '),
          roboto,
        ),
        throwsA(isA<PdfEditException>()),
      );
      await expectLater(
        PdfStamps.renderWatermark(
          source,
          const WatermarkOptions(text: 'X', pages: [4]),
          roboto,
        ),
        throwsA(isA<PdfEditException>()),
      );
    });
  });

  group('page numbers', () {
    test('numbers pages in order with the total', () async {
      final Uint8List out = await PdfStamps.renderPageNumbers(
        await buildDocument(3),
        const PageNumberOptions(style: PageNumberStyle.pageOfTotal),
        roboto,
      );
      for (int i = 0; i < 3; i++) {
        expect(textOnPage(out, i), contains('Page ${i + 1} of 3'));
      }
    });

    test('starts where told and skips pages left out', () async {
      final Uint8List out = await PdfStamps.renderPageNumbers(
        await buildDocument(3),
        const PageNumberOptions(
          style: PageNumberStyle.page,
          startAt: 5,
          pages: [1, 2],
        ),
        roboto,
      );
      expect(textOnPage(out, 0), isNot(contains('Page')));
      expect(textOnPage(out, 1), contains('Page 5'));
      expect(textOnPage(out, 2), contains('Page 6'));
    });

    test('sits in the corner it was given', () async {
      final Uint8List out = await PdfStamps.renderPageNumbers(
        await buildDocument(1),
        const PageNumberOptions(
          style: PageNumberStyle.page,
          position: StampPosition.bottomRight,
          margin: 30,
        ),
        roboto,
      );
      final Size page = withDocument(out, (d) => d.pages[0].size);
      final TextLine line = linesOnPage(
        out,
        0,
      ).firstWhere((l) => l.text.contains('Page 1'));
      expect(line.bounds.right, closeTo(page.width - 30, 4));
      expect(line.bounds.bottom, closeTo(page.height - 30, 6));
    });

    test('reads upright on a turned page', () async {
      final Uint8List source = await buildDocument(
        1,
        rotation: PdfPageRotateAngle.rotateAngle90,
      );
      final Uint8List out = await PdfStamps.renderPageNumbers(
        source,
        const PageNumberOptions(
          style: PageNumberStyle.page,
          position: StampPosition.topLeft,
          margin: 30,
        ),
        roboto,
      );
      // Top-left of the turned display is bottom-left of the page's own
      // space, and the line runs up the page there.
      final Size page = withDocument(out, (d) => d.pages[0].size);
      final TextLine line = linesOnPage(
        out,
        0,
      ).firstWhere((l) => RegExp(r'Page\s+1').hasMatch(l.text));
      expect(line.bounds.left, lessThan(60));
      expect(line.bounds.bottom, greaterThan(page.height - 80));
      expect(line.bounds.height, greaterThan(line.bounds.width));
    });
  });

  group('flatten', () {
    test('burns annotations into the page', () async {
      final Uint8List marked = await PdfService.renderHighlightAnnotation(
        await buildDocument(1),
        0,
        const [
          HighlightRect(
            bounds: Rect.fromLTWH(40, 40, 200, 30),
            color: Colors.yellow,
          ),
        ],
      );
      expect(await PdfStamps.countInteractive(marked), (1, 0));
      final Uint8List flat = await PdfStamps.renderFlatten(marked);
      expect(await PdfStamps.countInteractive(flat), (0, 0));
      expect(textOnPage(flat, 0), contains('MARKER1'));
    });

    test('burns form fields into the page with what was typed', () async {
      final PdfDocument document = PdfDocument();
      final PdfPage page = document.pages.add();
      document.form.fields.add(
        PdfTextBoxField(
          page,
          'name',
          const Rect.fromLTWH(40, 100, 200, 24),
          text: 'Ionel',
        ),
      );
      final Uint8List form = Uint8List.fromList(await document.save());
      document.dispose();

      expect((await PdfStamps.countInteractive(form)).$2, 1);
      final Uint8List flat = await PdfStamps.renderFlatten(form);
      expect((await PdfStamps.countInteractive(flat)).$2, 0);
      expect(textOnPage(flat, 0), contains('Ionel'));
    });
  });

  group('passwords', () {
    test('a protected document needs its password', () async {
      final Uint8List locked = await PdfStamps.renderProtect(
        await buildDocument(2),
        'secret',
      );
      expect(await PdfStamps.probe(locked), PdfLock.locked);
      expect(await PdfStamps.probe(locked, password: 'wrong'), PdfLock.locked);
      expect(await PdfStamps.probe(locked, password: 'secret'), PdfLock.open);
    });

    test('unlocking gives back a document that just opens', () async {
      final Uint8List locked = await PdfStamps.renderProtect(
        await buildDocument(2),
        'secret',
      );
      final Uint8List open = await PdfStamps.renderUnlock(locked, 'secret');
      expect(await PdfStamps.probe(open), PdfLock.open);
      expect(textOnPage(open, 1), contains('MARKER2'));
      await expectLater(
        PdfStamps.renderUnlock(locked, 'wrong'),
        throwsA(isA<PdfEditException>()),
      );
    });

    test('tells a plain document and junk apart from a locked one', () async {
      expect(await PdfStamps.probe(await buildDocument(1)), PdfLock.open);
      expect(
        await PdfStamps.probe(Uint8List.fromList(List.filled(64, 7))),
        PdfLock.unreadable,
      );
    });
  });

  group('blank document', () {
    test('has the pages and the paper asked for', () async {
      final Uint8List out = await PdfStamps.renderBlank(
        const Size(842, 595),
        3,
      );
      withDocument(out, (d) {
        expect(d.pages.count, 3);
        expect(d.pages[2].size.width, closeTo(842, 1));
        expect(d.pages[2].size.height, closeTo(595, 1));
      });
    });
  });

  group('text layer', () {
    test('puts recognised words where they were seen', () async {
      final Uint8List blank = await PdfStamps.renderBlank(
        const Size(595, 842),
        2,
      );
      final Uint8List out = await PdfStamps.renderTextLayer(blank, {
        1: const [
          TextLayerLine('Invoice number 42', Rect.fromLTWH(60, 100, 124, 16)),
          TextLayerLine('Total due', Rect.fromLTWH(60, 400, 48, 12)),
        ],
      }, roboto);
      expect(textOnPage(out, 0).trim(), isEmpty);
      expect(textOnPage(out, 1), contains('Invoice number 42'));
      final List<TextLine> lines = linesOnPage(out, 1);
      final TextLine first = lines.firstWhere(
        (l) => l.text.contains('Invoice'),
      );
      expect(first.bounds.left, closeTo(60, 3));
      expect(first.bounds.top, closeTo(100, 6));
      expect(first.bounds.width, closeTo(124, 10));
      expect(first.wordCollection.map((w) => w.text.trim()).where((w) => w.isNotEmpty), [
        'Invoice',
        'number',
        '42',
      ]);
      final TextLine second = lines.firstWhere((l) => l.text.contains('Total'));
      expect(second.bounds.top, closeTo(400, 6));
    });
  });

  group('text layer size', () {
    test('a page of uneven lines does not bloat the file', () async {
      final Uint8List blank = await PdfStamps.renderBlank(
        const Size(595, 842),
        1,
      );
      final Uint8List out = await PdfStamps.renderTextLayer(blank, {
        0: [
          for (int i = 0; i < 60; i++)
            TextLayerLine(
              'The quick brown fox jumps over line $i',
              Rect.fromLTWH(40, 20.0 + i * 13, 230 + i * 1.7, 9 + (i % 7) * 0.6),
            ),
        ],
      }, roboto);
      expect(textOnPage(out, 0), contains('jumps over line 59'));
      expect(out.length, lessThan(400 * 1024));
    });
  });

  group('shapes and notes', () {
    test('shapes are painted into the page, where every reader shows them', () async {
      final Uint8List source = await buildDocument(2);
      final Uint8List out = await PdfAnnotations.renderShapes(source, 1, const [
        ShapeMark(
          kind: ShapeKind.rectangle,
          start: Offset(50, 100),
          end: Offset(200, 180),
          color: Colors.red,
          width: 2,
        ),
        ShapeMark(
          kind: ShapeKind.ellipse,
          start: Offset(300, 300),
          end: Offset(220, 240),
          color: Colors.blue,
          width: 3,
        ),
        ShapeMark(
          kind: ShapeKind.arrow,
          start: Offset(60, 400),
          end: Offset(260, 460),
          color: Colors.black,
          width: 2,
        ),
        ShapeMark(
          kind: ShapeKind.line,
          start: Offset(60, 500),
          end: Offset(160, 500),
          color: Colors.black,
          width: 2,
        ),
      ]);
      expect(out.length, greaterThan(source.length));
      expect(textOnPage(out, 1), contains('MARKER2'));
      // Not annotations: the page renderer here would not draw those.
      expect(await PdfAnnotations.list(out), isEmpty);
      expect(await PdfStamps.countInteractive(out), (0, 0));
    });

    test('a slip of the finger draws nothing', () async {
      final Uint8List source = await buildDocument(1);
      const List<ShapeMark> slips = [
        ShapeMark(
          kind: ShapeKind.line,
          start: Offset(60, 500),
          end: Offset(61, 500),
          color: Colors.black,
          width: 2,
        ),
        ShapeMark(
          kind: ShapeKind.rectangle,
          start: Offset(60, 500),
          end: Offset(200, 501),
          color: Colors.black,
          width: 2,
        ),
      ];
      final Uint8List none = await PdfAnnotations.renderShapes(source, 0, slips);
      final Uint8List one = await PdfAnnotations.renderShapes(source, 0, [
        ...slips,
        const ShapeMark(
          kind: ShapeKind.ellipse,
          start: Offset(60, 100),
          end: Offset(200, 200),
          color: Colors.black,
          width: 2,
        ),
      ]);
      expect(one.length, greaterThan(none.length));
      await expectLater(
        PdfAnnotations.renderShapes(source, 3, slips),
        throwsA(isA<PdfEditException>()),
      );
    });

    test('a note keeps its words and its place', () async {
      final Uint8List out = await PdfAnnotations.renderNote(
        await buildDocument(1),
        0,
        const Offset(120, 240),
        ' Check this figure ',
      );
      final List<PdfMark> marks = await PdfAnnotations.list(out);
      expect(marks, hasLength(1));
      expect(marks.single.type, MarkType.note);
      expect(marks.single.text, 'Check this figure');
      // The viewer draws its icon from the box's corner and larger than
      // it, so the box sits up and left of the tap.
      final Rect icon =
          marks.single.bounds.topLeft & PdfAnnotations.noteIconSize;
      expect(icon.center.dx, closeTo(120, 2));
      expect(icon.center.dy, closeTo(240, 2));
      await expectLater(
        PdfAnnotations.renderNote(out, 0, Offset.zero, ' '),
        throwsA(isA<PdfEditException>()),
      );
    });

    test('the eraser removes one mark and leaves the rest', () async {
      Uint8List out = await PdfService.renderHighlightAnnotation(
        await buildDocument(1),
        0,
        const [
          HighlightRect(
            bounds: Rect.fromLTWH(40, 40, 200, 30),
            color: Colors.yellow,
          ),
        ],
      );
      out = await PdfAnnotations.renderNote(
        out,
        0,
        const Offset(300, 300),
        'Keep me',
      );
      List<PdfMark> marks = await PdfAnnotations.list(out);
      expect(marks.map((m) => m.type), [MarkType.highlight, MarkType.note]);

      out = await PdfAnnotations.renderRemove(out, 0, marks.first.index);
      marks = await PdfAnnotations.list(out);
      expect(marks.single.type, MarkType.note);
      expect(marks.single.text, 'Keep me');
      await expectLater(
        PdfAnnotations.renderRemove(out, 0, 7),
        throwsA(isA<PdfEditException>()),
      );
    });
  });

  group('highlighter', () {
    test('a see-through stroke is written like any other', () async {
      final Uint8List out = await PdfService.renderDrawAnnotation(
        await buildDocument(1),
        0,
        const [
          DrawStroke(
            points: [Offset(40, 60), Offset(120, 62), Offset(240, 60)],
            color: Colors.yellow,
            width: 16,
            opacity: 0.4,
          ),
        ],
      );
      expect(textOnPage(out, 0), contains('MARKER1'));
      expect(out.length, greaterThan(200));
    });
  });
}
