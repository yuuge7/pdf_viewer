import 'dart:math' as math;

/// An error a cell can hold, as a spreadsheet spells it.
class SheetError {
  final String code;
  const SheetError(this.code);

  static const SheetError div0 = SheetError('#DIV/0!');
  static const SheetError value = SheetError('#VALUE!');
  static const SheetError ref = SheetError('#REF!');
  static const SheetError name = SheetError('#NAME?');
  static const SheetError na = SheetError('#N/A');
  static const SheetError num = SheetError('#NUM!');

  /// Not a spreadsheet's own error: a formula that refers back to itself.
  static const SheetError cycle = SheetError('#CYCLE!');

  @override
  bool operator ==(Object other) => other is SheetError && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => code;
}

/// Thrown for a formula this engine cannot work out — a function it does
/// not know, syntax it does not read. The caller keeps whatever value the
/// file already had for the cell rather than showing a wrong one.
class UnsupportedFormula implements Exception {
  final String reason;
  const UnsupportedFormula(this.reason);
  @override
  String toString() => 'UnsupportedFormula: $reason';
}

/// A block of cells handed to a function.
class RangeValue {
  final List<List<Object?>> rows;
  const RangeValue(this.rows);

  Iterable<Object?> get cells => rows.expand((r) => r);
  int get height => rows.length;
  int get width => rows.isEmpty ? 0 : rows.first.length;
}

/// Where a formula reads its cells from.
abstract class FormulaContext {
  /// The value of a cell: a `double`, `String`, `bool`, [SheetError], or
  /// null when blank. [sheet] is null for the formula's own sheet.
  Object? cellValue(String? sheet, int row, int col);

  /// The last used row and column of [sheet], for `A:A` and `1:1`.
  (int rows, int cols) extent(String? sheet);
}

/// A reference as written in a formula: one cell, or a range.
class RefToken {
  final String? sheet;
  final int row1;
  final int col1;
  final bool rowAbs1;
  final bool colAbs1;

  /// Equal to the first corner for a single cell.
  final int row2;
  final int col2;
  final bool rowAbs2;
  final bool colAbs2;
  final bool isRange;

  /// -1 in [row1] and [row2] marks a whole-column range such as `A:C`;
  /// -1 in the columns a whole-row one.
  const RefToken({
    this.sheet,
    required this.row1,
    required this.col1,
    this.rowAbs1 = false,
    this.colAbs1 = false,
    required this.row2,
    required this.col2,
    this.rowAbs2 = false,
    this.colAbs2 = false,
    this.isRange = false,
  });

  bool get wholeColumns => row1 < 0;
  bool get wholeRows => col1 < 0;

  static String _corner(int row, int col, bool rowAbs, bool colAbs) {
    final StringBuffer out = StringBuffer();
    if (col >= 0) {
      if (colAbs) out.write(r'$');
      out.write(columnName(col));
    }
    if (row >= 0) {
      if (rowAbs) out.write(r'$');
      out.write(row + 1);
    }
    return out.toString();
  }

  /// As it is written in a formula.
  String get text {
    final StringBuffer out = StringBuffer();
    final String? name = sheet;
    if (name != null) {
      out.write(
        RegExp(r'^[A-Za-z_][A-Za-z0-9_.]*$').hasMatch(name)
            ? name
            : "'${name.replaceAll("'", "''")}'",
      );
      out.write('!');
    }
    out.write(_corner(row1, col1, rowAbs1, colAbs1));
    if (isRange) {
      out
        ..write(':')
        ..write(_corner(row2, col2, rowAbs2, colAbs2));
    }
    return out.toString();
  }

  RefToken copyWith({int? row1, int? col1, int? row2, int? col2}) => RefToken(
    sheet: sheet,
    row1: row1 ?? this.row1,
    col1: col1 ?? this.col1,
    rowAbs1: rowAbs1,
    colAbs1: colAbs1,
    row2: row2 ?? this.row2,
    col2: col2 ?? this.col2,
    rowAbs2: rowAbs2,
    colAbs2: colAbs2,
    isRange: isRange,
  );
}

/// "A", "Z", "AA" … for a 0-based column.
String columnName(int col) {
  final StringBuffer out = StringBuffer();
  int n = col + 1;
  final List<int> letters = [];
  while (n > 0) {
    final int rem = (n - 1) % 26;
    letters.add(65 + rem);
    n = (n - 1) ~/ 26;
  }
  for (final int code in letters.reversed) {
    out.writeCharCode(code);
  }
  return out.toString();
}

/// The 0-based column for "A", "AA" …, or -1 if [letters] is not one.
int columnIndex(String letters) {
  if (letters.isEmpty || letters.length > 3) return -1;
  int n = 0;
  for (final int unit in letters.toUpperCase().codeUnits) {
    if (unit < 65 || unit > 90) return -1;
    n = n * 26 + (unit - 64);
  }
  return n - 1;
}

/// "B12" for row 11, column 1.
String cellName(int row, int col) => '${columnName(col)}${row + 1}';

/// Row and column of "B12" (dollar signs allowed), or null.
(int row, int col)? parseCellName(String text) {
  final RegExpMatch? match = RegExp(
    r'^\$?([A-Za-z]{1,3})\$?(\d{1,7})$',
  ).firstMatch(text.trim());
  if (match == null) return null;
  final int col = columnIndex(match.group(1)!);
  final int row = int.parse(match.group(2)!) - 1;
  if (col < 0 || row < 0) return null;
  return (row, col);
}

