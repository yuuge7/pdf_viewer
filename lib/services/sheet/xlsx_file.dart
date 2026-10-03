import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'formula.dart';
import 'sheet_styles.dart';
import 'workbook.dart';

Iterable<XmlElement> _kids(XmlElement parent, String local) =>
    parent.childElements.where((e) => e.name.local == local);

XmlElement? _kid(XmlElement? parent, String local) {
  if (parent == null) return null;
  for (final XmlElement e in parent.childElements) {
    if (e.name.local == local) return e;
  }
  return null;
}

XmlElement _el(
  String name, [
  Map<String, String> attributes = const {},
  Iterable<XmlNode> children = const [],
]) => XmlElement(
  XmlName.parts(name),
  [
    for (final MapEntry<String, String> a in attributes.entries)
      XmlAttribute(XmlName.parse(a.key), a.value),
  ],
  children,
);

/// Reads and writes `.xlsx` packages.
///
/// Writing patches the package that was read rather than building a new
/// one: the cells, sizes and formats this editor changes are rewritten, and
/// every other part — charts, pictures, defined names, print settings —
/// goes back exactly as it came.
class XlsxFile {
  static const String mimeType =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  static const String _mainNs =
      'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
  static const String _relNs =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

  // --- Reading ----------------------------------------------------------------

  /// Throws a [FormatException], with a message fit to show, when [bytes]
  /// is not a workbook.
  static Workbook read(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('This is not an Excel workbook.');
    }
    XmlDocument? part(String name) {
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

    final XmlDocument? workbook = part('xl/workbook.xml');
    if (workbook == null) {
      throw const FormatException('This is not an Excel workbook.');
    }

    final Map<String, String> targets = {};
    final XmlDocument? rels = part('xl/_rels/workbook.xml.rels');
    if (rels != null) {
      for (final XmlElement rel in _kids(rels.rootElement, 'Relationship')) {
        final String? id = rel.getAttribute('Id');
        final String? target = rel.getAttribute('Target');
        if (id == null || target == null) continue;
        targets[id] = target.startsWith('/')
            ? target.substring(1)
            : 'xl/$target';
      }
    }

    final List<String> strings = [];
    final XmlDocument? shared = part('xl/sharedStrings.xml');
    if (shared != null) {
      for (final XmlElement si in _kids(shared.rootElement, 'si')) {
        strings.add(_richText(si));
      }
    }

    final XmlDocument? stylesXml = part('xl/styles.xml');
    final StyleBook styles = stylesXml == null
        ? StyleBook.blank()
        : StyleBook(stylesXml, theme: _themeColors(part('xl/theme/theme1.xml')));

    final bool date1904 = const {
      '1',
      'true',
    }.contains(_kid(workbook.rootElement, 'workbookPr')?.getAttribute('date1904'));

    final List<Sheet> sheets = [];
    final XmlElement? list = _kid(workbook.rootElement, 'sheets');
    for (final XmlElement entry
        in list == null ? const <XmlElement>[] : _kids(list, 'sheet')) {
      String? id;
      for (final XmlAttribute a in entry.attributes) {
        if (a.name.local == 'id' && a.name.prefix != null) id = a.value;
      }
      final String? path = targets[id];
      if (path == null || !path.contains('worksheets/')) continue; // A chart sheet.
      final XmlDocument? xml = part(path);
      if (xml == null) continue;
      final Sheet sheet = Sheet(
        name: entry.getAttribute('name') ?? 'Sheet${sheets.length + 1}',
        path: path,
        xml: xml,
      );
      _readSheet(sheet, strings);
      sheets.add(sheet);
    }
    if (sheets.isEmpty) {
      throw const FormatException('This workbook has no sheets to show.');
    }
    return Workbook(
      sheets: sheets,
      styles: styles,
      archive: archive,
      date1904: date1904,
    );
  }

  /// The text of a string item, runs joined, phonetic guides left out.
  static String _richText(XmlElement item) {
    final StringBuffer out = StringBuffer();
    void walk(XmlElement e) {
      for (final XmlElement child in e.childElements) {
        switch (child.name.local) {
          case 't':
            out.write(child.innerText);
          case 'rPh' || 'phoneticPr':
            break;
          default:
            walk(child);
        }
      }
    }

    walk(item);
    return out.toString();
  }

