import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'formula.dart';
import 'number_format.dart';
import 'sheet_styles.dart';

/// A rectangle of cells, corners included. Rows and columns are 0-based.
class CellRange {
  final int top;
  final int left;
  final int bottom;
  final int right;

  const CellRange(this.top, this.left, this.bottom, this.right);

  bool contains(int row, int col) =>
      row >= top && row <= bottom && col >= left && col <= right;

  bool get isSingle => top == bottom && left == right;

  /// "B2:D5", or "B2" for one cell.
  String get name => isSingle
      ? cellName(top, left)
      : '${cellName(top, left)}:${cellName(bottom, right)}';

  static CellRange? parse(String text) {
    final List<String> ends = text.replaceAll(r'$', '').split(':');
    final (int, int)? a = parseCellName(ends.first);
    final (int, int)? b = ends.length > 1 ? parseCellName(ends[1]) : a;
    if (a == null || b == null) return null;
    return CellRange(
      math.min(a.$1, b.$1),
      math.min(a.$2, b.$2),
      math.max(a.$1, b.$1),
      math.max(a.$2, b.$2),
    );
  }

  /// This range after [count] rows (or columns) were inserted before
  /// [index], or removed from it when [count] is negative. Null when all of
  /// it was removed.
  CellRange? shifted(int index, int count, {required bool columns}) {
    int first = columns ? left : top;
    int last = columns ? right : bottom;
    if (count > 0) {
      if (first >= index) first += count;
      if (last >= index) last += count;
    } else {
      final int removed = -count;
      final int end = index + removed;
      if (first >= index && last < end) return null;
      if (first >= end) {
        first -= removed;
      } else if (first >= index) {
        first = index;
      }
      if (last >= end) {
        last -= removed;
      } else if (last >= index) {
        last = index - 1;
      }
      if (last < first) return null;
    }
    return columns
        ? CellRange(top, first, bottom, last)
        : CellRange(first, left, last, right);
  }

  @override
  bool operator ==(Object other) =>
      other is CellRange &&
      other.top == top &&
      other.left == left &&
      other.bottom == bottom &&
      other.right == right;

  @override
  int get hashCode => Object.hash(top, left, bottom, right);
}

/// One cell: what it holds, how it is styled, and where it came from.
class SheetCell {
  /// A `double`, `String`, `bool` or [SheetError]; null when blank. For a
  /// formula this is the result the file was saved with.
  Object? value;

  /// Without the leading `=`.
  String? formula;

  /// Index into the workbook's cell formats.
  int style;

  /// The element this cell was read from, for as long as it is untouched.
  /// Writing it back as it was keeps what the model does not hold: shared
  /// strings, rich text within a cell, array formulas.
  XmlElement? source;

  SheetCell({this.value, this.formula, this.style = 0, this.source});

  SheetCell copy() => SheetCell(value: value, formula: formula, style: style);

  bool get isBlank => value == null && formula == null;
}

/// Cells that take their value from a fixed list.
class ListValidation {
  List<CellRange> ranges;

  /// The choices, when the file spells them out.
  final List<String>? options;

  /// Otherwise the range they are read from, as written ("Lists!$A$1:$A$9").
  final String? source;

  ListValidation(this.ranges, {this.options, this.source});
}

/// Everything about one sheet that the editor shows or changes.
class Sheet {
  String name;

  /// Its part inside the package, e.g. `xl/worksheets/sheet1.xml`.
  final String path;

  /// The sheet as it was read, kept so that saving only rewrites the parts
  /// this model understands.
  final XmlDocument xml;

  /// Sparse: row, then column.
  final Map<int, Map<int, SheetCell>> rows = {};

  /// In characters of the default font, as the file stores them.
  final Map<int, double> colWidths = {};

  /// In points.
  final Map<int, double> rowHeights = {};
  double defaultColWidth = 8.43;
  double defaultRowHeight = 15;

  final List<CellRange> merges = [];
  int frozenRows = 0;
  int frozenCols = 0;
  final List<ListValidation> validations = [];

  /// Set when widths were changed, or columns moved, so `<cols>` is rebuilt.
  bool colsChanged = false;

  /// Set when rows or columns were inserted or deleted.
  bool structureChanged = false;

  Sheet({required this.name, required this.path, required this.xml});

  SheetCell? cell(int row, int col) => rows[row]?[col];

  SheetCell ensure(int row, int col) =>
      rows.putIfAbsent(row, () => {}).putIfAbsent(col, SheetCell.new);

  void put(int row, int col, SheetCell? cell) {
    if (cell == null || (cell.isBlank && cell.style == 0)) {
      final Map<int, SheetCell>? cells = rows[row];
      cells?.remove(col);
      if (cells != null && cells.isEmpty) rows.remove(row);
      return;
    }
    rows.putIfAbsent(row, () => {})[col] = cell;
  }

