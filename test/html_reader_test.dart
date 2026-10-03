import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_viewer/services/document_import.dart';
import 'package:pdf_viewer/services/flow_document.dart';
import 'package:pdf_viewer/services/flow_renderer.dart';
import 'package:pdf_viewer/services/html_reader.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

List<FlowParagraph> paragraphs(String html) =>
    HtmlReader.read(html).blocks.whereType<FlowParagraph>().toList();

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

void main() {
  group('HtmlReader', () {
    test('headings and paragraphs become blocks in order', () {
      final List<FlowParagraph> p = paragraphs(
        '<html><head><title>Skip me</title></head><body>'
        '<h1>Title</h1><p>First   para\n graph.</p><p>Second.</p></body></html>',
      );
      expect(p.map((e) => e.text), ['Title', 'First para graph.', 'Second.']);
      expect(p[0].runs.single.bold, isTrue);
      expect(p[0].runs.single.sizePt, greaterThan(p[1].runs.single.sizePt));
    });

    test('emphasis nests and ends where its tag does', () {
      final List<FlowRun> runs = paragraphs(
        '<p>plain <b>bold <i>both</i></b> <u>under</u> <s>gone</s></p>',
      ).single.runs;
      FlowRun run(String text) => runs.firstWhere((r) => r.text.trim() == text);
      expect(run('plain').bold, isFalse);
      expect(run('bold').bold, isTrue);
      expect(run('bold').italic, isFalse);
      expect(run('both').bold && run('both').italic, isTrue);
      expect(run('under').underline, isTrue);
      expect(run('gone').strike, isTrue);
    });

    test('entities, line breaks and stray angle brackets', () {
      final FlowParagraph p = paragraphs(
        '<p>Fish &amp; chips &lt;3 &#233;t&#xE9;<br>next 2 < 3</p>',
      ).single;
      expect(p.text, 'Fish & chips <3 été\nnext 2 < 3');
    });

    test('lists get markers, numbers count, and nesting indents', () {
      final List<FlowParagraph> p = paragraphs(
        '<ul><li>one<li>two<ol start="3"><li>inner</li><li>more</li></ol></li></ul>',
      );
      expect(p.map((e) => e.text), [
        '${String.fromCharCode(0x2022)}\tone',
        '${String.fromCharCode(0x2022)}\ttwo',
        '3.\tinner',
        '4.\tmore',
      ]);
      expect(p[2].indentPt, greaterThan(p[0].indentPt));
      expect(p[0].firstLinePt, lessThan(0));
    });

    test('tables keep rows, spans, header weight and fills', () {
      final FlowTable table = HtmlReader.read(
        '<table><thead><tr><th>Day</th><th>City</th></tr></thead>'
        '<tr><td colspan="2" bgcolor="#ffee00">Both</td></tr>'
        '<tr><td>1<td style="background-color: rgb(0, 128, 0)">Cluj</table>',
      ).blocks.whereType<FlowTable>().single;
      expect(table.rows, hasLength(3));
      final FlowParagraph header =
          table.rows[0].cells[0].blocks.single as FlowParagraph;
      expect(header.runs.single.bold, isTrue);
      expect(table.rows[1].cells.single.span, 2);
      expect(table.rows[1].cells.single.fill, 0xFFEE00);
      expect(table.rows[2].cells, hasLength(2));
      expect(table.rows[2].cells[1].fill, 0x008000);
    });

    test('reads inline styles and plain style-sheet rules', () {
      final List<FlowParagraph> p = paragraphs(
        '<style>h2 { color: #1E3A8A; text-align: center }\n'
        '.note { font-style: italic; font-size: 20px }\n'
        'div > p { color: red }</style>'
        '<h2>Head</h2><p class="note">Note</p>'
        '<div><p style="color: green; font-weight: 700">Own</p></div>',
      );
      expect(p[0].runs.single.color, 0x1E3A8A);
      expect(p[0].align, FlowAlign.center);
      expect(p[1].runs.single.italic, isTrue);
      expect(p[1].runs.single.sizePt, 15);
      // The child-combinator rule is not applied; the inline one is.
      expect(p[2].runs.single.color, 0x008000);
      expect(p[2].runs.single.bold, isTrue);
    });

    test('scripts, styles and hidden things are not content', () {
      final List<FlowParagraph> p = paragraphs(
        '<script>var x = "<p>no</p>";</script><p>yes</p>'
        '<p style="display:none">hidden</p><!-- <p>comment</p> -->',
      );
      expect(p.map((e) => e.text), ['yes']);
    });

    test('preformatted text keeps its lines', () {
      final FlowParagraph p = paragraphs('<pre>a\n  b\nc</pre>').single;
      expect(p.text, 'a\n  b\nc');
    });

    test('embedded pictures come along; linked ones leave their alt text', () {
      final String png = base64.encode(
        img.encodePng(img.Image(width: 4, height: 2)),
      );
      final FlowDocument doc = HtmlReader.read(
        '<p>before</p><img src="data:image/png;base64,$png" width="40">'
        '<p><img src="https://example.com/a.png" alt="A chart"></p>',
      );
      final FlowImage image = doc.blocks.whereType<FlowImage>().single;
      expect(image.widthPt, 30);
      expect(
        doc.blocks.whereType<FlowParagraph>().map((e) => e.text),
        ['before', '[A chart]'],
      );
    });

    test('paper and margins are the ones asked for', () {
      final FlowDocument doc = HtmlReader.read(
        '',
        pageWidth: 792,
        pageHeight: 612,
        margin: 18,
      );
      expect(doc.pageWidth, 792);
      expect(doc.marginLeft, 18);
      expect(doc.blocks, isNotEmpty);
    });
  });

  test('renderHtml writes a PDF whose text can be found', () async {
    final Uint8List pdf = await DocumentImport.renderHtml(
      '<h1>Trip plan</h1><p>A <b>web page</b> turned into a PDF.</p>'
      '<table><tr><td>Day</td><td>Cluj</td></tr></table>'
      '${List.generate(80, (i) => '<p>Paragraph ${i + 1}</p>').join()}',
      fonts(),
    );
    final PdfDocument document = PdfDocument(inputBytes: pdf);
    final String text = PdfTextExtractor(document).extractText();
    expect(document.pages.count, greaterThan(1));
    document.dispose();
    expect(text, contains('Trip plan'));
    expect(text, contains('web page'));
    expect(text, contains('Cluj'));
    expect(text, contains('Paragraph 80'));
  });
}
