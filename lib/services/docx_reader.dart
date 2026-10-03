import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'flow_document.dart';

/// Reads a Word (.docx) file into a [FlowDocument].
///
/// The counterpart of [DocxWriter], and as selective: text with its size,
/// weight, colour and alignment; paragraph spacing and indents; numbered and
/// bulleted lists; tables; pictures; page breaks; the paper size. Headers,
/// footers, footnotes, comments, columns and floating layout are not read,
/// and tracked deletions are left out as Word would show them accepted.
///
/// Elements are matched by local name. The `w:` prefix is a convention, not
/// a rule, and files written by other tools do use others.
class DocxReader {
  /// Largest XML part worth parsing. A real document's body is a few
  /// megabytes at most; anything far past that is a zip bomb or a mistake.
  static const int _maxPartBytes = 64 * 1024 * 1024;

  /// Throws a [FormatException] with a message fit to show the user.
  static FlowDocument read(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('This is not a Word document.');
    }
    return _DocxReader(archive).read();
  }
}

String? _attr(XmlElement? element, String local) {
  if (element == null) return null;
  for (final XmlAttribute attribute in element.attributes) {
    if (attribute.name.local == local) return attribute.value;
  }
  return null;
}

XmlElement? _child(XmlElement? element, String local) {
  if (element == null) return null;
  for (final XmlElement child in element.childElements) {
    if (child.name.local == local) return child;
  }
  return null;
}

Iterable<XmlElement> _children(XmlElement? element, String local) =>
    element == null
    ? const []
    : element.childElements.where((e) => e.name.local == local);

/// A measurement in twentieths of a point, as points.
double? _twips(String? value) {
  final double? parsed = value == null ? null : double.tryParse(value);
  return parsed == null ? null : parsed / 20;
}

/// An on/off property: absent means "not said", present means on unless it
/// carries an explicit off.
bool? _toggle(XmlElement? properties, String local) {
  final XmlElement? element = _child(properties, local);
  if (element == null) return null;
  final String? value = _attr(element, 'val');
  return !(value == '0' || value == 'false' || value == 'off');
}

int? _hexColor(String? value) {
  if (value == null || value.length != 6) return null;
  return int.tryParse(value, radix: 16);
}

/// Run formatting. Null means "inherit".
class _RunProps {
  bool? bold;
  bool? italic;
  bool? underline;
  bool? strike;
  bool? caps;
  bool? hidden;
  double? size;

  /// 0xRRGGBB, or [automatic] for "whatever the default is".
  int? color;
  String? style;

  static const int automatic = -1;

  _RunProps();

  factory _RunProps.parse(XmlElement? rPr) {
    final _RunProps props = _RunProps();
    if (rPr == null) return props;
    props.bold = _toggle(rPr, 'b');
    props.italic = _toggle(rPr, 'i');
    props.strike = _toggle(rPr, 'strike') ?? _toggle(rPr, 'dstrike');
    props.caps = _toggle(rPr, 'caps');
    props.hidden = _toggle(rPr, 'vanish');
    final XmlElement? underline = _child(rPr, 'u');
    if (underline != null) props.underline = _attr(underline, 'val') != 'none';
    final double? halfPoints = double.tryParse(
      _attr(_child(rPr, 'sz'), 'val') ?? '',
    );
    if (halfPoints != null && halfPoints > 0) props.size = halfPoints / 2;
    final String? color = _attr(_child(rPr, 'color'), 'val');
    if (color != null) {
      props.color = color == 'auto' ? automatic : _hexColor(color);
    }
    props.style = _attr(_child(rPr, 'rStyle'), 'val');
    return props;
  }

  /// These properties, with whatever [over] says laid on top.
  _RunProps merged(_RunProps over) => _RunProps()
    ..bold = over.bold ?? bold
    ..italic = over.italic ?? italic
    ..underline = over.underline ?? underline
    ..strike = over.strike ?? strike
    ..caps = over.caps ?? caps
    ..hidden = over.hidden ?? hidden
    ..size = over.size ?? size
    ..color = over.color ?? color
    ..style = over.style ?? style;
}