  /// One past the last row that holds anything.
  int get usedRows =>
      rows.isEmpty ? 0 : rows.keys.reduce(math.max) + 1;

  /// One past the last column that holds anything.
  int get usedCols {
    int last = -1;
    for (final Map<int, SheetCell> cells in rows.values) {
      for (final int col in cells.keys) {
        if (col > last) last = col;
      }
    }
    return last + 1;
  }

  /// The merged block [row], [col] belongs to, if any.
  CellRange? mergeAt(int row, int col) {
    for (final CellRange merge in merges) {
      if (merge.contains(row, col)) return merge;
    }
    return null;
  }

  ListValidation? validationAt(int row, int col) {
    for (final ListValidation validation in validations) {
      if (validation.ranges.any((r) => r.contains(row, col))) {
        return validation;
      }
    }
    return null;
  }

  /// A deep copy of everything an edit can change, for undo.
  SheetSnapshot snapshot() => SheetSnapshot._(this);

  void restore(SheetSnapshot snapshot) => snapshot._applyTo(this);

  /// Moves everything from [index] on by [count] rows or columns: positive
  /// makes room, negative removes. Formulas are the workbook's to fix.
  void shift(int index, int count, {required bool columns}) {
    if (count == 0) return;
    final int removedEnd = count < 0 ? index - count : index;
    int? move(int at) {
      if (at < index) return at;
      if (count < 0 && at < removedEnd) return null;
      return at + count;
    }

    if (columns) {
      for (final MapEntry<int, Map<int, SheetCell>> row in rows.entries) {
        final Map<int, SheetCell> moved = {};
        row.value.forEach((col, cell) {
          final int? to = move(col);
          if (to != null) moved[to] = cell;
        });
        row.value
          ..clear()
          ..addAll(moved);
      }
      rows.removeWhere((_, cells) => cells.isEmpty);
      _shiftSizes(colWidths, move);
      colsChanged = true;
      if (frozenCols > index) {
        frozenCols = math.max(index, frozenCols + count);
      }
    } else {
      final Map<int, Map<int, SheetCell>> moved = {};
      rows.forEach((row, cells) {
        final int? to = move(row);
        if (to != null) moved[to] = cells;
      });
      rows
        ..clear()
        ..addAll(moved);
      _shiftSizes(rowHeights, move);
      if (frozenRows > index) {
        frozenRows = math.max(index, frozenRows + count);
      }
    }

    final List<CellRange> kept = [
      for (final CellRange merge in merges)
        if (merge.shifted(index, count, columns: columns) case final CellRange m)
          // A merge squeezed down to one cell is no longer a merge.
          if (!m.isSingle) m,
    ];
    merges
      ..clear()
      ..addAll(kept);
    for (final ListValidation validation in validations) {
      validation.ranges = [
        for (final CellRange range in validation.ranges)
          if (range.shifted(index, count, columns: columns) case final CellRange r)
            r,
      ];
    }
    validations.removeWhere((v) => v.ranges.isEmpty);
    structureChanged = true;
  }

  static void _shiftSizes(Map<int, double> sizes, int? Function(int) move) {
    final Map<int, double> moved = {};
    sizes.forEach((at, size) {
      final int? to = move(at);
      if (to != null) moved[to] = size;
    });
    sizes
      ..clear()
      ..addAll(moved);
  }
}

/// A sheet as it was at one moment.
class SheetSnapshot {
  final Map<int, Map<int, SheetCell>> _rows;
  final Map<int, double> _colWidths;
  final Map<int, double> _rowHeights;
  final List<CellRange> _merges;
  final List<ListValidation> _validations;
  final int _frozenRows;
  final int _frozenCols;

  SheetSnapshot._(Sheet sheet)
    : _rows = {
        for (final MapEntry<int, Map<int, SheetCell>> row in sheet.rows.entries)
          row.key: {
            for (final MapEntry<int, SheetCell> cell in row.value.entries)
              // The source element goes with it: an undone edit really is
              // the cell as it was read.
              cell.key: cell.value.copy()..source = cell.value.source,
          },
      },
      _colWidths = {...sheet.colWidths},
      _rowHeights = {...sheet.rowHeights},
      _merges = [...sheet.merges],
      _validations = [
        for (final ListValidation v in sheet.validations)
          ListValidation([...v.ranges], options: v.options, source: v.source),
      ],
      _frozenRows = sheet.frozenRows,
      _frozenCols = sheet.frozenCols;