enum _T { number, string, ref, name, op, open, close, comma, error }

class _Token {
  final _T type;
  final String text;
  final int start;
  final int end;
  final RefToken? ref;
  const _Token(this.type, this.text, this.start, this.end, [this.ref]);
}

sealed class _Node {
  const _Node();
}

class _Literal extends _Node {
  final Object? value;
  const _Literal(this.value);
}

class _Ref extends _Node {
  final RefToken ref;
  const _Ref(this.ref);
}

class _Unary extends _Node {
  final String op;
  final _Node operand;
  const _Unary(this.op, this.operand);
}

class _Binary extends _Node {
  final String op;
  final _Node left;
  final _Node right;
  const _Binary(this.op, this.left, this.right);
}

class _Call extends _Node {
  final String name;
  final List<_Node> args;
  const _Call(this.name, this.args);
}

/// Reads, evaluates and rewrites spreadsheet formulas.
///
/// Covers arithmetic, comparison, text joining, references across sheets
/// and the functions people actually type. Anything else raises
/// [UnsupportedFormula], which is a different thing from a formula that is
/// understood and evaluates to an error.
class Formula {
  static final RegExp _refPattern = RegExp(
    r"^(?:(?:'((?:[^']|'')+)'|([A-Za-z_][A-Za-z0-9_.]*))!)?"
    r'(?:'
    r'(\$?)([A-Za-z]{1,3})(\$?)(\d{1,7})(?::(\$?)([A-Za-z]{1,3})(\$?)(\d{1,7}))?'
    r'|(\$?)([A-Za-z]{1,3}):(\$?)([A-Za-z]{1,3})'
    r'|(\$?)(\d{1,7}):(\$?)(\d{1,7})'
    r')',
  );
  static final RegExp _numberPattern = RegExp(
    r'^(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?',
  );
  static final RegExp _namePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_.]*');
  static final RegExp _errorPattern = RegExp(
    r'^#(?:DIV/0!|VALUE!|REF!|NAME\?|N/A|NUM!|NULL!)',
  );

  static List<_Token> _tokenize(String source) {
    final List<_Token> tokens = [];
    int i = 0;
    while (i < source.length) {
      final String ch = source[i];
      if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t') {
        i++;
        continue;
      }
      final String rest = source.substring(i);
      if (ch == '"') {
        final StringBuffer text = StringBuffer();
        int j = i + 1;
        bool closed = false;
        while (j < source.length) {
          if (source[j] == '"') {
            if (j + 1 < source.length && source[j + 1] == '"') {
              text.write('"');
              j += 2;
              continue;
            }
            closed = true;
            j++;
            break;
          }
          text.write(source[j]);
          j++;
        }
        if (!closed) throw const UnsupportedFormula('unterminated string');
        tokens.add(_Token(_T.string, text.toString(), i, j));
        i = j;
        continue;
      }
      final RegExpMatch? error = _errorPattern.firstMatch(rest);
      if (error != null) {
        tokens.add(_Token(_T.error, error.group(0)!, i, i + error.end));
        i += error.end;
        continue;
      }
      final RegExpMatch? ref = _refPattern.firstMatch(rest);
      if (ref != null && _isRefBoundary(rest, ref.end)) {
        final RefToken? parsed = _refFrom(ref);
        if (parsed != null) {
          tokens.add(_Token(_T.ref, ref.group(0)!, i, i + ref.end, parsed));
          i += ref.end;
          continue;
        }
      }
      final RegExpMatch? number = _numberPattern.firstMatch(rest);
      if (number != null) {
        tokens.add(_Token(_T.number, number.group(0)!, i, i + number.end));
        i += number.end;
        continue;
      }
      final RegExpMatch? name = _namePattern.firstMatch(rest);
      if (name != null) {
        tokens.add(_Token(_T.name, name.group(0)!, i, i + name.end));
        i += name.end;
        continue;
      }
      if (ch == '(') {
        tokens.add(_Token(_T.open, ch, i, i + 1));
      } else if (ch == ')') {
        tokens.add(_Token(_T.close, ch, i, i + 1));
      } else if (ch == ',' || ch == ';') {
        tokens.add(_Token(_T.comma, ch, i, i + 1));
      } else if ('<>='.contains(ch)) {
        final String two = i + 1 < source.length ? source.substring(i, i + 2) : '';
        if (two == '<>' || two == '<=' || two == '>=') {
          tokens.add(_Token(_T.op, two, i, i + 2));
          i += 2;
          continue;
        }
        tokens.add(_Token(_T.op, ch, i, i + 1));
      } else if ('+-*/^&%'.contains(ch)) {
        tokens.add(_Token(_T.op, ch, i, i + 1));
      } else {
        throw UnsupportedFormula('unexpected "$ch"');
      }
      i++;
    }
    return tokens;
  }

  /// A reference must not run straight into more name: `A1B` and `SUM1(`
  /// are names, not the cell A1 followed by something.
  static bool _isRefBoundary(String rest, int end) {
    if (end >= rest.length) return true;
    final String next = rest[end];
    return !RegExp(r'[A-Za-z0-9_.(]').hasMatch(next);
  }

  static RefToken? _refFrom(RegExpMatch m) {
    final String? sheet = m.group(1)?.replaceAll("''", "'") ?? m.group(2);
    if (m.group(4) != null) {
      final int col1 = columnIndex(m.group(4)!);
      final int row1 = int.parse(m.group(6)!) - 1;
      if (col1 < 0 || row1 < 0) return null;
      if (m.group(8) == null) {
        return RefToken(
          sheet: sheet,
          row1: row1,
          col1: col1,
          rowAbs1: m.group(5) == r'$',
          colAbs1: m.group(3) == r'$',
          row2: row1,
          col2: col1,
          rowAbs2: m.group(5) == r'$',
          colAbs2: m.group(3) == r'$',
        );
      }
      final int col2 = columnIndex(m.group(8)!);
      final int row2 = int.parse(m.group(10)!) - 1;
      if (col2 < 0 || row2 < 0) return null;
      return RefToken(
        sheet: sheet,
        row1: row1,
        col1: col1,
        rowAbs1: m.group(5) == r'$',
        colAbs1: m.group(3) == r'$',
        row2: row2,
        col2: col2,
        rowAbs2: m.group(9) == r'$',
        colAbs2: m.group(7) == r'$',
        isRange: true,
      );
    }
    if (m.group(12) != null) {
      final int col1 = columnIndex(m.group(12)!);
      final int col2 = columnIndex(m.group(14)!);
      if (col1 < 0 || col2 < 0) return null;
      return RefToken(
        sheet: sheet,
        row1: -1,
        col1: col1,
        colAbs1: m.group(11) == r'$',
        row2: -1,
        col2: col2,
        colAbs2: m.group(13) == r'$',
        isRange: true,
      );
    }
    final int row1 = int.parse(m.group(16)!) - 1;
    final int row2 = int.parse(m.group(18)!) - 1;
    if (row1 < 0 || row2 < 0) return null;
    return RefToken(
      sheet: sheet,
      row1: row1,
      col1: -1,
      rowAbs1: m.group(15) == r'$',
      row2: row2,
      col2: -1,
      rowAbs2: m.group(17) == r'$',
      isRange: true,
    );
  }

  // --- Rewriting ------------------------------------------------------------

  /// [formula] with every reference passed through [rewrite], which returns
  /// the text to put in its place, or null to leave it as written.
  ///
  /// Everything between references is kept character for character. A
  /// formula that cannot be tokenised is returned untouched.
  static String rewriteRefs(
    String formula,
    String? Function(RefToken ref) rewrite,
  ) {
    final List<_Token> tokens;
    try {
      tokens = _tokenize(formula);
    } on UnsupportedFormula {
      return formula;
    }
    final StringBuffer out = StringBuffer();
    int at = 0;
    for (final _Token token in tokens) {
      if (token.type != _T.ref) continue;
      final String? replacement = rewrite(token.ref!);
      if (replacement == null) continue;
      out
        ..write(formula.substring(at, token.start))
        ..write(replacement);
      at = token.end;
    }
    out.write(formula.substring(at));
    return out.toString();
  }

  /// [formula] as it reads [rows] down and [cols] across from where it was
  /// written: relative references move, `$` ones stay.
  static String offset(String formula, int rows, int cols) {
    if (rows == 0 && cols == 0) return formula;
    return rewriteRefs(formula, (ref) {
      int move(int value, bool absolute, int by) =>
          value < 0 || absolute ? value : value + by;
      final int row1 = move(ref.row1, ref.rowAbs1, rows);
      final int col1 = move(ref.col1, ref.colAbs1, cols);
      final int row2 = move(ref.row2, ref.rowAbs2, rows);
      final int col2 = move(ref.col2, ref.colAbs2, cols);
      if ((ref.row1 >= 0 && (row1 < 0 || row2 < 0)) ||
          (ref.col1 >= 0 && (col1 < 0 || col2 < 0))) {
        return SheetError.ref.code;
      }
      return ref.copyWith(row1: row1, col1: col1, row2: row2, col2: col2).text;
    });
  }

  /// [formula] after [count] rows (or columns, with [columns]) were inserted
  /// before [index], or removed from it when [count] is negative.
  ///
  /// Only references into [sheet] move; [ownSheet] is the sheet the formula
  /// sits on, which is the one an unqualified reference means.
  static String shift(
    String formula, {
    required String sheet,
    required String ownSheet,
    required int index,
    required int count,
    required bool columns,
  }) {
    return rewriteRefs(formula, (ref) {
      if ((ref.sheet ?? ownSheet) != sheet) return null;
      final int a = columns ? ref.col1 : ref.row1;
      final int b = columns ? ref.col2 : ref.row2;
      if (a < 0) return null; // Whole rows when shifting columns, and so on.
      int first = a;
      int last = b;
      if (count > 0) {
        if (first >= index) first += count;
        if (last >= index) last += count;
      } else {
        final int removed = -count;
        final int end = index + removed; // First index that survives.
        int close(int value, {required bool isEnd}) {
          if (value < index) return value;
          if (value >= end) return value - removed;
          // Inside what was removed: a range closes up around the gap.
          return isEnd ? index - 1 : index;
        }

        if (!ref.isRange) {
          if (first >= index && first < end) return SheetError.ref.code;
          first = close(first, isEnd: false);
          last = first;
        } else {
          first = close(a, isEnd: false);
          last = close(b, isEnd: true);
          if (last < first) return SheetError.ref.code;
        }
      }
      if (first == a && last == b) return null;
      return (columns
              ? ref.copyWith(col1: first, col2: last)
              : ref.copyWith(row1: first, row2: last))
          .text;
    });
  }

  // --- Parsing --------------------------------------------------------------

  static _Node _parse(String source) {
    final _Parser parser = _Parser(_tokenize(source));
    final _Node node = parser.expression();
    if (!parser.done) throw const UnsupportedFormula('trailing input');
    return node;
  }

  /// Whether [formula] is one this engine can evaluate.
  static bool isSupported(String formula) {
    try {
      final _Node node = _parse(formula);
      return _knows(node);
    } on UnsupportedFormula {
      return false;
    }
  }

  static bool _knows(_Node node) => switch (node) {
    _Literal() || _Ref() => true,
    _Unary(:final operand) => _knows(operand),
    _Binary(:final left, :final right) => _knows(left) && _knows(right),
    _Call(:final name, :final args) =>
      _Functions.table.containsKey(name) && args.every(_knows),
  };

  /// Works [formula] (without its leading `=`) out against [context].
  ///
  /// Returns a `double`, `String`, `bool` or [SheetError]. Throws
  /// [UnsupportedFormula] for one it cannot read.
  static Object? evaluate(String formula, FormulaContext context) {
    final Object? result = _Evaluator(context).eval(_parse(formula));
    if (result is RangeValue) {
      // A bare range in a cell shows its first value.
      return result.rows.isEmpty || result.rows.first.isEmpty
          ? null
          : result.rows.first.first;
    }
    return result;
  }

  /// Every cell [formula] reads, for telling which formulas an edit touches.
  static List<RefToken> references(String formula) {
    try {
      return [
        for (final _Token token in _tokenize(formula))
          if (token.type == _T.ref) token.ref!,
      ];
    } on UnsupportedFormula {
      return const [];
    }
  }
}