/// Paragraph formatting. Null means "inherit".
class _ParaProps {
  FlowAlign? align;
  double? left;
  double? right;

  /// First-line offset; negative for a hanging indent.
  double? firstLine;
  double? before;
  double? after;

  /// Line spacing as a multiple of single.
  double? line;
  String? numId;
  int? level;
  bool? pageBreakBefore;

  /// "Don't add space between paragraphs of the same style", which is what
  /// keeps the items of a list together.
  bool? contextual;
  String? style;

  _ParaProps();

  factory _ParaProps.parse(XmlElement? pPr) {
    final _ParaProps props = _ParaProps();
    if (pPr == null) return props;
    props.style = _attr(_child(pPr, 'pStyle'), 'val');
    props.pageBreakBefore = _toggle(pPr, 'pageBreakBefore');
    props.contextual = _toggle(pPr, 'contextualSpacing');
    props.align = switch (_attr(_child(pPr, 'jc'), 'val')) {
      null => null,
      'center' => FlowAlign.center,
      'right' || 'end' => FlowAlign.right,
      // Justified text is set ragged; stretching spaces is not worth it.
      _ => FlowAlign.left,
    };

    final XmlElement? indent = _child(pPr, 'ind');
    if (indent != null) {
      props.left = _twips(_attr(indent, 'left') ?? _attr(indent, 'start'));
      props.right = _twips(_attr(indent, 'right') ?? _attr(indent, 'end'));
      final double? hanging = _twips(_attr(indent, 'hanging'));
      props.firstLine = hanging != null
          ? -hanging
          : _twips(_attr(indent, 'firstLine'));
    }

    final XmlElement? spacing = _child(pPr, 'spacing');
    if (spacing != null) {
      props.before = _twips(_attr(spacing, 'before'));
      props.after = _twips(_attr(spacing, 'after'));
      final double? line = double.tryParse(_attr(spacing, 'line') ?? '');
      final String rule = _attr(spacing, 'lineRule') ?? 'auto';
      // "auto" counts in 240ths of a line. The exact and at-least rules are
      // in points and depend on the font, so they are left at single.
      if (line != null && line > 0 && rule == 'auto') props.line = line / 240;
    }

    final XmlElement? numbering = _child(pPr, 'numPr');
    if (numbering != null) {
      props.numId = _attr(_child(numbering, 'numId'), 'val');
      props.level = int.tryParse(_attr(_child(numbering, 'ilvl'), 'val') ?? '');
    }
    return props;
  }

  _ParaProps merged(_ParaProps over) => _ParaProps()
    ..align = over.align ?? align
    ..left = over.left ?? left
    ..right = over.right ?? right
    ..firstLine = over.firstLine ?? firstLine
    ..before = over.before ?? before
    ..after = over.after ?? after
    ..line = over.line ?? line
    ..numId = over.numId ?? numId
    ..level = over.level ?? level
    ..pageBreakBefore = over.pageBreakBefore ?? pageBreakBefore
    ..contextual = over.contextual ?? contextual
    ..style = over.style ?? style;
}

class _Style {
  final String? basedOn;
  final _ParaProps para;
  final _RunProps run;

  /// For a table style: whether it outlines its cells.
  final bool borders;

  _Style(this.basedOn, this.para, this.run, this.borders);
}

/// One level of a list definition.
class _Level {
  int start = 1;
  String format = 'decimal';

  /// The label pattern; `%1` stands for the first level's number.
  String text = '';
  _ParaProps para = _ParaProps();
}

/// The paragraph most recently written, for the one after it to check
/// whether the two are neighbours of the same style.
class _Written {
  final List<FlowBlock> out;
  final int index;
  final String? style;
  final bool contextual;

  _Written(this.out, this.index, this.style, this.contextual);
}

/// What a paragraph's children are collected into.
class _ParagraphSink {
  final _ParaProps para;
  final FlowAlign align;
  final List<FlowBlock> out;
  List<FlowRun> runs = [];