  static List<int> _themeColors(XmlDocument? theme) {
    if (theme == null) return StyleBook.defaultTheme;
    XmlElement? scheme;
    for (final XmlElement e in theme.rootElement.descendantElements) {
      if (e.name.local == 'clrScheme') {
        scheme = e;
        break;
      }
    }
    if (scheme == null) return StyleBook.defaultTheme;
    int? color(String name) {
      final XmlElement? slot = _kid(scheme, name);
      final XmlElement? value = slot?.childElements.firstOrNull;
      if (value == null) return null;
      final String? hex =
          value.getAttribute('val') ?? value.getAttribute('lastClr');
      // A system colour names the colour and remembers what it last was.
      final String? last = value.getAttribute('lastClr');
      final int? parsed = int.tryParse(
        value.name.local == 'sysClr' ? (last ?? '') : (hex ?? ''),
        radix: 16,
      );
      return parsed == null ? null : 0xFF000000 | parsed;
    }

    // Formats count them light-dark-light-dark; the theme lists them
    // dark-light-dark-light.
    const List<String> order = [
      'lt1', 'dk1', 'lt2', 'dk2', 'accent1', 'accent2', 'accent3', //
      'accent4', 'accent5', 'accent6', 'hlink', 'folHlink',
    ];
    return [
      for (int i = 0; i < order.length; i++)
        color(order[i]) ?? StyleBook.defaultTheme[i],
    ];
  }

