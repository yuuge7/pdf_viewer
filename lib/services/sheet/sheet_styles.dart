import 'package:xml/xml.dart';

import 'number_format.dart';

enum HAlign { general, left, center, right }

enum VAlign { top, center, bottom }

/// One edge of a cell's border.
class CellBorder {
  /// Stroke in logical pixels at 100% zoom.
  final double width;
  final int color;
  final bool dashed;

  const CellBorder(this.width, this.color, {this.dashed = false});
}

/// How a cell looks, with every indirection in the file followed.
class CellStyle {
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final double fontSize;
  final String? fontName;

  /// Text colour as ARGB; null for the default.
  final int? color;

  /// Background as ARGB; null for none.
  final int? fill;
  final HAlign hAlign;
  final VAlign vAlign;
  final bool wrap;

  /// The number format code, "General" when there is none.
  final String numFmt;
  final CellBorder? left;
  final CellBorder? top;
  final CellBorder? right;
  final CellBorder? bottom;

  const CellStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.fontSize = 11,
    this.fontName,
    this.color,
    this.fill,
    this.hAlign = HAlign.general,
    this.vAlign = VAlign.bottom,
    this.wrap = false,
    this.numFmt = 'General',
    this.left,
    this.top,
    this.right,
    this.bottom,
  });

  static const CellStyle plain = CellStyle();
}

/// A change to make to a cell's format. Null fields are left as they are.
class StyleChange {
  final bool? bold;
  final bool? italic;
  final bool? underline;

  /// ARGB, or 0 to go back to the default text colour.
  final int? color;

  /// ARGB, or 0 for no fill.
  final int? fill;
  final HAlign? hAlign;

  /// A number format code.
  final String? numFmt;

  const StyleChange({
    this.bold,
    this.italic,
    this.underline,
    this.color,
    this.fill,
    this.hAlign,
    this.numFmt,
  });

  String get _key => '$bold|$italic|$underline|$color|$fill|$hAlign|$numFmt';
}

Iterable<XmlElement> _kids(XmlElement parent, String local) =>
    parent.childElements.where((e) => e.name.local == local);

XmlElement? _kid(XmlElement? parent, String local) {
  if (parent == null) return null;
  for (final XmlElement e in parent.childElements) {
    if (e.name.local == local) return e;
  }
  return null;
}

bool _flag(XmlElement? e) {
  if (e == null) return false;
  final String? val = e.getAttribute('val');
  return val == null || (val != '0' && val != 'false' && val != 'none');
}

/// The workbook's formats: read from `styles.xml`, and written back into
/// the same document so that a format this model does not understand is
/// still there afterwards.
class StyleBook {
  final XmlDocument xml;
  final List<int> _theme;
  final List<CellStyle> _resolved = [];
  final Map<String, int> _restyled = {};
  bool changed = false;

  /// The palette `indexed="n"` colours refer to.
  static const List<int> _indexed = [
    0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00, //
    0xFFFF00FF, 0xFF00FFFF, 0xFF000000, 0xFFFFFFFF, 0xFFFF0000, 0xFF00FF00,
    0xFF0000FF, 0xFFFFFF00, 0xFFFF00FF, 0xFF00FFFF, 0xFF800000, 0xFF008000,
    0xFF000080, 0xFF808000, 0xFF800080, 0xFF008080, 0xFFC0C0C0, 0xFF808080,
    0xFF9999FF, 0xFF993366, 0xFFFFFFCC, 0xFFCCFFFF, 0xFF660066, 0xFFFF8080,
    0xFF0066CC, 0xFFCCCCFF, 0xFF000080, 0xFFFF00FF, 0xFFFFFF00, 0xFF00FFFF,
    0xFF800080, 0xFF800000, 0xFF008080, 0xFF0000FF, 0xFF00CCFF, 0xFFCCFFFF,
    0xFFCCFFCC, 0xFFFFFF99, 0xFF99CCFF, 0xFFFF99CC, 0xFFCC99FF, 0xFFFFCC99,
    0xFF3366FF, 0xFF33CCCC, 0xFF99CC00, 0xFFFFCC00, 0xFFFF9900, 0xFFFF6600,
    0xFF666699, 0xFF969696, 0xFF003366, 0xFF339966, 0xFF003300, 0xFF333300,
    0xFF993300, 0xFF993366, 0xFF333399, 0xFF333333,
  ];

  /// The Office theme, for files that carry none.
  static const List<int> defaultTheme = [
    0xFFFFFFFF, 0xFF000000, 0xFFE7E6E6, 0xFF44546A, 0xFF4472C4, 0xFFED7D31, //
    0xFFA5A5A5, 0xFFFFC000, 0xFF5B9BD5, 0xFF70AD47, 0xFF0563C1, 0xFF954F72,
  ];