class _Parser {
  final List<_Token> tokens;
  int _at = 0;
  _Parser(this.tokens);

  bool get done => _at >= tokens.length;
  _Token? get _peek => done ? null : tokens[_at];

  bool _isOp(String op) => _peek?.type == _T.op && _peek!.text == op;

  _Node expression() => _comparison();

  _Node _comparison() {
    _Node left = _concat();
    while (!done &&
        _peek!.type == _T.op &&
        const {'=', '<>', '<', '>', '<=', '>='}.contains(_peek!.text)) {
      final String op = tokens[_at++].text;
      left = _Binary(op, left, _concat());
    }
    return left;
  }

  _Node _concat() {
    _Node left = _additive();
    while (_isOp('&')) {
      _at++;
      left = _Binary('&', left, _additive());
    }
    return left;
  }

  _Node _additive() {
    _Node left = _multiplicative();
    while (_isOp('+') || _isOp('-')) {
      final String op = tokens[_at++].text;
      left = _Binary(op, left, _multiplicative());
    }
    return left;
  }

  _Node _multiplicative() {
    _Node left = _power();
    while (_isOp('*') || _isOp('/')) {
      final String op = tokens[_at++].text;
      left = _Binary(op, left, _power());
    }
    return left;
  }

  _Node _power() {
    _Node left = _unary();
    while (_isOp('^')) {
      _at++;
      left = _Binary('^', left, _unary());
    }
    return left;
  }

