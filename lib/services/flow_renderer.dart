import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset, Rect, Size;
import 'package:image/image.dart' as img;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'flow_document.dart';

/// The four cuts of the typeface a converted document is set in, as the
/// bytes of their TrueType files.
///
/// PDF's built-in fonts only cover Western European letters, so anything
/// else (ă, ș, ț, Cyrillic, Greek) needs a real font embedded.
@immutable
class FlowFonts {
  final Uint8List regular;
  final Uint8List bold;
  final Uint8List italic;
  final Uint8List boldItalic;

  const FlowFonts({
    required this.regular,
    required this.bold,
    required this.italic,
    required this.boldItalic,
  });
}

/// Lays a [FlowDocument] out on pages and writes it as a PDF.
///
/// Syncfusion can paginate a single string in a single font, which is not
/// enough for a paragraph that mixes formats, so lines are broken here:
/// every block becomes a list of fixed-height items (a line of text, a
/// picture, a gap, a table row) and pages are filled with them in order.
///
/// CPU-bound and free of platform channels; callers run it in an isolate.
class FlowRenderer {
  static Future<Uint8List> render(
    FlowDocument source,
    FlowFonts fonts, {
    String title = '',
  }) => _Renderer(source, fonts).run(title);
}

/// One font file: its metrics, the characters it can draw, and a
/// [PdfFont] for every size asked of it.
class FlowFace {
  final Uint8List bytes;
  final List<PdfFontStyle> styles;

  /// Distance from the baseline to the top and bottom of a line, per point
  /// of font size. Syncfusion places text by the same `hhea` numbers.
  late final double ascent;
  late final double descent;

  /// 1 for every UTF-16 code unit the font has a glyph for.
  final Uint8List _covered = Uint8List(0x10000);

  final Map<int, PdfFont> _sized = {};
  final Map<int, Map<String, double>> _widths = {};

  static final PdfStringFormat _measuring = PdfStringFormat(
    measureTrailingSpaces: true,
  );

  FlowFace(this.bytes, this.styles) {
    _read();
  }

  bool has(int codeUnit) => _covered[codeUnit] == 1;

  /// [text] on one line, with every character the font cannot draw
  /// replaced. See `_drawable` for why none may reach Syncfusion.
  String drawable(String text) {
    final StringBuffer out = StringBuffer();
    for (final int rune in text.runes) {
      if (rune == 0x09 || rune == 0x0A || rune == 0x0D) {
        out.writeCharCode(0x20);
      } else if (rune <= 0xFFFF && has(rune)) {
        out.writeCharCode(rune);
      } else {
        out.writeCharCode(has(0xFFFD) ? 0xFFFD : 0x3F);
      }
    }
    return out.toString();
  }

  static int _key(double size) => (size * 2).round();

  PdfFont at(double size) => _sized.putIfAbsent(
    _key(size),
    () => PdfTrueTypeFont(bytes, size, multiStyle: styles),
  );

  double measure(String text, double size) =>
      at(size).measureString(text, format: _measuring).width;

  /// [measure], remembered: a document repeats most of its words.
  double width(String text, double size) =>
      _widths.putIfAbsent(_key(size), () => {})[text] ??= measure(text, size);

