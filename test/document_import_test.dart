import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_viewer/services/document_import.dart';
import 'package:pdf_viewer/services/docx_reader.dart';
import 'package:pdf_viewer/services/docx_writer.dart';
import 'package:pdf_viewer/services/flow_document.dart';
import 'package:pdf_viewer/services/flow_renderer.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// The bundled typeface, read straight off disk: the asset bundle is a
/// platform channel, and none of this needs one.
FlowFonts loadFonts() {
  Uint8List cut(String name) =>
      File('assets/fonts/Roboto-$name.ttf').readAsBytesSync();
  return FlowFonts(
    regular: cut('Regular'),
    bold: cut('Bold'),
    italic: cut('Italic'),
    boldItalic: cut('BoldItalic'),
  );
}

const String _namespaces =
    'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
    'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
    'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
    'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
    'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" '
    'xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape" '
    'xmlns:v="urn:schemas-microsoft-com:vml"';

/// A .docx with [body] as the contents of `w:body`, and whichever side
/// parts are given.
Uint8List docxOf(
  String body, {
  String? styles,
  String? numbering,
  String? relationships,
  Map<String, Uint8List> media = const {},
}) {
  final Archive archive = Archive();
  void add(String name, String xml) => archive.addFile(
    ArchiveFile.string(name, '<?xml version="1.0" encoding="UTF-8"?>$xml'),
  );
  add(
    'word/document.xml',
    '<w:document $_namespaces><w:body>$body</w:body></w:document>',
  );
  if (styles != null) {
    add('word/styles.xml', '<w:styles $_namespaces>$styles</w:styles>');
  }
  if (numbering != null) {
    add(
      'word/numbering.xml',
      '<w:numbering $_namespaces>$numbering</w:numbering>',
    );
  }
  if (relationships != null) {
    add(
      'word/_rels/document.xml.rels',
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '$relationships</Relationships>',
    );
  }
  media.forEach(
    (name, bytes) => archive.addFile(ArchiveFile.bytes('word/$name', bytes)),
  );
  return ZipEncoder().encodeBytes(archive);
}

String p(String text, {String properties = ''}) =>
    '<w:p>$properties<w:r><w:t xml:space="preserve">$text</w:t></w:r></w:p>';

Uint8List jpegOf(int width, int height) =>
    img.encodeJpg(img.Image(width: width, height: height));

List<FlowParagraph> paragraphsOf(FlowDocument document) =>
    document.blocks.whereType<FlowParagraph>().toList();

T withPdf<T>(Uint8List bytes, T Function(PdfDocument document) read) {
  final PdfDocument document = PdfDocument(inputBytes: bytes);
  try {
    return read(document);
  } finally {
    document.dispose();
  }
}

int pageCountOf(Uint8List pdf) => withPdf(pdf, (d) => d.pages.count);

String textOf(Uint8List pdf, [int? page]) => withPdf(
  pdf,
  (d) => page == null
      ? PdfTextExtractor(d).extractText()
      : PdfTextExtractor(d).extractText(startPageIndex: page, endPageIndex: page),
);

List<TextLine> linesOf(Uint8List pdf) =>
    withPdf(pdf, (d) => PdfTextExtractor(d).extractTextLines());