  /// Pictures and text boxes anchored in the paragraph, emitted after it.
  final List<FlowBlock> trailing = [];

  /// False once a piece of the paragraph has been emitted, so space above
  /// and the first-line indent are only applied once.
  bool first = true;

  _ParagraphSink(this.para, this.align, this.out);
}

class _DocxReader {
  final Archive archive;

  _RunProps _defaultRun = _RunProps();
  _ParaProps _defaultPara = _ParaProps();
  String? _defaultParaStyle;
  final Map<String, _Style> _styles = {};
  final Map<String, (_ParaProps, _RunProps)> _resolved = {};

  /// List definitions, by abstract id, and the lists that use them.
  final Map<String, Map<int, _Level>> _abstractLists = {};
  final Map<String, String> _listDefinition = {};
  final Map<String, Map<int, int>> _listStartOverrides = {};
  final Map<String, List<int?>> _counters = {};

  /// Relationship id to the part it names, for pictures.
  final Map<String, String> _relationships = {};

  XmlElement? _section;
  _Written? _previous;

  _DocxReader(this.archive);

  FlowDocument read() {
    final XmlDocument? document = _part('word/document.xml');
    final XmlElement? body = _child(document?.rootElement, 'body');
    if (body == null) {
      throw const FormatException('This is not a Word document.');
    }
    _readStyles(_part('word/styles.xml'));
    _readNumbering(_part('word/numbering.xml'));
    _readRelationships(_part('word/_rels/document.xml.rels'));

    final List<FlowBlock> blocks = [];
    _blocks(body, blocks);

    final XmlElement? size = _child(_section, 'pgSz');
    final XmlElement? margins = _child(_section, 'pgMar');
    return FlowDocument(
      blocks,
      pageWidth: _twips(_attr(size, 'w')) ?? FlowDocument.a4Width,
      pageHeight: _twips(_attr(size, 'h')) ?? FlowDocument.a4Height,
      marginLeft: _twips(_attr(margins, 'left'))?.abs() ?? 72,
      marginRight: _twips(_attr(margins, 'right'))?.abs() ?? 72,
      // Word writes a negative margin to mean "exactly this, whatever the
      // header needs"; either way it is a distance.
      marginTop: _twips(_attr(margins, 'top'))?.abs() ?? 72,
      marginBottom: _twips(_attr(margins, 'bottom'))?.abs() ?? 72,
    );
  }

  // --- Parts -----------------------------------------------------------------

  Uint8List? _bytes(String name) {
    final ArchiveFile? file = archive.findFile(name);
    if (file == null || !file.isFile) return null;
    if (file.size > DocxReader._maxPartBytes) {
      throw const FormatException('This document is too large to convert.');
    }
    return file.content;
  }

  XmlDocument? _part(String name) {
    final Uint8List? bytes = _bytes(name);
    if (bytes == null) return null;
    try {
      return XmlDocument.parse(utf8.decode(bytes, allowMalformed: true));
    } on XmlException {
      // The body is the document; a damaged side part only costs detail.
      if (name == 'word/document.xml') {
        throw const FormatException('This Word document is damaged.');
      }
      return null;
    }
  }

  void _readRelationships(XmlDocument? document) {
    for (final XmlElement relation in _children(
      document?.rootElement,
      'Relationship',
    )) {
      final String? id = _attr(relation, 'Id');
      final String? target = _attr(relation, 'Target');
      if (id == null || target == null) continue;
      if (_attr(relation, 'TargetMode') == 'External') continue;
      _relationships[id] = _resolve(target);
    }
  }

