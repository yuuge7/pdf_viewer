import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_viewer/services/docx_writer.dart';
import 'package:pdf_viewer/services/pdf_page_geometry.dart';
import 'package:pdf_viewer/services/pdf_service.dart';
import 'package:pdf_viewer/services/pdf_tools.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// A document whose pages each carry their own marker, so tests can prove
/// where every page ended up.
Future<Uint8List> buildDocument(int pageCount, {String prefix = 'MARKER'}) async {
  final PdfDocument document = PdfDocument();
  for (int i = 0; i < pageCount; i++) {
    document.pages.add().graphics.drawString(
      '$prefix${i + 1}',
      PdfStandardFont(PdfFontFamily.helvetica, 20),
      bounds: const Rect.fromLTWH(40, 40, 300, 40),
    );
  }
  final bytes = Uint8List.fromList(await document.save());
  document.dispose();
  return bytes;
}

T withDocument<T>(Uint8List bytes, T Function(PdfDocument document) read) {
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

/// The marker on each page, in page order.
List<String> markers(Uint8List bytes, {String prefix = 'MARKER'}) =>
    withDocument(bytes, (d) {
      final extractor = PdfTextExtractor(d);
      return [
        for (int i = 0; i < d.pages.count; i++)
          RegExp('$prefix\\d+')
                  .firstMatch(
                    extractor.extractText(startPageIndex: i, endPageIndex: i),
                  )
                  ?.group(0) ??
              '',
      ];
    });

int pageCountOf(Uint8List bytes) => withDocument(bytes, (d) => d.pages.count);

PdfPageRotateAngle rotationOf(Uint8List bytes, int page) =>
    withDocument(bytes, (d) => d.pages[page].rotation);

Size pageSizeOf(Uint8List bytes, int page) =>
    withDocument(bytes, (d) => d.pages[page].size);

Uint8List jpegOf(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 200, 200));
  return img.encodeJpg(image);
}