  /// [theme] is the twelve theme colours in the order formats index them:
  /// light 1, dark 1, light 2, dark 2, six accents, two link colours.
  StyleBook(this.xml, {this._theme = defaultTheme}) {
    _resolveAll();
  }

  /// A style sheet with nothing but the defaults in it.
  factory StyleBook.blank() => StyleBook(XmlDocument.parse(blankXml));

  static const String blankXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
      '<fills count="2"><fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill></fills>'
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      '</styleSheet>';

  int get count => _resolved.length;

  CellStyle at(int index) =>
      index >= 0 && index < _resolved.length ? _resolved[index] : CellStyle.plain;

  XmlElement get _root => xml.rootElement;

  List<XmlElement> _list(String container, String item) {
    final XmlElement? parent = _kid(_root, container);
    return parent == null ? const [] : _kids(parent, item).toList();
  }

  void _resolveAll() {
    _resolved.clear();
    final List<XmlElement> fonts = _list('fonts', 'font');
    final List<XmlElement> fills = _list('fills', 'fill');
    final List<XmlElement> borders = _list('borders', 'border');
    final Map<int, String> formats = {
      for (final XmlElement f in _list('numFmts', 'numFmt'))
        if (int.tryParse(f.getAttribute('numFmtId') ?? '') case final int id)
          id: f.getAttribute('formatCode') ?? 'General',
    };
    for (final XmlElement xf in _list('cellXfs', 'xf')) {
      _resolved.add(_resolve(xf, fonts, fills, borders, formats));
    }
    if (_resolved.isEmpty) _resolved.add(CellStyle.plain);
  }

  CellStyle _resolve(
    XmlElement xf,
    List<XmlElement> fonts,
    List<XmlElement> fills,
    List<XmlElement> borders,
    Map<int, String> formats,
  ) {
    int index(String name) => int.tryParse(xf.getAttribute(name) ?? '') ?? 0;
    T? pick<T>(List<T> list, int i) => i >= 0 && i < list.length ? list[i] : null;

    final XmlElement? font = pick(fonts, index('fontId'));
    final XmlElement? fill = _kid(pick(fills, index('fillId')), 'patternFill');
    final XmlElement? border = pick(borders, index('borderId'));
    final XmlElement? alignment = _kid(xf, 'alignment');
    final int numFmtId = index('numFmtId');

    int? fillColor;
    final String pattern = fill?.getAttribute('patternType') ?? 'none';
    if (fill != null && pattern != 'none') {
      // A solid fill keeps its colour in fgColor, of all places.
      fillColor = colorOf(_kid(fill, 'fgColor')) ?? colorOf(_kid(fill, 'bgColor'));
    }

    CellBorder? edge(String side) {
      final XmlElement? e = _kid(border, side);
      final String? style = e?.getAttribute('style');
      if (e == null || style == null || style == 'none') return null;
      final double width = switch (style) {
        'medium' || 'mediumDashed' || 'mediumDashDot' || 'double' => 2,
        'thick' => 3,
        'hair' => 0.5,
        _ => 1,
      };
      return CellBorder(
        width,
        colorOf(_kid(e, 'color')) ?? 0xFF000000,
        dashed: style.toLowerCase().contains('dash') || style == 'dotted',
      );
    }

    return CellStyle(
      bold: _flag(_kid(font, 'b')),
      italic: _flag(_kid(font, 'i')),
      underline: _flag(_kid(font, 'u')),
      strike: _flag(_kid(font, 'strike')),
      fontSize:
          double.tryParse(_kid(font, 'sz')?.getAttribute('val') ?? '') ?? 11,
      fontName: _kid(font, 'name')?.getAttribute('val'),
      color: colorOf(_kid(font, 'color')),
      fill: fillColor,
      hAlign: switch (alignment?.getAttribute('horizontal')) {
        'left' => HAlign.left,
        'center' || 'centerContinuous' => HAlign.center,
        'right' => HAlign.right,
        _ => HAlign.general,
      },
      vAlign: switch (alignment?.getAttribute('vertical')) {
        'top' => VAlign.top,
        'center' => VAlign.center,
        _ => VAlign.bottom,
      },
      wrap: const {'1', 'true'}.contains(alignment?.getAttribute('wrapText')),
      numFmt: formats[numFmtId] ?? NumberFormat.builtIn[numFmtId] ?? 'General',
      left: edge('left'),
      top: edge('top'),
      right: edge('right'),
      bottom: edge('bottom'),
    );
  }

