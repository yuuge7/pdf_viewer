import 'dart:convert';
import 'dart:typed_data';

import 'flow_document.dart';

/// Reads HTML into a [FlowDocument].
///
/// This is the layout a page gets when the system web view cannot print
/// it: headings, paragraphs, emphasis, colours and sizes, lists, tables and
/// embedded pictures, set one after another down the page. It is not a
/// browser. Positioning, floats, flexbox and anything a script would have
/// drawn are not there, and a style sheet is read only for the plain rules
/// (`h1 { … }`, `.note { … }`) that say how text looks.
class HtmlReader {
  /// [pageWidth] and [pageHeight] are the paper, [margin] the space around
  /// the text, all in points.
  static FlowDocument read(
    String html, {
    double pageWidth = FlowDocument.a4Width,
    double pageHeight = FlowDocument.a4Height,
    double margin = 50,
  }) {
    final _Node root = _Parser(html).parse();
    final _Converter converter = _Converter(_Css.collect(root));
    final List<FlowBlock> blocks = converter.blocksOf(root, const _Text());
    return FlowDocument(
      blocks.isEmpty ? const [FlowParagraph([FlowRun('')])] : blocks,
      pageWidth: pageWidth,
      pageHeight: pageHeight,
      marginLeft: margin,
      marginRight: margin,
      marginTop: margin,
      marginBottom: margin,
    );
  }
}

// --- A forgiving parser ---------------------------------------------------------

class _Node {
  /// Lower-case tag name; empty for text.
  final String tag;
  final Map<String, String> attributes;
  final List<_Node> children = [];
  final String text;

  _Node(this.tag, [this.attributes = const {}]) : text = '';
  _Node.text(this.text) : tag = '', attributes = const {};

  bool get isText => tag.isEmpty;

  String get innerText =>
      isText ? text : children.map((c) => c.innerText).join();
}

class _Parser {
  final String source;
  int _at = 0;
  _Parser(this.source);

  static const Set<String> _void = {
    'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', //
    'meta', 'source', 'track', 'wbr',
  };

  /// Tags that end a paragraph left open before them.
  static const Set<String> _blocks = {
    'address', 'article', 'aside', 'blockquote', 'div', 'dl', 'fieldset', //
    'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr',
    'main', 'nav', 'ol', 'p', 'pre', 'section', 'table', 'ul',
  };

  /// What a new one of each of these closes, if still open.
  static const Map<String, Set<String>> _closes = {
    'li': {'li'},
    'dt': {'dt', 'dd'},
    'dd': {'dt', 'dd'},
    'tr': {'tr', 'td', 'th'},
    'td': {'td', 'th'},
    'th': {'td', 'th'},
    'option': {'option'},
    'thead': {'thead', 'tbody', 'tfoot', 'tr', 'td', 'th'},
    'tbody': {'thead', 'tbody', 'tfoot', 'tr', 'td', 'th'},
    'tfoot': {'thead', 'tbody', 'tfoot', 'tr', 'td', 'th'},
  };

  /// Where an implied close stops looking: a cell inside a nested table
  /// does not close a row of the outer one.
  static const Set<String> _scopes = {'table', 'ul', 'ol', 'dl', 'html'};