  void _applyTo(Sheet sheet) {
    sheet.rows
      ..clear()
      ..addAll({
        for (final MapEntry<int, Map<int, SheetCell>> row in _rows.entries)
          row.key: {
            for (final MapEntry<int, SheetCell> cell in row.value.entries)
              cell.key: cell.value.copy()..source = cell.value.source,
          },
      });
    sheet.colWidths
      ..clear()
      ..addAll(_colWidths);
    sheet.rowHeights
      ..clear()
      ..addAll(_rowHeights);
    sheet.merges
      ..clear()
      ..addAll(_merges);
    sheet.validations
      ..clear()
      ..addAll([
        for (final ListValidation v in _validations)
          ListValidation([...v.ranges], options: v.options, source: v.source),
      ]);
    sheet.frozenRows = _frozenRows;
    sheet.frozenCols = _frozenCols;
    sheet.colsChanged = true;
    sheet.structureChanged = true;
  }
}

/// A spreadsheet file: its sheets, its formats, and the package they came
/// in.
class Workbook {
  final List<Sheet> sheets;
  final StyleBook styles;

  /// The file as opened. Saving rewrites the sheets and styles inside it
  /// and carries everything else — charts, pictures, names — across as is.
  final Archive archive;

  /// Whether day 0 is 1 January 1904 rather than 30 December 1899.
  final bool date1904;

  /// True once anything was changed, which is when a result this engine
  /// could not recompute has to be left for the next spreadsheet to do.
  bool edited = false;

  final Map<int, Object?> _memo = {};
  final Set<int> _visiting = {};

  Workbook({
    required this.sheets,
    required this.styles,
    required this.archive,
    this.date1904 = false,
  });

  static int _key(int sheet, int row, int col) =>
      (sheet << 44) | (row << 20) | col;

  int sheetIndex(String name) {
    final String wanted = name.toLowerCase();
    return sheets.indexWhere((s) => s.name.toLowerCase() == wanted);
  }

  /// Forgets every worked-out result. Call after any change.
  void invalidate() => _memo.clear();

  /// What the cell holds once formulas are worked out.
  Object? valueAt(int sheet, int row, int col) {
    final SheetCell? cell = sheets[sheet].cell(row, col);
    if (cell == null) return null;
    final String? formula = cell.formula;
    if (formula == null) return cell.value;
    final int key = _key(sheet, row, col);
    if (_memo.containsKey(key)) return _memo[key];
    if (!_visiting.add(key)) return SheetError.cycle;
    Object? result;
    try {
      result = Formula.evaluate(formula, _Context(this, sheet));
    } on UnsupportedFormula {
      // Not one this engine reads: show what the file was saved with.
      result = cell.value;
    } catch (_) {
      result = SheetError.value;
    } finally {
      _visiting.remove(key);
    }
    _memo[key] = result;
    return result;
  }

  /// Whether the formula in a cell is one this engine recomputes, as
  /// opposed to showing the result the file came with.
  bool recomputes(SheetCell cell) {
    final String? formula = cell.formula;
    return formula != null && Formula.isSupported(formula);
  }

  /// The cell as the grid shows it.
  String display(int sheet, int row, int col) {
    final SheetCell? cell = sheets[sheet].cell(row, col);
    if (cell == null) return '';
    final Object? value = valueAt(sheet, row, col);
    if (value == null) return '';
    if (value is bool) return value ? 'TRUE' : 'FALSE';
    if (value is double) {
      return NumberFormat.format(
        value,
        styles.at(cell.style).numFmt,
        date1904: date1904,
      );
    }
    return value.toString();
  }

  /// The cell as the formula bar shows it: what would be typed to get it.
  String inputOf(int sheet, int row, int col) {
    final SheetCell? cell = sheets[sheet].cell(row, col);
    if (cell == null) return '';
    final String? formula = cell.formula;
    if (formula != null) return '=$formula';
    final Object? value = cell.value;
    if (value == null) return '';
    if (value is bool) return value ? 'TRUE' : 'FALSE';
    if (value is double) {
      final String code = styles.at(cell.style).numFmt;
      if (NumberFormat.isDate(code)) {
        return NumberFormat.format(value, code, date1904: date1904);
      }
      return formatGeneral(value);
    }
    return value.toString();
  }

  /// Puts what was typed into a cell, read the way a spreadsheet reads it:
  /// `=` starts a formula, a number is a number, the rest is text.
  void setInput(int sheet, int row, int col, String input) {
    final Sheet target = sheets[sheet];
    final SheetCell? existing = target.cell(row, col);
    final int style = existing?.style ?? 0;
    final String text = input;
    SheetCell? next;
    if (text.trim().isEmpty) {
      next = style == 0 ? null : SheetCell(style: style);
    } else if (text.startsWith('=') && text.length > 1) {
      next = SheetCell(formula: text.substring(1), style: style);
    } else if (text.startsWith("'")) {
      // A leading apostrophe says "this is text", as everywhere.
      next = SheetCell(value: text.substring(1), style: style);
    } else {
      next = SheetCell(value: _parseTyped(text.trim(), style), style: style);
    }
    target.put(row, col, next);
    edited = true;
    invalidate();
  }

