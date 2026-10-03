import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'flow_document.dart';

/// Reads an OpenDocument text (.odt) file into a [FlowDocument].
///
/// The same selection as the Word reader: text and how it looks, paragraph
/// alignment and spacing, lists, tables, pictures, page breaks and the
/// paper size. Headers, footers, footnotes and frames laid out beside the
/// text are not read.
class OdtReader {
  /// Throws a [FormatException], with a message fit to show, when [bytes]
  /// is not an OpenDocument text file.
  static FlowDocument read(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('This is not an OpenDocument file.');
    }
    final XmlDocument? content = _part(archive, 'content.xml');
    if (content == null) {
      throw const FormatException('This is not an OpenDocument file.');
    }
    return _Odt(archive, content, _part(archive, 'styles.xml')).read();
  }

  static XmlDocument? _part(Archive archive, String name) {
    final ArchiveFile? file = archive.findFile(name);
    if (file == null) return null;
    try {
      return XmlDocument.parse(
        utf8.decode(file.readBytes()!, allowMalformed: true),
      );
    } catch (_) {
      return null;
    }
  }
}

class _Look {
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final double size;
  final int? color;

  const _Look({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.size = 12,
    this.color,
  });

  FlowRun run(String text) => FlowRun(
    text,
    sizePt: size,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    color: color,
  );
}

class _Odt {
  final Archive archive;
  final XmlDocument content;
  final XmlDocument? styles;

  /// Every style by name: its parent, and its properties as written.
  final Map<String, (String?, Map<String, String>)> _styles = {};
  final Set<String> _numberedLists = {};

  _Odt(this.archive, this.content, this.styles);

  final List<FlowBlock> _blocks = [];

  /// Where blocks are going: the document, or a table cell being read.
  late List<FlowBlock> _sink = _blocks;

  static String? _attr(XmlElement e, String local) {
    for (final XmlAttribute a in e.attributes) {
      if (a.name.local == local) return a.value;
    }
    return null;
  }

  /// A length such as "2.54cm" or "12pt", in points.
  static double? _length(String? value) {
    if (value == null) return null;
    final RegExpMatch? m = RegExp(
      r'^(-?[\d.]+)\s*(cm|mm|in|pt|pc|px)?$',
    ).firstMatch(value.trim());
    if (m == null) return null;
    final double? n = double.tryParse(m.group(1)!);
    if (n == null) return null;
    return switch (m.group(2)) {
      'cm' => n * 72 / 2.54,
      'mm' => n * 72 / 25.4,
      'in' => n * 72,
      'pc' => n * 12,
      'px' => n * 0.75,
      _ => n,
    };
  }

  void _collectStyles(XmlDocument? document) {
    if (document == null) return;
    for (final XmlElement e in document.rootElement.descendantElements) {
      if (e.name.local == 'list-style') {
        final String? name = _attr(e, 'name');
        final XmlElement? first = e.childElements.firstOrNull;
        if (name != null && first?.name.local == 'list-level-style-number') {
          _numberedLists.add(name);
        }
        continue;
      }
      if (e.name.local != 'style' && e.name.local != 'default-style') continue;
      final String name =
          _attr(e, 'name') ?? 'default:${_attr(e, 'family') ?? ''}';
      final Map<String, String> props = {};
      for (final XmlElement group in e.childElements) {
        if (!group.name.local.endsWith('-properties')) continue;
        for (final XmlAttribute a in group.attributes) {
          props[a.name.local] = a.value;
        }
      }
      _styles[name] = (_attr(e, 'parent-style-name'), props);
    }
  }

  /// A style's properties with its parents' underneath.
  Map<String, String> _resolve(String? name, String family) {
    final List<Map<String, String>> chain = [];
    String? current = name;
    for (int depth = 0; current != null && depth < 20; depth++) {
      final (String?, Map<String, String>)? style = _styles[current];
      if (style == null) break;
      chain.add(style.$2);
      current = style.$1;
    }
    final Map<String, String> out = {
      ...?_styles['default:$family']?.$2,
    };
    for (final Map<String, String> props in chain.reversed) {
      out.addAll(props);
    }
    return out;
  }