  _Node parse() {
    final _Node root = _Node('html');
    final List<_Node> open = [root];

    void close(String tag) {
      for (int i = open.length - 1; i > 0; i--) {
        if (open[i].tag == tag) {
          open.removeRange(i, open.length);
          return;
        }
      }
    }

    void closeImplied(String tag) {
      final Set<String>? closing = tag == 'p' || _blocks.contains(tag)
          ? {...?_closes[tag], 'p'}
          : _closes[tag];
      if (closing == null) return;
      for (int i = open.length - 1; i > 0; i--) {
        final String current = open[i].tag;
        if (closing.contains(current)) {
          open.removeRange(i, open.length);
          // A cell closes its predecessor and nothing further up.
          if (current != 'p') return;
          continue;
        }
        if (_scopes.contains(current) || current == 'td' || current == 'th') {
          return;
        }
      }
    }

    while (_at < source.length) {
      final int lt = source.indexOf('<', _at);
      if (lt < 0) {
        open.last.children.add(_Node.text(_decode(source.substring(_at))));
        break;
      }
      if (lt > _at) {
        open.last.children.add(_Node.text(_decode(source.substring(_at, lt))));
      }
      _at = lt;
      if (source.startsWith('<!--', _at)) {
        final int end = source.indexOf('-->', _at + 4);
        _at = end < 0 ? source.length : end + 3;
        continue;
      }
      if (source.startsWith('<!', _at) || source.startsWith('<?', _at)) {
        final int end = source.indexOf('>', _at);
        _at = end < 0 ? source.length : end + 1;
        continue;
      }
      if (source.startsWith('</', _at)) {
        final int end = source.indexOf('>', _at);
        final String tag = source
            .substring(_at + 2, end < 0 ? source.length : end)
            .trim()
            .toLowerCase();
        _at = end < 0 ? source.length : end + 1;
        close(tag);
        continue;
      }
      final RegExpMatch? name = RegExp(
        r'^<([A-Za-z][A-Za-z0-9:-]*)',
      ).firstMatch(source.substring(_at, (_at + 64).clamp(0, source.length)));
      if (name == null) {
        // A bare "<", as in "a < b".
        open.last.children.add(_Node.text('<'));
        _at++;
        continue;
      }
      final String tag = name.group(1)!.toLowerCase();
      _at += name.end;
      final Map<String, String> attributes = _attributes();
      final bool selfClosed = _at > 1 && source[_at - 2] == '/';

      closeImplied(tag);
      final _Node node = _Node(tag, attributes);
      open.last.children.add(node);
      if (tag == 'script' || tag == 'style' || tag == 'textarea' || tag == 'title') {
        // Raw text up to the matching close.
        final int end = source.toLowerCase().indexOf('</$tag', _at);
        final String raw = source.substring(_at, end < 0 ? source.length : end);
        node.children.add(_Node.text(raw));
        final int gt = end < 0 ? -1 : source.indexOf('>', end);
        _at = gt < 0 ? source.length : gt + 1;
        continue;
      }
      if (!_void.contains(tag) && !selfClosed) open.add(node);
    }
    return root;
  }

  /// Reads attributes up to and past the tag's closing `>`.
  Map<String, String> _attributes() {
    final Map<String, String> attributes = {};
    while (_at < source.length) {
      while (_at < source.length && ' \t\r\n/'.contains(source[_at])) {
        _at++;
      }
      if (_at >= source.length) break;
      if (source[_at] == '>') {
        _at++;
        break;
      }
      final int start = _at;
      while (_at < source.length && !' \t\r\n=>/'.contains(source[_at])) {
        _at++;
      }
      final String key = source.substring(start, _at).toLowerCase();
      while (_at < source.length && ' \t\r\n'.contains(source[_at])) {
        _at++;
      }
      String value = '';
      if (_at < source.length && source[_at] == '=') {
        _at++;
        while (_at < source.length && ' \t\r\n'.contains(source[_at])) {
          _at++;
        }
        if (_at < source.length &&
            (source[_at] == '"' || source[_at] == "'")) {
          final String quote = source[_at];
          final int end = source.indexOf(quote, _at + 1);
          value = source.substring(_at + 1, end < 0 ? source.length : end);
          _at = end < 0 ? source.length : end + 1;
        } else {
          final int from = _at;
          while (_at < source.length && !' \t\r\n>'.contains(source[_at])) {
            _at++;
          }
          value = source.substring(from, _at);
        }
      }
      if (key.isEmpty) {
        // Not an attribute at all; step over it rather than loop on it.
        if (_at == start) _at++;
        continue;
      }
      attributes.putIfAbsent(key, () => _decode(value));
    }
    return attributes;
  }