  Object _parseTyped(String text, int style) {
    final String upper = text.toUpperCase();
    if (upper == 'TRUE') return true;
    if (upper == 'FALSE') return false;
    final double? number = double.tryParse(text.replaceAll(',', ''));
    if (number != null && RegExp(r'^[+-]?[\d,]*\.?\d*(e[+-]?\d+)?$', caseSensitive: false).hasMatch(text)) {
      return number;
    }
    if (text.endsWith('%')) {
      final double? percent = double.tryParse(
        text.substring(0, text.length - 1).trim(),
      );
      if (percent != null) return percent / 100;
    }
    // A date typed into a cell that shows dates goes back in as one.
    if (NumberFormat.isDate(styles.at(style).numFmt)) {
      final RegExpMatch? dmy = RegExp(
        r'^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})$',
      ).firstMatch(text);
      final RegExpMatch? ymd = RegExp(
        r'^(\d{4})-(\d{1,2})-(\d{1,2})$',
      ).firstMatch(text);
      DateTime? date;
      if (ymd != null) {
        date = DateTime.utc(
          int.parse(ymd.group(1)!),
          int.parse(ymd.group(2)!),
          int.parse(ymd.group(3)!),
        );
      } else if (dmy != null) {
        int year = int.parse(dmy.group(3)!);
        if (year < 100) year += year < 30 ? 2000 : 1900;
        date = DateTime.utc(
          year,
          int.parse(dmy.group(2)!),
          int.parse(dmy.group(1)!),
        );
      }
      if (date != null) {
        return NumberFormat.serialOf(date, date1904: date1904);
      }
    }
    return text;
  }

  /// Gives every cell in [range] the format [change] makes of its own.
  void applyStyle(int sheet, CellRange range, StyleChange change) {
    final Sheet target = sheets[sheet];
    for (int row = range.top; row <= range.bottom; row++) {
      for (int col = range.left; col <= range.right; col++) {
        final SheetCell cell = target.ensure(row, col);
        cell.style = styles.restyle(cell.style, change);
        // The element it was read from still carries the old format.
        cell.source = null;
      }
    }
    edited = true;
    invalidate();
  }

  /// Inserts ([count] > 0) or deletes ([count] < 0) rows or columns of
  /// [sheet] at [index], and rewrites every formula that pointed past them.
  void shift(int sheet, int index, int count, {required bool columns}) {
    final Sheet target = sheets[sheet];
    target.shift(index, count, columns: columns);
    for (final Sheet other in sheets) {
      for (final Map<int, SheetCell> cells in other.rows.values) {
        for (final SheetCell cell in cells.values) {
          final String? formula = cell.formula;
          if (formula == null) continue;
          final String moved = Formula.shift(
            formula,
            sheet: target.name,
            ownSheet: other.name,
            index: index,
            count: count,
            columns: columns,
          );
          if (moved != formula) {
            cell.formula = moved;
            cell.source = null;
          }
        }
      }
    }
    edited = true;
    invalidate();
  }

  /// The choices a list-validated cell offers.
  List<String> optionsFor(int sheet, ListValidation validation) {
    final List<String>? fixed = validation.options;
    if (fixed != null) return fixed;
    final String? source = validation.source;
    if (source == null) return const [];
    final List<RefToken> refs = Formula.references(source);
    if (refs.isEmpty) return const [];
    final RefToken ref = refs.first;
    final int from = ref.sheet == null ? sheet : sheetIndex(ref.sheet!);
    if (from < 0 || ref.wholeColumns || ref.wholeRows) return const [];
    final List<String> options = [];
    for (int row = math.min(ref.row1, ref.row2);
        row <= math.max(ref.row1, ref.row2);
        row++) {
      for (int col = math.min(ref.col1, ref.col2);
          col <= math.max(ref.col1, ref.col2);
          col++) {
        final String shown = display(from, row, col);
        if (shown.isNotEmpty) options.add(shown);
      }
    }
    return options;
  }
}

class _Context implements FormulaContext {
  final Workbook book;
  final int own;
  _Context(this.book, this.own);

  int _resolve(String? sheet) => sheet == null ? own : book.sheetIndex(sheet);

  @override
  Object? cellValue(String? sheet, int row, int col) {
    final int index = _resolve(sheet);
    if (index < 0) return SheetError.ref;
    return book.valueAt(index, row, col);
  }

  @override
  (int, int) extent(String? sheet) {
    final int index = _resolve(sheet);
    if (index < 0) return (0, 0);
    return (book.sheets[index].usedRows, book.sheets[index].usedCols);
  }
}