  /// Reads the three tables that matter out of the TrueType file.
  void _read() {
    final ByteData data = ByteData.sublistView(bytes);
    int? head;
    int? hhea;
    int? cmap;
    final int tableCount = data.getUint16(4);
    for (int i = 0; i < tableCount; i++) {
      final int record = 12 + i * 16;
      final int offset = data.getUint32(record + 8);
      switch (String.fromCharCodes(bytes, record, record + 4)) {
        case 'head':
          head = offset;
        case 'hhea':
          hhea = offset;
        case 'cmap':
          cmap = offset;
      }
    }
    if (head == null || hhea == null || cmap == null) {
      throw const FormatException('The built-in font could not be read.');
    }
    final int unitsPerEm = data.getUint16(head + 18);
    ascent = data.getInt16(hhea + 4) / unitsPerEm;
    descent = -data.getInt16(hhea + 6) / unitsPerEm;

    // Format 4 is the Basic Multilingual Plane map, and the Windows Unicode
    // one is the copy Syncfusion draws from.
    int? table;
    final int subtables = data.getUint16(cmap + 2);
    for (int i = 0; i < subtables; i++) {
      final int record = cmap + 4 + i * 8;
      final int start = cmap + data.getUint32(record + 4);
      if (data.getUint16(start) != 4) continue;
      table ??= start;
      if (data.getUint16(record) == 3 && data.getUint16(record + 2) == 1) {
        table = start;
        break;
      }
    }
    if (table == null) {
      throw const FormatException('The built-in font could not be read.');
    }
    final int segments = data.getUint16(table + 6) ~/ 2;
    final int ends = table + 14;
    final int starts = ends + segments * 2 + 2;
    final int deltas = starts + segments * 2;
    final int ranges = deltas + segments * 2;
    for (int s = 0; s < segments; s++) {
      final int first = data.getUint16(starts + s * 2);
      final int last = data.getUint16(ends + s * 2);
      final int delta = data.getUint16(deltas + s * 2);
      final int range = data.getUint16(ranges + s * 2);
      for (int code = first; code <= last && code < 0xFFFF; code++) {
        int glyph;
        if (range == 0) {
          glyph = (code + delta) & 0xFFFF;
        } else {
          final int at = ranges + s * 2 + range + (code - first) * 2;
          if (at + 2 > bytes.length) break;
          glyph = data.getUint16(at);
          if (glyph != 0) glyph = (glyph + delta) & 0xFFFF;
        }
        if (glyph != 0) _covered[code] = 1;
      }
    }
  }
}

/// How a stretch of text is drawn.
class _Style {
  final FlowFace face;
  final double size;
  final int color;
  final bool underline;
  final bool strike;

  _Style(this.face, this.size, this.color, this.underline, this.strike);

  double get ascent => face.ascent * size;
  double get descent => face.descent * size;
  PdfFont get font => face.at(size);
  double get spaceWidth => face.width(' ', size);
  double width(String text) => face.width(text, size);

  bool same(_Style other) =>
      identical(face, other.face) &&
      size == other.size &&
      color == other.color &&
      underline == other.underline &&
      strike == other.strike;
}

/// Something of a fixed height that goes on a page in one piece.
sealed class _Item {
  double get height;
}

class _Gap extends _Item {
  @override
  final double height;
  _Gap(this.height);
}

class _Break extends _Item {
  @override
  double get height => 0;
}

/// Words in one style, drawn with a single call.
class _Fragment {
  double x;
  final _Style style;
  final StringBuffer text = StringBuffer();
  double width = 0;
  _Fragment(this.x, this.style);
}

class _Line extends _Item {
  final List<_Fragment> fragments;

  /// Baseline, measured from the top of the line.
  final double ascent;
  @override
  final double height;
  _Line(this.fragments, this.ascent, this.height);
}

class _Picture extends _Item {
  final PdfBitmap bitmap;
  final double x;
  final double width;
  @override
  final double height;
  _Picture(this.bitmap, this.x, this.width, this.height);
}

class _CellBox {
  final double x;
  final double width;
  final List<_Item> items;
  final int? fill;
  _CellBox(this.x, this.width, this.items, this.fill);

  double get contentHeight =>
      items.fold<double>(0, (sum, item) => sum + item.height);
}

class _Row extends _Item {
  final List<_CellBox> cells;
  final bool bordered;
  _Row(this.cells, this.bordered);

  @override
  double get height =>
      cells.fold<double>(0, (max, c) => math.max(max, c.contentHeight)) +
      2 * _Renderer.cellPadV;
}

/// Breaks one paragraph into lines.
class _LineBuilder {
  final double left;
  final double right;
  final FlowAlign align;
  final double lineHeight;

  final List<_Line> lines = [];
  List<_Fragment> _fragments = [];
  double _x;
  double _ascent = 0;
  double _descent = 0;

  /// Spaces seen since the last word, not yet given any room: at the end
  /// of a line they never are.
  int _spaces = 0;
  double _spaceWidth = 0;
  _Style? _spaceStyle;

  /// Whether the next word may be appended to the last fragment.
  bool _joinable = false;
  bool _hasContent = false;

  /// What an empty line takes its height from.
  _Style _lastStyle;