  // Negation binds tighter than ^ in a spreadsheet: -2^2 is 4.
  _Node _unary() {
    if (_isOp('-') || _isOp('+')) {
      final String op = tokens[_at++].text;
      return _Unary(op, _unary());
    }
    return _postfix();
  }

  _Node _postfix() {
    _Node node = _primary();
    while (_isOp('%')) {
      _at++;
      node = _Unary('%', node);
    }
    return node;
  }

  _Node _primary() {
    final _Token? token = _peek;
    if (token == null) throw const UnsupportedFormula('unexpected end');
    _at++;
    switch (token.type) {
      case _T.number:
        return _Literal(double.parse(token.text));
      case _T.string:
        return _Literal(token.text);
      case _T.error:
        return _Literal(SheetError(token.text));
      case _T.ref:
        return _Ref(token.ref!);
      case _T.open:
        final _Node inner = expression();
        _expect(_T.close);
        return inner;
      case _T.name:
        final String upper = token.text.toUpperCase();
        if (_peek?.type == _T.open) {
          _at++;
          final List<_Node> args = [];
          if (_peek?.type == _T.close) {
            _at++;
            return _Call(upper, args);
          }
          while (true) {
            // An empty argument, as in IF(A1,,"x"), is a blank.
            if (_peek?.type == _T.comma || _peek?.type == _T.close) {
              args.add(const _Literal(null));
            } else {
              args.add(expression());
            }
            if (_peek?.type == _T.comma) {
              _at++;
              continue;
            }
            _expect(_T.close);
            break;
          }
          return _Call(upper, args);
        }
        if (upper == 'TRUE') return const _Literal(true);
        if (upper == 'FALSE') return const _Literal(false);
        // A defined name, a table reference: not something read here.
        throw UnsupportedFormula('name "${token.text}"');
      case _T.op:
      case _T.close:
      case _T.comma:
        throw UnsupportedFormula('unexpected "${token.text}"');
    }
  }