void main() {
  group('longestIncreasingRun', () {
    test('finds the longest run already in order', () {
      final List<int> values = [0, 3, 1, 2, 4];
      final List<int> run = PdfService.longestIncreasingRun(values);
      expect(run.map((i) => values[i]).toList(), [0, 1, 2, 4]);
    });

    test('handles empty and reversed input', () {
      expect(PdfService.longestIncreasingRun(const []), isEmpty);
      expect(PdfService.longestIncreasingRun(const [3, 2, 1]), hasLength(1));
    });
  });

  group('renderLayout', () {
    test('rearranges pages into the requested order', () async {
      final source = await buildDocument(4);
      final out = await PdfService.renderLayout(source, const [
        PageSpec(OriginalPageSource(2)),
        PageSpec(OriginalPageSource(0)),
        PageSpec(OriginalPageSource(3)),
        PageSpec(OriginalPageSource(1)),
      ], const {});
      expect(markers(out), ['MARKER3', 'MARKER1', 'MARKER4', 'MARKER2']);
    });

    test('drops pages left out of the plan', () async {
      final source = await buildDocument(4);
      final out = await PdfService.renderLayout(source, const [
        PageSpec(OriginalPageSource(3)),
        PageSpec(OriginalPageSource(1)),
      ], const {});
      expect(markers(out), ['MARKER4', 'MARKER2']);
    });

    test('adds turns on top of each page', () async {
      final source = await buildDocument(3);
      final out = await PdfService.renderLayout(source, const [
        PageSpec(OriginalPageSource(0), quarterTurns: 1),
        PageSpec(OriginalPageSource(2), quarterTurns: 2),
        // Moved, so redrawn from a template; the turn must survive that too.
        PageSpec(OriginalPageSource(1), quarterTurns: 3),
      ], const {});
      expect(markers(out), ['MARKER1', 'MARKER3', 'MARKER2']);
      expect(rotationOf(out, 0), PdfPageRotateAngle.rotateAngle90);
      expect(rotationOf(out, 1), PdfPageRotateAngle.rotateAngle180);
      expect(rotationOf(out, 2), PdfPageRotateAngle.rotateAngle270);
    });

    test('inserts blank and image pages where asked', () async {
      final source = await buildDocument(2);
      final out = await PdfService.renderLayout(source, [
        const PageSpec(OriginalPageSource(0)),
        const PageSpec(BlankPageSource(Size(300, 400))),
        PageSpec(ImagePageSource(jpegOf(400, 200))),
        const PageSpec(OriginalPageSource(1)),
      ], const {});
      expect(pageCountOf(out), 4);
      expect(markers(out), ['MARKER1', '', '', 'MARKER2']);
      expect(pageSizeOf(out, 1).width, closeTo(300, 0.5));
      final Size image = pageSizeOf(out, 2);
      expect(image.width, greaterThan(image.height));
    });

    test('borrows pages from another document', () async {
      final source = await buildDocument(2);
      final other = await buildDocument(2, prefix: 'OTHER');
      final out = await PdfService.renderLayout(source, const [
        PageSpec(OriginalPageSource(0)),
        PageSpec(ForeignPageSource('other.pdf', 1)),
        PageSpec(OriginalPageSource(1)),
      ], {'other.pdf': other});
      expect(textOnPage(out, 1), contains('OTHER2'));
      expect(markers(out), ['MARKER1', '', 'MARKER2']);
    });

    test('page setup re-lays a page onto the chosen sheet', () async {
      final source = await buildDocument(2);
      final out = await PdfService.renderLayout(source, const [
        PageSpec(
          OriginalPageSource(0),
          setup: PageSetup(
            paper: PaperSize.letter,
            orientation: SetupOrientation.landscape,
          ),
        ),
        PageSpec(OriginalPageSource(1)),
      ], const {});
      expect(markers(out), ['MARKER1', 'MARKER2']);
      final Size sheet = pageSizeOf(out, 0);
      expect(sheet.width, closeTo(792, 0.5));
      expect(sheet.height, closeTo(612, 0.5));
    });

    test('page setup bakes a turned page upright onto the sheet', () async {
      final source = await buildDocument(1);
      final out = await PdfService.renderLayout(source, const [
        PageSpec(
          OriginalPageSource(0),
          quarterTurns: 1,
          setup: PageSetup(paper: PaperSize.a4),
        ),
      ], const {});
      // A portrait page turned a quarter displays landscape, so "auto" picks
      // a landscape sheet, and the turn is now in the content, not /Rotate.
      expect(rotationOf(out, 0), PdfPageRotateAngle.rotateAngle0);
      expect(pageSizeOf(out, 0).width, greaterThan(pageSizeOf(out, 0).height));
      // A clockwise quarter turn carries the top-left marker to the right.
      final Rect bounds = withDocument(
        out,
        (d) => PdfTextExtractor(d).extractTextLines().first.bounds,
      );
      expect(bounds.left, greaterThan(pageSizeOf(out, 0).width / 2));
    });

    test('a second copy of a kept page leaves the original interactive', () async {
      final annotated = await PdfService.renderHighlightAnnotation(
        await buildDocument(2),
        0,
        const [
          HighlightRect(bounds: Rect.fromLTWH(10, 10, 50, 20), color: Colors.red),
        ],
      );
      final out = await PdfService.renderLayout(annotated, const [
        PageSpec(OriginalPageSource(0)),
        PageSpec(OriginalPageSource(1)),
        PageSpec(OriginalPageSource(0)),
      ], const {});
      expect(markers(out), ['MARKER1', 'MARKER2', 'MARKER1']);
      // The kept first page still has its annotation as an annotation.
      expect(withDocument(out, (d) => d.pages[0].annotations.count), 1);
    });

    test('refuses an empty plan and out-of-range pages', () async {
      final source = await buildDocument(2);
      expect(
        () => PdfService.renderLayout(source, const [], const {}),
        throwsA(isA<PdfEditException>()),
      );
      expect(
        () => PdfService.renderLayout(source, const [
          PageSpec(OriginalPageSource(5)),
        ], const {}),
        throwsA(isA<PdfEditException>()),
      );
    });
  });

  group('renderSplit', () {
    test('produces one document per group', () async {
      final source = await buildDocument(5);
      final parts = await PdfService.renderSplit(source, const [
        [0, 1],
        [2],
        [3, 4],
      ]);
      expect(parts.map(markers).toList(), [
        ['MARKER1', 'MARKER2'],
        ['MARKER3'],
        ['MARKER4', 'MARKER5'],
      ]);
    });

    test('rejects an out-of-range page', () async {
      final source = await buildDocument(2);
      expect(
        () => PdfService.renderSplit(source, const [
          [7],
        ]),
        throwsA(isA<PdfEditException>()),
      );
    });
  });

  group('renderMerge', () {
    test('joins documents in order', () async {
      final a = await buildDocument(2, prefix: 'AAA');
      final b = await buildDocument(1, prefix: 'BBB');
      final out = await PdfService.renderMerge([a, b]);
      expect(pageCountOf(out), 3);
      expect(textOnPage(out, 0), contains('AAA1'));
      expect(textOnPage(out, 2), contains('BBB1'));
    });

    test('keeps the rotation of merged-in pages', () async {
      final a = await buildDocument(1);
      final b = await PdfService.renderRotatePages(
        await buildDocument(1),
        const [0],
        1,
      );
      final out = await PdfService.renderMerge([a, b]);
      expect(rotationOf(out, 1), PdfPageRotateAngle.rotateAngle90);
    });

    test('needs at least two documents', () async {
      expect(
        () async => PdfService.renderMerge([await buildDocument(1)]),
        throwsA(isA<PdfEditException>()),
      );
    });
  });

  group('renderCompact and renderImagePages', () {
    test('compacting keeps every page and its text', () async {
      final source = await buildDocument(3);
      final out = await PdfService.renderCompact(source);
      expect(markers(out), ['MARKER1', 'MARKER2', 'MARKER3']);
    });

    test('image pages take the sizes they are given, not the pixels', () async {
      final out = await PdfService.renderImagePages(
        [jpegOf(150, 300), jpegOf(300, 150)],
        const [Size(595, 842), Size(842, 595)],
      );
      expect(pageCountOf(out), 2);
      expect(pageSizeOf(out, 0).width, closeTo(595, 0.5));
      expect(pageSizeOf(out, 0).height, closeTo(842, 0.5));
      expect(pageSizeOf(out, 1).width, closeTo(842, 0.5));
    });
  });

  group('stamping', () {
    test('markup kinds all write an annotation', () async {
      final source = await buildDocument(1);
      final out = await PdfService.renderHighlightAnnotation(source, 0, const [
        HighlightRect(bounds: Rect.fromLTWH(10, 10, 50, 20), color: Colors.red),
        HighlightRect(
          bounds: Rect.fromLTWH(10, 40, 50, 20),
          color: Colors.blue,
          kind: MarkupKind.underline,
        ),
        HighlightRect(
          bounds: Rect.fromLTWH(10, 70, 50, 20),
          color: Colors.green,
          kind: MarkupKind.strikethrough,
        ),
      ]);
      expect(withDocument(out, (d) => d.pages[0].annotations.count), 3);
    });

    test('an image stamp keeps transparency and a turned page', () async {
      final source = await buildDocument(1);
      final img.Image signature = img.Image(
        width: 60,
        height: 20,
        numChannels: 4,
      );
      signature.setPixelRgba(5, 5, 0, 0, 0, 255);
      final out = await PdfService.renderImageStamp(
        source,
        0,
        img.encodePng(signature),
        const Rect.fromLTWH(100, 100, 120, 40),
        1,
      );
      expect(out.length, greaterThan(source.length));
      expect(textOnPage(out, 0), contains('MARKER1'));
    });

    test('an unreadable image is reported, not written', () async {
      final source = await buildDocument(1);
      expect(
        () => PdfService.renderImageStamp(
          source,
          0,
          Uint8List.fromList(const [1, 2, 3]),
          const Rect.fromLTWH(0, 0, 10, 10),
          0,
        ),
        throwsA(isA<PdfEditException>()),
      );
    });

    test('replacing text keeps the direction the line runs in', () async {
      // A landscape page stored the usual way: portrait paper, /Rotate 90,
      // and content drawn turned back so it reads upright on screen.
      final PdfDocument built = PdfDocument();
      built.pageSettings.margins.all = 0;
      final PdfPage page = built.pages.add();
      page.graphics
        ..save()
        ..translateTransform(0, 842)
        ..rotateTransform(-90)
        ..drawString(
          'UPRIGHTLINE',
          PdfStandardFont(PdfFontFamily.helvetica, 20),
          bounds: const Rect.fromLTWH(40, 40, 300, 40),
        )
        ..restore();
      final Uint8List drawn = Uint8List.fromList(await built.save());
      built.dispose();
      final Uint8List source = await PdfService.renderRotatePages(
        drawn,
        const [0],
        1,
      );

      Rect lineOf(Uint8List bytes, String text) => withDocument(
        bytes,
        (d) => PdfTextExtractor(d)
            .extractTextLines()
            .firstWhere((l) => l.text.contains(text))
            .bounds,
      );
      final Rect original = lineOf(source, 'UPRIGHT');
      // Runs up the page in its own space.
      expect(original.height, greaterThan(original.width));

      final out = await PdfService.renderReplaceText(
        source,
        0,
        original,
        'NEWTEXT',
        20,
      );
      final Rect replaced = lineOf(out, 'NEWTEXT');
      expect(replaced.height, greaterThan(replaced.width));
    });

    test('replacing text writes the new line', () async {
      final source = await buildDocument(1);
      final out = await PdfService.renderReplaceText(
        source,
        0,
        const Rect.fromLTRB(80, 83.6, 165.6, 103.6),
        'CHANGED',
        20,
      );
      expect(textOnPage(out, 0), contains('CHANGED'));
    });
  });

  group('page ranges', () {
    test('parses single pages and ranges in the order written', () {
      expect(PdfTools.parseRanges('1-3, 5 ,8-7', 10), [
        [0, 1, 2],
        [4],
        [6, 7],
      ]);
    });

    test('rejects nonsense and pages past the end', () {
      expect(() => PdfTools.parseRanges('a-b', 5), throwsFormatException);
      expect(() => PdfTools.parseRanges('2-9', 5), throwsFormatException);
      expect(() => PdfTools.parseRanges(' , ', 5), throwsFormatException);
      expect(() => PdfTools.parseRanges('0', 5), throwsFormatException);
    });

    test('chunks cover every page exactly once', () {
      expect(PdfTools.chunk(5, 2), [
        [0, 1],
        [2, 3],
        [4],
      ]);
      expect(PdfTools.chunk(3, 0), [
        [0],
        [1],
        [2],
      ]);
    });
  });

  group('text', () {
    test('extracts lines with their page and position', () async {
      final Directory dir = await Directory.systemTemp.createTemp('pdftools');
      addTearDown(() => dir.delete(recursive: true));
      final File file = File('${dir.path}/doc.pdf')
        ..writeAsBytesSync(await buildDocument(2));
      final pages = await PdfTools.extractText(file);
      expect(pages, hasLength(2));
      expect(pages[1].lines.single.text, contains('MARKER2'));
      // The 40pt offset plus the default 40pt page margin.
      expect(pages[1].lines.single.bounds.left, closeTo(80, 1));
      expect(pages[1].turn, PdfPageTurn.none);
    });

    test('groups lines into paragraphs by gaps and indents', () {
      PdfTextLine line(String text, double top, {double left = 40}) =>
          PdfTextLine(
            text: text,
            bounds: Rect.fromLTWH(left, top, 200, 12),
            fontSize: 12,
          );
      final page = PdfTextPage(
        index: 0,
        size: const Size(595, 842),
        turn: PdfPageTurn.none,
        lines: [
          line('first line of a para-', 100),
          line('graph continues', 113),
          line('after a gap', 160),
          line('indented', 173, left: 120),
        ],
      );
      final paragraphs = PdfTools.paragraphsOf(page);
      expect(paragraphs.map((p) => p.text).toList(), [
        'first line of a para-graph continues',
        'after a gap',
        'indented',
      ]);
    });
  });

  group('DocxWriter', () {
    Archive unzip(Uint8List bytes) => ZipDecoder().decodeBytes(bytes);
    String part(Archive archive, String name) =>
        utf8.decode(archive.findFile(name)!.content as List<int>);

    test('writes the parts Word needs', () {
      final Archive archive = unzip(
        DocxWriter.build(const [
          DocxParagraph([DocxRun('Hello', bold: true)]),
        ], title: 'T'),
      );
      for (final String name in [
        '[Content_Types].xml',
        '_rels/.rels',
        'word/document.xml',
        'word/_rels/document.xml.rels',
        'word/styles.xml',
      ]) {
        expect(archive.findFile(name), isNotNull, reason: name);
      }
      final String body = part(archive, 'word/document.xml');
      expect(body, contains('Hello'));
      expect(body, contains('<w:b/>'));
    });

    test('escapes markup and drops characters XML cannot hold', () {
      final Archive archive = unzip(
        DocxWriter.build(const [
          DocxParagraph([DocxRun('a < b & "c"\u0001')]),
        ]),
      );
      final String body = part(archive, 'word/document.xml');
      expect(body, contains('a &lt; b &amp; &quot;c&quot;'));
      expect(body, isNot(contains('\u0001')));
    });

    test('embeds pictures with a relationship and a content type', () {
      final Archive archive = unzip(
        DocxWriter.build([
          DocxImage(jpegOf(20, 10), format: 'jpeg', widthPx: 20, heightPx: 10),
          const DocxPageBreak(),
        ]),
      );
      expect(archive.findFile('word/media/image1.jpeg'), isNotNull);
      expect(
        part(archive, 'word/_rels/document.xml.rels'),
        contains('media/image1.jpeg'),
      );
      expect(part(archive, '[Content_Types].xml'), contains('image/jpeg'));
      expect(part(archive, 'word/document.xml'), contains('w:type="page"'));
    });
  });

  group('page rotation helpers', () {
    test('rotatePageRect undoes unrotatePageRect for every turn', () {
      const Size size = Size(595, 842);
      const Rect display = Rect.fromLTWH(30, 50, 100, 20);
      for (final PdfPageTurn turn in PdfPageTurn.values) {
        final Rect page = unrotatePageRect(display, size, turn);
        final Rect back = rotatePageRect(page, size, turn);
        expect(back.left, closeTo(display.left, 0.001), reason: '$turn');
        expect(back.top, closeTo(display.top, 0.001), reason: '$turn');
        expect(back.width, closeTo(display.width, 0.001), reason: '$turn');
        expect(back.height, closeTo(display.height, 0.001), reason: '$turn');
      }
    });
  });
}
