import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_viewer/services/document_import.dart';
import 'package:pdf_viewer/services/flow_document.dart';
import 'package:pdf_viewer/services/flow_renderer.dart';
import 'package:pdf_viewer/services/odt_reader.dart';
import 'package:pdf_viewer/services/pptx_reader.dart';
import 'package:pdf_viewer/services/rtf_reader.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

Uint8List ascii(String text) => Uint8List.fromList(latin1.encode(text));

Uint8List zip(Map<String, List<int>> parts) {
  final Archive archive = Archive();
  parts.forEach((name, bytes) {
    archive.addFile(ArchiveFile.bytes(name, bytes));
  });
  return ZipEncoder().encodeBytes(archive);
}

List<int> xml(String text) => utf8.encode(text);

FlowFonts fonts() {
  Uint8List cut(String name) =>
      File('assets/fonts/Roboto-$name.ttf').readAsBytesSync();
  return FlowFonts(
    regular: cut('Regular'),
    bold: cut('Bold'),
    italic: cut('Italic'),
    boldItalic: cut('BoldItalic'),
  );
}

String textOf(Uint8List pdf) {
  final PdfDocument document = PdfDocument(inputBytes: pdf);
  try {
    return PdfTextExtractor(document).extractText();
  } finally {
    document.dispose();
  }
}

const String rtf =
    r'{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}'
    r'{\colortbl;\red255\green0\blue0;\red0\green0\blue255;}'
    r'{\info{\title Hidden title}}\paperw12240\paperh15840\margl1440'
    r'\pard\qc\b\fs48 Report\b0\par'
    r'\pard\fs24 Plain \i slanted\i0  and \cf1 red\cf0  text.\par '
    r"caf\'e9 costs \u8364?5 \{really\}\par"
    r'{\*\generator Something 1.0;}'
    r'\trowd\cellx3000\cellx6000\intbl Left\cell Right\cell\row'
    r'\pard After the table\line second line\par}';

const String _odtNs =
    'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
    'xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" '
    'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" '
    'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
    'xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" '
    'xmlns:xlink="http://www.w3.org/1999/xlink" '
    'xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" '
    'xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0"';

Uint8List odt() => zip({
  'mimetype': ascii('application/vnd.oasis.opendocument.text'),
  'styles.xml': xml(
    '<office:document-styles $_odtNs><office:styles>'
    '<style:style style:name="Standard" style:family="paragraph">'
    '<style:text-properties fo:font-size="11pt"/></style:style>'
    '<style:style style:name="Quote" style:family="paragraph" style:parent-style-name="Standard">'
    '<style:text-properties fo:font-style="italic"/></style:style>'
    '</office:styles><office:automatic-styles>'
    '<style:page-layout style:name="pm1"><style:page-layout-properties '
    'fo:page-width="21cm" fo:page-height="29.7cm" fo:margin-left="2cm" fo:margin-right="2cm"/>'
    '</style:page-layout></office:automatic-styles></office:document-styles>',
  ),
  'content.xml': xml(
    '<office:document-content $_odtNs><office:automatic-styles>'
    '<style:style style:name="T1" style:family="text"><style:text-properties fo:font-weight="bold" fo:color="#ff0000"/></style:style>'
    '<style:style style:name="P1" style:family="paragraph" style:parent-style-name="Quote">'
    '<style:paragraph-properties fo:text-align="center" fo:break-before="page"/></style:style>'
    '<text:list-style style:name="L1"><text:list-level-style-number text:level="1"/></text:list-style>'
    '</office:automatic-styles><office:body><office:text>'
    '<text:h text:outline-level="1">Heading</text:h>'
    '<text:p text:style-name="Standard">Plain <text:span text:style-name="T1">loud</text:span>'
    '<text:s text:c="2"/>end<text:line-break/>next</text:p>'
    '<text:list text:style-name="L1"><text:list-item><text:p>one</text:p></text:list-item>'
    '<text:list-item><text:p>two</text:p><text:list><text:list-item><text:p>inner</text:p></text:list-item></text:list></text:list-item></text:list>'
    '<table:table><table:table-row><table:table-cell><text:p>A</text:p></table:table-cell>'
    '<table:table-cell table:number-columns-spanned="2"><text:p>B</text:p></table:table-cell>'
    '<table:covered-table-cell/></table:table-row></table:table>'
    '<text:p text:style-name="P1">Quoted<draw:frame svg:width="2cm" svg:height="1cm">'
    '<draw:image xlink:href="Pictures/a.png"/></draw:frame></text:p>'
    '</office:text></office:body></office:document-content>',
  ),
  'Pictures/a.png': img.encodePng(img.Image(width: 4, height: 2)),
});