  static void _readSheet(Sheet sheet, List<String> strings) {
    final XmlElement root = sheet.xml.rootElement;

    final XmlElement? format = _kid(root, 'sheetFormatPr');
    sheet.defaultRowHeight =
        double.tryParse(format?.getAttribute('defaultRowHeight') ?? '') ?? 15;
    sheet.defaultColWidth =
        double.tryParse(format?.getAttribute('defaultColWidth') ?? '') ??
        ((double.tryParse(format?.getAttribute('baseColWidth') ?? '') ?? 8) +
            0.43);

    final XmlElement? pane = _kid(
      _kid(_kid(root, 'sheetViews'), 'sheetView'),
      'pane',
    );
    final String? state = pane?.getAttribute('state');
    if (pane != null && (state == 'frozen' || state == 'frozenSplit')) {
      sheet.frozenCols =
          (double.tryParse(pane.getAttribute('xSplit') ?? '') ?? 0).round();
      sheet.frozenRows =
          (double.tryParse(pane.getAttribute('ySplit') ?? '') ?? 0).round();
    }

    final XmlElement? cols = _kid(root, 'cols');
    if (cols != null) {
      for (final XmlElement col in _kids(cols, 'col')) {
        final int min = int.tryParse(col.getAttribute('min') ?? '') ?? 1;
        final int max = int.tryParse(col.getAttribute('max') ?? '') ?? min;
        final double? width = double.tryParse(col.getAttribute('width') ?? '');
        final bool hidden = const {'1', 'true'}.contains(
          col.getAttribute('hidden'),
        );
        if (width == null && !hidden) continue;
        // A format applied to "the rest of the sheet" runs to column 16384;
        // only the columns a person could reach are worth an entry.
        for (int c = min; c <= max && c <= 2000; c++) {
          sheet.colWidths[c - 1] = hidden ? 0 : width!;
        }
      }
    }

    final Map<String, (int, int, String)> sharedFormulas = {};
    final XmlElement? data = _kid(root, 'sheetData');
    int nextRow = 0;
    for (final XmlElement row
        in data == null ? const <XmlElement>[] : _kids(data, 'row')) {
      final int r = (int.tryParse(row.getAttribute('r') ?? '') ?? nextRow + 1) - 1;
      nextRow = r + 1;
      final double? height = double.tryParse(row.getAttribute('ht') ?? '');
      if (const {'1', 'true'}.contains(row.getAttribute('hidden'))) {
        sheet.rowHeights[r] = 0;
      } else if (height != null) {
        sheet.rowHeights[r] = height;
      }
      int nextCol = 0;
      for (final XmlElement c in _kids(row, 'c')) {
        final (int, int)? at = parseCellName(c.getAttribute('r') ?? '');
        final int col = at?.$2 ?? nextCol;
        nextCol = col + 1;
        final SheetCell cell = SheetCell(
          style: int.tryParse(c.getAttribute('s') ?? '') ?? 0,
          source: c,
        );
        final String type = c.getAttribute('t') ?? 'n';
        final String? raw = _kid(c, 'v')?.innerText;
        switch (type) {
          case 's':
            final int? index = int.tryParse(raw ?? '');
            if (index != null && index >= 0 && index < strings.length) {
              cell.value = strings[index];
            }
          case 'b':
            if (raw != null) cell.value = raw == '1' || raw == 'true';
          case 'e':
            if (raw != null) cell.value = SheetError(raw);
          case 'str' || 'd':
            cell.value = raw;
          case 'inlineStr':
            final XmlElement? inline = _kid(c, 'is');
            if (inline != null) cell.value = _richText(inline);
          default:
            if (raw != null) cell.value = double.tryParse(raw);
        }

        final XmlElement? f = _kid(c, 'f');
        if (f != null) {
          final String text = f.innerText;
          final String? group = f.getAttribute('si');
          if (f.getAttribute('t') == 'shared' && group != null) {
            if (text.isNotEmpty) {
              sharedFormulas[group] = (r, col, text);
              cell.formula = text;
            } else if (sharedFormulas[group] case (
              final int fromRow,
              final int fromCol,
              final String master,
            )) {
              // Written once and stretched over a range: every other cell
              // in it means "the same, from where I stand".
              cell.formula = Formula.offset(master, r - fromRow, col - fromCol);
            }
          } else if (text.isNotEmpty) {
            cell.formula = text;
          }
          // Rebuilt on save, unless it is an array formula, whose braces
          // only its own element knows about.
          if (f.getAttribute('t') != 'array') cell.source = null;
        }
        if (cell.isBlank && cell.style == 0) continue;
        sheet.rows.putIfAbsent(r, () => {})[col] = cell;
      }
    }

    final XmlElement? merges = _kid(root, 'mergeCells');
    if (merges != null) {
      for (final XmlElement merge in _kids(merges, 'mergeCell')) {
        final CellRange? range = CellRange.parse(merge.getAttribute('ref') ?? '');
        if (range != null && !range.isSingle) sheet.merges.add(range);
      }
    }

    final XmlElement? validations = _kid(root, 'dataValidations');
    if (validations != null) {
      for (final XmlElement v in _kids(validations, 'dataValidation')) {
        if (v.getAttribute('type') != 'list') continue;
        final List<CellRange> ranges = [
          for (final String ref in (v.getAttribute('sqref') ?? '').split(' '))
            if (CellRange.parse(ref) case final CellRange range) range,
        ];
        final String formula = _kid(v, 'formula1')?.innerText.trim() ?? '';
        if (ranges.isEmpty || formula.isEmpty) continue;
        if (formula.startsWith('"') && formula.endsWith('"')) {
          sheet.validations.add(
            ListValidation(
              ranges,
              options: formula
                  .substring(1, formula.length - 1)
                  .split(',')
                  .map((o) => o.trim())
                  .where((o) => o.isNotEmpty)
                  .toList(),
            ),
          );
        } else {
          sheet.validations.add(ListValidation(ranges, source: formula));
        }
      }
    }
  }

  // --- Writing ----------------------------------------------------------------