  static const Map<String, int> _entities = {
    'amp': 0x26, 'lt': 0x3C, 'gt': 0x3E, 'quot': 0x22, 'apos': 0x27, //
    'nbsp': 0xA0, 'copy': 0xA9, 'reg': 0xAE, 'trade': 0x2122, 'deg': 0xB0,
    'euro': 0x20AC, 'pound': 0xA3, 'yen': 0xA5, 'cent': 0xA2, 'sect': 0xA7,
    'para': 0xB6, 'middot': 0xB7, 'bull': 0x2022, 'hellip': 0x2026,
    'ndash': 0x2013, 'mdash': 0x2014, 'lsquo': 0x2018, 'rsquo': 0x2019,
    'ldquo': 0x201C, 'rdquo': 0x201D, 'laquo': 0xAB, 'raquo': 0xBB,
    'times': 0xD7, 'divide': 0xF7, 'plusmn': 0xB1, 'frac12': 0xBD,
    'larr': 0x2190, 'rarr': 0x2192, 'uarr': 0x2191, 'darr': 0x2193,
    'shy': 0xAD, 'ensp': 0x2002, 'emsp': 0x2003, 'thinsp': 0x2009,
  };

  static String _decode(String text) {
    if (!text.contains('&')) return text;
    return text.replaceAllMapped(
      RegExp(r'&(#[xX][0-9a-fA-F]+|#\d+|[A-Za-z][A-Za-z0-9]*);?'),
      (m) {
        final String body = m.group(1)!;
        int? code;
        if (body.startsWith('#x') || body.startsWith('#X')) {
          code = int.tryParse(body.substring(2), radix: 16);
        } else if (body.startsWith('#')) {
          code = int.tryParse(body.substring(1));
        } else {
          code = _entities[body];
        }
        if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
        return String.fromCharCode(code);
      },
    );
  }
}

// --- How text looks --------------------------------------------------------------

/// The inherited look of text at some point in the tree.
class _Text {
  final double size;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final int? color;
  final FlowAlign align;

  /// Whether white space is kept as written, as inside `<pre>`.
  final bool pre;

  const _Text({
    this.size = 11,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color,
    this.align = FlowAlign.left,
    this.pre = false,
  });

  _Text copyWith({
    double? size,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    int? color,
    FlowAlign? align,
    bool? pre,
  }) => _Text(
    size: size ?? this.size,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strike: strike ?? this.strike,
    color: color ?? this.color,
    align: align ?? this.align,
    pre: pre ?? this.pre,
  );

  FlowRun run(String text) => FlowRun(
    text,
    sizePt: size,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    color: color,
  );

  /// This look with [declarations] (a `style` attribute, or a rule's body)
  /// applied.
  _Text styled(Map<String, String> declarations) {
    if (declarations.isEmpty) return this;
    _Text out = this;
    declarations.forEach((property, value) {
      final String v = value.trim().toLowerCase();
      switch (property) {
        case 'color':
          final int? c = _Css.color(v);
          if (c != null) out = out.copyWith(color: c);
        case 'font-size':
          final double? s = _Css.length(v, out.size);
          if (s != null) out = out.copyWith(size: s.clamp(4.0, 96.0));
        case 'font-weight':
          final int? weight = int.tryParse(v);
          out = out.copyWith(
            bold: v == 'bold' || v == 'bolder' || (weight != null && weight >= 600),
          );
        case 'font-style':
          out = out.copyWith(italic: v == 'italic' || v == 'oblique');
        case 'text-decoration' || 'text-decoration-line':
          out = out.copyWith(
            underline: v.contains('underline') ? true : (v == 'none' ? false : null),
            strike: v.contains('line-through') ? true : (v == 'none' ? false : null),
          );
        case 'text-align':
          final FlowAlign? a = switch (v) {
            'center' => FlowAlign.center,
            'right' || 'end' => FlowAlign.right,
            'left' || 'start' || 'justify' => FlowAlign.left,
            _ => null,
          };
          if (a != null) out = out.copyWith(align: a);
        case 'white-space':
          out = out.copyWith(pre: v.startsWith('pre'));
      }
    });
    return out;
  }
}

