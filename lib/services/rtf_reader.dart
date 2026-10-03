import 'dart:typed_data';

import 'flow_document.dart';

/// Reads a Rich Text (.rtf) file into a [FlowDocument].
///
/// Text with its weight, slant, size and colour; paragraph alignment and
/// indents; simple tables; embedded PNG and JPEG pictures; the paper size.
/// Headers, footers, footnotes, fields' instructions and drawings are
/// skipped, as every destination this does not know is.
class RtfReader {
  /// Throws a [FormatException], with a message fit to show, when [bytes]
  /// is not RTF.
  static FlowDocument read(Uint8List bytes) {
    // RTF is seven-bit by definition; anything else is escaped.
    final String source = String.fromCharCodes(bytes);
    if (!source.trimLeft().startsWith(r'{\rtf')) {
      throw const FormatException('This is not a Rich Text document.');
    }
    return _Rtf(source).parse();
  }
}

class _State {
  bool bold = false;
  bool italic = false;
  bool underline = false;
  bool strike = false;
  bool hidden = false;
  double size = 12;
  int color = 0;

  /// Inside a group whose content is not document text.
  bool skip = false;

  /// How many characters after a `\u` are its fallback, to be dropped.
  int unicodeSkip = 1;

  _State copy() => _State()
    ..bold = bold
    ..italic = italic
    ..underline = underline
    ..strike = strike
    ..hidden = hidden
    ..size = size
    ..color = color
    ..skip = skip
    ..unicodeSkip = unicodeSkip;
}

class _Rtf {
  final String source;
  int _at = 0;

  _Rtf(this.source);

  /// Destinations whose content is something other than body text.
  static const Set<String> _skipped = {
    'fonttbl', 'stylesheet', 'info', 'header', 'headerl', 'headerr', //
    'headerf', 'footer', 'footerl', 'footerr', 'footerf', 'footnote',
    'generator', 'listtable', 'listoverridetable', 'revtbl', 'rsidtbl',
    'themedata', 'colorschememapping', 'datastore', 'latentstyles',
    'xmlnstbl', 'pgdsctbl', 'fldinst', 'object', 'objdata', 'shpinst',
    'nonshppict', 'bkmkstart', 'bkmkend', 'mmathPr', 'wgrffmtfilter',
    'filetbl', 'template', 'operator', 'comment', 'annotation', 'atnid',
    'atnauthor', 'pn', 'pntext', 'listtext',
  };

  /// Windows-1252 where it differs from Latin-1.
  static const List<int> _cp1252 = [
    0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, //
    0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019,
    0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A,
    0x0153, 0x9D, 0x017E, 0x0178,
  ];

  final List<_State> _stack = [];
  _State _state = _State();
  final List<int> _colors = [];

  final List<FlowBlock> _blocks = [];
  List<FlowRun> _runs = [];
  final StringBuffer _text = StringBuffer();
  int _pendingSkip = 0;

  FlowAlign _align = FlowAlign.left;
  double _indent = 0;
  double _firstLine = 0;
  double _spaceBefore = 0;
  double _spaceAfter = 0;
  bool _inTable = false;

  List<FlowBlock> _cell = [];
  List<FlowCell> _row = [];
  final List<FlowRow> _table = [];

  double _paperWidth = FlowDocument.a4Width;
  double _paperHeight = FlowDocument.a4Height;
  double _marginLeft = 72, _marginRight = 72, _marginTop = 72, _marginBottom = 72;

  void _flushText() {
    if (_text.isEmpty) return;
    final String text = _text.toString();
    _text.clear();
    if (_state.skip || _state.hidden) return;
    _runs.add(
      FlowRun(
        text,
        sizePt: _state.size,
        bold: _state.bold,
        italic: _state.italic,
        underline: _state.underline,
        strike: _state.strike,
        color: _state.color > 0 && _state.color < _colors.length
            ? _colors[_state.color]
            : null,
      ),
    );
  }

  void _endParagraph() {
    _flushText();
    final FlowParagraph paragraph = FlowParagraph(
      _runs.isEmpty ? [FlowRun('', sizePt: _state.size)] : _runs,
      align: _align,
      indentPt: _indent,
      firstLinePt: _firstLine,
      spaceBeforePt: _spaceBefore,
      spaceAfterPt: _spaceAfter,
      lineHeight: 1.15,
    );
    _runs = [];
    if (_inTable) {
      _cell.add(paragraph);
    } else {
      _endTable();
      _blocks.add(paragraph);
    }
  }

  void _endCell() {
    _flushText();
    if (_runs.isNotEmpty || _cell.isEmpty) {
      _cell.add(
        FlowParagraph(
          _runs.isEmpty ? [FlowRun('', sizePt: _state.size)] : _runs,
          align: _align,
        ),
      );
    }
    _runs = [];
    _row.add(FlowCell(_cell));
    _cell = [];
  }

