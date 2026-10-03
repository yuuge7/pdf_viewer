import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'flow_document.dart';

/// Reads a PowerPoint (.pptx) file into a [FlowDocument], one page a slide.
///
/// What is on a slide comes out in order, title first: its text with bullets
/// and levels, its pictures, its tables. A slide is a drawing and this is a
/// reading of it — nothing is where it was, and charts, diagrams,
/// backgrounds and the master's decoration are not there at all.
class PptxReader {
  /// English Metric Units to a point.
  static const double _emu = 12700;

  /// Throws a [FormatException], with a message fit to show, when [bytes]
  /// is not a presentation.
  static FlowDocument read(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('This is not a PowerPoint presentation.');
    }
    final XmlDocument? presentation = _part(archive, 'ppt/presentation.xml');
    if (presentation == null) {
      throw const FormatException('This is not a PowerPoint presentation.');
    }

    double width = 720, height = 405;
    final List<String> ids = [];
    for (final XmlElement e in presentation.rootElement.descendantElements) {
      if (e.name.local == 'sldSz') {
        width = (double.tryParse(e.getAttribute('cx') ?? '') ?? 9144000) / _emu;
        height = (double.tryParse(e.getAttribute('cy') ?? '') ?? 5143500) / _emu;
      } else if (e.name.local == 'sldId') {
        final String? id = _relId(e);
        if (id != null) ids.add(id);
      }
    }
    final Map<String, String> targets = _relationships(
      archive,
      'ppt/_rels/presentation.xml.rels',
      'ppt/',
    );

    final List<FlowBlock> blocks = [];
    for (final String id in ids) {
      final String? path = targets[id];
      final XmlDocument? slide = path == null ? null : _part(archive, path);
      if (path == null || slide == null) continue;
      final int slash = path.lastIndexOf('/');
      final Map<String, String> media = _relationships(
        archive,
        '${path.substring(0, slash)}/_rels/${path.substring(slash + 1)}.rels',
        '${path.substring(0, slash)}/',
      );
      if (blocks.isNotEmpty) blocks.add(const FlowPageBreak());
      final List<FlowBlock> content = _Slide(archive, media).read(slide);
      // A slide that was all drawing still takes its page.
      blocks.addAll(
        content.isEmpty ? const [FlowParagraph([FlowRun('')])] : content,
      );
    }
    if (blocks.isEmpty) {
      throw const FormatException('This presentation has no slides.');
    }
    return FlowDocument(
      blocks,
      pageWidth: width,
      pageHeight: height,
      marginLeft: 40,
      marginRight: 40,
      marginTop: 36,
      marginBottom: 36,
    );
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

  /// The `r:id` (or `r:embed`) of an element, whatever prefix it uses.
  static String? _relId(XmlElement e, [String local = 'id']) {
    for (final XmlAttribute a in e.attributes) {
      if (a.name.local == local && a.name.prefix != null) return a.value;
    }
    return null;
  }

  /// Relationship ids to package paths, resolved against [base].
  static Map<String, String> _relationships(
    Archive archive,
    String name,
    String base,
  ) {
    final Map<String, String> out = {};
    final XmlDocument? rels = _part(archive, name);
    if (rels == null) return out;
    for (final XmlElement rel in rels.rootElement.childElements) {
      final String? id = rel.getAttribute('Id');
      final String? target = rel.getAttribute('Target');
      if (id == null || target == null) continue;
      if (rel.getAttribute('TargetMode') == 'External') continue;
      out[id] = _resolve(base, target);
    }
    return out;
  }

  static String _resolve(String base, String target) {
    if (target.startsWith('/')) return target.substring(1);
    final List<String> parts = base.split('/')..removeLast();
    for (final String piece in target.split('/')) {
      if (piece == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else if (piece != '.' && piece.isNotEmpty) {
        parts.add(piece);
      }
    }
    return parts.join('/');
  }
}

class _Slide {
  final Archive archive;
  final Map<String, String> media;
  _Slide(this.archive, this.media);