  /// Turns a relationship target, which is relative to `word/`, into the
  /// part's name in the archive.
  static String _resolve(String target) {
    if (target.startsWith('/')) return target.substring(1);
    final List<String> parts = ['word'];
    for (final String segment in target.split('/')) {
      if (segment == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (segment != '.' && segment.isNotEmpty) {
        parts.add(segment);
      }
    }
    return parts.join('/');
  }

  // --- Styles ----------------------------------------------------------------

  void _readStyles(XmlDocument? document) {
    final XmlElement? root = document?.rootElement;
    if (root == null) return;
    final XmlElement? defaults = _child(root, 'docDefaults');
    _defaultRun = _RunProps.parse(
      _child(_child(defaults, 'rPrDefault'), 'rPr'),
    );
    _defaultPara = _ParaProps.parse(
      _child(_child(defaults, 'pPrDefault'), 'pPr'),
    );
    for (final XmlElement style in _children(root, 'style')) {
      final String? id = _attr(style, 'styleId');
      if (id == null) continue;
      final String? type = _attr(style, 'type');
      final String? isDefault = _attr(style, 'default');
      if (type == 'paragraph' && (isDefault == '1' || isDefault == 'true')) {
        _defaultParaStyle = id;
      }
      _styles[id] = _Style(
        _attr(_child(style, 'basedOn'), 'val'),
        _ParaProps.parse(_child(style, 'pPr')),
        _RunProps.parse(_child(style, 'rPr')),
        _hasBorders(_child(_child(style, 'tblPr'), 'tblBorders')),
      );
    }
  }

  /// A style's own properties on top of everything it is based on.
  (_ParaProps, _RunProps) _styleProps(String? id) {
    if (id == null) return (_ParaProps(), _RunProps());
    final (_ParaProps, _RunProps)? known = _resolved[id];
    if (known != null) return known;
    _ParaProps para = _ParaProps();
    _RunProps run = _RunProps();
    // Walked from the style up to its root, then applied root first. The
    // visited set stops a file whose styles are based on each other.
    final List<_Style> chain = [];
    final Set<String> visited = {};
    String? current = id;
    while (current != null && visited.add(current)) {
      final _Style? style = _styles[current];
      if (style == null) break;
      chain.add(style);
      current = style.basedOn;
    }
    for (final _Style style in chain.reversed) {
      para = para.merged(style.para);
      run = run.merged(style.run);
    }
    return _resolved[id] = (para, run);
  }

  bool _styleHasBorders(String? id) {
    final Set<String> visited = {};
    String? current = id;
    while (current != null && visited.add(current)) {
      final _Style? style = _styles[current];
      if (style == null) return false;
      if (style.borders) return true;
      current = style.basedOn;
    }
    return false;
  }

  static bool _hasBorders(XmlElement? borders) {
    if (borders == null) return false;
    for (final XmlElement side in borders.childElements) {
      final String? value = _attr(side, 'val');
      if (value != null && value != 'none' && value != 'nil') return true;
    }
    return false;
  }

  // --- Lists -----------------------------------------------------------------

  void _readNumbering(XmlDocument? document) {
    final XmlElement? root = document?.rootElement;
    if (root == null) return;
    for (final XmlElement definition in _children(root, 'abstractNum')) {
      final String? id = _attr(definition, 'abstractNumId');
      if (id == null) continue;
      final Map<int, _Level> levels = {};
      for (final XmlElement lvl in _children(definition, 'lvl')) {
        final int? index = int.tryParse(_attr(lvl, 'ilvl') ?? '');
        if (index == null) continue;
        levels[index] = _Level()
          ..start = int.tryParse(_attr(_child(lvl, 'start'), 'val') ?? '') ?? 1
          ..format = _attr(_child(lvl, 'numFmt'), 'val') ?? 'decimal'
          ..text = _attr(_child(lvl, 'lvlText'), 'val') ?? ''
          ..para = _ParaProps.parse(_child(lvl, 'pPr'));
      }
      _abstractLists[id] = levels;
    }
    for (final XmlElement list in _children(root, 'num')) {
      final String? id = _attr(list, 'numId');
      final String? definition = _attr(_child(list, 'abstractNumId'), 'val');
      if (id == null || definition == null) continue;
      _listDefinition[id] = definition;
      for (final XmlElement override in _children(list, 'lvlOverride')) {
        final int? index = int.tryParse(_attr(override, 'ilvl') ?? '');
        final int? start = int.tryParse(
          _attr(_child(override, 'startOverride'), 'val') ?? '',
        );
        if (index == null || start == null) continue;
        (_listStartOverrides[id] ??= {})[index] = start;
      }
    }
  }

  _Level? _levelOf(String numId, int level) =>
      _abstractLists[_listDefinition[numId]]?[level];

  int _startOf(String numId, int level) =>
      _listStartOverrides[numId]?[level] ?? _levelOf(numId, level)?.start ?? 1;

  /// Advances the list's counter and returns the label for this item.
  String _nextLabel(String numId, int level) {
    final List<int?> counters = _counters[numId] ??= List<int?>.filled(9, null);
    counters[level] = (counters[level] ?? _startOf(numId, level) - 1) + 1;
    // A new item restarts everything nested under it.
    for (int i = level + 1; i < counters.length; i++) {
      counters[i] = null;
    }

    final _Level? definition = _levelOf(numId, level);
    if (definition == null) return '•';
    switch (definition.format) {
      case 'none':
        return '';
      case 'bullet':
        // The stored character is a code in a symbol font (Wingdings,
        // Symbol) that means nothing outside it.
        return level.isEven ? '•' : 'o';
    }
    return definition.text.replaceAllMapped(RegExp(r'%(\d)'), (match) {
      final int index = int.parse(match.group(1)!) - 1;
      if (index < 0 || index >= counters.length) return '';
      return _formatNumber(
        counters[index] ?? _startOf(numId, index),
        _levelOf(numId, index)?.format ?? 'decimal',
      );
    });
  }

  static String _formatNumber(int value, String format) {
    switch (format) {
      case 'lowerLetter':
        return _letters(value);
      case 'upperLetter':
        return _letters(value).toUpperCase();
      case 'lowerRoman':
        return _roman(value).toLowerCase();
      case 'upperRoman':
        return _roman(value);
      case 'decimalZero':
        return value.toString().padLeft(2, '0');
      default:
        return value.toString();
    }
  }

  /// 1 → a, 26 → z, 27 → aa, the way Word repeats the letter.
  static String _letters(int value) {
    if (value < 1) return value.toString();
    final String letter = String.fromCharCode(0x61 + (value - 1) % 26);
    return letter * ((value - 1) ~/ 26 + 1);
  }

  static String _roman(int value) {
    if (value < 1 || value > 3999) return value.toString();
    const List<(int, String)> numerals = [
      (1000, 'M'), (900, 'CM'), (500, 'D'), (400, 'CD'), (100, 'C'),
      (90, 'XC'), (50, 'L'), (40, 'XL'), (10, 'X'), (9, 'IX'), (5, 'V'),
      (4, 'IV'), (1, 'I'),
    ];
    final StringBuffer out = StringBuffer();
    int rest = value;
    for (final (int amount, String numeral) in numerals) {
      while (rest >= amount) {
        out.write(numeral);
        rest -= amount;
      }
    }
    return out.toString();
  }

  // --- Body ------------------------------------------------------------------

  /// The element to read out of an `mc:AlternateContent`: the modern form
  /// if there is one, the fallback otherwise — never both, they are the
  /// same content twice.
  static XmlElement? _alternative(XmlElement alternate) =>
      _child(alternate, 'Choice') ?? _child(alternate, 'Fallback');

  void _blocks(XmlElement container, List<FlowBlock> out) {
    for (final XmlElement element in container.childElements) {
      switch (element.name.local) {
        case 'p':
          _paragraph(element, out);
        case 'tbl':
          out.add(_table(element));
        case 'sdt':
          final XmlElement? content = _child(element, 'sdtContent');
          if (content != null) _blocks(content, out);
        case 'customXml' || 'ins' || 'moveTo' || 'smartTag':
          _blocks(element, out);
        case 'AlternateContent':
          final XmlElement? chosen = _alternative(element);
          if (chosen != null) _blocks(chosen, out);
        case 'sectPr':
          _section = element;
      }
    }
  }

  void _paragraph(XmlElement paragraph, List<FlowBlock> out) {
    final XmlElement? pPr = _child(paragraph, 'pPr');
    final _ParaProps direct = _ParaProps.parse(pPr);
    final String? styleId = direct.style ?? _defaultParaStyle;
    final (_ParaProps stylePara, _RunProps styleRun) = _styleProps(styleId);
    _ParaProps para = _defaultPara.merged(stylePara);

    // A list can be asked for by the paragraph or by its style, and brings
    // its own indent, which sits between the style's and the paragraph's.
    final String? numId = direct.numId ?? para.numId;
    final int level = (direct.level ?? para.level ?? 0).clamp(0, 8);
    final bool listed = numId != null && numId != '0';
    if (listed) {
      final _Level? definition = _levelOf(numId, level);
      if (definition != null) para = para.merged(definition.para);
    }
    para = para.merged(direct);

    final _RunProps base = _defaultRun.merged(styleRun);
    final _RunProps mark = base.merged(_RunProps.parse(_child(pPr, 'rPr')));

    if (para.pageBreakBefore == true) out.add(const FlowPageBreak());

    // Two neighbours in the same style close up, each giving up the space
    // on its own side of the join if it asks for that.
    final _Written? previous = _previous;
    final bool contextual = para.contextual == true;
    if (previous != null &&
        identical(previous.out, out) &&
        previous.index == out.length - 1 &&
        previous.style == styleId) {
      if (previous.contextual) {
        final FlowParagraph above = out[previous.index] as FlowParagraph;
        out[previous.index] = FlowParagraph(
          above.runs,
          align: above.align,
          indentPt: above.indentPt,
          firstLinePt: above.firstLinePt,
          rightIndentPt: above.rightIndentPt,
          spaceBeforePt: above.spaceBeforePt,
          lineHeight: above.lineHeight,
        );
      }
      if (contextual) para.before = 0;
    }

    final _ParagraphSink sink = _ParagraphSink(
      para,
      para.align ?? FlowAlign.left,
      out,
    );
    if (listed) {
      final String label = _nextLabel(numId, level);
      if (label.isNotEmpty) {
        // The label takes its size from the paragraph, not its emphasis.
        sink.runs.add(FlowRun('$label\t', sizePt: mark.size ?? 10));
      }
    }
    _inlines(paragraph, base, sink);
    _emit(sink, mark, last: true);
    _previous = out.isNotEmpty && out.last is FlowParagraph
        ? _Written(out, out.length - 1, styleId, contextual)
        : null;

    // A section that ends here starts the next one on a new page, unless
    // it is marked as continuing on the same one.
    final XmlElement? section = _child(pPr, 'sectPr');
    if (section != null) {
      _section ??= section;
      if (_attr(_child(section, 'type'), 'val') != 'continuous') {
        out.add(const FlowPageBreak());
      }
    }
  }

  /// Writes out what the sink has gathered as a paragraph.
  void _emit(_ParagraphSink sink, _RunProps mark, {required bool last}) {
    final _ParaProps para = sink.para;
    final bool hasText = sink.runs.any((run) => run.text.isNotEmpty);
    // A paragraph that only holds a picture is the picture, and one that
    // holds nothing at all is a blank line, as tall as its (invisible) mark.
    // The empty halves either side of a page break are neither: a blank
    // line there could spill onto a page of its own.
    final bool blank = sink.trailing.isEmpty && sink.first && last;
    if (hasText || blank) {
      sink.out.add(
        FlowParagraph(
          hasText ? sink.runs : [FlowRun('', sizePt: mark.size ?? 10)],
          align: sink.align,
          indentPt: para.left ?? 0,
          firstLinePt: sink.first ? para.firstLine ?? 0 : 0,
          rightIndentPt: para.right ?? 0,
          spaceBeforePt: sink.first ? para.before ?? 0 : 0,
          spaceAfterPt: last ? para.after ?? 0 : 0,
          lineHeight: para.line ?? 1,
        ),
      );
    }
    sink.out.addAll(sink.trailing);
    sink.trailing.clear();
    sink.runs = [];
    sink.first = false;
  }

  /// Reads the runs of a paragraph, or of something inside one that holds
  /// runs of its own.
  void _inlines(XmlElement container, _RunProps base, _ParagraphSink sink) {
    for (final XmlElement element in container.childElements) {
      switch (element.name.local) {
        case 'r':
          _run(element, base, sink);
        // Wrappers around ordinary runs. A tracked insertion is text; a
        // tracked deletion ('del', 'moveFrom') is not, and is not listed.
        case 'hyperlink' ||
            'ins' ||
            'moveTo' ||
            'smartTag' ||
            'fldSimple' ||
            'customXml' ||
            'dir' ||
            'bdo':
          _inlines(element, base, sink);
        case 'sdt':
          final XmlElement? content = _child(element, 'sdtContent');
          if (content != null) _inlines(content, base, sink);
        case 'oMath' || 'oMathPara':
          // An equation, as the characters in it; the layout is lost.
          final String text = element.descendantElements
              .where((e) => e.name.local == 't')
              .map((e) => e.innerText)
              .join();
          if (text.isNotEmpty) sink.runs.add(_flowRun(text, base));
      }
    }
  }

  FlowRun _flowRun(String text, _RunProps props) => FlowRun(
    props.caps == true ? text.toUpperCase() : text,
    // Word's own fallback when a file names no size anywhere.
    sizePt: props.size ?? 10,
    bold: props.bold ?? false,
    italic: props.italic ?? false,
    underline: props.underline ?? false,
    strike: props.strike ?? false,
    color: props.color == _RunProps.automatic ? null : props.color,
  );

  void _run(XmlElement run, _RunProps base, _ParagraphSink sink) {
    final _RunProps direct = _RunProps.parse(_child(run, 'rPr'));
    final _RunProps props = base
        .merged(_styleProps(direct.style).$2)
        .merged(direct);
    if (props.hidden == true) return;

    final StringBuffer text = StringBuffer();
    void endText() {
      if (text.isEmpty) return;
      sink.runs.add(_flowRun(text.toString(), props));
      text.clear();
    }

    for (final XmlElement element in run.childElements) {
      switch (element.name.local) {
        case 't':
          text.write(element.innerText);
        case 'tab':
          text.write('\t');
        case 'cr':
          text.write('\n');
        case 'noBreakHyphen':
          text.write('-');
        case 'br':
          if (_attr(element, 'type') == 'page') {
            endText();
            _emit(sink, props, last: false);
            sink.out.add(const FlowPageBreak());
          } else {
            text.write('\n');
          }
        case 'drawing' || 'pict' || 'object':
          _graphic(element, sink, null);
        case 'AlternateContent':
          final XmlElement? chosen = _alternative(element);
          if (chosen != null) _graphic(chosen, sink, null);
      }
    }
    endText();
  }

  // --- Pictures and text boxes -----------------------------------------------

  /// Walks a drawing for the two things worth keeping: pictures, and the
  /// paragraphs of any text box. [extent] is the size, in points, of the
  /// nearest enclosing shape that states one.
  void _graphic(
    XmlElement element,
    _ParagraphSink sink,
    (double, double)? extent,
  ) {
    for (final XmlElement child in element.childElements) {
      switch (child.name.local) {
        case 'txbxContent':
          _blocks(child, sink.trailing);
        case 'AlternateContent':
          final XmlElement? chosen = _alternative(child);
          if (chosen != null) _graphic(chosen, sink, extent);
        case 'blip':
          _picture(_attr(child, 'embed'), sink, extent);
        case 'imagedata':
          // Legacy VML: sized by the CSS on the shape that holds it.
          _picture(_attr(child, 'id'), sink, _cssSize(_attr(element, 'style')));
        case 'inline' || 'anchor':
          _graphic(child, sink, _emuSize(_child(child, 'extent')) ?? extent);
        case 'pic':
          final XmlElement? own = _child(
            _child(_child(child, 'spPr'), 'xfrm'),
            'ext',
          );
          _graphic(child, sink, _emuSize(own) ?? extent);
        default:
          _graphic(child, sink, extent);
      }
    }
  }

  void _picture(
    String? relationship,
    _ParagraphSink sink,
    (double, double)? extent,
  ) {
    final String? part = _relationships[relationship];
    if (part == null) return;
    final Uint8List? bytes = _bytes(part);
    if (bytes == null || bytes.isEmpty) return;
    sink.trailing.add(
      FlowImage(
        bytes,
        widthPt: extent?.$1 ?? 0,
        heightPt: extent?.$2 ?? 0,
        align: sink.align,
      ),
    );
  }

  /// A size in English Metric Units (914400 to the inch), as points.
  static (double, double)? _emuSize(XmlElement? extent) {
    final double? cx = double.tryParse(_attr(extent, 'cx') ?? '');
    final double? cy = double.tryParse(_attr(extent, 'cy') ?? '');
    if (cx == null || cy == null || cx <= 0 || cy <= 0) return null;
    return (cx / 12700, cy / 12700);
  }

  static (double, double)? _cssSize(String? style) {
    if (style == null) return null;
    double? length(String property) {
      final Match? match = RegExp(
        '(?:^|;)\\s*$property\\s*:\\s*([\\d.]+)(pt|in|px)',
      ).firstMatch(style);
      final double? value = double.tryParse(match?.group(1) ?? '');
      if (value == null) return null;
      return switch (match!.group(2)) {
        'in' => value * 72,
        'px' => value * 0.75,
        _ => value,
      };
    }

    final double? width = length('width');
    final double? height = length('height');
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return (width, height);
  }

  // --- Tables ----------------------------------------------------------------

  FlowTable _table(XmlElement table) {
    final XmlElement? properties = _child(table, 'tblPr');
    bool bordered =
        _hasBorders(_child(properties, 'tblBorders')) ||
        _styleHasBorders(_attr(_child(properties, 'tblStyle'), 'val'));

    final List<FlowRow> rows = [];
    void readRows(XmlElement container) {
      for (final XmlElement element in container.childElements) {
        switch (element.name.local) {
          case 'tr':
            final List<FlowCell> cells = [];
            void readCells(XmlElement rowContainer) {
              for (final XmlElement cell in rowContainer.childElements) {
                switch (cell.name.local) {
                  case 'tc':
                    final XmlElement? tcPr = _child(cell, 'tcPr');
                    if (_hasBorders(_child(tcPr, 'tcBorders'))) bordered = true;
                    final List<FlowBlock> blocks = [];
                    // A cell merged into the one above is drawn empty; the
                    // text belongs to the cell that started the merge.
                    final XmlElement? merge = _child(tcPr, 'vMerge');
                    if (merge == null || _attr(merge, 'val') == 'restart') {
                      _blocks(cell, blocks);
                    }
                    cells.add(
                      FlowCell(
                        blocks,
                        span:
                            int.tryParse(
                              _attr(_child(tcPr, 'gridSpan'), 'val') ?? '',
                            ) ??
                            1,
                        fill: _hexColor(_attr(_child(tcPr, 'shd'), 'fill')),
                      ),
                    );
                  case 'sdt':
                    final XmlElement? content = _child(cell, 'sdtContent');
                    if (content != null) readCells(content);
                }
              }
            }

            readCells(element);
            rows.add(FlowRow(cells));
          case 'sdt':
            final XmlElement? content = _child(element, 'sdtContent');
            if (content != null) readRows(content);
          case 'ins' || 'customXml':
            readRows(element);
        }
      }
    }

    readRows(table);
    return FlowTable(
      rows,
      columnWidths: [
        for (final XmlElement column in _children(
          _child(table, 'tblGrid'),
          'gridCol',
        ))
          _twips(_attr(column, 'w')) ?? 0,
      ],
      bordered: bordered,
    );
  }
}