  /// The ARGB a colour element names, or null for "automatic".
  int? colorOf(XmlElement? e) {
    if (e == null) return null;
    final String? rgb = e.getAttribute('rgb');
    int? base;
    if (rgb != null) {
      final int? parsed = int.tryParse(rgb, radix: 16);
      if (parsed != null) base = rgb.length <= 6 ? 0xFF000000 | parsed : parsed;
    } else if (int.tryParse(e.getAttribute('theme') ?? '') case final int t) {
      if (t >= 0 && t < _theme.length) base = _theme[t];
    } else if (int.tryParse(e.getAttribute('indexed') ?? '') case final int i) {
      // 64 and 65 are the system foreground and background.
      if (i >= 0 && i < _indexed.length) base = _indexed[i];
    }
    if (base == null) return null;
    final double tint = double.tryParse(e.getAttribute('tint') ?? '') ?? 0;
    return tint == 0 ? base | 0xFF000000 : _tinted(base, tint);
  }

  /// Lightens (positive [tint]) or darkens a colour the way the format
  /// defines it: on its luminance, in HSL.
  static int _tinted(int argb, double tint) {
    final double r = ((argb >> 16) & 0xFF) / 255;
    final double g = ((argb >> 8) & 0xFF) / 255;
    final double b = (argb & 0xFF) / 255;
    final double max = [r, g, b].reduce((a, c) => a > c ? a : c);
    final double min = [r, g, b].reduce((a, c) => a < c ? a : c);
    double h = 0, s = 0;
    double l = (max + min) / 2;
    if (max != min) {
      final double d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      if (max == r) {
        h = (g - b) / d + (g < b ? 6 : 0);
      } else if (max == g) {
        h = (b - r) / d + 2;
      } else {
        h = (r - g) / d + 4;
      }
      h /= 6;
    }
    l = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint;

    double channel(double p, double q, double t) {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }

    double nr = l, ng = l, nb = l;
    if (s != 0) {
      final double q = l < 0.5 ? l * (1 + s) : l + s - l * s;
      final double p = 2 * l - q;
      nr = channel(p, q, h + 1 / 3);
      ng = channel(p, q, h);
      nb = channel(p, q, h - 1 / 3);
    }
    int byte(double v) => (v * 255).round().clamp(0, 255);
    return 0xFF000000 | (byte(nr) << 16) | (byte(ng) << 8) | byte(nb);
  }

  // --- Changing ---------------------------------------------------------------

  static String _hex(int argb) =>
      (argb | 0xFF000000).toRadixString(16).toUpperCase().padLeft(8, '0');

  XmlElement _container(String name, {required List<String> before}) {
    final XmlElement? existing = _kid(_root, name);
    if (existing != null) return existing;
    final XmlElement created = XmlElement(XmlName.parts(name));
    // The schema fixes the order of the lists; a new one goes in its place.
    int at = _root.children.length;
    for (int i = 0; i < _root.children.length; i++) {
      final XmlNode node = _root.children[i];
      if (node is XmlElement && before.contains(node.name.local)) {
        at = i;
        break;
      }
    }
    _root.children.insert(at, created);
    return created;
  }

  int _append(XmlElement container, XmlElement item) {
    container.children.add(item);
    final int count = container.childElements.length;
    container.setAttribute('count', '$count');
    return count - 1;
  }