  _Look _look(_Look base, Map<String, String> props) {
    double size = base.size;
    final String? rawSize = props['font-size'];
    if (rawSize != null) {
      if (rawSize.endsWith('%')) {
        final double? percent = double.tryParse(
          rawSize.substring(0, rawSize.length - 1),
        );
        if (percent != null) size = base.size * percent / 100;
      } else {
        size = _length(rawSize) ?? size;
      }
    }
    int? color = base.color;
    final String? rawColor = props['color'];
    if (rawColor != null && rawColor.startsWith('#') && rawColor.length == 7) {
      color = int.tryParse(rawColor.substring(1), radix: 16) ?? color;
    }
    bool flag(String key, bool Function(String) on, bool fallback) {
      final String? value = props[key];
      return value == null ? fallback : on(value);
    }

    return _Look(
      bold: flag('font-weight', (v) => v == 'bold' || (int.tryParse(v) ?? 0) >= 600, base.bold),
      italic: flag('font-style', (v) => v == 'italic' || v == 'oblique', base.italic),
      underline: flag('text-underline-style', (v) => v != 'none', base.underline),
      strike: flag('text-line-through-style', (v) => v != 'none', base.strike),
      size: size.clamp(4.0, 144.0),
      color: color,
    );
  }

  FlowDocument read() {
    _collectStyles(styles);
    _collectStyles(content);

    double pageWidth = FlowDocument.a4Width, pageHeight = FlowDocument.a4Height;
    double left = 72, right = 72, top = 72, bottom = 72;
    final XmlDocument? source = styles;
    if (source != null) {
      for (final XmlElement e in source.rootElement.descendantElements) {
        if (e.name.local != 'page-layout-properties') continue;
        pageWidth = _length(_attr(e, 'page-width')) ?? pageWidth;
        pageHeight = _length(_attr(e, 'page-height')) ?? pageHeight;
        final double? all = _length(_attr(e, 'margin'));
        left = _length(_attr(e, 'margin-left')) ?? all ?? left;
        right = _length(_attr(e, 'margin-right')) ?? all ?? right;
        top = _length(_attr(e, 'margin-top')) ?? all ?? top;
        bottom = _length(_attr(e, 'margin-bottom')) ?? all ?? bottom;
        break;
      }
    }

    XmlElement? body;
    for (final XmlElement e in content.rootElement.descendantElements) {
      if (e.name.local == 'text' && e.parentElement?.name.local == 'body') {
        body = e;
        break;
      }
    }
    if (body == null) {
      throw const FormatException('This is not an OpenDocument text file.');
    }
    _walkBlocks(body, 0, null);
    return FlowDocument(
      _blocks.isEmpty ? const [FlowParagraph([FlowRun('')])] : _blocks,
      pageWidth: pageWidth,
      pageHeight: pageHeight,
      marginLeft: left,
      marginRight: right,
      marginTop: top,
      marginBottom: bottom,
    );
  }

  /// [counters] holds the next number for a numbered list, or null in a
  /// bulleted one or outside any list.
  void _walkBlocks(XmlElement parent, int listDepth, List<int>? counters) {
    for (final XmlElement e in parent.childElements) {
      switch (e.name.local) {
        case 'p' || 'h':
          _paragraph(e, listDepth, null);
        case 'list':
          _list(e, listDepth + 1);
        case 'table':
          _table(e);
        case 'section' || 'text-box' || 'frame':
          _walkBlocks(e, listDepth, counters);
      }
    }
  }

  void _list(XmlElement list, int depth) {
    final bool numbered = _numberedLists.contains(_attr(list, 'style-name'));
    int number = 1;
    for (final XmlElement item in list.childElements) {
      if (item.name.local != 'list-item' && item.name.local != 'list-header') {
        continue;
      }
      bool first = true;
      for (final XmlElement e in item.childElements) {
        switch (e.name.local) {
          case 'p' || 'h':
            // Only the first paragraph of an item carries its marker.
            final String marker = !first || item.name.local == 'list-header'
                ? ''
                : numbered
                ? '${number++}.'
                : String.fromCharCode(0x2022);
            _paragraph(e, depth, marker);
            first = false;
          case 'list':
            _list(e, depth + 1);
        }
      }
    }
  }