  /// The workbook as an `.xlsx` file.
  static Uint8List write(Workbook book) {
    final Map<String, List<int>> replaced = {};
    for (int i = 0; i < book.sheets.length; i++) {
      final Sheet sheet = book.sheets[i];
      _writeSheet(book, i);
      replaced[sheet.path] = utf8.encode(sheet.xml.toXmlString());
    }
    if (book.styles.changed || book.archive.findFile('xl/styles.xml') == null) {
      replaced['xl/styles.xml'] = utf8.encode(book.styles.xml.toXmlString());
    }

    // The calculation chain lists every formula cell in order. It is only
    // a cache, and one that names a cell which no longer has a formula
    // makes Excel declare the file damaged, so it goes.
    const String chain = 'xl/calcChain.xml';
    final bool dropChain = book.edited && book.archive.findFile(chain) != null;

    XmlDocument? parse(String name) {
      final ArchiveFile? file = book.archive.findFile(name);
      if (file == null) return null;
      try {
        return XmlDocument.parse(utf8.decode(file.readBytes()!));
      } catch (_) {
        return null;
      }
    }

    if (book.edited) {
      final XmlDocument? workbook = parse('xl/workbook.xml');
      if (workbook != null) {
        // Results this engine could not recompute were left out; have the
        // next spreadsheet work everything out when it opens the file.
        final XmlElement root = workbook.rootElement;
        XmlElement? calc = _kid(root, 'calcPr');
        if (calc == null) {
          calc = _el('calcPr');
          int at = root.children.length;
          const List<String> after = [
            'oleSize', 'customWorkbookViews', 'pivotCaches', 'smartTagPr', //
            'smartTagTypes', 'webPublishing', 'fileRecoveryPr',
            'webPublishObjects', 'extLst',
          ];
          for (int i = 0; i < root.children.length; i++) {
            final XmlNode node = root.children[i];
            if (node is XmlElement && after.contains(node.name.local)) {
              at = i;
              break;
            }
          }
          root.children.insert(at, calc);
        }
        calc.setAttribute('fullCalcOnLoad', '1');
        replaced['xl/workbook.xml'] = utf8.encode(workbook.toXmlString());
      }
    }
    if (dropChain) {
      final XmlDocument? types = parse('[Content_Types].xml');
      if (types != null) {
        types.rootElement.children.removeWhere(
          (n) =>
              n is XmlElement &&
              (n.getAttribute('PartName') ?? '').endsWith('/calcChain.xml'),
        );
        replaced['[Content_Types].xml'] = utf8.encode(types.toXmlString());
      }
      final XmlDocument? rels = parse('xl/_rels/workbook.xml.rels');
      if (rels != null) {
        rels.rootElement.children.removeWhere(
          (n) =>
              n is XmlElement &&
              (n.getAttribute('Type') ?? '').endsWith('/calcChain'),
        );
        replaced['xl/_rels/workbook.xml.rels'] = utf8.encode(
          rels.toXmlString(),
        );
      }
    }

    final Archive out = Archive();
    for (final ArchiveFile file in book.archive.files) {
      if (!file.isFile) continue;
      if (dropChain && file.name == chain) continue;
      final List<int>? fresh = replaced.remove(file.name);
      out.addFile(
        ArchiveFile.bytes(file.name, fresh ?? file.readBytes()!),
      );
    }
    replaced.forEach((name, bytes) {
      out.addFile(ArchiveFile.bytes(name, bytes));
    });
    return ZipEncoder().encodeBytes(out);
  }

  static void _writeSheet(Workbook book, int index) {
    final Sheet sheet = book.sheets[index];
    final XmlElement root = sheet.xml.rootElement;

    XmlElement? data = _kid(root, 'sheetData');
    if (data == null) {
      data = _el('sheetData');
      root.children.add(data);
    }
    // What each row said about itself, to say again.
    final Map<int, List<XmlAttribute>> rowAttributes = {};
    if (!sheet.structureChanged) {
      for (final XmlElement row in _kids(data, 'row')) {
        final int? r = int.tryParse(row.getAttribute('r') ?? '');
        if (r == null) continue;
        rowAttributes[r - 1] = [
          for (final XmlAttribute a in row.attributes)
            if (!const {'r', 'spans', 'ht', 'customHeight', 'hidden'}.contains(
              a.name.local,
            ))
              a.copy(),
        ];
      }
    }

    final List<XmlElement> rows = [];
    final Set<int> rowIndices = {...sheet.rows.keys, ...sheet.rowHeights.keys};
    for (final int r in rowIndices.toList()..sort()) {
      final Map<int, SheetCell> cells = sheet.rows[r] ?? const {};
      final List<XmlElement> written = [];
      for (final int c in cells.keys.toList()..sort()) {
        final XmlElement? cell = _writeCell(book, index, r, c, cells[c]!);
        if (cell != null) written.add(cell);
      }
      final double? height = sheet.rowHeights[r];
      if (written.isEmpty && height == null) continue;
      final XmlElement row = _el('row', {'r': '${r + 1}'}, written);
      for (final XmlAttribute a in rowAttributes[r] ?? const <XmlAttribute>[]) {
        row.attributes.add(a);
      }
      if (height != null) {
        if (height == 0) {
          row.setAttribute('hidden', '1');
        } else {
          row.setAttribute('ht', _number(height));
          row.setAttribute('customHeight', '1');
        }
      }
      rows.add(row);
    }
    data.children
      ..clear()
      ..addAll(rows);

    final int usedRows = sheet.usedRows, usedCols = sheet.usedCols;
    _kid(root, 'dimension')?.setAttribute(
      'ref',
      usedRows == 0 || usedCols == 0
          ? 'A1'
          : CellRange(0, 0, usedRows - 1, usedCols - 1).name,
    );

    final XmlElement? merges = _kid(root, 'mergeCells');
    if (merges != null) {
      if (sheet.merges.isEmpty) {
        root.children.remove(merges);
      } else {
        merges.children
          ..clear()
          ..addAll([
            for (final CellRange merge in sheet.merges)
              _el('mergeCell', {'ref': merge.name}),
          ]);
        merges.setAttribute('count', '${sheet.merges.length}');
      }
    }

    if (sheet.colsChanged) _writeCols(sheet, root);
    if (sheet.structureChanged) _writeValidations(sheet, root);
  }