  void _endRow() {
    if (_row.isNotEmpty) _table.add(FlowRow(_row));
    _row = [];
  }

  void _endTable() {
    if (_table.isEmpty) return;
    _blocks.add(FlowTable(List<FlowRow>.of(_table)));
    _table.clear();
  }

  void _char(int code) {
    if (_pendingSkip > 0) {
      _pendingSkip--;
      return;
    }
    if (_state.skip) return;
    _text.writeCharCode(code);
  }

  FlowDocument parse() {
    while (_at < source.length) {
      final String ch = source[_at];
      if (ch == '{') {
        _flushText();
        _stack.add(_state);
        _state = _state.copy();
        _at++;
      } else if (ch == '}') {
        _flushText();
        if (_stack.isNotEmpty) _state = _stack.removeLast();
        _at++;
      } else if (ch == r'\') {
        _control();
      } else if (ch == '\r' || ch == '\n') {
        _at++;
      } else {
        _char(ch.codeUnitAt(0));
        _at++;
      }
    }
    _flushText();
    if (_runs.isNotEmpty) _endParagraph();
    if (_row.isNotEmpty || _cell.isNotEmpty) {
      if (_cell.isNotEmpty) _row.add(FlowCell(_cell));
      _endRow();
    }
    _endTable();
    return FlowDocument(
      _blocks.isEmpty ? const [FlowParagraph([FlowRun('')])] : _blocks,
      pageWidth: _paperWidth,
      pageHeight: _paperHeight,
      marginLeft: _marginLeft,
      marginRight: _marginRight,
      marginTop: _marginTop,
      marginBottom: _marginBottom,
    );
  }

  void _control() {
    _at++; // The backslash.
    if (_at >= source.length) return;
    final String next = source[_at];
    final int unit = next.codeUnitAt(0);
    final bool letter = (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122);
    if (!letter) {
      _at++;
      switch (next) {
        case "'":
          final int? byte = int.tryParse(
            source.substring(_at, (_at + 2).clamp(0, source.length)),
            radix: 16,
          );
          _at += 2;
          if (byte != null) {
            _char(byte >= 0x80 && byte <= 0x9F ? _cp1252[byte - 0x80] : byte);
          }
        case '*':
          // "Skip this group if you do not know what follows."
          final RegExpMatch? word = RegExp(
            r'^\\([a-zA-Z]+)',
          ).firstMatch(source.substring(_at, (_at + 40).clamp(0, source.length)));
          if (word == null || !_keepsStarred(word.group(1)!)) {
            _flushText();
            _state.skip = true;
          }
        case '~':
          _char(0xA0);
        case '_':
          _char(0x2D);
        case '-':
          break;
        case '\n' || '\r':
          _endParagraph();
        default:
          // \\, \{ and \}: the character itself.
          _char(next.codeUnitAt(0));
      }
      return;
    }

    final int start = _at;
    while (_at < source.length) {
      final int c = source.codeUnitAt(_at);
      if (!((c >= 65 && c <= 90) || (c >= 97 && c <= 122))) break;
      _at++;
    }
    final String word = source.substring(start, _at);
    int? value;
    final int numberStart = _at;
    if (_at < source.length && source[_at] == '-') _at++;
    while (_at < source.length) {
      final int c = source.codeUnitAt(_at);
      if (c < 48 || c > 57) break;
      _at++;
    }
    if (_at > numberStart) {
      value = int.tryParse(source.substring(numberStart, _at));
    }
    // One space after a control word belongs to it.
    if (_at < source.length && source[_at] == ' ') _at++;
    _word(word, value);
  }

  static bool _keepsStarred(String word) =>
      word == 'shppict' || word == 'fldrslt';