  void _expect(_T type) {
    if (_peek?.type != type) throw const UnsupportedFormula('unbalanced');
    _at++;
  }
}

class _Evaluator {
  final FormulaContext context;
  _Evaluator(this.context);

  Object? eval(_Node node) {
    switch (node) {
      case _Literal(:final value):
        return value;
      case _Ref(:final ref):
        return _resolve(ref);
      case _Unary(:final op, :final operand):
        final Object? value = scalar(eval(operand));
        if (value is SheetError) return value;
        final Object n = number(value);
        if (n is SheetError) return n;
        final double x = n as double;
        return switch (op) {
          '-' => -x,
          '%' => x / 100,
          _ => x,
        };
      case _Binary(:final op, :final left, :final right):
        return _binary(op, scalar(eval(left)), scalar(eval(right)));
      case _Call(:final name, :final args):
        final _Function? function = _Functions.table[name];
        if (function == null) throw UnsupportedFormula('function $name');
        return function(this, args);
    }
  }

  Object? _resolve(RefToken ref) {
    int row1 = ref.row1, row2 = ref.row2, col1 = ref.col1, col2 = ref.col2;
    if (ref.wholeColumns || ref.wholeRows) {
      final (int rows, int cols) = context.extent(ref.sheet);
      if (ref.wholeColumns) {
        row1 = 0;
        row2 = math.max(0, rows - 1);
      }
      if (ref.wholeRows) {
        col1 = 0;
        col2 = math.max(0, cols - 1);
      }
    }
    if (!ref.isRange) return context.cellValue(ref.sheet, row1, col1);
    final int top = math.min(row1, row2), bottom = math.max(row1, row2);
    final int left = math.min(col1, col2), right = math.max(col1, col2);
    return RangeValue([
      for (int r = top; r <= bottom; r++)
        [for (int c = left; c <= right; c++) context.cellValue(ref.sheet, r, c)],
    ]);
  }

  /// One value where one is wanted: the first cell of a range.
  static Object? scalar(Object? value) {
    if (value is RangeValue) {
      return value.rows.isEmpty || value.rows.first.isEmpty
          ? null
          : value.rows.first.first;
    }
    return value;
  }

  /// A `double`, or the [SheetError] that stands in the way.
  static Object number(Object? value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is bool) return value ? 1.0 : 0.0;
    if (value is SheetError) return value;
    if (value is String) {
      final String trimmed = value.trim();
      if (trimmed.isEmpty) return 0.0;
      final double? parsed = double.tryParse(trimmed);
      if (parsed != null) return parsed;
      if (trimmed.endsWith('%')) {
        final double? percent = double.tryParse(
          trimmed.substring(0, trimmed.length - 1),
        );
        if (percent != null) return percent / 100;
      }
    }
    return SheetError.value;
  }

  static String text(Object? value) {
    if (value == null) return '';
    if (value is bool) return value ? 'TRUE' : 'FALSE';
    if (value is double) return formatGeneral(value);
    return value.toString();
  }

  static Object truth(Object? value) {
    if (value is SheetError) return value;
    if (value is bool) return value;
    if (value == null) return false;
    if (value is num) return value != 0;
    if (value is String) {
      final String upper = value.trim().toUpperCase();
      if (upper == 'TRUE') return true;
      if (upper == 'FALSE') return false;
    }
    return SheetError.value;
  }

  Object? _binary(String op, Object? a, Object? b) {
    if (a is SheetError) return a;
    if (b is SheetError) return b;
    if (op == '&') return text(a) + text(b);
    if (const {'=', '<>', '<', '>', '<=', '>='}.contains(op)) {
      final int order = compare(a, b);
      return switch (op) {
        '=' => order == 0,
        '<>' => order != 0,
        '<' => order < 0,
        '>' => order > 0,
        '<=' => order <= 0,
        _ => order >= 0,
      };
    }
    final Object x = number(a);
    if (x is SheetError) return x;
    final Object y = number(b);
    if (y is SheetError) return y;
    final double l = x as double, r = y as double;
    switch (op) {
      case '+':
        return l + r;
      case '-':
        return l - r;
      case '*':
        return l * r;
      case '/':
        return r == 0 ? SheetError.div0 : l / r;
      case '^':
        final double result = math.pow(l, r).toDouble();
        return result.isNaN || result.isInfinite ? SheetError.num : result;
    }
    throw UnsupportedFormula('operator $op');
  }

  /// Orders two values as a spreadsheet does: numbers before text before
  /// booleans, text without regard to case, a blank as zero or as "".
  static int compare(Object? a, Object? b) {
    int rank(Object? v) => v is bool
        ? 2
        : v is String
        ? 1
        : 0;
    if (a == null && b is String) a = '';
    if (b == null && a is String) b = '';
    if (a == null && b is bool) a = false;
    if (b == null && a is bool) b = false;
    final int ra = rank(a), rb = rank(b);
    if (ra != rb) return ra.compareTo(rb);
    if (a is String && b is String) {
      return a.toLowerCase().compareTo(b.toLowerCase());
    }
    if (a is bool && b is bool) return (a ? 1 : 0).compareTo(b ? 1 : 0);
    final double x = a == null ? 0 : (a as num).toDouble();
    final double y = b == null ? 0 : (b as num).toDouble();
    return x.compareTo(y);
  }
}