  /// The index of the format that is [base] with [change] applied, adding
  /// it to the file's formats if it is not there yet.
  int restyle(int base, StyleChange change) {
    final String key = '$base>${change._key}';
    final int? known = _restyled[key];
    if (known != null) return known;

    final XmlElement cellXfs = _container('cellXfs', before: const [
      'cellStyles', 'dxfs', 'tableStyles', 'colors', 'extLst', //
    ]);
    final List<XmlElement> xfs = _kids(cellXfs, 'xf').toList();
    final XmlElement xf = base >= 0 && base < xfs.length
        ? xfs[base].copy()
        : XmlElement(XmlName.parts('xf'), [
            XmlAttribute(XmlName.parts('numFmtId'), '0'),
            XmlAttribute(XmlName.parts('fontId'), '0'),
            XmlAttribute(XmlName.parts('fillId'), '0'),
            XmlAttribute(XmlName.parts('borderId'), '0'),
            XmlAttribute(XmlName.parts('xfId'), '0'),
          ]);

    if (change.bold != null ||
        change.italic != null ||
        change.underline != null ||
        change.color != null) {
      final XmlElement fonts = _container('fonts', before: const [
        'fills', 'borders', 'cellStyleXfs', 'cellXfs', //
      ]);
      final List<XmlElement> all = _kids(fonts, 'font').toList();
      final int fontId = int.tryParse(xf.getAttribute('fontId') ?? '') ?? 0;
      final XmlElement font = fontId < all.length
          ? all[fontId].copy()
          : XmlElement(XmlName.parts('font'));
      void toggle(String name, bool? on) {
        if (on == null) return;
        font.children.removeWhere(
          (n) => n is XmlElement && n.name.local == name,
        );
        if (on) font.children.add(XmlElement(XmlName.parts(name)));
      }

      toggle('b', change.bold);
      toggle('i', change.italic);
      toggle('u', change.underline);
      final int? color = change.color;
      if (color != null) {
        font.children.removeWhere(
          (n) => n is XmlElement && n.name.local == 'color',
        );
        if (color != 0) {
          font.children.add(
            XmlElement(XmlName.parts('color'), [
              XmlAttribute(XmlName.parts('rgb'), _hex(color)),
            ]),
          );
        }
      }
      // Spreadsheets refuse a font whose properties are out of order.
      const List<String> order = [
        'b', 'i', 'strike', 'condense', 'extend', 'outline', 'shadow', 'u', //
        'vertAlign', 'sz', 'color', 'name', 'family', 'charset', 'scheme',
      ];
      final List<XmlElement> parts = font.childElements.toList()
        ..sort((a, b) {
          int rank(XmlElement e) {
            final int i = order.indexOf(e.name.local);
            return i < 0 ? order.length : i;
          }

          return rank(a).compareTo(rank(b));
        });
      font.children
        ..clear()
        ..addAll(parts.map((e) => e.copy()));
      xf.setAttribute('fontId', '${_append(fonts, font)}');
      xf.setAttribute('applyFont', '1');
    }

    final int? fill = change.fill;
    if (fill != null) {
      if (fill == 0) {
        xf.setAttribute('fillId', '0');
      } else {
        final XmlElement fills = _container('fills', before: const [
          'borders', 'cellStyleXfs', 'cellXfs', //
        ]);
        final XmlElement created = XmlElement(XmlName.parts('fill'), [], [
          XmlElement(
            XmlName.parts('patternFill'),
            [XmlAttribute(XmlName.parts('patternType'), 'solid')],
            [
              XmlElement(XmlName.parts('fgColor'), [
                XmlAttribute(XmlName.parts('rgb'), _hex(fill)),
              ]),
              XmlElement(XmlName.parts('bgColor'), [
                XmlAttribute(XmlName.parts('indexed'), '64'),
              ]),
            ],
          ),
        ]);
        xf.setAttribute('fillId', '${_append(fills, created)}');
      }
      xf.setAttribute('applyFill', '1');
    }

    final HAlign? hAlign = change.hAlign;
    if (hAlign != null) {
      XmlElement? alignment = _kid(xf, 'alignment');
      if (alignment == null) {
        alignment = XmlElement(XmlName.parts('alignment'));
        // Before <protection>, which is the only thing that can follow.
        xf.children.insert(0, alignment);
      }
      if (hAlign == HAlign.general) {
        alignment.removeAttribute('horizontal');
      } else {
        alignment.setAttribute('horizontal', hAlign.name);
      }
      xf.setAttribute('applyAlignment', '1');
    }

    final String? numFmt = change.numFmt;
    if (numFmt != null) {
      int? id;
      NumberFormat.builtIn.forEach((key, code) {
        if (code == numFmt && key != 14 && key != 22) id ??= key;
      });
      if (id == null) {
        final XmlElement numFmts = _container('numFmts', before: const [
          'fonts', 'fills', 'borders', 'cellStyleXfs', 'cellXfs', //
        ]);
        int next = 164;
        for (final XmlElement f in _kids(numFmts, 'numFmt')) {
          final int existing =
              int.tryParse(f.getAttribute('numFmtId') ?? '') ?? 0;
          if (f.getAttribute('formatCode') == numFmt) id = existing;
          if (existing >= next) next = existing + 1;
        }
        if (id == null) {
          id = next;
          _append(
            numFmts,
            XmlElement(XmlName.parts('numFmt'), [
              XmlAttribute(XmlName.parts('numFmtId'), '$next'),
              XmlAttribute(XmlName.parts('formatCode'), numFmt),
            ]),
          );
        }
      }
      xf.setAttribute('numFmtId', '$id');
      xf.setAttribute('applyNumberFormat', '1');
    }

    final int index = _append(cellXfs, xf);
    changed = true;
    // Everything is resolved again rather than just the new one: the lists
    // it points into have grown.
    _resolveAll();
    return _restyled[key] = index;
  }
}