  void _paragraph(XmlElement e, int listDepth, String? marker) {
    final Map<String, String> props = _resolve(
      _attr(e, 'style-name'),
      'paragraph',
    );
    _Look look = _look(const _Look(), props);
    if (e.name.local == 'h' && !props.containsKey('font-size')) {
      // A heading with no size of its own takes one from its level.
      final int level = int.tryParse(_attr(e, 'outline-level') ?? '') ?? 1;
      const List<double> sizes = [20, 16, 14, 12, 11, 10];
      look = _Look(
        bold: true,
        italic: look.italic,
        size: sizes[(level - 1).clamp(0, sizes.length - 1)],
        color: look.color,
      );
    }
    if (props['break-before'] == 'page' && identical(_sink, _blocks)) {
      _blocks.add(const FlowPageBreak());
    }

    List<FlowRun> runs = [];
    if (marker != null && marker.isNotEmpty) {
      runs.add(FlowRun('$marker\t', sizePt: look.size));
    }
    void flush() {
      _sink.add(
        FlowParagraph(
          runs.isEmpty ? [look.run('')] : runs,
          align: switch (props['text-align']) {
            'center' => FlowAlign.center,
            'end' || 'right' => FlowAlign.right,
            _ => FlowAlign.left,
          },
          indentPt: (_length(props['margin-left']) ?? 0) + listDepth * 18.0,
          firstLinePt: marker != null && marker.isNotEmpty
              ? -14
              : (_length(props['text-indent']) ?? 0),
          spaceBeforePt: _length(props['margin-top']) ?? 0,
          spaceAfterPt: _length(props['margin-bottom']) ?? 0,
          lineHeight: 1.15,
        ),
      );
      runs = [];
    }

    void inline(XmlNode node, _Look current) {
      if (node is XmlText) {
        if (node.value.isNotEmpty) runs.add(current.run(node.value));
        return;
      }
      if (node is! XmlElement) return;
      switch (node.name.local) {
        case 'span' || 'a':
          final _Look next = _look(
            current,
            _resolve(_attr(node, 'style-name'), 'text'),
          );
          for (final XmlNode child in node.children) {
            inline(child, next);
          }
        case 's':
          runs.add(
            current.run(' ' * (int.tryParse(_attr(node, 'c') ?? '') ?? 1)),
          );
        case 'tab':
          runs.add(current.run('\t'));
        case 'line-break':
          runs.add(current.run('\n'));
        case 'frame':
          final FlowImage? image = _image(node);
          if (image != null) {
            // A picture stands on a line of its own.
            if (runs.isNotEmpty) flush();
            _sink.add(image);
          }
        case 'note' || 'annotation' || 'annotation-end' || 'bookmark' ||
            'bookmark-start' || 'bookmark-end' || 'soft-page-break':
          break;
        default:
          for (final XmlNode child in node.children) {
            inline(child, current);
          }
      }
    }

    final int before = _sink.length;
    for (final XmlNode child in e.children) {
      inline(child, look);
    }
    // A paragraph that was only a picture has already put it out.
    if (runs.isNotEmpty || _sink.length == before) flush();
  }

  FlowImage? _image(XmlElement frame) {
    for (final XmlElement child in frame.childElements) {
      if (child.name.local != 'image') continue;
      final String? href = _attr(child, 'href');
      if (href == null) return null;
      final ArchiveFile? file = archive.findFile(
        href.startsWith('./') ? href.substring(2) : href,
      );
      final Uint8List? bytes = file?.readBytes();
      if (bytes == null) return null;
      return FlowImage(
        bytes,
        widthPt: _length(_attr(frame, 'width')) ?? 0,
        heightPt: _length(_attr(frame, 'height')) ?? 0,
      );
    }
    return null;
  }

  void _table(XmlElement table) {
    final List<FlowRow> rows = [];
    void collect(XmlElement parent) {
      for (final XmlElement e in parent.childElements) {
        switch (e.name.local) {
          case 'table-header-rows' || 'table-rows' || 'table-row-group':
            collect(e);
          case 'table-row':
            final List<FlowCell> cells = [];
            for (final XmlElement cell in e.childElements) {
              if (cell.name.local != 'table-cell') continue;
              final List<FlowBlock> outer = _sink;
              final List<FlowBlock> inner = [];
              _sink = inner;
              _walkBlocks(cell, 0, null);
              _sink = outer;
              cells.add(
                FlowCell(
                  inner.isEmpty ? const [FlowParagraph([FlowRun('')])] : inner,
                  span:
                      (int.tryParse(
                                _attr(cell, 'number-columns-spanned') ?? '',
                              ) ??
                              1)
                          .clamp(1, 50),
                ),
              );
            }
            if (cells.isNotEmpty) rows.add(FlowRow(cells));
        }
      }
    }

    collect(table);
    if (rows.isNotEmpty) _sink.add(FlowTable(rows));
  }
}