/// A number as a cell with no format shows it: no trailing zeros, at most
/// eleven significant digits, and an exponent only when it would not fit.
String formatGeneral(double value) {
  if (value.isNaN || value.isInfinite) return SheetError.num.code;
  if (value == value.roundToDouble() && value.abs() < 1e11) {
    return value.toInt().toString();
  }
  final double magnitude = value.abs();
  if (magnitude >= 1e11 || magnitude < 1e-9) {
    String text = value.toStringAsExponential(5);
    // 1.50000e+21 reads as 1.5E+21.
    text = text.replaceFirstMapped(
      RegExp(r'\.?0*e([+-])(\d+)$'),
      (m) => 'E${m.group(1)}${m.group(2)!.padLeft(2, '0')}',
    );
    return text;
  }
  String text = value.toStringAsPrecision(10);
  if (text.contains('e')) text = value.toString();
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  }
  return text;
}

typedef _Function = Object? Function(_Evaluator e, List<_Node> args);

class _Functions {
  /// Every number in [values], ranges opened up. Text and blanks inside a
  /// range are skipped; a text argument given directly must be a number.
  static Object _numbers(_Evaluator e, List<_Node> args) {
    final List<double> out = [];
    for (final _Node arg in args) {
      final Object? value = e.eval(arg);
      if (value is RangeValue) {
        for (final Object? cell in value.cells) {
          if (cell is SheetError) return cell;
          if (cell is num) out.add(cell.toDouble());
        }
      } else {
        if (value == null) continue;
        final Object n = _Evaluator.number(value);
        if (n is SheetError) return n;
        out.add(n as double);
      }
    }
    return out;
  }

  static Object? _one(_Evaluator e, List<_Node> args, int index) =>
      index < args.length ? _Evaluator.scalar(e.eval(args[index])) : null;

  static Object _num(_Evaluator e, List<_Node> args, int index, [double? or]) {
    if (index >= args.length) return or ?? SheetError.value;
    final Object? value = _one(e, args, index);
    if (value == null && or != null) return or;
    return _Evaluator.number(value);
  }

  /// Applies [f] to the first argument as a number.
  static _Function _math(Object Function(double x) f) => (e, args) {
    final Object x = _num(e, args, 0);
    return x is SheetError ? x : f(x as double);
  };

  static _Function _aggregate(Object Function(List<double> values) f) =>
      (e, args) {
        final Object values = _numbers(e, args);
        return values is SheetError ? values : f(values as List<double>);
      };

  static _Function _textFn(Object Function(String s) f) => (e, args) {
    final Object? value = _one(e, args, 0);
    return value is SheetError ? value : f(_Evaluator.text(value));
  };

  /// A test such as `">5"`, `"<>x"`, `"apple"` or `12`, as SUMIF takes it.
  static bool Function(Object? cell) _criterion(Object? criterion) {
    if (criterion is String) {
      final RegExpMatch? match = RegExp(
        r'^(<=|>=|<>|<|>|=)(.*)$',
      ).firstMatch(criterion);
      final String op = match?.group(1) ?? '=';
      final String operand = match?.group(2) ?? criterion;
      final double? n = double.tryParse(operand.trim());
      final Object target = n ?? operand;
      if (n == null && (op == '=' || op == '<>') && operand.contains('*')) {
        final RegExp wild = RegExp(
          '^${operand.split('*').map(RegExp.escape).join('.*')}\$',
          caseSensitive: false,
        );
        return (cell) =>
            wild.hasMatch(_Evaluator.text(cell)) == (op == '=');
      }
      return (cell) {
        if (cell is SheetError) return false;
        // A number test passes over text, and the other way round.
        if (n != null && cell is! num) return op == '<>';
        if (n == null && cell is num) return op == '<>';
        final int order = _Evaluator.compare(cell, target);
        return switch (op) {
          '=' => order == 0,
          '<>' => order != 0,
          '<' => order < 0,
          '>' => order > 0,
          '<=' => order <= 0,
          _ => order >= 0,
        };
      };
    }
    return (cell) =>
        cell is! SheetError &&
        cell != null &&
        _Evaluator.compare(cell, criterion) == 0;
  }

  static const int _epoch = 25569; // 1970-01-01 as a day number.

  static double _serial(DateTime date) =>
      date.millisecondsSinceEpoch / 86400000 +
      _epoch +
      date.timeZoneOffset.inMilliseconds / 86400000;

  static DateTime _date(double serial) => DateTime.fromMillisecondsSinceEpoch(
    ((serial - _epoch) * 86400000).round(),
    isUtc: true,
  );