class _Rule {
  final String? tag;
  final String? className;
  final String? id;
  final Map<String, String> declarations;
  const _Rule(this.tag, this.className, this.id, this.declarations);

  bool matches(_Node node) {
    if (tag != null && tag != node.tag) return false;
    if (id != null && node.attributes['id'] != id) return false;
    if (className != null &&
        !(node.attributes['class'] ?? '').split(RegExp(r'\s+')).contains(className)) {
      return false;
    }
    return true;
  }
}

class _Css {
  final List<_Rule> rules;
  const _Css(this.rules);

  /// Every plain rule in every `<style>` of the document.
  static _Css collect(_Node root) {
    final List<_Rule> rules = [];
    void walk(_Node node) {
      if (node.tag == 'style') {
        rules.addAll(_parseSheet(node.innerText));
        return;
      }
      node.children.forEach(walk);
    }

    walk(root);
    return _Css(rules);
  }

  static List<_Rule> _parseSheet(String css) {
    final List<_Rule> rules = [];
    final String clean = css.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
    for (final RegExpMatch m in RegExp(
      r'([^{}@]+)\{([^{}]*)\}',
    ).allMatches(clean)) {
      final Map<String, String> declarations = parseDeclarations(m.group(2)!);
      if (declarations.isEmpty) continue;
      for (final String raw in m.group(1)!.split(',')) {
        final RegExpMatch? simple = RegExp(
          r'^([a-zA-Z][a-zA-Z0-9]*)?(?:\.([\w-]+))?(?:#([\w-]+))?$',
        ).firstMatch(raw.trim());
        // Anything with a combinator or a pseudo-class is left alone: a
        // rule applied too widely is worse than one not applied.
        if (simple == null || raw.trim().isEmpty) continue;
        rules.add(
          _Rule(
            simple.group(1)?.toLowerCase(),
            simple.group(2),
            simple.group(3),
            declarations,
          ),
        );
      }
    }
    return rules;
  }

  static Map<String, String> parseDeclarations(String body) {
    final Map<String, String> out = {};
    for (final String part in body.split(';')) {
      final int colon = part.indexOf(':');
      if (colon <= 0) continue;
      out[part.substring(0, colon).trim().toLowerCase()] = part
          .substring(colon + 1)
          .replaceAll(RegExp(r'!important', caseSensitive: false), '')
          .trim();
    }
    return out;
  }

  /// Everything that applies to [node]: the sheet's rules, then its own
  /// `style`, which wins.
  Map<String, String> declarationsFor(_Node node) {
    final Map<String, String> out = {};
    for (final _Rule rule in rules) {
      if (rule.matches(node)) out.addAll(rule.declarations);
    }
    final String? inline = node.attributes['style'];
    if (inline != null) out.addAll(parseDeclarations(inline));
    return out;
  }

  static const Map<String, int> _named = {
    'black': 0x000000, 'white': 0xFFFFFF, 'red': 0xFF0000, 'green': 0x008000, //
    'blue': 0x0000FF, 'yellow': 0xFFFF00, 'orange': 0xFFA500, 'purple': 0x800080,
    'gray': 0x808080, 'grey': 0x808080, 'silver': 0xC0C0C0, 'maroon': 0x800000,
    'navy': 0x000080, 'teal': 0x008080, 'olive': 0x808000, 'lime': 0x00FF00,
    'aqua': 0x00FFFF, 'cyan': 0x00FFFF, 'fuchsia': 0xFF00FF, 'magenta': 0xFF00FF,
    'pink': 0xFFC0CB, 'brown': 0xA52A2A, 'gold': 0xFFD700, 'darkgray': 0xA9A9A9,
    'darkgrey': 0xA9A9A9, 'lightgray': 0xD3D3D3, 'lightgrey': 0xD3D3D3,
    'darkblue': 0x00008B, 'darkgreen': 0x006400, 'darkred': 0x8B0000,
    'whitesmoke': 0xF5F5F5, 'crimson': 0xDC143C, 'indigo': 0x4B0082,
  };

