import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// A piece of a Word document body.
sealed class DocxBlock {
  const DocxBlock();
}

/// A run of text sharing one format.
class DocxRun {
  final String text;
  final double sizePt;
  final bool bold;
  final bool italic;

  /// Font family name, or null for the document default.
  final String? font;

  const DocxRun(
    this.text, {
    this.sizePt = 11,
    this.bold = false,
    this.italic = false,
    this.font,
  });
}

class DocxParagraph extends DocxBlock {
  final List<DocxRun> runs;

  /// Left indent, in points.
  final double indentPt;

  /// Extra space above the paragraph, in points.
  final double spaceBeforePt;

  const DocxParagraph(
    this.runs, {
    this.indentPt = 0,
    this.spaceBeforePt = 0,
  });
}

/// An inline picture, scaled to fit the text column.
class DocxImage extends DocxBlock {
  final Uint8List bytes;

  /// `png` or `jpeg`.
  final String format;
  final int widthPx;
  final int heightPx;

  const DocxImage(
    this.bytes, {
    required this.format,
    required this.widthPx,
    required this.heightPx,
  });
}

class DocxPageBreak extends DocxBlock {
  const DocxPageBreak();
}

/// Writes a minimal, valid WordprocessingML (.docx) package.
///
/// Only what a PDF conversion needs: paragraphs of formatted runs, inline
/// pictures and page breaks. No dependency beyond `archive`, which the
/// `image` package already pulls in.
class DocxWriter {
  static const String mimeType =
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

  /// Usable width and height of a Letter/A4 page with one-inch margins, in
  /// EMUs (914400 per inch). Pictures are shrunk to fit inside both.
  static const int _maxImageWidthEmu = 914400 * 6;
  static const int _maxImageHeightEmu = 914400 * 9;

  static Uint8List build(List<DocxBlock> blocks, {String title = ''}) {
    final Archive archive = Archive();
    final StringBuffer body = StringBuffer();
    final List<String> imageRels = [];
    int imageCount = 0;
    bool hasJpeg = false;
    bool hasPng = false;

    for (final DocxBlock block in blocks) {
      switch (block) {
        case DocxParagraph():
          body.write(_paragraph(block));
        case DocxPageBreak():
          body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
        case DocxImage():
          imageCount++;
          final String ext = block.format == 'jpeg' ? 'jpeg' : 'png';
          if (ext == 'jpeg') {
            hasJpeg = true;
          } else {
            hasPng = true;
          }
          final String target = 'media/image$imageCount.$ext';
          final String relId = 'rIdImg$imageCount';
          archive.addFile(ArchiveFile.bytes('word/$target', block.bytes));
          imageRels.add(
            '<Relationship Id="$relId" '
            'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
            'Target="$target"/>',
          );
          body.write(_picture(block, relId, imageCount));
      }
    }

    archive.addFile(
      ArchiveFile.string(
        '[Content_Types].xml',
        '$_xmlHeader'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '${hasPng ? '<Default Extension="png" ContentType="image/png"/>' : ''}'
            '${hasJpeg ? '<Default Extension="jpeg" ContentType="image/jpeg"/>' : ''}'
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
            '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
            '</Types>',
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        '_rels/.rels',
        '$_xmlHeader'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
            '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
            '</Relationships>',
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        'word/_rels/document.xml.rels',
        '$_xmlHeader'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
            '${imageRels.join()}'
            '</Relationships>',
      ),
    );
    archive.addFile(ArchiveFile.string('word/styles.xml', _styles));
    archive.addFile(
      ArchiveFile.string(
        'docProps/core.xml',
        '$_xmlHeader'
            '<cp:coreProperties '
            'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/">'
            '<dc:title>${escape(title)}</dc:title>'
            '<dc:creator>ProPDF Studio</dc:creator>'
            '</cp:coreProperties>',
      ),
    );
    archive.addFile(
      ArchiveFile.string(
        'word/document.xml',
        '$_xmlHeader'
            '<w:document '
            'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
            'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
            'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
            'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
            '<w:body>$body'
            '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
            '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" '
            'w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>'
            '</w:body></w:document>',
      ),
    );

    return ZipEncoder().encodeBytes(archive);
  }

  /// Escapes text for XML and drops characters XML 1.0 cannot carry at all,
  /// which PDF text extraction occasionally produces from odd font encodings.
  static String escape(String text) {
    final StringBuffer out = StringBuffer();
    for (final int rune in text.runes) {
      switch (rune) {
        case 0x26:
          out.write('&amp;');
        case 0x3C:
          out.write('&lt;');
        case 0x3E:
          out.write('&gt;');
        case 0x22:
          out.write('&quot;');
        case 0x27:
          out.write('&apos;');
        default:
          final bool allowed =
              rune == 0x9 ||
              rune == 0xA ||
              rune == 0xD ||
              (rune >= 0x20 && rune <= 0xD7FF) ||
              (rune >= 0xE000 && rune <= 0xFFFD) ||
              (rune >= 0x10000 && rune <= 0x10FFFF);
          if (allowed) out.writeCharCode(rune);
      }
    }
    return out.toString();
  }

  static String _paragraph(DocxParagraph paragraph) {
    final StringBuffer p = StringBuffer('<w:p><w:pPr>');
    p.write(
      '<w:spacing w:before="${(paragraph.spaceBeforePt * 20).round()}" '
      'w:after="0"/>',
    );
    if (paragraph.indentPt > 0) {
      p.write('<w:ind w:left="${(paragraph.indentPt * 20).round()}"/>');
    }
    p.write('</w:pPr>');
    for (final DocxRun run in paragraph.runs) {
      p.write('<w:r><w:rPr>');
      if (run.font != null) {
        final String font = escape(run.font!);
        p.write('<w:rFonts w:ascii="$font" w:hAnsi="$font" w:cs="$font"/>');
      }
      if (run.bold) p.write('<w:b/>');
      if (run.italic) p.write('<w:i/>');
      // Half-points.
      final int size = (run.sizePt.clamp(4, 96) * 2).round();
      p.write('<w:sz w:val="$size"/><w:szCs w:val="$size"/>');
      p.write('</w:rPr>');
      p.write('<w:t xml:space="preserve">${escape(run.text)}</w:t></w:r>');
    }
    p.write('</w:p>');
    return p.toString();
  }

  static String _picture(DocxImage image, String relId, int id) {
    // 96 dpi is Word's own assumption for pixel sizes.
    double cx = image.widthPx * 914400 / 96;
    double cy = image.heightPx * 914400 / 96;
    final double shrink = math.min(
      1.0,
      math.min(_maxImageWidthEmu / cx, _maxImageHeightEmu / cy),
    );
    cx *= shrink;
    cy *= shrink;
    final int w = cx.round();
    final int h = cy.round();
    return '<w:p><w:r><w:drawing>'
        '<wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="$w" cy="$h"/>'
        '<wp:docPr id="$id" name="Picture $id"/>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic><pic:nvPicPr><pic:cNvPr id="$id" name="image$id"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="$relId"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$w" cy="$h"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic>'
        '</wp:inline></w:drawing></w:r></w:p>';
  }

  static const String _xmlHeader =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';

  static const String _styles =
      '$_xmlHeader'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:docDefaults><w:rPrDefault><w:rPr>'
      '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/>'
      '<w:sz w:val="22"/><w:szCs w:val="22"/>'
      '</w:rPr></w:rPrDefault>'
      '<w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault>'
      '</w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>'
      '</w:styles>';
}