  static final Map<String, _Function> table = {
    'SUM': _aggregate((v) => v.fold<double>(0, (a, b) => a + b)),
    'PRODUCT': _aggregate((v) => v.fold<double>(1, (a, b) => a * b)),
    'AVERAGE': _aggregate(
      (v) => v.isEmpty
          ? SheetError.div0
          : v.fold<double>(0, (a, b) => a + b) / v.length,
    ),
    'MIN': _aggregate((v) => v.isEmpty ? 0.0 : v.reduce(math.min)),
    'MAX': _aggregate((v) => v.isEmpty ? 0.0 : v.reduce(math.max)),
    'COUNT': _aggregate((v) => v.length.toDouble()),
    'MEDIAN': _aggregate((v) {
      if (v.isEmpty) return SheetError.num;
      final List<double> sorted = [...v]..sort();
      final int mid = sorted.length ~/ 2;
      return sorted.length.isOdd
          ? sorted[mid]
          : (sorted[mid - 1] + sorted[mid]) / 2;
    }),
    'COUNTA': (e, args) {
      int count = 0;
      for (final _Node arg in args) {
        final Object? value = e.eval(arg);
        if (value is RangeValue) {
          count += value.cells.where((c) => c != null && c != '').length;
        } else if (value != null) {
          count++;
        }
      }
      return count.toDouble();
    },
    'COUNTBLANK': (e, args) {
      final Object? value = args.isEmpty ? null : e.eval(args[0]);
      if (value is! RangeValue) return value == null ? 1.0 : 0.0;
      return value.cells
          .where((c) => c == null || c == '')
          .length
          .toDouble();
    },
    'IF': (e, args) {
      if (args.length < 2) return SheetError.value;
      final Object test = _Evaluator.truth(_one(e, args, 0));
      if (test is SheetError) return test;
      if (test == true) return _one(e, args, 1);
      return args.length > 2 ? _one(e, args, 2) : false;
    },
    'IFERROR': (e, args) {
      if (args.length < 2) return SheetError.value;
      final Object? value = _one(e, args, 0);
      return value is SheetError ? _one(e, args, 1) : value;
    },
    'AND': (e, args) {
      bool all = true;
      for (final _Node arg in args) {
        final Object? value = e.eval(arg);
        for (final Object? cell
            in value is RangeValue ? value.cells : [value]) {
          if (cell == null || cell is String) continue;
          final Object t = _Evaluator.truth(cell);
          if (t is SheetError) return t;
          all = all && t == true;
        }
      }
      return all;
    },
    'OR': (e, args) {
      bool any = false;
      for (final _Node arg in args) {
        final Object? value = e.eval(arg);
        for (final Object? cell
            in value is RangeValue ? value.cells : [value]) {
          if (cell == null || cell is String) continue;
          final Object t = _Evaluator.truth(cell);
          if (t is SheetError) return t;
          any = any || t == true;
        }
      }
      return any;
    },
    'NOT': (e, args) {
      final Object t = _Evaluator.truth(_one(e, args, 0));
      return t is SheetError ? t : t != true;
    },
    'TRUE': (e, args) => true,
    'FALSE': (e, args) => false,
    'ABS': _math((x) => x.abs()),
    'INT': _math((x) => x.floorToDouble()),
    'SQRT': _math((x) => x < 0 ? SheetError.num : math.sqrt(x)),
    'EXP': _math((x) => math.exp(x)),
    'LN': _math((x) => x <= 0 ? SheetError.num : math.log(x)),
    'LOG10': _math((x) => x <= 0 ? SheetError.num : math.log(x) / math.ln10),
    'SIGN': _math((x) => x.sign),
    'PI': (e, args) => math.pi,
    'POWER': (e, args) {
      final Object x = _num(e, args, 0), y = _num(e, args, 1);
      if (x is SheetError) return x;
      if (y is SheetError) return y;
      final double r = math.pow(x as double, y as double).toDouble();
      return r.isNaN || r.isInfinite ? SheetError.num : r;
    },
    'MOD': (e, args) {
      final Object x = _num(e, args, 0), y = _num(e, args, 1);
      if (x is SheetError) return x;
      if (y is SheetError) return y;
      final double d = y as double;
      if (d == 0) return SheetError.div0;
      final double n = x as double;
      // Takes the sign of the divisor.
      return n - d * (n / d).floorToDouble();
    },
    'ROUND': (e, args) => _round(e, args, 0),
    'ROUNDUP': (e, args) => _round(e, args, 1),
    'ROUNDDOWN': (e, args) => _round(e, args, -1),
    'LEN': _textFn((s) => s.length.toDouble()),
    'UPPER': _textFn((s) => s.toUpperCase()),
    'LOWER': _textFn((s) => s.toLowerCase()),
    'TRIM': _textFn((s) => s.trim().replaceAll(RegExp(' +'), ' ')),
    'VALUE': (e, args) => _Evaluator.number(_one(e, args, 0)),
    'LEFT': (e, args) {
      final Object? s = _one(e, args, 0);
      final Object n = _num(e, args, 1, 1);
      if (s is SheetError) return s;
      if (n is SheetError) return n;
      final String text = _Evaluator.text(s);
      return text.substring(0, (n as double).toInt().clamp(0, text.length));
    },
    'RIGHT': (e, args) {
      final Object? s = _one(e, args, 0);
      final Object n = _num(e, args, 1, 1);
      if (s is SheetError) return s;
      if (n is SheetError) return n;
      final String text = _Evaluator.text(s);
      return text.substring(
        text.length - (n as double).toInt().clamp(0, text.length),
      );
    },
    'MID': (e, args) {
      final Object? s = _one(e, args, 0);
      final Object start = _num(e, args, 1), count = _num(e, args, 2);
      if (s is SheetError) return s;
      if (start is SheetError) return start;
      if (count is SheetError) return count;
      final String text = _Evaluator.text(s);
      final int from = (start as double).toInt() - 1;
      if (from < 0 || (count as double) < 0) return SheetError.value;
      if (from >= text.length) return '';
      return text.substring(
        from,
        math.min(text.length, from + count.toInt()),
      );
    },
    'CONCATENATE': _join,
    'CONCAT': _join,
    'ISBLANK': (e, args) => _one(e, args, 0) == null,
    'ISNUMBER': (e, args) => _one(e, args, 0) is num,
    'ISTEXT': (e, args) => _one(e, args, 0) is String,
    'ISERROR': (e, args) => _one(e, args, 0) is SheetError,
    'TODAY': (e, args) => _serial(DateTime.now()).floorToDouble(),
    'NOW': (e, args) => _serial(DateTime.now()),
    'DATE': (e, args) {
      final Object y = _num(e, args, 0), m = _num(e, args, 1);
      final Object d = _num(e, args, 2);
      if (y is SheetError) return y;
      if (m is SheetError) return m;
      if (d is SheetError) return d;
      final DateTime date = DateTime.utc(
        (y as double).toInt(),
        (m as double).toInt(),
        (d as double).toInt(),
      );
      return (date.millisecondsSinceEpoch / 86400000 + _epoch)
          .roundToDouble();
    },
    'YEAR': _math((x) => _date(x).year.toDouble()),
    'MONTH': _math((x) => _date(x).month.toDouble()),
    'DAY': _math((x) => _date(x).day.toDouble()),
    'SUMIF': (e, args) => _conditional(e, args, sum: true),
    'COUNTIF': (e, args) => _conditional(e, args, sum: false),
    'AVERAGEIF': (e, args) => _conditional(e, args, sum: true, average: true),
    'VLOOKUP': (e, args) {
      if (args.length < 3) return SheetError.value;
      final Object? key = _one(e, args, 0);
      final Object? table = e.eval(args[1]);
      final Object column = _num(e, args, 2);
      if (key is SheetError) return key;
      if (table is! RangeValue) return SheetError.value;
      if (column is SheetError) return column;
      final int index = (column as double).toInt() - 1;
      if (index < 0 || index >= table.width) return SheetError.ref;
      bool approximate = true;
      if (args.length > 3) {
        final Object t = _Evaluator.truth(_one(e, args, 3));
        if (t is SheetError) return t;
        approximate = t == true;
      }
      List<Object?>? best;
      for (final List<Object?> row in table.rows) {
        final Object? first = row.first;
        if (first == null || first is SheetError) continue;
        final int order = _Evaluator.compare(first, key);
        if (order == 0) return row[index];
        if (approximate && order < 0) best = row;
        if (approximate && order > 0) break;
      }
      return best == null ? SheetError.na : best[index];
    },
  };