void main() {
  final FlowFonts fonts = loadFonts();

  group('DocumentImport.sniff', () {
    Uint8List bytes(List<int> values) => Uint8List.fromList(values);
    Uint8List ascii(String text) => Uint8List.fromList(latin1.encode(text));

    test('knows a PDF by its header, whatever it is called', () {
      expect(
        DocumentImport.sniff(
          ascii('%PDF-1.7\n...'),
          name: 'attachment.bin',
          mimeType: 'application/octet-stream',
        ),
        ImportKind.pdf,
      );
    });

    test('allows junk ahead of the PDF header', () {
      expect(
        DocumentImport.sniff(ascii('\n\n  garbage %PDF-1.4')),
        ImportKind.pdf,
      );
    });

    test('takes a zip container for a Word file', () {
      expect(
        DocumentImport.sniff(bytes([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])),
        ImportKind.word,
      );
    });

    test('knows pictures by their signatures', () {
      expect(
        DocumentImport.sniff(bytes([0xFF, 0xD8, 0xFF, 0xE0])),
        ImportKind.image,
      );
      expect(
        DocumentImport.sniff(bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])),
        ImportKind.image,
      );
      expect(DocumentImport.sniff(ascii('GIF89a')), ImportKind.image);
      expect(
        DocumentImport.sniff(ascii('RIFF\x00\x00\x00\x00WEBPVP8 ')),
        ImportKind.image,
      );
    });

    test('only trusts the two-byte BMP signature with a second opinion', () {
      expect(
        DocumentImport.sniff(ascii('BM\x00\x00'), name: 'scan.bmp'),
        ImportKind.image,
      );
      // A note that happens to start with those letters is still a note.
      expect(
        DocumentImport.sniff(
          ascii('BMW service booked for Monday'),
          name: 'note.txt',
          mimeType: 'text/plain',
        ),
        ImportKind.text,
      );
    });

    test('falls back on the label for text, which has no signature', () {
      expect(
        DocumentImport.sniff(ascii('hello'), mimeType: 'text/plain'),
        ImportKind.text,
      );
      expect(
        DocumentImport.sniff(ascii('hello'), name: 'README.TXT'),
        ImportKind.text,
      );
      expect(DocumentImport.sniff(ascii('hello')), ImportKind.unsupported);
    });

    test('does not believe a text label on a binary file', () {
      expect(
        DocumentImport.sniff(bytes([1, 2, 0, 3]), mimeType: 'text/plain'),
        ImportKind.unsupported,
      );
      // ...unless the zero bytes are UTF-16, which announces itself.
      expect(
        DocumentImport.sniff(
          bytes([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00]),
          mimeType: 'text/plain',
        ),
        ImportKind.text,
      );
    });

    test('lets a headerless file that claims to be a PDF through', () {
      // The viewer reports a damaged PDF better than "unsupported" would.
      expect(
        DocumentImport.sniff(ascii('not really'), name: 'broken.pdf'),
        ImportKind.pdf,
      );
    });

    test('reads the kind off the start of a file', () async {
      final Directory temp = Directory.systemTemp.createTempSync('sniff');
      addTearDown(() => temp.deleteSync(recursive: true));
      final File file = File('${temp.path}/x')
        ..writeAsBytesSync(docxOf(p('hi')));
      expect(await DocumentImport.kindOf(file, name: 'x'), ImportKind.word);
    });
  });

  group('plain text', () {
    test('decodes by byte-order mark, then UTF-8, then Latin-1', () {
      expect(
        FlowDocument.decodeText(
          Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('ș')]),
        ),
        'ș',
      );
      expect(
        FlowDocument.decodeText(
          Uint8List.fromList([0xFF, 0xFE, 0x68, 0x00, 0x19, 0x02]),
        ),
        'hș',
      );
      expect(
        FlowDocument.decodeText(
          Uint8List.fromList([0xFE, 0xFF, 0x00, 0x68, 0x02, 0x19]),
        ),
        'hș',
      );
      expect(
        FlowDocument.decodeText(Uint8List.fromList(utf8.encode('țară'))),
        'țară',
      );
      // 0xE9 alone is not valid UTF-8; it is é in Latin-1.
      expect(
        FlowDocument.decodeText(Uint8List.fromList([0x63, 0x61, 0x66, 0xE9])),
        'café',
      );
    });

    test('makes a paragraph of every line, blank ones included', () {
      final FlowDocument document = FlowDocument.plainText(
        'one\r\ntwo\n\nfour\n',
      );
      expect(paragraphsOf(document).map((p) => p.text).toList(), [
        'one',
        'two',
        '',
        'four',
      ]);
    });

    test('comes out as a PDF with its lines in order', () async {
      final Uint8List pdf = await DocumentImport.renderText(
        Uint8List.fromList(utf8.encode('first line\nsecond line\nthird')),
        fonts,
        title: 'notes',
      );
      final List<String> lines = linesOf(pdf).map((l) => l.text).toList();
      expect(lines, ['first line', 'second line', 'third']);
      expect(
        withPdf(pdf, (d) => d.documentInformation.title),
        'notes',
      );
    });
  });

  group('DocxReader', () {
    test('refuses what is not a Word document', () {
      expect(
        () => DocxReader.read(Uint8List.fromList(utf8.encode('plain'))),
        throwsFormatException,
      );
      // A zip, but of something else.
      final Archive other = Archive()
        ..addFile(ArchiveFile.string('xl/workbook.xml', '<workbook/>'));
      expect(
        () => DocxReader.read(ZipEncoder().encodeBytes(other)),
        throwsFormatException,
      );
      expect(
        () => DocxReader.read(
          docxOf('<w:p><w:r><w:t>unclosed</w:r></w:p>'),
        ),
        throwsFormatException,
      );
    });

    test('reads back what DocxWriter wrote', () {
      final Uint8List picture = jpegOf(40, 20);
      final FlowDocument document = DocxReader.read(
        DocxWriter.build([
          const DocxParagraph([
            DocxRun('Title', sizePt: 20, bold: true),
            DocxRun(' and more', italic: true),
          ], indentPt: 18, spaceBeforePt: 6),
          const DocxPageBreak(),
          DocxImage(picture, format: 'jpeg', widthPx: 40, heightPx: 20),
          const DocxParagraph([DocxRun('after')]),
        ]),
      );

      final FlowParagraph first = document.blocks.first as FlowParagraph;
      expect(first.text, 'Title and more');
      expect(first.runs[0].sizePt, 20);
      expect(first.runs[0].bold, isTrue);
      expect(first.runs[1].italic, isTrue);
      // The writer's document default.
      expect(first.runs[1].sizePt, 11);
      expect(first.indentPt, 18);
      expect(first.spaceBeforePt, 6);

      expect(document.blocks[1], isA<FlowPageBreak>());
      final FlowImage image = document.blocks[2] as FlowImage;
      expect(image.bytes, picture);
      // 40 px at 96 dpi.
      expect(image.widthPt, closeTo(30, 0.01));
      expect(image.heightPt, closeTo(15, 0.01));
      expect((document.blocks[3] as FlowParagraph).text, 'after');

      // A4 with one-inch margins, as written.
      expect(document.pageWidth, closeTo(595.3, 0.01));
      expect(document.pageHeight, closeTo(841.9, 0.01));
      expect(document.marginLeft, 72);
    });

    test('resolves formatting through styles and document defaults', () {
      final FlowDocument document = DocxReader.read(
        docxOf(
          '${p('Heading', properties: '<w:pPr><w:pStyle w:val="H1"/></w:pPr>')}'
          '${p('Body')}'
          '<w:p><w:pPr><w:pStyle w:val="H1"/><w:jc w:val="right"/></w:pPr>'
          '<w:r><w:rPr><w:b w:val="0"/><w:rStyle w:val="Link"/></w:rPr>'
          '<w:t>Override</w:t></w:r></w:p>',
          styles:
              '<w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="24"/></w:rPr></w:rPrDefault>'
              '<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="360" w:lineRule="auto"/></w:pPr></w:pPrDefault>'
              '</w:docDefaults>'
              '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"/>'
              '<w:style w:type="paragraph" w:styleId="Base"><w:basedOn w:val="Normal"/>'
              '<w:pPr><w:jc w:val="center"/></w:pPr><w:rPr><w:b/><w:color w:val="2F5496"/></w:rPr></w:style>'
              '<w:style w:type="paragraph" w:styleId="H1"><w:basedOn w:val="Base"/>'
              '<w:pPr><w:spacing w:before="240"/></w:pPr><w:rPr><w:sz w:val="32"/></w:rPr></w:style>'
              '<w:style w:type="character" w:styleId="Link"><w:rPr><w:u w:val="single"/><w:color w:val="auto"/></w:rPr></w:style>',
        ),
      );
      final List<FlowParagraph> paragraphs = paragraphsOf(document);

      final FlowParagraph heading = paragraphs[0];
      expect(heading.runs.single.sizePt, 16);
      expect(heading.runs.single.bold, isTrue);
      expect(heading.runs.single.color, 0x2F5496);
      expect(heading.align, FlowAlign.center);
      expect(heading.spaceBeforePt, 12);
      expect(heading.spaceAfterPt, 8);
      expect(heading.lineHeight, 1.5);

      final FlowParagraph body = paragraphs[1];
      expect(body.runs.single.sizePt, 12);
      expect(body.runs.single.bold, isFalse);
      expect(body.runs.single.color, isNull);
      expect(body.align, FlowAlign.left);

      // What the paragraph and the run say directly beats their styles.
      final FlowParagraph override = paragraphs[2];
      expect(override.align, FlowAlign.right);
      expect(override.runs.single.bold, isFalse);
      expect(override.runs.single.underline, isTrue);
      expect(override.runs.single.color, isNull);
    });

    test('closes up neighbours of a style that asks for it', () {
      String item(String text) =>
          p(text, properties: '<w:pPr><w:pStyle w:val="Item"/></w:pPr>');
      final FlowDocument document = DocxReader.read(
        docxOf(
          '${p('intro')}${item('a')}${item('b')}${item('c')}${p('outro')}'
          '<w:tbl><w:tr><w:tc>${item('in a cell')}</w:tc></w:tr></w:tbl>'
          '${item('after the table')}',
          styles:
              '<w:docDefaults><w:pPrDefault><w:pPr><w:spacing w:before="120" w:after="160"/>'
              '</w:pPr></w:pPrDefault></w:docDefaults>'
              '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"/>'
              '<w:style w:type="paragraph" w:styleId="Item"><w:pPr><w:contextualSpacing/></w:pPr></w:style>',
        ),
      );
      final List<FlowParagraph> paragraphs = paragraphsOf(document);
      List<double> spacing(int i) => [
        paragraphs[i].spaceBeforePt,
        paragraphs[i].spaceAfterPt,
      ];
      // Ordinary paragraphs keep both; "Normal" did not ask to close up.
      expect(spacing(0), [6, 8]);
      // The run of items keeps only its outer edges.
      expect(spacing(1), [6, 0]);
      expect(spacing(2), [0, 0]);
      expect(spacing(3), [0, 8]);
      expect(spacing(4), [6, 8]);
      // Same style, but a table away: not a neighbour.
      expect(spacing(5), [6, 8]);
    });

    test('survives styles that are based on each other', () {
      final FlowDocument document = DocxReader.read(
        docxOf(
          p('x', properties: '<w:pPr><w:pStyle w:val="A"/></w:pPr>'),
          styles:
              '<w:style w:type="paragraph" w:styleId="A"><w:basedOn w:val="B"/></w:style>'
              '<w:style w:type="paragraph" w:styleId="B"><w:basedOn w:val="A"/><w:rPr><w:i/></w:rPr></w:style>',
        ),
      );
      expect(paragraphsOf(document).single.runs.single.italic, isTrue);
    });

    test('numbers and bullets lists', () {
      String item(String text, int numId, int level) => p(
        text,
        properties:
            '<w:pPr><w:numPr><w:ilvl w:val="$level"/><w:numId w:val="$numId"/></w:numPr></w:pPr>',
      );
      final FlowDocument document = DocxReader.read(
        docxOf(
          item('one', 1, 0) +
              item('two', 1, 0) +
              item('nested', 1, 1) +
              item('nested again', 1, 1) +
              item('three', 1, 0) +
              item('restarted nest', 1, 1) +
              item('bullet', 2, 0) +
              item('fifth', 3, 0) +
              p('plain'),
          numbering:
              '<w:abstractNum w:abstractNumId="10">'
              '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/>'
              '<w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>'
              '<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2)"/>'
              '<w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr></w:lvl>'
              '</w:abstractNum>'
              '<w:abstractNum w:abstractNumId="11">'
              '<w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="\uF0B7"/></w:lvl>'
              '</w:abstractNum>'
              '<w:abstractNum w:abstractNumId="12">'
              '<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="upperRoman"/><w:lvlText w:val="(%1)"/></w:lvl>'
              '</w:abstractNum>'
              '<w:num w:numId="1"><w:abstractNumId w:val="10"/></w:num>'
              '<w:num w:numId="2"><w:abstractNumId w:val="11"/></w:num>'
              '<w:num w:numId="3"><w:abstractNumId w:val="12"/>'
              '<w:lvlOverride w:ilvl="0"><w:startOverride w:val="5"/></w:lvlOverride></w:num>',
        ),
      );
      final List<FlowParagraph> paragraphs = paragraphsOf(document);
      expect(paragraphs.map((p) => p.text).toList(), [
        '1.\tone',
        '2.\ttwo',
        '2.a)\tnested',
        '2.b)\tnested again',
        '3.\tthree',
        '3.a)\trestarted nest',
        '•\tbullet',
        '(V)\tfifth',
        'plain',
      ]);
      // The level's own indent: text at half an inch, number hung left of it.
      expect(paragraphs[0].indentPt, 36);
      expect(paragraphs[0].firstLinePt, -18);
      expect(paragraphs[2].indentPt, 72);
      expect(paragraphs.last.indentPt, 0);
    });

    test('keeps what Word shows and drops what it hides', () {
      final FlowDocument document = DocxReader.read(
        docxOf(
          '<w:p>'
          '<w:r><w:t xml:space="preserve">Kept </w:t></w:r>'
          '<w:hyperlink r:id="rId9"><w:r><w:t xml:space="preserve">link </w:t></w:r></w:hyperlink>'
          '<w:ins><w:r><w:t xml:space="preserve">inserted </w:t></w:r></w:ins>'
          '<w:del><w:r><w:delText>deleted </w:delText></w:r></w:del>'
          '<w:r><w:rPr><w:vanish/></w:rPr><w:t>hidden </w:t></w:r>'
          '<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
          '<w:r><w:instrText> PAGE </w:instrText></w:r>'
          '<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
          '<w:r><w:t>7</w:t></w:r>'
          '<w:r><w:fldChar w:fldCharType="end"/></w:r>'
          '<w:r><w:tab/><w:t>tabbed</w:t><w:br/><w:t>next</w:t><w:noBreakHyphen/></w:r>'
          '<w:r><w:rPr><w:caps/></w:rPr><w:t>loud</w:t></w:r>'
          '</w:p>'
          '<w:sdt><w:sdtContent>${p('in a content control')}</w:sdtContent></w:sdt>',
        ),
      );
      final List<FlowParagraph> paragraphs = paragraphsOf(document);
      expect(
        paragraphs[0].text,
        'Kept link inserted 7\ttabbed\nnext-LOUD',
      );
      expect(paragraphs[1].text, 'in a content control');
    });

    test('matches elements by local name, whatever the prefix', () {
      final Archive archive = Archive()
        ..addFile(
          ArchiveFile.string(
            'word/document.xml',
            '<x:document xmlns:x="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
                '<x:body><x:p><x:r><x:rPr><x:b/></x:rPr><x:t>prefixed</x:t></x:r></x:p></x:body>'
                '</x:document>',
          ),
        );
      final FlowDocument document = DocxReader.read(
        ZipEncoder().encodeBytes(archive),
      );
      final FlowRun run = paragraphsOf(document).single.runs.single;
      expect(run.text, 'prefixed');
      expect(run.bold, isTrue);
    });

    test('splits a paragraph at a page break without leaving blank lines', () {
      final FlowDocument document = DocxReader.read(
        docxOf(
          '<w:p><w:r><w:t>before</w:t><w:br w:type="page"/><w:t>after</w:t></w:r></w:p>'
          '<w:p><w:r><w:br w:type="page"/></w:r></w:p>'
          '${p('next', properties: '<w:pPr><w:pageBreakBefore/></w:pPr>')}'
          '<w:p/>',
        ),
      );
      expect(
        document.blocks
            .map((b) => b is FlowParagraph ? b.text : '<break>')
            .toList(),
        ['before', '<break>', 'after', '<break>', '<break>', 'next', ''],
      );
    });

    test('reads tables: grid, spans, merges, shading and borders', () {
      final FlowDocument document = DocxReader.read(
        docxOf(
          '<w:tbl>'
          '<w:tblPr><w:tblBorders><w:top w:val="single"/></w:tblBorders></w:tblPr>'
          '<w:tblGrid><w:gridCol w:w="2000"/><w:gridCol w:w="4000"/></w:tblGrid>'
          '<w:tr>'
          '<w:tc><w:tcPr><w:vMerge w:val="restart"/><w:shd w:fill="D9D9D9"/></w:tcPr>${p('a')}</w:tc>'
          '<w:tc>${p('b')}${p('b2')}</w:tc>'
          '</w:tr>'
          '<w:tr>'
          '<w:tc><w:tcPr><w:vMerge/></w:tcPr>${p('ghost')}</w:tc>'
          '<w:tc>${p('c')}</w:tc>'
          '</w:tr>'
          '<w:tr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr>${p('wide')}</w:tc></w:tr>'
          '</w:tbl>'
          '<w:tbl><w:tr><w:tc>${p('layout only')}</w:tc></w:tr></w:tbl>'
          '<w:tbl><w:tblPr><w:tblStyle w:val="Grid"/></w:tblPr>'
          '<w:tr><w:tc>${p('styled')}</w:tc></w:tr></w:tbl>',
          styles:
              '<w:style w:type="table" w:styleId="Grid"><w:tblPr><w:tblBorders>'
              '<w:insideH w:val="single"/></w:tblBorders></w:tblPr></w:style>',
        ),
      );
      final List<FlowTable> tables = document.blocks
          .whereType<FlowTable>()
          .toList();
      String cellText(FlowCell cell) =>
          cell.blocks.whereType<FlowParagraph>().map((p) => p.text).join('|');

      final FlowTable table = tables[0];
      expect(table.columnWidths, [100, 200]);
      expect(table.bordered, isTrue);
      expect(table.rows[0].cells.map(cellText).toList(), ['a', 'b|b2']);
      expect(table.rows[0].cells[0].fill, 0xD9D9D9);
      // The continuation of a vertical merge is drawn empty.
      expect(table.rows[1].cells.map(cellText).toList(), ['', 'c']);
      expect(table.rows[2].cells.single.span, 2);

      expect(tables[1].bordered, isFalse);
      expect(tables[1].columnWidths, isEmpty);
      expect(tables[2].bordered, isTrue);
    });

    test('finds pictures and text boxes, and reads each only once', () {
      final Uint8List picture = jpegOf(10, 10);
      String drawing(String relationship) =>
          '<w:drawing><wp:inline><wp:extent cx="1270000" cy="635000"/>'
          '<a:graphic><a:graphicData><pic:pic><pic:blipFill>'
          '<a:blip r:embed="$relationship"/></pic:blipFill></pic:pic>'
          '</a:graphicData></a:graphic></wp:inline></w:drawing>';
      final FlowDocument document = DocxReader.read(
        docxOf(
          '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>'
          '<w:r><w:t>caption</w:t>${drawing('rId1')}</w:r></w:p>'
          '<w:p><w:r>${drawing('rId2')}</w:r></w:p>'
          '<w:p><w:r>${drawing('rIdMissing')}</w:r></w:p>'
          '<w:p><w:r><mc:AlternateContent>'
          '<mc:Choice Requires="wps"><w:drawing><wp:anchor><a:graphic><a:graphicData>'
          '<wps:wsp><wps:txbx><w:txbxContent>${p('boxed')}</w:txbxContent></wps:txbx></wps:wsp>'
          '</a:graphicData></a:graphic></wp:anchor></w:drawing></mc:Choice>'
          '<mc:Fallback><w:pict><v:shape><v:textbox><w:txbxContent>${p('boxed')}</w:txbxContent>'
          '</v:textbox></v:shape></w:pict></mc:Fallback>'
          '</mc:AlternateContent></w:r></w:p>'
          '<w:p><w:r><w:pict><v:shape style="width:144pt;height:1in">'
          '<v:imagedata r:id="rId1"/></v:shape></w:pict></w:r></w:p>',
          relationships:
              '<Relationship Id="rId1" Target="media/image1.jpeg"/>'
              '<Relationship Id="rId2" Target="/word/media/image1.jpeg"/>'
              '<Relationship Id="rId3" Target="http://example.com/x.png" TargetMode="External"/>',
          media: {'media/image1.jpeg': picture},
        ),
      );

      final List<FlowImage> images = document.blocks
          .whereType<FlowImage>()
          .toList();
      expect(images, hasLength(3));
      expect(images[0].bytes, picture);
      expect(images[0].widthPt, closeTo(100, 0.01));
      expect(images[0].heightPt, closeTo(50, 0.01));
      expect(images[0].align, FlowAlign.center);
      expect(images[2].widthPt, 144);
      expect(images[2].heightPt, 72);

      // The paragraph that only held a picture leaves no blank line behind,
      // and the text box is read from one of its two renderings, not both.
      expect(paragraphsOf(document).map((p) => p.text).toList(), [
        'caption',
        // The drawing whose picture is missing: nothing in it, so a blank.
        '',
        'boxed',
      ]);
    });

    test('takes the paper from the section, and breaks between sections', () {
      final FlowDocument document = DocxReader.read(
        docxOf(
          '<w:p><w:pPr><w:sectPr><w:pgSz w:w="100" w:h="100"/></w:sectPr></w:pPr>'
          '<w:r><w:t>first section</w:t></w:r></w:p>'
          '<w:p><w:pPr><w:sectPr><w:type w:val="continuous"/></w:sectPr></w:pPr>'
          '<w:r><w:t>second</w:t></w:r></w:p>'
          '${p('third')}'
          '<w:sectPr><w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/>'
          '<w:pgMar w:top="720" w:right="1080" w:bottom="-360" w:left="1440"/></w:sectPr>',
        ),
      );
      expect(
        document.blocks
            .map((b) => b is FlowParagraph ? b.text : '<break>')
            .toList(),
        ['first section', '<break>', 'second', 'third'],
      );
      expect(document.pageWidth, 792);
      expect(document.pageHeight, 612);
      expect(document.marginTop, 36);
      expect(document.marginRight, 54);
      expect(document.marginBottom, 18);
      expect(document.marginLeft, 72);
    });
  });

  group('FlowRenderer', () {
    Future<Uint8List> render(FlowDocument document) =>
        FlowRenderer.render(document, fonts);

    test('writes text that can be found again, accents and all', () async {
      final Uint8List pdf = await render(
        const FlowDocument([
          FlowParagraph([FlowRun('Fișă de înscriere: ăâîșț ĂÂÎȘȚ')]),
          FlowParagraph([FlowRun('Привет мир and Καλημέρα')]),
        ]),
      );
      final String text = textOf(pdf);
      expect(text, contains('Fișă de înscriere: ăâîșț ĂÂÎȘȚ'));
      expect(text, contains('Привет мир and Καλημέρα'));
    });

    test('keeps spaces as spaces when the font lacks a character', () async {
      // Syncfusion draws a missing character with the space glyph and then
      // records that glyph as meaning the missing character, which turns
      // every space in the document into it on extraction and search.
      final Uint8List pdf = await render(
        const FlowDocument([
          FlowParagraph([FlowRun('plain words here')]),
          FlowParagraph([FlowRun('漢字 and 😀 and עברית')]),
          FlowParagraph([FlowRun('more plain words')]),
        ]),
      );
      final String text = textOf(pdf);
      expect(text, contains('plain words here'));
      expect(text, contains('more plain words'));
      // What stands in for the missing characters is not itself text.
      expect(text, contains(' and  and '));
      expect(text, isNot(contains('漢')));
    });

    test('drops characters that take no room and maps odd spaces', () async {
      final Uint8List pdf = await render(
        const FlowDocument([
          FlowParagraph([
            FlowRun('soft\u00ADhyphen zero\u200Bwidth nbsp\u00A0here a\u2011b'),
          ]),
        ]),
      );
      expect(
        textOf(pdf),
        contains('softhyphen zerowidth nbsp here a-b'),
      );
    });

    test('honours the paper size and the margins', () async {
      final Uint8List pdf = await render(
        const FlowDocument(
          [
            FlowParagraph([FlowRun('edge')]),
          ],
          pageWidth: 792,
          pageHeight: 612,
          marginLeft: 100,
          marginTop: 50,
        ),
      );
      withPdf(pdf, (d) {
        expect(d.pages.count, 1);
        expect(d.pages[0].size.width, closeTo(792, 0.5));
        expect(d.pages[0].size.height, closeTo(612, 0.5));
      });
      final TextLine line = linesOf(pdf).single;
      expect(line.bounds.left, closeTo(100, 1));
      expect(line.bounds.top, greaterThanOrEqualTo(50));
      expect(line.bounds.top, lessThan(56));
    });

    test('falls back to A4 for paper no page could be', () async {
      final Uint8List pdf = await render(
        const FlowDocument(
          [
            FlowParagraph([FlowRun('x')]),
          ],
          pageWidth: 5,
          pageHeight: double.nan,
          marginLeft: 9000,
        ),
      );
      withPdf(pdf, (d) {
        expect(d.pages[0].size.width, closeTo(595.3, 0.5));
        expect(d.pages[0].size.height, closeTo(841.9, 0.5));
      });
      expect(linesOf(pdf).single.bounds.left, closeTo(72, 1));
    });

    test('wraps a paragraph inside the margins', () async {
      final String sentence = List.generate(60, (i) => 'word$i').join(' ');
      final Uint8List pdf = await render(
        FlowDocument([
          FlowParagraph([FlowRun(sentence)]),
        ]),
      );
      final List<TextLine> lines = linesOf(pdf);
      expect(lines.length, greaterThan(3));
      for (final TextLine line in lines) {
        expect(line.bounds.left, closeTo(72, 1));
        expect(line.bounds.right, lessThanOrEqualTo(595.3 - 72 + 1));
      }
      // Nothing lost or reordered at the breaks.
      expect(lines.map((l) => l.text.trim()).join(' '), sentence);
    });

    test('cuts a word longer than the line instead of losing it', () async {
      final String url = 'https://example.com/${'segment' * 40}';
      final Uint8List pdf = await render(
        FlowDocument([
          FlowParagraph([FlowRun('see $url now')]),
        ]),
      );
      final List<TextLine> lines = linesOf(pdf);
      for (final TextLine line in lines) {
        expect(line.bounds.right, lessThanOrEqualTo(595.3 - 72 + 1));
      }
      expect(
        lines.map((l) => l.text).join().replaceAll(' ', ''),
        'see${url}now',
      );
    });

    test('flows onto new pages and keeps every line', () async {
      final Uint8List pdf = await render(
        FlowDocument([
          for (int i = 0; i < 200; i++) FlowParagraph([FlowRun('LINE$i.')]),
        ]),
      );
      final int pages = pageCountOf(pdf);
      expect(pages, greaterThan(3));
      final List<TextLine> lines = linesOf(pdf);
      expect(lines.map((l) => l.text).toList(), [
        for (int i = 0; i < 200; i++) 'LINE$i.',
      ]);
      for (final TextLine line in lines) {
        expect(line.bounds.top, greaterThanOrEqualTo(72));
        expect(line.bounds.bottom, lessThanOrEqualTo(841.9 - 72 + 1));
      }
    });

    test('breaks pages where asked, and never leaves one empty', () async {
      final Uint8List pdf = await render(
        const FlowDocument([
          FlowPageBreak(),
          FlowParagraph([FlowRun('ONE')], spaceBeforePt: 40),
          FlowPageBreak(),
          FlowPageBreak(),
          FlowParagraph([FlowRun('TWO')]),
          FlowPageBreak(),
        ]),
      );
      expect(pageCountOf(pdf), 2);
      expect(textOf(pdf, 0), contains('ONE'));
      expect(textOf(pdf, 1), contains('TWO'));
      // Space above a paragraph is not carried to the top of a page.
      expect(linesOf(pdf).first.bounds.top, lessThan(80));
    });

    test('gives an empty document one blank page', () async {
      final Uint8List pdf = await render(const FlowDocument([]));
      expect(pageCountOf(pdf), 1);
      expect(textOf(pdf).trim(), isEmpty);
    });

    test('sets bold and italic in their own cuts of the font', () async {
      final Uint8List pdf = await render(
        const FlowDocument([
          FlowParagraph([FlowRun('regular')]),
          FlowParagraph([FlowRun('heavy', bold: true)]),
          FlowParagraph([FlowRun('slanted', italic: true)]),
          FlowParagraph([FlowRun('both', bold: true, italic: true)]),
        ]),
      );
      final Map<String, List<PdfFontStyle>> styles = {
        for (final TextLine line in linesOf(pdf)) line.text: line.fontStyle,
      };
      expect(styles['regular'], isNot(contains(PdfFontStyle.bold)));
      expect(styles['heavy'], contains(PdfFontStyle.bold));
      expect(styles['slanted'], contains(PdfFontStyle.italic));
      expect(styles['both'], contains(PdfFontStyle.bold));
      expect(styles['both'], contains(PdfFontStyle.italic));
    });

    test('keeps a sentence of mixed formats on one line, in order', () async {
      final Uint8List pdf = await render(
        const FlowDocument([
          FlowParagraph([
            FlowRun('Start '),
            FlowRun('big', sizePt: 24, bold: true),
            FlowRun(' then '),
            FlowRun('struck', strike: true, underline: true, color: 0xCC0000),
            FlowRun(' end.'),
          ]),
        ]),
      );
      final List<TextLine> lines = linesOf(pdf);
      // One visual line, however the extractor chooses to group it.
      final double top = lines.map((l) => l.bounds.top).reduce((a, b) => a < b ? a : b);
      final double bottom = lines
          .map((l) => l.bounds.bottom)
          .reduce((a, b) => a > b ? a : b);
      expect(bottom - top, lessThan(24 * 1.3));
      final List<TextLine> ordered = [...lines]
        ..sort((a, b) => a.bounds.left.compareTo(b.bounds.left));
      expect(
        ordered.map((l) => l.text.trim()).join(' '),
        'Start big then struck end.',
      );
      // Words do not overlap where one format gives way to the next.
      for (int i = 1; i < ordered.length; i++) {
        expect(
          ordered[i].bounds.left,
          greaterThanOrEqualTo(ordered[i - 1].bounds.right - 0.5),
        );
      }
    });

    test('aligns, indents and hangs', () async {
      final Uint8List pdf = await render(
        const FlowDocument([
          FlowParagraph([FlowRun('left')]),
          FlowParagraph([FlowRun('middle')], align: FlowAlign.center),
          FlowParagraph([FlowRun('right')], align: FlowAlign.right),
          FlowParagraph([FlowRun('indented')], indentPt: 50),
          FlowParagraph(
            [FlowRun('1.\titem text')],
            indentPt: 36,
            firstLinePt: -18,
          ),
        ]),
      );
      const double left = 72;
      const double right = 595.3 - 72;
      final Map<String, TextLine> lines = {
        for (final TextLine line in linesOf(pdf)) line.text.trim(): line,
      };
      expect(lines['left']!.bounds.left, closeTo(left, 1));
      expect(lines['right']!.bounds.right, closeTo(right, 1.5));
      final TextLine middle = lines['middle']!;
      expect(
        (middle.bounds.left + middle.bounds.right) / 2,
        closeTo((left + right) / 2, 1.5),
      );
      expect(lines['indented']!.bounds.left, closeTo(left + 50, 1));

      // The number hangs at 18pt and the tab carries the text to the indent.
      final TextLine item = linesOf(
        pdf,
      ).firstWhere((l) => l.text.contains('item text'));
      final TextWord number = item.wordCollection.firstWhere(
        (w) => w.text.contains('1.'),
      );
      final TextWord first = item.wordCollection.firstWhere(
        (w) => w.text.contains('item'),
      );
      expect(number.bounds.left, closeTo(left + 18, 1));
      expect(first.bounds.left, closeTo(left + 36, 1));
    });

    test('draws tables, and carries a tall row across pages', () async {
      final List<FlowBlock> tall = [
        for (int i = 0; i < 90; i++) FlowParagraph([FlowRun('ROW$i.')]),
      ];
      final Uint8List pdf = await render(
        FlowDocument([
          const FlowParagraph([FlowRun('above')]),
          FlowTable(
            [
              const FlowRow([
                FlowCell([
                  FlowParagraph([FlowRun('head one')]),
                ], fill: 0xDDDDDD),
                FlowCell([
                  FlowParagraph([FlowRun('head two')]),
                ]),
              ]),
              FlowRow([
                FlowCell(tall),
                const FlowCell([
                  FlowParagraph([FlowRun('short')]),
                  // A table inside a cell is read through, not drawn.
                  FlowTable([
                    FlowRow([
                      FlowCell([
                        FlowParagraph([FlowRun('inner')]),
                      ]),
                    ]),
                  ]),
                ]),
              ]),
              const FlowRow([
                FlowCell([
                  FlowParagraph([FlowRun('spans both')]),
                ], span: 2),
              ]),
            ],
            columnWidths: const [100, 200],
          ),
          const FlowParagraph([FlowRun('below')]),
        ]),
      );
      expect(pageCountOf(pdf), greaterThan(1));
      final String text = textOf(pdf);
      for (final String expected in [
        'above',
        'head one',
        'head two',
        'short',
        'inner',
        'spans both',
        'below',
        for (int i = 0; i < 90; i++) 'ROW$i.',
      ]) {
        expect(text, contains(expected), reason: expected);
      }
      final List<TextLine> lines = linesOf(pdf);
      for (final TextLine line in lines) {
        expect(line.bounds.bottom, lessThanOrEqualTo(841.9 - 72 + 1));
      }
      // Second column starts where the first one's 100pt end.
      final TextLine second = lines.firstWhere((l) => l.text.contains('short'));
      expect(second.bounds.left, greaterThan(72 + 100));
      expect(second.bounds.left, lessThan(72 + 110));
    });

    test('places pictures, scaled to fit, and skips ones it cannot read',
        () async {
      final Uint8List pdf = await render(
        FlowDocument([
          const FlowParagraph([FlowRun('before')]),
          // Wider than the page: must be scaled down, not cropped.
          FlowImage(jpegOf(400, 200), widthPt: 2000, heightPt: 1000),
          FlowImage(img.encodePng(img.Image(width: 8, height: 8))),
          FlowImage(img.encodeGif(img.Image(width: 8, height: 8))),
          // No signature the renderer knows: a vector drawing, say.
          FlowImage(
            Uint8List.fromList(List<int>.generate(4000, (i) => i % 7)),
          ),
          const FlowParagraph([FlowRun('after')]),
        ]),
      );
      expect(pageCountOf(pdf), 1);
      expect('/Subtype /Image'.allMatches(latin1.decode(pdf)).length, 3);
      final List<TextLine> lines = linesOf(pdf);
      final double before = lines
          .firstWhere((l) => l.text == 'before')
          .bounds
          .bottom;
      final double after = lines.firstWhere((l) => l.text == 'after').bounds.top;
      // 451pt wide at 2:1 is 226pt tall, plus the two small ones at 6pt.
      expect(after - before, closeTo(225.65 + 12, 4));
    });

    test('converts a Word file end to end', () async {
      final Uint8List pdf = await DocumentImport.renderWord(
        DocxWriter.build(const [
          DocxParagraph([DocxRun('Raport anual', sizePt: 18, bold: true)]),
          DocxParagraph([DocxRun('Conținut în limba română.')]),
          DocxPageBreak(),
          DocxParagraph([DocxRun('Pagina a doua')]),
        ]),
        fonts,
        title: 'raport',
      );
      expect(pageCountOf(pdf), 2);
      expect(textOf(pdf, 0), contains('Raport anual'));
      expect(textOf(pdf, 0), contains('Conținut în limba română.'));
      expect(textOf(pdf, 1), contains('Pagina a doua'));
      final TextLine title = linesOf(
        pdf,
      ).firstWhere((l) => l.text == 'Raport anual');
      expect(title.fontSize, closeTo(18, 0.1));
      expect(title.fontStyle, contains(PdfFontStyle.bold));
    });

    test('reports a file that is not a Word document', () {
      expect(
        DocumentImport.renderWord(
          Uint8List.fromList(utf8.encode('nope')),
          fonts,
        ),
        throwsFormatException,
      );
    });
  });
}