  _LineBuilder({
    required this.left,
    required this.right,
    required double firstLeft,
    required this.align,
    required this.lineHeight,
    required _Style initial,
  }) : _x = firstLeft,
       _lastStyle = initial;

  void word(String text, _Style style) {
    _lastStyle = style;
    double width = style.width(text);
    if (_hasContent && _x + _spaceWidth + width > right + 0.01) _flush();
    // A word wider than the line it starts — a URL, a long number — is cut
    // where the room runs out rather than left to run off the page.
    while (!_hasContent && text.length > 1) {
      final double room = right - (_x + _spaceWidth);
      if (width <= room + 0.01 || width <= 0) break;
      int cut = (text.length * room / width).floor().clamp(1, text.length - 1);
      while (cut > 1 &&
          style.face.measure(text.substring(0, cut), style.size) > room) {
        cut--;
      }
      final String head = text.substring(0, cut);
      _place(head, style, style.face.measure(head, style.size));
      _flush();
      text = text.substring(cut);
      width = style.face.measure(text, style.size);
    }
    _place(text, style, width);
  }

  void space(_Style style) {
    _lastStyle = style;
    final double width = style.spaceWidth;
    // Spaces that would run past the edge are the end of the line.
    if (_x + _spaceWidth + width > right) return;
    _spaces++;
    _spaceWidth += width;
    _spaceStyle = style;
  }

  /// Advances to the next tab stop: every half inch, and the paragraph's
  /// own indent, which is where the text after a list number lines up.
  void tab() {
    _x += _spaceWidth;
    _spaces = 0;
    _spaceWidth = 0;
    double stop = ((_x + 0.01) / 36).floor() * 36 + 36;
    if (left > _x + 0.5 && left < stop) stop = left;
    if (stop > right - 1) {
      if (_hasContent) _flush();
      return;
    }
    _x = stop;
    _joinable = false;
    _hasContent = true;
  }

  void newline(_Style style) {
    _lastStyle = style;
    _flush();
  }

  List<_Line> finish() {
    _flush();
    return lines;
  }

  void _place(String text, _Style style, double width) {
    final double x = _x + _spaceWidth;
    final _Fragment? last = _joinable ? _fragments.last : null;
    if (last != null &&
        last.style.same(style) &&
        (_spaces == 0 || _spaceStyle!.same(style))) {
      last.text
        ..write(' ' * _spaces)
        ..write(text);
      last.width = x + width - last.x;
    } else {
      _fragments.add(
        _Fragment(x, style)
          ..text.write(text)
          ..width = width,
      );
    }
    _x = x + width;
    _spaces = 0;
    _spaceWidth = 0;
    _joinable = true;
    _hasContent = true;
    _ascent = math.max(_ascent, style.ascent);
    _descent = math.max(_descent, style.descent);
  }

  void _flush() {
    final double ascent = _fragments.isEmpty ? _lastStyle.ascent : _ascent;
    final double descent = _fragments.isEmpty ? _lastStyle.descent : _descent;
    if (_fragments.isNotEmpty && align != FlowAlign.left) {
      final double slack = right - (_fragments.last.x + _fragments.last.width);
      if (slack > 0) {
        final double shift = align == FlowAlign.center ? slack / 2 : slack;
        for (final _Fragment fragment in _fragments) {
          fragment.x += shift;
        }
      }
    }
    lines.add(_Line(_fragments, ascent, (ascent + descent) * lineHeight));
    _fragments = [];
    _x = left;
    _ascent = 0;
    _descent = 0;
    _spaces = 0;
    _spaceWidth = 0;
    _joinable = false;
    _hasContent = false;
  }
}

class _Renderer {
  /// Room between a table cell's edge and what is in it.
  static const double cellPadH = 4;
  static const double cellPadV = 3;

  final FlowDocument source;
  final PdfDocument _document = PdfDocument();
  late final PdfSection _section;

  /// Indexed by `(bold ? 1 : 0) + (italic ? 2 : 0)`.
  final List<FlowFace> _faces;

  late final double _left;
  late final double _top;
  late final double _bottom;
  late final double _width;

  PdfGraphics? _graphics;
  double _y = 0;

  /// False until something is drawn on the current page. Spacing and page
  /// breaks at the top of a page are dropped, so no page comes out empty.
  bool _pageHasContent = false;