  static Object? _join(_Evaluator e, List<_Node> args) {
    final StringBuffer out = StringBuffer();
    for (final _Node arg in args) {
      final Object? value = e.eval(arg);
      for (final Object? cell in value is RangeValue ? value.cells : [value]) {
        if (cell is SheetError) return cell;
        out.write(_Evaluator.text(cell));
      }
    }
    return out.toString();
  }

  /// [mode] 0 rounds half away from zero, 1 away from zero, -1 toward it.
  static Object _round(_Evaluator e, List<_Node> args, int mode) {
    final Object x = _num(e, args, 0), digits = _num(e, args, 1, 0);
    if (x is SheetError) return x;
    if (digits is SheetError) return digits;
    final double scale = math.pow(10, (digits as double).toInt()).toDouble();
    final double scaled = (x as double) * scale;
    // A hair of slack, so 2.675 held as 2.67499999 still rounds as written.
    final double slack = scaled.abs() * 1e-12;
    final double magnitude = switch (mode) {
      1 => (scaled.abs() - slack).ceilToDouble(),
      -1 => (scaled.abs() + slack).floorToDouble(),
      _ => (scaled.abs() + 0.5 + slack).floorToDouble(),
    };
    return magnitude * scaled.sign / scale;
  }

  static Object? _conditional(
    _Evaluator e,
    List<_Node> args, {
    required bool sum,
    bool average = false,
  }) {
    if (args.length < 2) return SheetError.value;
    final Object? range = e.eval(args[0]);
    final Object? criterion = _one(e, args, 1);
    if (criterion is SheetError) return criterion;
    final List<Object?> tested = range is RangeValue
        ? range.cells.toList()
        : [range];
    List<Object?> summed = tested;
    if (sum && args.length > 2) {
      final Object? other = e.eval(args[2]);
      summed = other is RangeValue ? other.cells.toList() : [other];
    }
    final bool Function(Object?) passes = _criterion(criterion);
    double total = 0;
    int count = 0;
    for (int i = 0; i < tested.length; i++) {
      if (!passes(tested[i])) continue;
      if (!sum) {
        count++;
        continue;
      }
      final Object? value = i < summed.length ? summed[i] : null;
      if (value is SheetError) return value;
      if (value is num) {
        total += value;
        count++;
      }
    }
    if (!sum) return count.toDouble();
    if (average) return count == 0 ? SheetError.div0 : total / count;
    return total;
  }
}