  /// 0xRRGGBB, or null for a colour not read here.
  static int? color(String value) {
    final String v = value.trim().toLowerCase();
    if (v.startsWith('#')) {
      final String hex = v.substring(1);
      if (hex.length == 3 || hex.length == 4) {
        final int? n = int.tryParse(
          hex.substring(0, 3).split('').map((c) => '$c$c').join(),
          radix: 16,
        );
        return n;
      }
      if (hex.length == 6 || hex.length == 8) {
        return int.tryParse(hex.substring(0, 6), radix: 16);
      }
      return null;
    }
    final RegExpMatch? rgb = RegExp(
      r'^rgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)',
    ).firstMatch(v);
    if (rgb != null) {
      int part(int i) => int.parse(rgb.group(i)!).clamp(0, 255);
      return (part(1) << 16) | (part(2) << 8) | part(3);
    }
    return _named[v];
  }

  /// A font size in points. [parent] is the size it is relative to.
  static double? length(String value, double parent) {
    const Map<String, double> named = {
      'xx-small': 7, 'x-small': 8, 'small': 9.5, 'medium': 11, 'large': 14, //
      'x-large': 18, 'xx-large': 24,
    };
    if (named.containsKey(value)) return named[value];
    if (value == 'smaller') return parent * 0.83;
    if (value == 'larger') return parent * 1.2;
    final RegExpMatch? m = RegExp(
      r'^([\d.]+)\s*(px|pt|em|rem|%)?$',
    ).firstMatch(value);
    if (m == null) return null;
    final double? n = double.tryParse(m.group(1)!);
    if (n == null) return null;
    return switch (m.group(2)) {
      'pt' => n,
      'em' => n * parent,
      'rem' => n * 11,
      '%' => n / 100 * parent,
      // A CSS pixel is three quarters of a point.
      _ => n * 0.75,
    };
  }
}

// --- Tree to blocks --------------------------------------------------------------

class _Converter {
  final _Css css;
  _Converter(this.css);

  static const Map<String, double> _headings = {
    'h1': 22, 'h2': 17, 'h3': 14, 'h4': 12, 'h5': 11, 'h6': 10, //
  };

  static const Set<String> _skipped = {
    'head', 'script', 'style', 'title', 'meta', 'link', 'noscript', //
    'template', 'svg', 'iframe', 'object', 'select', 'button', 'input',
    'textarea', 'canvas', 'video', 'audio',
  };

  static const Set<String> _blockTags = {
    'html', 'body', 'div', 'p', 'section', 'article', 'aside', 'header', //
    'footer', 'main', 'nav', 'address', 'blockquote', 'pre', 'figure',
    'figcaption', 'form', 'fieldset', 'dl', 'dt', 'dd', 'ul', 'ol', 'li',
    'table', 'hr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'center', 'details',
    'summary',
  };

  final List<FlowBlock> _out = [];
  List<FlowRun> _runs = [];
  _Text _paragraphLook = const _Text();
  double _indent = 0;
  double _firstLine = 0;
  double _spaceBefore = 0;
  double _spaceAfter = 6;
  String? _marker;

  /// Open lists, innermost last: the next number, or null for bullets.
  final List<int?> _lists = [];

  List<FlowBlock> blocksOf(_Node node, _Text look) {
    final _Converter inner = _Converter(css);
    inner._walkChildren(node, look);
    inner._flush();
    return inner._out;
  }

  void _flush() {
    // White space at the edges of a block is not content.
    while (_runs.isNotEmpty && _runs.first.text.trim().isEmpty && !_paragraphLook.pre) {
      _runs.removeAt(0);
    }
    while (_runs.isNotEmpty && _runs.last.text.trim().isEmpty && !_paragraphLook.pre) {
      _runs.removeLast();
    }
    if (_runs.isNotEmpty) {
      if (!_paragraphLook.pre) {
        final FlowRun first = _runs.first;
        _runs[0] = _retext(first, first.text.trimLeft());
        final FlowRun last = _runs.last;
        _runs[_runs.length - 1] = _retext(last, last.text.trimRight());
      }
      final String? marker = _marker;
      _out.add(
        FlowParagraph(
          [
            if (marker != null)
              FlowRun('$marker\t', sizePt: _paragraphLook.size),
            ..._runs,
          ],
          align: _paragraphLook.align,
          indentPt: _indent,
          firstLinePt: _firstLine,
          spaceBeforePt: _spaceBefore,
          spaceAfterPt: _spaceAfter,
          lineHeight: 1.2,
        ),
      );
      _marker = null;
      _firstLine = 0;
    }
    _runs = [];
    _spaceBefore = 0;
  }