const String _a = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const String _p = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const String _r =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const String _rels =
    'http://schemas.openxmlformats.org/package/2006/relationships';

String _slide(String shapes) =>
    '<p:sld xmlns:a="$_a" xmlns:p="$_p" xmlns:r="$_r"><p:cSld><p:spTree>'
    '$shapes</p:spTree></p:cSld></p:sld>';

String _shape(String placeholder, String paragraphs) =>
    '<p:sp><p:nvSpPr><p:nvPr>$placeholder</p:nvPr></p:nvSpPr>'
    '<p:txBody>$paragraphs</p:txBody></p:sp>';

Uint8List pptx() => zip({
  'ppt/presentation.xml': xml(
    '<p:presentation xmlns:p="$_p" xmlns:r="$_r"><p:sldIdLst>'
    '<p:sldId id="256" r:id="rId2"/><p:sldId id="257" r:id="rId3"/>'
    '</p:sldIdLst><p:sldSz cx="9144000" cy="6858000"/></p:presentation>',
  ),
  'ppt/_rels/presentation.xml.rels': xml(
    '<Relationships xmlns="$_rels">'
    '<Relationship Id="rId2" Type="x/slide" Target="slides/slide1.xml"/>'
    '<Relationship Id="rId3" Type="x/slide" Target="slides/slide2.xml"/>'
    '</Relationships>',
  ),
  // The body is listed before the title, as it may well be in a file.
  'ppt/slides/slide1.xml': xml(
    _slide(
      '${_shape('<p:ph idx="1"/>', '<a:p><a:r><a:t>First point</a:t></a:r></a:p>'
          '<a:p><a:pPr lvl="1"/><a:r><a:rPr i="1" sz="2400"><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></a:rPr><a:t>Sub point</a:t></a:r></a:p>'
          '<a:p><a:pPr><a:buNone/></a:pPr><a:r><a:t>No bullet</a:t></a:r></a:p>')}'
      '${_shape('<p:ph type="title"/>', '<a:p><a:r><a:t>Quarterly </a:t></a:r><a:r><a:t>review</a:t></a:r></a:p>')}'
      '${_shape('<p:ph type="sldNum"/>', '<a:p><a:r><a:t>1</a:t></a:r></a:p>')}'
      '<p:pic><p:blipFill><a:blip r:embed="rId9"/></p:blipFill>'
      '<p:spPr><a:xfrm><a:ext cx="1270000" cy="635000"/></a:xfrm></p:spPr></p:pic>',
    ),
  ),
  'ppt/slides/_rels/slide1.xml.rels': xml(
    '<Relationships xmlns="$_rels">'
    '<Relationship Id="rId9" Type="x/image" Target="../media/image1.png"/>'
    '</Relationships>',
  ),
  'ppt/media/image1.png': img.encodePng(img.Image(width: 4, height: 2)),
  'ppt/slides/slide2.xml': xml(
    _slide(
      '${_shape('', '<a:p><a:r><a:t>A text box</a:t></a:r></a:p>')}'
      '<p:graphicFrame><a:graphic><a:graphicData><a:tbl>'
      '<a:tr><a:tc><a:txBody><a:p><a:r><a:t>Cell</a:t></a:r></a:p></a:txBody></a:tc>'
      '<a:tc gridSpan="2"><a:txBody><a:p><a:r><a:t>Wide</a:t></a:r></a:p></a:txBody></a:tc>'
      '<a:tc hMerge="1"><a:txBody><a:p/></a:txBody></a:tc></a:tr>'
      '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>',
    ),
  ),
});