  static String _number(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  static XmlElement? _writeCell(
    Workbook book,
    int sheetIndex,
    int row,
    int col,
    SheetCell cell,
  ) {
    final String ref = cellName(row, col);
    final XmlElement? source = cell.source;
    if (source != null) {
      final XmlElement copy = source.copy();
      copy.setAttribute('r', ref);
      return copy;
    }
    if (cell.isBlank && cell.style == 0) return null;

    final Map<String, String> attributes = {
      'r': ref,
      if (cell.style != 0) 's': '${cell.style}',
    };
    final List<XmlNode> children = [];
    Object? value = cell.value;
    final String? formula = cell.formula;
    if (formula != null) {
      children.add(_el('f', const {}, [XmlText(formula)]));
      if (book.recomputes(cell)) {
        value = book.valueAt(sheetIndex, row, col);
      } else if (book.edited) {
        // Stale by now; left for the next spreadsheet to compute.
        value = null;
      }
    }
    if (value is double) {
      children.add(_el('v', const {}, [XmlText(_number(value))]));
    } else if (value is bool) {
      attributes['t'] = 'b';
      children.add(_el('v', const {}, [XmlText(value ? '1' : '0')]));
    } else if (value is SheetError) {
      attributes['t'] = 'e';
      children.add(_el('v', const {}, [XmlText(value.code)]));
    } else if (value is String) {
      if (formula != null) {
        attributes['t'] = 'str';
        children.add(_el('v', const {}, [XmlText(_clean(value))]));
      } else {
        // Inline, so the shared string table can stay exactly as it was.
        attributes['t'] = 'inlineStr';
        children.add(
          _el('is', const {}, [
            _el('t', const {'xml:space': 'preserve'}, [XmlText(_clean(value))]),
          ]),
        );
      }
    }
    return _el('c', attributes, children);
  }

  /// [text] without the control characters XML cannot hold.
  static String _clean(String text) => text.replaceAll(
    RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\uFFFE\uFFFF]'),
    '',
  );

  static void _writeCols(Sheet sheet, XmlElement root) {
    XmlElement? cols = _kid(root, 'cols');
    // The format each column gave its empty cells, which is all a <col>
    // holds besides its width.
    final Map<int, String> styles = {};
    if (cols != null && !sheet.structureChanged) {
      for (final XmlElement col in _kids(cols, 'col')) {
        final String? style = col.getAttribute('style');
        if (style == null) continue;
        final int min = int.tryParse(col.getAttribute('min') ?? '') ?? 1;
        final int max = int.tryParse(col.getAttribute('max') ?? '') ?? min;
        for (int c = min; c <= max && c <= 2000; c++) {
          styles[c - 1] = style;
        }
      }
    }
    final Set<int> columns = {...sheet.colWidths.keys, ...styles.keys};
    if (columns.isEmpty) {
      if (cols != null) root.children.remove(cols);
      return;
    }
    if (cols == null) {
      cols = _el('cols');
      // Between the sheet's defaults and its cells, where the schema wants it.
      final XmlElement? data = _kid(root, 'sheetData');
      root.children.insert(
        data == null ? root.children.length : root.children.indexOf(data),
        cols,
      );
    }
    cols.children
      ..clear()
      ..addAll([
        for (final int c in columns.toList()..sort())
          _el('col', {
            'min': '${c + 1}',
            'max': '${c + 1}',
            'width': _number(
              (sheet.colWidths[c] ?? sheet.defaultColWidth) == 0
                  ? sheet.defaultColWidth
                  : (sheet.colWidths[c] ?? sheet.defaultColWidth),
            ),
            if (sheet.colWidths.containsKey(c)) 'customWidth': '1',
            if (sheet.colWidths[c] == 0) 'hidden': '1',
            if (styles[c] != null) 'style': styles[c]!,
          }),
      ]);
  }