  final List<FlowBlock> _titles = [];
  final List<FlowBlock> _body = [];

  static XmlElement? _kid(XmlElement? parent, String local) {
    if (parent == null) return null;
    for (final XmlElement e in parent.childElements) {
      if (e.name.local == local) return e;
    }
    return null;
  }

  List<FlowBlock> read(XmlDocument slide) {
    XmlElement? tree;
    for (final XmlElement e in slide.rootElement.descendantElements) {
      if (e.name.local == 'spTree') {
        tree = e;
        break;
      }
    }
    if (tree != null) _walk(tree);
    return [..._titles, ..._body];
  }

  void _walk(XmlElement parent) {
    for (final XmlElement e in parent.childElements) {
      switch (e.name.local) {
        case 'sp':
          _shape(e);
        case 'pic':
          _picture(e);
        case 'graphicFrame':
          _table(e);
        case 'grpSp':
          _walk(e);
      }
    }
  }

  void _shape(XmlElement shape) {
    final XmlElement? text = _kid(shape, 'txBody');
    if (text == null) return;
    final String? placeholder = _kid(
      _kid(_kid(shape, 'nvSpPr'), 'nvPr'),
      'ph',
    )?.getAttribute('type');
    final bool hasPlaceholder =
        _kid(_kid(_kid(shape, 'nvSpPr'), 'nvPr'), 'ph') != null;
    final bool title = placeholder == 'title' || placeholder == 'ctrTitle';
    final bool subtitle = placeholder == 'subTitle';
    // The outline placeholder, which bullets its paragraphs unless told not
    // to. It is the one a slide leaves untyped.
    final bool outline =
        hasPlaceholder && (placeholder == null || placeholder == 'body');
    if (const {'dt', 'ftr', 'sldNum', 'hdr'}.contains(placeholder)) return;

    final List<FlowBlock> into = title ? _titles : _body;
    for (final XmlElement p in text.childElements) {
      if (p.name.local != 'p') continue;
      final XmlElement? props = _kid(p, 'pPr');
      final int level = (int.tryParse(props?.getAttribute('lvl') ?? '') ?? 0)
          .clamp(0, 8);
      final double base = title
          ? 26
          : subtitle
          ? 16
          : outline
          ? (18 - level * 2).clamp(11, 18).toDouble()
          : 13;
      final List<FlowRun> runs = [];
      for (final XmlElement r in p.childElements) {
        switch (r.name.local) {
          case 'r' || 'fld':
            final String value = _kid(r, 't')?.innerText ?? '';
            if (value.isNotEmpty) runs.add(_run(value, _kid(r, 'rPr'), base, title));
          case 'br':
            runs.add(FlowRun('\n', sizePt: base));
        }
      }
      if (runs.every((r) => r.text.trim().isEmpty)) continue;

      final bool bulleted =
          props != null && _kid(props, 'buNone') != null
          ? false
          : outline ||
                (props != null &&
                    (_kid(props, 'buChar') != null ||
                        _kid(props, 'buAutoNum') != null));
      final FlowAlign align = switch (props?.getAttribute('algn')) {
        'ctr' => FlowAlign.center,
        'r' => FlowAlign.right,
        _ => title && placeholder == 'ctrTitle' ? FlowAlign.center : FlowAlign.left,
      };
      into.add(
        FlowParagraph(
          [
            if (bulleted)
              FlowRun('${String.fromCharCode(0x2022)}\t', sizePt: base),
            ...runs,
          ],
          align: bulleted ? FlowAlign.left : align,
          indentPt: bulleted ? 18.0 * (level + 1) : 18.0 * level,
          firstLinePt: bulleted ? -14 : 0,
          spaceAfterPt: title ? 12 : 5,
          lineHeight: 1.15,
        ),
      );
    }
  }