void main() {
  group('RtfReader', () {
    late FlowDocument doc;
    setUp(() => doc = RtfReader.read(ascii(rtf)));

    List<FlowParagraph> paragraphs() =>
        doc.blocks.whereType<FlowParagraph>().toList();

    test('reads paragraphs with their weight, size, slant and colour', () {
      final List<FlowParagraph> p = paragraphs();
      expect(p[0].text, 'Report');
      expect(p[0].align, FlowAlign.center);
      expect(p[0].runs.single.bold, isTrue);
      expect(p[0].runs.single.sizePt, 24);
      expect(p[1].text, 'Plain slanted and red text.');
      expect(p[1].align, FlowAlign.left);
      final FlowRun slanted = p[1].runs.firstWhere((r) => r.text == 'slanted');
      expect(slanted.italic, isTrue);
      expect(slanted.bold, isFalse);
      expect(p[1].runs.firstWhere((r) => r.text == 'red').color, 0xFF0000);
    });

    test('decodes escapes: bytes, Unicode with its fallback, braces', () {
      expect(
        paragraphs()[2].text,
        'caf${String.fromCharCode(0xE9)} costs '
        '${String.fromCharCode(0x20AC)}5 {really}',
      );
    });

    test('skips what is not body text', () {
      final String all = paragraphs().map((p) => p.text).join('|');
      expect(all, isNot(contains('Hidden title')));
      expect(all, isNot(contains('Arial')));
      expect(all, isNot(contains('Something')));
    });

    test('rows of cells become a table, and text goes on after it', () {
      final FlowTable table = doc.blocks.whereType<FlowTable>().single;
      expect(table.rows.single.cells, hasLength(2));
      expect(
        (table.rows.single.cells[1].blocks.single as FlowParagraph).text,
        'Right',
      );
      expect(paragraphs().last.text, 'After the table\nsecond line');
      expect(doc.blocks.indexOf(table), lessThan(doc.blocks.length - 1));
    });

    test('takes the paper and margins from the file', () {
      expect(doc.pageWidth, 612);
      expect(doc.pageHeight, 792);
      expect(doc.marginLeft, 72);
    });

    test('rejects what is not RTF', () {
      expect(() => RtfReader.read(ascii('plain text')), throwsFormatException);
    });
  });

  group('OdtReader', () {
    late FlowDocument doc;
    setUp(() => doc = OdtReader.read(odt()));

    List<FlowParagraph> paragraphs() =>
        doc.blocks.whereType<FlowParagraph>().toList();

    test('reads headings, spans, spaces and line breaks', () {
      final List<FlowParagraph> p = paragraphs();
      expect(p[0].text, 'Heading');
      expect(p[0].runs.single.bold, isTrue);
      expect(p[0].runs.single.sizePt, greaterThan(11));
      expect(p[1].text, 'Plain loud  end\nnext');
      final FlowRun loud = p[1].runs.firstWhere((r) => r.text == 'loud');
      expect(loud.bold, isTrue);
      expect(loud.color, 0xFF0000);
      expect(loud.sizePt, 11);
    });

    test('numbers a numbered list and bullets one nested in it', () {
      final List<String> items = paragraphs()
          .map((p) => p.text)
          .where((t) => t.contains('\t'))
          .toList();
      expect(items, [
        '1.\tone',
        '2.\ttwo',
        '${String.fromCharCode(0x2022)}\tinner',
      ]);
    });

    test('reads tables, spans included, and skips covered cells', () {
      final FlowTable table = doc.blocks.whereType<FlowTable>().single;
      expect(table.rows.single.cells, hasLength(2));
      expect(table.rows.single.cells[1].span, 2);
    });

    test('follows styles to their parents, and breaks pages', () {
      final FlowParagraph quoted = paragraphs().firstWhere(
        (p) => p.text == 'Quoted',
      );
      expect(quoted.align, FlowAlign.center);
      expect(quoted.runs.single.italic, isTrue);
      final int at = doc.blocks.indexOf(quoted);
      expect(doc.blocks[at - 1], isA<FlowPageBreak>());
    });

    test('brings pictures along at their size', () {
      final FlowImage image = doc.blocks.whereType<FlowImage>().single;
      expect(image.widthPt, closeTo(56.7, 0.1));
      expect(image.heightPt, closeTo(28.35, 0.1));
    });

    test('takes the paper from the page layout', () {
      expect(doc.pageWidth, closeTo(595.3, 0.1));
      expect(doc.marginLeft, closeTo(56.7, 0.1));
    });

    test('rejects what is not OpenDocument', () {
      expect(() => OdtReader.read(ascii('nope')), throwsFormatException);
      expect(
        () => OdtReader.read(zip({'other.xml': xml('<a/>')})),
        throwsFormatException,
      );
    });
  });

  group('PptxReader', () {
    late FlowDocument doc;
    setUp(() => doc = PptxReader.read(pptx()));

    test('a slide is a page, in the size of the slide', () {
      expect(doc.pageWidth, 720);
      expect(doc.pageHeight, 540);
      expect(doc.blocks.whereType<FlowPageBreak>(), hasLength(1));
    });

    test('the title comes first, whatever order the file lists things in', () {
      final FlowParagraph first = doc.blocks.first as FlowParagraph;
      expect(first.text, 'Quarterly review');
      expect(first.runs.every((r) => r.bold), isTrue);
    });

    test('body text is bulleted by level; marked paragraphs are not', () {
      final List<FlowParagraph> p = doc.blocks
          .whereType<FlowParagraph>()
          .toList();
      final String bullet = String.fromCharCode(0x2022);
      expect(p[1].text, '$bullet\tFirst point');
      expect(p[2].text, '$bullet\tSub point');
      expect(p[2].indentPt, greaterThan(p[1].indentPt));
      final FlowRun sub = p[2].runs.last;
      expect(sub.italic, isTrue);
      expect(sub.color, 0xFF0000);
      expect(p[3].text, 'No bullet');
    });

    test('slide numbers and the like are left out', () {
      expect(
        doc.blocks.whereType<FlowParagraph>().map((p) => p.text),
        isNot(contains('1')),
      );
    });

    test('pictures and tables come along', () {
      final FlowImage image = doc.blocks.whereType<FlowImage>().single;
      expect(image.widthPt, 100);
      expect(image.heightPt, 50);
      final FlowTable table = doc.blocks.whereType<FlowTable>().single;
      expect(table.rows.single.cells, hasLength(2));
      expect(table.rows.single.cells[1].span, 2);
      // On the second slide, after the break.
      final int breakAt = doc.blocks.indexWhere((b) => b is FlowPageBreak);
      expect(doc.blocks.indexOf(table), greaterThan(breakAt));
    });

    test('rejects what is not a presentation', () {
      expect(
        () => PptxReader.read(zip({'word/document.xml': xml('<a/>')})),
        throwsFormatException,
      );
    });
  });

  group('telling files apart', () {
    test('by how they begin', () {
      expect(DocumentImport.sniff(ascii(rtf)), ImportKind.rtf);
      expect(
        DocumentImport.sniff(
          Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0]),
          name: 'old.doc',
        ),
        ImportKind.legacyOffice,
      );
      expect(
        DocumentImport.sniff(ascii('a,b\n1,2\n'), name: 'data.csv'),
        ImportKind.sheet,
      );
      expect(
        DocumentImport.sniff(ascii('<!DOCTYPE html><p>x</p>'), name: 'x.bin'),
        ImportKind.html,
      );
    });

    test('and zips by what is inside them', () {
      expect(DocumentImport.zipKind(pptx()), ImportKind.slides);
      expect(DocumentImport.zipKind(odt()), ImportKind.openDocument);
      expect(
        DocumentImport.zipKind(zip({'xl/workbook.xml': xml('<a/>')})),
        ImportKind.sheet,
      );
      expect(
        DocumentImport.zipKind(zip({'word/document.xml': xml('<a/>')})),
        ImportKind.word,
      );
      expect(DocumentImport.zipKind(zip({'readme.txt': [1]})), isNull);
      expect(DocumentImport.zipKind(ascii('not a zip')), isNull);
    });
  });

  test('each of them comes out as a PDF with its text in it', () async {
    final FlowFonts f = fonts();
    expect(
      textOf(await DocumentImport.renderOffice(ascii(rtf), ImportKind.rtf, f)),
      allOf(contains('Report'), contains('After the table')),
    );
    expect(
      textOf(
        await DocumentImport.renderOffice(odt(), ImportKind.openDocument, f),
      ),
      allOf(contains('Heading'), contains('inner'), contains('Quoted')),
    );
    final Uint8List slides = await DocumentImport.renderOffice(
      pptx(),
      ImportKind.slides,
      f,
    );
    expect(textOf(slides), allOf(contains('Quarterly'), contains('Wide')));
    final PdfDocument document = PdfDocument(inputBytes: slides);
    expect(document.pages.count, 2);
    expect(document.pages[0].size.width, closeTo(720, 1));
    document.dispose();
  });
}