  /// Puts the list validations back where their cells went. The other
  /// kinds, which this model does not hold, keep the ranges they had.
  static void _writeValidations(Sheet sheet, XmlElement root) {
    final XmlElement? validations = _kid(root, 'dataValidations');
    if (validations == null) return;
    final List<XmlElement> lists = [
      for (final XmlElement v in _kids(validations, 'dataValidation'))
        if (v.getAttribute('type') == 'list') v,
    ];
    for (int i = 0; i < lists.length; i++) {
      if (i < sheet.validations.length) {
        lists[i].setAttribute(
          'sqref',
          sheet.validations[i].ranges.map((r) => r.name).join(' '),
        );
      } else {
        validations.children.remove(lists[i]);
      }
    }
    final int count = validations.childElements.length;
    if (count == 0) {
      root.children.remove(validations);
    } else {
      validations.setAttribute('count', '$count');
    }
  }

  // --- New workbooks ----------------------------------------------------------

  /// An empty workbook with one sheet.
  static Workbook blank({String sheetName = 'Sheet1'}) {
    final Archive archive = Archive();
    void add(String name, String content) =>
        archive.addFile(ArchiveFile.bytes(name, utf8.encode(content)));
    const String header =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
    const String pkg =
        'http://schemas.openxmlformats.org/package/2006';
    add(
      '[Content_Types].xml',
      '$header<Types xmlns="$pkg/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
          '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
          '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
          '</Types>',
    );
    add(
      '_rels/.rels',
      '$header<Relationships xmlns="$pkg/relationships">'
          '<Relationship Id="rId1" Type="$_relNs/officeDocument" Target="xl/workbook.xml"/>'
          '</Relationships>',
    );
    final String name = const HtmlEscape(
      HtmlEscapeMode.attribute,
    ).convert(sheetName);
    add(
      'xl/workbook.xml',
      '$header<workbook xmlns="$_mainNs" xmlns:r="$_relNs">'
          '<sheets><sheet name="$name" sheetId="1" r:id="rId1"/></sheets>'
          '</workbook>',
    );
    add(
      'xl/_rels/workbook.xml.rels',
      '$header<Relationships xmlns="$pkg/relationships">'
          '<Relationship Id="rId1" Type="$_relNs/worksheet" Target="worksheets/sheet1.xml"/>'
          '<Relationship Id="rId2" Type="$_relNs/styles" Target="styles.xml"/>'
          '</Relationships>',
    );
    add('xl/styles.xml', StyleBook.blankXml);
    add(
      'xl/worksheets/sheet1.xml',
      '$header<worksheet xmlns="$_mainNs"><dimension ref="A1"/>'
          '<sheetData/></worksheet>',
    );
    return read(ZipEncoder().encodeBytes(archive));
  }

  /// A workbook holding the rows of a comma-separated file.
  ///
  /// The separator is whichever of comma, semicolon and tab the first line
  /// uses most, since "CSV" from a European spreadsheet is semicolons.
  static Workbook fromCsv(String text, {String sheetName = 'Sheet1'}) {
    final Workbook book = blank(sheetName: sheetName);
    final String firstLine = text.split('\n').first;
    String separator = ',';
    int best = 0;
    for (final String candidate in const [',', ';', '\t']) {
      final int count = candidate.allMatches(firstLine).length;
      if (count > best) {
        best = count;
        separator = candidate;
      }
    }
    int row = 0, col = 0;
    final StringBuffer field = StringBuffer();
    bool quoted = false;
    void endField() {
      final String value = field.toString();
      field.clear();
      if (value.isNotEmpty) book.setInput(0, row, col, value);
      col++;
    }

    for (int i = 0; i < text.length; i++) {
      final String ch = text[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          field.write(ch);
        }
      } else if (ch == '"' && field.isEmpty) {
        quoted = true;
      } else if (ch == separator) {
        endField();
      } else if (ch == '\n') {
        endField();
        row++;
        col = 0;
      } else if (ch != '\r') {
        field.write(ch);
      }
    }
    if (field.isNotEmpty) endField();
    book.edited = false;
    return book;
  }
}
