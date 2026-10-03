import 'dart:convert';
import 'dart:typed_data';

/// Running text and pictures with no pages yet: what a Word or text file
/// holds, before [FlowRenderer] lays it out as a PDF.
///
/// Deliberately small. It carries what survives a conversion to fixed pages
/// (words, their weight and size, paragraph spacing, simple tables,
/// pictures) and nothing that would need a real word processor to honour.
class FlowDocument {
  final List<FlowBlock> blocks;

  /// Paper size and margins, in points.
  final double pageWidth;
  final double pageHeight;
  final double marginLeft;
  final double marginTop;
  final double marginRight;
  final double marginBottom;

  const FlowDocument(
    this.blocks, {
    this.pageWidth = a4Width,
    this.pageHeight = a4Height,
    this.marginLeft = 72,
    this.marginTop = 72,
    this.marginRight = 72,
    this.marginBottom = 72,
  });

  static const double a4Width = 595.3;
  static const double a4Height = 841.9;

  /// One paragraph per line of [text], which is how a text file reads.
  factory FlowDocument.plainText(String text) {
    final List<String> lines = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    // A file usually ends in a newline; that is not a blank last line.
    if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
    return FlowDocument([
      for (final String line in lines)
        FlowParagraph([FlowRun(line, sizePt: 10.5)], lineHeight: 1.15),
    ], marginLeft: 56, marginRight: 56, marginTop: 56, marginBottom: 56);
  }

  /// Decodes a text file: by its byte-order mark where it has one, as UTF-8
  /// where that is valid, and as Latin-1 — which cannot fail — otherwise.
  static String decodeText(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2) {
      final bool little = bytes[0] == 0xFF && bytes[1] == 0xFE;
      final bool big = bytes[0] == 0xFE && bytes[1] == 0xFF;
      if (little || big) {
        final ByteData data = ByteData.sublistView(bytes, 2);
        final Endian endian = little ? Endian.little : Endian.big;
        return String.fromCharCodes([
          for (int i = 0; i + 1 < data.lengthInBytes; i += 2)
            data.getUint16(i, endian),
        ]);
      }
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }
}

sealed class FlowBlock {
  const FlowBlock();
}

enum FlowAlign { left, center, right }

/// A stretch of text in one format. `\n` breaks the line and `\t` advances
/// to the next tab stop.
class FlowRun {
  final String text;
  final double sizePt;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;

  /// 0xRRGGBB, or null for black.
  final int? color;

  const FlowRun(
    this.text, {
    this.sizePt = 11,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color,
  });
}

class FlowParagraph extends FlowBlock {
  /// A paragraph with no text still takes a line, as tall as its first run.
  final List<FlowRun> runs;
  final FlowAlign align;

  /// Left edge of the text, in points from the column's edge.
  final double indentPt;

  /// Where the first line starts relative to [indentPt]; negative hangs it
  /// out to the left, which is where a list number sits.
  final double firstLinePt;
  final double rightIndentPt;
  final double spaceBeforePt;
  final double spaceAfterPt;

  /// Multiple of the font's own line height.
  final double lineHeight;

  const FlowParagraph(
    this.runs, {
    this.align = FlowAlign.left,
    this.indentPt = 0,
    this.firstLinePt = 0,
    this.rightIndentPt = 0,
    this.spaceBeforePt = 0,
    this.spaceAfterPt = 0,
    this.lineHeight = 1,
  });

  String get text => runs.map((r) => r.text).join();
}

/// A picture on a line of its own.
class FlowImage extends FlowBlock {
  /// The file as stored. Formats the PDF writer cannot place directly are
  /// re-encoded when rendering, and ones nothing can decode are left out.
  final Uint8List bytes;

  /// Intended size in points; zero means the picture's own size at 96 dpi.
  final double widthPt;
  final double heightPt;
  final FlowAlign align;

  const FlowImage(
    this.bytes, {
    this.widthPt = 0,
    this.heightPt = 0,
    this.align = FlowAlign.left,
  });
}

class FlowTable extends FlowBlock {
  /// Width of each grid column, in points. Empty when the file gave none,
  /// and the columns then share the width equally.
  final List<double> columnWidths;
  final List<FlowRow> rows;

  /// Whether cells are outlined. Tables used purely for layout are not.
  final bool bordered;

  const FlowTable(
    this.rows, {
    this.columnWidths = const [],
    this.bordered = true,
  });
}

class FlowRow {
  final List<FlowCell> cells;
  const FlowRow(this.cells);
}

class FlowCell {
  final List<FlowBlock> blocks;

  /// How many grid columns the cell covers.
  final int span;

  /// Background, 0xRRGGBB, or null for none.
  final int? fill;

  const FlowCell(this.blocks, {this.span = 1, this.fill});
}

class FlowPageBreak extends FlowBlock {
  const FlowPageBreak();
}