  void _word(String word, int? value) {
    if (_skipped.contains(word)) {
      _flushText();
      _state.skip = true;
      return;
    }
    if (word == 'colortbl') {
      _colorTable();
      return;
    }
    if (word == 'pict') {
      _picture();
      return;
    }
    if (_state.skip) return;
    final bool on = value != 0;
    switch (word) {
      case 'par' || 'sect':
        _endParagraph();
      case 'line':
        _char(0x0A);
      case 'tab':
        _char(0x09);
      case 'page':
        _endParagraph();
        if (!_inTable) _blocks.add(const FlowPageBreak());
      case 'u':
        if (value != null) {
          _char(value < 0 ? value + 65536 : value);
          _pendingSkip = _state.unicodeSkip;
        }
      case 'uc':
        _state.unicodeSkip = value ?? 1;
      case 'b':
        _flushText();
        _state.bold = on;
      case 'i':
        _flushText();
        _state.italic = on;
      case 'ul' || 'uld' || 'uldb' || 'ulw':
        _flushText();
        _state.underline = on;
      case 'ulnone':
        _flushText();
        _state.underline = false;
      case 'strike':
        _flushText();
        _state.strike = on;
      case 'v':
        _flushText();
        _state.hidden = on;
      case 'fs':
        _flushText();
        if (value != null && value > 0) _state.size = value / 2;
      case 'cf':
        _flushText();
        _state.color = value ?? 0;
      case 'plain':
        _flushText();
        _state
          ..bold = false
          ..italic = false
          ..underline = false
          ..strike = false
          ..hidden = false
          ..size = 12
          ..color = 0;
      case 'pard':
        _align = FlowAlign.left;
        _indent = 0;
        _firstLine = 0;
        _spaceBefore = 0;
        _spaceAfter = 0;
        _inTable = false;
      case 'ql' || 'qj':
        _align = FlowAlign.left;
      case 'qc':
        _align = FlowAlign.center;
      case 'qr':
        _align = FlowAlign.right;
      case 'li':
        _indent = (value ?? 0) / 20;
      case 'fi':
        _firstLine = (value ?? 0) / 20;
      case 'sb':
        _spaceBefore = (value ?? 0) / 20;
      case 'sa':
        _spaceAfter = (value ?? 0) / 20;
      case 'intbl':
        _inTable = true;
      case 'cell':
        _inTable = true;
        _endCell();
      case 'row':
        _endRow();
      case 'paperw':
        if (value != null && value > 1440) _paperWidth = value / 20;
      case 'paperh':
        if (value != null && value > 1440) _paperHeight = value / 20;
      case 'margl':
        if (value != null) _marginLeft = value / 20;
      case 'margr':
        if (value != null) _marginRight = value / 20;
      case 'margt':
        if (value != null) _marginTop = value / 20;
      case 'margb':
        if (value != null) _marginBottom = value / 20;
      case 'emdash':
        _char(0x2014);
      case 'endash':
        _char(0x2013);
      case 'bullet':
        _char(0x2022);
      case 'lquote':
        _char(0x2018);
      case 'rquote':
        _char(0x2019);
      case 'ldblquote':
        _char(0x201C);
      case 'rdblquote':
        _char(0x201D);
    }
  }

  /// Reads `\red0\green0\blue0;` entries up to the end of the group.
  void _colorTable() {
    final int end = source.indexOf('}', _at);
    final String body = source.substring(_at, end < 0 ? source.length : end);
    _colors.clear();
    for (final String entry in body.split(';')) {
      int part(String name) =>
          int.tryParse(
            RegExp('\\\\$name(\\d+)').firstMatch(entry)?.group(1) ?? '',
          ) ??
          0;
      _colors.add((part('red') << 16) | (part('green') << 8) | part('blue'));
    }
    _at = end < 0 ? source.length : end;
  }

  /// Reads a picture group: its format and size from the control words,
  /// then the bytes as hex.
  void _picture() {
    final int end = _groupEnd(_at);
    final String body = source.substring(_at, end);
    _at = end;
    if (_state.skip) return;
    final bool supported =
        body.contains(r'\pngblip') || body.contains(r'\jpegblip');
    if (!supported) return;
    double goal(String name) =>
        (int.tryParse(
              RegExp('\\\\$name(\\d+)').firstMatch(body)?.group(1) ?? '',
            ) ??
            0) /
        20;
    final StringBuffer hex = StringBuffer();
    // The data is what is left once every control word is taken out.
    final String data = body.replaceAll(RegExp(r'\\[a-zA-Z]+-?\d* ?'), '');
    for (final int unit in data.codeUnits) {
      final bool digit =
          (unit >= 48 && unit <= 57) ||
          (unit >= 65 && unit <= 70) ||
          (unit >= 97 && unit <= 102);
      if (digit) hex.writeCharCode(unit);
    }
    final String digits = hex.toString();
    if (digits.length < 16) return;
    final Uint8List bytes = Uint8List(digits.length ~/ 2);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(digits.substring(i * 2, i * 2 + 2), radix: 16);
    }
    _flushText();
    if (_runs.isNotEmpty) _endParagraph();
    final FlowImage image = FlowImage(
      bytes,
      widthPt: goal('picwgoal'),
      heightPt: goal('pichgoal'),
      align: _align,
    );
    if (_inTable) {
      _cell.add(image);
    } else {
      _endTable();
      _blocks.add(image);
    }
  }

  /// The index of the brace that closes the group [from] is inside.
  int _groupEnd(int from) {
    int depth = 0;
    for (int i = from; i < source.length; i++) {
      final String ch = source[i];
      if (ch == r'\') {
        i++;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        if (depth == 0) return i;
        depth--;
      }
    }
    return source.length;
  }
}