  FlowRun _run(String text, XmlElement? props, double base, bool title) {
    final double? size = double.tryParse(props?.getAttribute('sz') ?? '');
    int? color;
    final XmlElement? rgb = _kid(_kid(props, 'solidFill'), 'srgbClr');
    if (rgb != null) color = int.tryParse(rgb.getAttribute('val') ?? '', radix: 16);
    // White on a dark slide would be white on white here.
    if (color != null &&
        (color >> 16) >= 0xF0 &&
        ((color >> 8) & 0xFF) >= 0xF0 &&
        (color & 0xFF) >= 0xF0) {
      color = null;
    }
    final String? underline = props?.getAttribute('u');
    final String? strike = props?.getAttribute('strike');
    return FlowRun(
      text,
      // Slides are set large to be read across a room; brought down to
      // what reads on a page, in proportion.
      sizePt: size == null ? base : (size / 100 * 0.62).clamp(8.0, 30.0),
      bold: props?.getAttribute('b') == '1' || (title && props?.getAttribute('b') != '0'),
      italic: props?.getAttribute('i') == '1',
      underline: underline != null && underline != 'none',
      strike: strike != null && strike != 'noStrike',
      color: color,
    );
  }

  void _picture(XmlElement picture) {
    XmlElement? blip;
    for (final XmlElement e in picture.descendantElements) {
      if (e.name.local == 'blip') {
        blip = e;
        break;
      }
    }
    final String? id = blip == null ? null : PptxReader._relId(blip, 'embed');
    final String? path = id == null ? null : media[id];
    final Uint8List? bytes = path == null
        ? null
        : archive.findFile(path)?.readBytes();
    if (bytes == null) return;
    double width = 0, height = 0;
    for (final XmlElement e in picture.descendantElements) {
      if (e.name.local == 'ext' && e.getAttribute('cx') != null) {
        width = (double.tryParse(e.getAttribute('cx')!) ?? 0) / PptxReader._emu;
        height =
            (double.tryParse(e.getAttribute('cy') ?? '') ?? 0) / PptxReader._emu;
        break;
      }
    }
    _body.add(
      FlowImage(bytes, widthPt: width, heightPt: height, align: FlowAlign.center),
    );
  }

  void _table(XmlElement frame) {
    XmlElement? table;
    for (final XmlElement e in frame.descendantElements) {
      if (e.name.local == 'tbl') {
        table = e;
        break;
      }
    }
    if (table == null) return;
    final List<FlowRow> rows = [];
    for (final XmlElement tr in table.childElements) {
      if (tr.name.local != 'tr') continue;
      final List<FlowCell> cells = [];
      for (final XmlElement tc in tr.childElements) {
        if (tc.name.local != 'tc') continue;
        // The cells a merge swallowed are still listed; skip them.
        if (tc.getAttribute('hMerge') == '1' || tc.getAttribute('vMerge') == '1') {
          continue;
        }
        final List<FlowBlock> blocks = [];
        final XmlElement? body = _kid(tc, 'txBody');
        for (final XmlElement p
            in body == null ? const <XmlElement>[] : body.childElements) {
          if (p.name.local != 'p') continue;
          final List<FlowRun> runs = [
            for (final XmlElement r in p.childElements)
              if (r.name.local == 'r')
                _run(_kid(r, 't')?.innerText ?? '', _kid(r, 'rPr'), 11, false),
          ];
          blocks.add(FlowParagraph(runs.isEmpty ? const [FlowRun('')] : runs));
        }
        cells.add(
          FlowCell(
            blocks.isEmpty ? const [FlowParagraph([FlowRun('')])] : blocks,
            span: (int.tryParse(tc.getAttribute('gridSpan') ?? '') ?? 1).clamp(
              1,
              50,
            ),
          ),
        );
      }
      if (cells.isNotEmpty) rows.add(FlowRow(cells));
    }
    if (rows.isNotEmpty) _body.add(FlowTable(rows));
  }
}