  /// Set by a page break and acted on by whatever is drawn next. A break
  /// with nothing after it must not leave a blank page at the end.
  bool _needsPage = true;

  final Map<int, PdfBrush> _brushes = {};
  final PdfPen _borderPen = PdfPen(PdfColor(120, 120, 120), width: 0.5);

  _Renderer(this.source, FlowFonts fonts)
    : _faces = [
        FlowFace(fonts.regular, const [PdfFontStyle.regular]),
        FlowFace(fonts.bold, const [PdfFontStyle.bold]),
        FlowFace(fonts.italic, const [PdfFontStyle.italic]),
        FlowFace(fonts.boldItalic, const [PdfFontStyle.bold, PdfFontStyle.italic]),
      ];

  Future<Uint8List> run(String title) async {
    try {
      _document.compressionLevel = PdfCompressionLevel.best;
      if (title.isNotEmpty) _document.documentInformation.title = title;

      // A file can claim any paper it likes; keep it to something a page
      // can actually be.
      final double pageWidth = _sane(source.pageWidth, 144, 4000, 595.3);
      final double pageHeight = _sane(source.pageHeight, 144, 4000, 841.9);
      double left = _sane(source.marginLeft, 0, pageWidth, 72);
      double right = _sane(source.marginRight, 0, pageWidth, 72);
      double top = _sane(source.marginTop, 0, pageHeight, 72);
      double bottom = _sane(source.marginBottom, 0, pageHeight, 72);
      if (pageWidth - left - right < 72) left = right = 36;
      if (pageHeight - top - bottom < 72) top = bottom = 36;
      _left = left;
      _top = top;
      _bottom = pageHeight - bottom;
      _width = pageWidth - left - right;

      // One section, orientation before size: see PdfService.appendImages.
      _section = _document.sections!.add();
      _section.pageSettings.margins.all = 0;
      _section.pageSettings.orientation = pageWidth > pageHeight
          ? PdfPageOrientation.landscape
          : PdfPageOrientation.portrait;
      _section.pageSettings.size = Size(pageWidth, pageHeight);

      _draw(_layout(source.blocks, _width, _bottom - _top));
      // An empty document is still a document: one blank page.
      if (_graphics == null) _newPage();
      return Uint8List.fromList(await _document.save());
    } finally {
      _document.dispose();
    }
  }

  /// [value] where it is a size a page could have, [fallback] otherwise.
  static double _sane(double value, double min, double max, double fallback) =>
      value.isFinite && value >= min && value <= max ? value : fallback;

  /// [value] held within [min]..[max]; [min] for something not a number.
  static double _within(double value, double min, double max) =>
      value.isFinite ? value.clamp(min, max).toDouble() : min;

  // --- Layout ----------------------------------------------------------------

  List<_Item> _layout(
    List<FlowBlock> blocks,
    double width,
    double maxHeight, {
    bool inCell = false,
  }) {
    final List<_Item> items = [];
    for (final FlowBlock block in blocks) {
      switch (block) {
        case FlowParagraph():
          final double before = _within(block.spaceBeforePt, 0, 200);
          final double after = _within(block.spaceAfterPt, 0, 200);
          if (before > 0) items.add(_Gap(before));
          items.addAll(_lines(block, width));
          if (after > 0) items.add(_Gap(after));
        case FlowImage():
          final _Picture? picture = _picture(block, width, maxHeight);
          if (picture != null) items.add(picture);
        case FlowTable():
          if (inCell) {
            // A table inside a table is read cell by cell, in order.
            for (final FlowRow row in block.rows) {
              for (final FlowCell cell in row.cells) {
                items.addAll(
                  _layout(cell.blocks, width, maxHeight, inCell: true),
                );
              }
            }
          } else {
            items.addAll(_rows(block, width, maxHeight));
          }
        case FlowPageBreak():
          if (!inCell) items.add(_Break());
      }
    }
    return items;
  }

  _Style _styleOf(FlowRun run) => _Style(
    _faces[(run.bold ? 1 : 0) + (run.italic ? 2 : 0)],
    // Halves are as fine as Word goes, and they keep the font cache small.
    (_within(run.sizePt, 4, 96) * 2).round() / 2,
    run.color ?? 0,
    run.underline,
    run.strike,
  );