  static FlowRun _retext(FlowRun run, String text) => FlowRun(
    text,
    sizePt: run.sizePt,
    bold: run.bold,
    italic: run.italic,
    underline: run.underline,
    strike: run.strike,
    color: run.color,
  );

  void _text(String text, _Text look) {
    String value = text;
    if (!look.pre) {
      value = value.replaceAll(RegExp(r'[ \t\r\n\f]+'), ' ');
      // One space between words, however the markup was broken up.
      final bool afterSpace =
          _runs.isEmpty || _runs.last.text.endsWith(' ') || _runs.last.text.endsWith('\n');
      if (afterSpace && value.startsWith(' ')) value = value.substring(1);
      if (value.isEmpty) return;
    } else {
      value = value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    }
    if (_runs.isEmpty) _paragraphLook = look;
    _runs.add(look.run(value));
  }

  void _walkChildren(_Node node, _Text look) {
    for (final _Node child in node.children) {
      _walk(child, look);
    }
  }

  void _walk(_Node node, _Text inherited) {
    if (node.isText) {
      _text(node.text, inherited);
      return;
    }
    final String tag = node.tag;
    if (_skipped.contains(tag)) return;
    final Map<String, String> declarations = css.declarationsFor(node);
    if (declarations['display']?.trim() == 'none') return;

    _Text look = switch (tag) {
      'b' || 'strong' || 'th' => inherited.copyWith(bold: true),
      'i' || 'em' || 'cite' || 'var' || 'dfn' => inherited.copyWith(italic: true),
      'u' || 'ins' => inherited.copyWith(underline: true),
      's' || 'strike' || 'del' => inherited.copyWith(strike: true),
      'small' || 'sub' || 'sup' => inherited.copyWith(size: inherited.size * 0.83),
      'big' => inherited.copyWith(size: inherited.size * 1.2),
      'a' =>
        node.attributes.containsKey('href')
            ? inherited.copyWith(underline: true, color: 0x1A4FBF)
            : inherited,
      'pre' => inherited.copyWith(pre: true, size: 9.5),
      'center' => inherited.copyWith(align: FlowAlign.center),
      'blockquote' => inherited.copyWith(italic: true),
      'dt' => inherited.copyWith(bold: true),
      _ => inherited,
    };
    final double? heading = _headings[tag];
    if (heading != null) look = look.copyWith(size: heading, bold: true);
    if (tag == 'font') {
      final int? color = _Css.color(node.attributes['color'] ?? '');
      if (color != null) look = look.copyWith(color: color);
    }
    final String? alignAttr = node.attributes['align']?.toLowerCase();
    if (alignAttr == 'center') look = look.copyWith(align: FlowAlign.center);
    if (alignAttr == 'right') look = look.copyWith(align: FlowAlign.right);
    look = look.styled(declarations);

    switch (tag) {
      case 'br':
        if (_runs.isEmpty) _paragraphLook = look;
        _runs.add(look.run('\n'));
        return;
      case 'hr':
        _flush();
        _out.add(
          FlowParagraph(
            [FlowRun('_' * 60, sizePt: 6, color: 0x999999)],
            spaceAfterPt: 8,
          ),
        );
        return;
      case 'img':
        final Uint8List? bytes = _dataUri(node.attributes['src'] ?? '');
        if (bytes == null) {
          final String alt = node.attributes['alt'] ?? '';
          if (alt.trim().isNotEmpty) _text('[$alt]', look.copyWith(italic: true));
          return;
        }
        _flush();
        _out.add(
          FlowImage(
            bytes,
            widthPt: (double.tryParse(node.attributes['width'] ?? '') ?? 0) * 0.75,
            heightPt: (double.tryParse(node.attributes['height'] ?? '') ?? 0) * 0.75,
            align: look.align,
          ),
        );
        return;
      case 'table':
        _flush();
        final FlowTable? table = _table(node, look);
        if (table != null) {
          _out.add(table);
          // A table has no spacing of its own to keep what follows off it.
          _spaceBefore = 8;
        }
        return;
      case 'ul' || 'ol':
        _flush();
        _lists.add(
          tag == 'ol' ? (int.tryParse(node.attributes['start'] ?? '') ?? 1) : null,
        );
        final double before = _indent;
        _indent = 18.0 * _lists.length;
        _walkChildren(node, look);
        _flush();
        _lists.removeLast();
        _indent = before;
        return;
      case 'li':
        _flush();
        if (_lists.isEmpty) {
          _marker = String.fromCharCode(0x2022);
        } else if (_lists.last case final int number) {
          _marker = '$number.';
          _lists[_lists.length - 1] = number + 1;
        } else {
          _marker = String.fromCharCode(0x2022);
        }
        if (_lists.isEmpty) _indent = 18;
        _firstLine = -14;
        _spaceAfter = 2;
        _walkChildren(node, look);
        _flush();
        _spaceAfter = 6;
        if (_lists.isEmpty) _indent = 0;
        return;
    }

    if (!_blockTags.contains(tag)) {
      _walkChildren(node, look);
      return;
    }

    _flush();
    final double indentBefore = _indent;
    if (tag == 'blockquote' || tag == 'dd') _indent += 24;
    if (heading != null) {
      _spaceBefore = heading * 0.6;
      _spaceAfter = heading * 0.35;
    }
    _walkChildren(node, look);
    _flush();
    _spaceAfter = 6;
    _indent = indentBefore;
  }

  FlowTable? _table(_Node table, _Text look) {
    final List<FlowRow> rows = [];
    void collect(_Node node) {
      for (final _Node child in node.children) {
        if (child.tag == 'tr') {
          final List<FlowCell> cells = [];
          for (final _Node cell in child.children) {
            if (cell.tag != 'td' && cell.tag != 'th') continue;
            final Map<String, String> declarations = css.declarationsFor(cell);
            _Text cellLook = cell.tag == 'th'
                ? look.copyWith(bold: true)
                : look;
            cellLook = cellLook.styled(declarations);
            final int? fill =
                _Css.color(declarations['background-color'] ?? '') ??
                _Css.color(declarations['background'] ?? '') ??
                _Css.color(cell.attributes['bgcolor'] ?? '');
            final List<FlowBlock> blocks = blocksOf(cell, cellLook);
            cells.add(
              FlowCell(
                blocks.isEmpty
                    ? [FlowParagraph([cellLook.run('')])]
                    : blocks,
                span: (int.tryParse(cell.attributes['colspan'] ?? '') ?? 1)
                    .clamp(1, 50),
                fill: fill,
              ),
            );
          }
          if (cells.isNotEmpty) rows.add(FlowRow(cells));
        } else if (const {'thead', 'tbody', 'tfoot'}.contains(child.tag)) {
          collect(child);
        }
      }
    }

    collect(table);
    if (rows.isEmpty) return null;
    return FlowTable(rows);
  }

  /// The bytes of a `data:` URI holding a base64 picture, which is the only
  /// kind of picture a page can carry with it.
  static Uint8List? _dataUri(String src) {
    final RegExpMatch? m = RegExp(
      r'^data:image/[a-zA-Z0-9.+-]+;base64,(.*)$',
      dotAll: true,
    ).firstMatch(src.trim());
    if (m == null) return null;
    try {
      return base64.decode(m.group(1)!.replaceAll(RegExp(r'\s'), ''));
    } catch (_) {
      return null;
    }
  }
}