  List<_Line> _lines(FlowParagraph paragraph, double width) {
    final double left = _within(paragraph.indentPt, 0, width * 0.7);
    final double right =
        width - _within(paragraph.rightIndentPt, 0, width * 0.3);
    final double firstLeft = (left + paragraph.firstLinePt)
        .clamp(0, math.max(0, right - 36))
        .toDouble();

    final _LineBuilder builder = _LineBuilder(
      left: left,
      right: right,
      firstLeft: firstLeft,
      align: paragraph.align,
      lineHeight: _within(paragraph.lineHeight, 0.8, 3),
      initial: _styleOf(
        paragraph.runs.isEmpty ? const FlowRun('') : paragraph.runs.first,
      ),
    );

    for (final FlowRun run in paragraph.runs) {
      final _Style style = _styleOf(run);
      final StringBuffer word = StringBuffer();
      void endWord() {
        if (word.isEmpty) return;
        builder.word(word.toString(), style);
        word.clear();
      }

      for (final int rune in run.text.runes) {
        if (rune == 0x0A || rune == 0x0B || rune == 0x0C || rune == 0x2028) {
          endWord();
          builder.newline(style);
        } else if (rune == 0x09) {
          endWord();
          builder.tab();
        } else if (_isSpace(rune)) {
          endWord();
          builder.space(style);
        } else if (!_isInvisible(rune)) {
          word.write(_drawable(rune, style.face));
        }
      }
      endWord();
    }
    return builder.finish();
  }

  static bool _isSpace(int rune) =>
      rune == 0x20 ||
      rune == 0xA0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200A) ||
      rune == 0x202F ||
      rune == 0x205F ||
      rune == 0x3000;

  /// Characters that take no room: controls, soft hyphens, joiners,
  /// direction marks, variation selectors.
  static bool _isInvisible(int rune) =>
      rune < 0x20 ||
      (rune >= 0x7F && rune <= 0x9F) ||
      rune == 0xAD ||
      (rune >= 0x200B && rune <= 0x200F) ||
      (rune >= 0x2029 && rune <= 0x202E) ||
      (rune >= 0x2060 && rune <= 0x2064) ||
      (rune >= 0xFE00 && rune <= 0xFE0F) ||
      rune == 0xFEFF ||
      rune == 0xFFFC;

  /// The character to draw for [rune].
  ///
  /// One the font lacks must never reach Syncfusion: it draws the space
  /// glyph for it and then records that glyph as meaning the missing
  /// character, after which every real space in the document is extracted,
  /// searched and copied as that character.
  static String _drawable(int rune, FlowFace face) {
    if (rune == 0x2011) return '-';
    if (rune <= 0xFFFF && face.has(rune)) return String.fromCharCode(rune);
    return face.has(0xFFFD) ? '\uFFFD' : '?';
  }

  _Picture? _picture(FlowImage image, double width, double maxHeight) {
    final PdfBitmap? bitmap = _bitmap(image.bytes);
    if (bitmap == null) return null;
    double w = image.widthPt;
    double h = image.heightPt;
    if (!(w > 0 && h > 0)) {
      // Unsized: one pixel is 1/96 inch, as Word assumes.
      w = bitmap.width * 0.75;
      h = bitmap.height * 0.75;
    }
    if (!(w > 0 && h > 0)) return null;
    final double fit = math.min(1, math.min(width / w, maxHeight / h));
    w *= fit;
    h *= fit;
    final double slack = width - w;
    final double x = switch (image.align) {
      FlowAlign.left => 0,
      FlowAlign.center => slack / 2,
      FlowAlign.right => slack,
    };
    return _Picture(bitmap, x, w, h);
  }

  /// Syncfusion places JPEG and plain PNG as they are. The other formats a
  /// Word file commonly holds are re-encoded; the rest (EMF, WMF) are left
  /// out.
  static PdfBitmap? _bitmap(Uint8List bytes) {
    bool starts(List<int> magic, [int offset = 0]) {
      if (bytes.length < offset + magic.length) return false;
      for (int i = 0; i < magic.length; i++) {
        if (bytes[offset + i] != magic[i]) return false;
      }
      return true;
    }

    try {
      final bool png = bytes.length > 29 && starts(const [0x89, 0x50, 0x4E, 0x47]);
      // 16-bit and interlaced PNGs are the ones its decoder is not sure of.
      final bool plainPng = png && bytes[24] <= 8 && bytes[28] == 0;
      if (starts(const [0xFF, 0xD8, 0xFF]) || plainPng) return PdfBitmap(bytes);

      // Chosen by signature. Letting the decoder guess would have it read
      // any bytes at all as one of the formats that has none, and draw
      // noise where the document had a vector drawing.
      final img.Image? decoded;
      if (png) {
        decoded = img.decodePng(bytes);
      } else if (starts(const [0x47, 0x49, 0x46, 0x38])) {
        decoded = img.decodeGif(bytes);
      } else if (starts(const [0x42, 0x4D])) {
        decoded = img.decodeBmp(bytes);
      } else if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
          starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
        decoded = img.decodeWebP(bytes);
      } else if (starts(const [0x49, 0x49, 0x2A, 0x00]) ||
          starts(const [0x4D, 0x4D, 0x00, 0x2A])) {
        decoded = img.decodeTiff(bytes);
      } else {
        decoded = null;
      }
      if (decoded == null) return null;
      return PdfBitmap(
        decoded.numChannels == 4
            ? img.encodePng(decoded)
            : img.encodeJpg(decoded, quality: 88),
      );
    } catch (_) {
      return null;
    }
  }

  List<_Row> _rows(FlowTable table, double width, double maxHeight) {
    List<double> grid = table.columnWidths
        .where((w) => w.isFinite && w > 0)
        .toList(growable: false);
    if (grid.length != table.columnWidths.length) grid = const [];
    final double total = grid.fold<double>(0, (sum, w) => sum + w);
    if (total > width) {
      grid = [for (final double w in grid) w * width / total];
    }

    final List<_Row> rows = [];
    for (final FlowRow row in table.rows) {
      if (row.cells.isEmpty) continue;
      final int units = row.cells.fold<int>(
        0,
        (sum, cell) => sum + math.max(1, cell.span),
      );
      // A row the grid does not describe shares the width equally.
      final bool gridFits = grid.length >= units;
      final List<_CellBox> cells = [];
      double x = 0;
      int column = 0;
      for (final FlowCell cell in row.cells) {
        final int span = math.max(1, cell.span);
        double cellWidth = 0;
        if (gridFits) {
          for (int i = column; i < column + span; i++) {
            cellWidth += grid[i];
          }
        } else {
          cellWidth = width * span / units;
        }
        column += span;
        final List<_Item> items = _layout(
          cell.blocks,
          math.max(cellWidth - 2 * cellPadH, 12),
          maxHeight - 2 * cellPadV,
          inCell: true,
        );
        // Paragraph spacing against a cell's own edge would only pad it.
        while (items.isNotEmpty && items.first is _Gap) {
          items.removeAt(0);
        }
        while (items.isNotEmpty && items.last is _Gap) {
          items.removeLast();
        }
        cells.add(_CellBox(x, cellWidth, items, cell.fill));
        x += cellWidth;
      }
      rows.add(_Row(cells, table.bordered));
    }
    return rows;
  }

  // --- Drawing ---------------------------------------------------------------

  void _newPage() {
    _graphics = _section.pages.add().graphics;
    _y = _top;
    _pageHasContent = false;
    _needsPage = false;
  }

  /// Makes sure [height] fits below the cursor, turning the page if not.
  void _fit(double height) {
    if (_needsPage || (_pageHasContent && _y + height > _bottom + 0.01)) {
      _newPage();
    }
  }

  void _draw(List<_Item> items) {
    for (final _Item item in items) {
      switch (item) {
        case _Break():
          if (_pageHasContent) {
            _needsPage = true;
            _pageHasContent = false;
          }
        case _Gap():
          if (_pageHasContent) _y = math.min(_y + item.height, _bottom);
        case _Line():
          _fit(item.height);
          _drawLine(item, _left, _y);
          _y += item.height;
          _pageHasContent = true;
        case _Picture():
          _fit(item.height);
          _drawPicture(item, _left, _y);
          _y += item.height;
          _pageHasContent = true;
        case _Row():
          _drawRow(item);
      }
    }
  }

  PdfBrush _brush(int color) => _brushes.putIfAbsent(
    color,
    () => PdfSolidBrush(_color(color)),
  );

  static PdfColor _color(int color) =>
      PdfColor((color >> 16) & 0xFF, (color >> 8) & 0xFF, color & 0xFF);

  void _drawLine(_Line line, double originX, double top) {
    final PdfGraphics graphics = _graphics!;
    final double baseline = top + line.ascent;
    for (final _Fragment fragment in line.fragments) {
      final _Style style = fragment.style;
      final double x = originX + fragment.x;
      graphics.drawString(
        fragment.text.toString(),
        style.font,
        brush: _brush(style.color),
        // No width: the line is already broken, and must not be again.
        bounds: Rect.fromLTWH(x, baseline - style.ascent, 0, 0),
      );
      if (!style.underline && !style.strike) continue;
      final PdfPen pen = PdfPen(_color(style.color), width: style.size / 18);
      if (style.underline) {
        final double y = baseline + style.size * 0.1;
        graphics.drawLine(pen, Offset(x, y), Offset(x + fragment.width, y));
      }
      if (style.strike) {
        final double y = baseline - style.size * 0.28;
        graphics.drawLine(pen, Offset(x, y), Offset(x + fragment.width, y));
      }
    }
  }

  void _drawPicture(_Picture picture, double originX, double top) {
    try {
      _graphics!.drawImage(
        picture.bitmap,
        Rect.fromLTWH(originX + picture.x, top, picture.width, picture.height),
      );
    } catch (_) {
      // One picture the writer cannot place should not sink the document.
    }
  }

  /// Draws a table row, across as many pages as its tallest cell needs.
  void _drawRow(_Row row) {
    if (_needsPage) _newPage();
    // A row a page can hold whole is not started where it would be split.
    if (_pageHasContent &&
        _y + row.height > _bottom + 0.01 &&
        row.height <= _bottom - _top) {
      _newPage();
    }

    final int count = row.cells.length;
    List<int> cursor = List<int>.filled(count, 0);
    while (true) {
      final double room = _bottom - _y - 2 * cellPadV;
      final List<int> end = List<int>.of(cursor);
      double tallest = 0;
      bool pending = false;
      bool moved = false;
      for (int c = 0; c < count; c++) {
        final List<_Item> items = row.cells[c].items;
        double used = 0;
        int i = cursor[c];
        if (i < items.length) pending = true;
        while (i < items.length && used + items[i].height <= room + 0.01) {
          used += items[i].height;
          i++;
        }
        if (i > cursor[c]) moved = true;
        end[c] = i;
        tallest = math.max(tallest, used);
      }
      if (pending && !moved) {
        if (_pageHasContent) {
          _newPage();
          continue;
        }
        // Too tall even for an empty page: take it anyway, or this loops.
        for (int c = 0; c < count; c++) {
          final List<_Item> items = row.cells[c].items;
          if (cursor[c] >= items.length) continue;
          end[c] = cursor[c] + 1;
          tallest = math.max(tallest, items[cursor[c]].height);
        }
      }

      final double height = tallest + 2 * cellPadV;
      final PdfGraphics graphics = _graphics!;
      bool done = true;
      for (int c = 0; c < count; c++) {
        final _CellBox cell = row.cells[c];
        final Rect box = Rect.fromLTWH(_left + cell.x, _y, cell.width, height);
        final int? fill = cell.fill;
        if (fill != null) {
          graphics.drawRectangle(brush: _brush(fill), bounds: box);
        }
        double y = _y + cellPadV;
        for (int i = cursor[c]; i < end[c]; i++) {
          final _Item item = cell.items[i];
          final double x = _left + cell.x + cellPadH;
          if (item is _Line) _drawLine(item, x, y);
          if (item is _Picture) _drawPicture(item, x, y);
          y += item.height;
        }
        if (row.bordered) graphics.drawRectangle(pen: _borderPen, bounds: box);
        if (end[c] < cell.items.length) done = false;
      }
      _y += height;
      _pageHasContent = true;
      if (done) return;
      cursor = end;
      _newPage();
    }
  }
}
