import 'formula.dart';

/// Shows a number the way a cell's format code says to.
///
/// Covers what spreadsheets are mostly made of: fixed decimals, thousands
/// separators, percentages, currency and other text around the number,
/// exponents, and dates and times. Fractions and conditional sections fall
/// back to the plain number rather than showing something wrong.
class NumberFormat {
  /// The format codes behind the built-in ids.
  static const Map<int, String> builtIn = {
    0: 'General',
    1: '0',
    2: '0.00',
    3: '#,##0',
    4: '#,##0.00',
    9: '0%',
    10: '0.00%',
    11: '0.00E+00',
    12: '# ?/?',
    13: '# ??/??',
    14: 'dd/mm/yyyy',
    15: 'd-mmm-yy',
    16: 'd-mmm',
    17: 'mmm-yy',
    18: 'h:mm AM/PM',
    19: 'h:mm:ss AM/PM',
    20: 'h:mm',
    21: 'h:mm:ss',
    22: 'dd/mm/yyyy h:mm',
    37: '#,##0;(#,##0)',
    38: '#,##0;(#,##0)',
    39: '#,##0.00;(#,##0.00)',
    40: '#,##0.00;(#,##0.00)',
    45: 'mm:ss',
    46: '[h]:mm:ss',
    47: 'mm:ss.0',
    48: '##0.0E+0',
    49: '@',
  };

  static const List<String> _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July', //
    'August', 'September', 'October', 'November', 'December',
  ];
  static const List<String> _days = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', //
    'Sunday',
  ];

  static final Map<String, _Compiled> _cache = {};

  /// Whether [code] shows its number as a date or a time.
  static bool isDate(String code) => _compile(code).isDate;

  /// [value] as [code] shows it. [date1904] is the workbook's date system.
  static String format(double value, String code, {bool date1904 = false}) {
    final _Compiled compiled = _compile(code);
    if (compiled.isGeneral) return formatGeneral(value);
    final List<List<_Part>> sections = compiled.sections;
    List<_Part> section = sections.first;
    double shown = value;
    if (value < 0 && sections.length > 1) {
      section = sections[1];
      shown = -value;
    } else if (value == 0 && sections.length > 2) {
      section = sections[2];
    }
    if (section.any((p) => p.kind == _K.date)) {
      return _formatDate(value, section, date1904);
    }
    if (!section.any((p) => p.kind == _K.digits)) {
      // Nothing but text, as in "Paid"; or a pattern not read here.
      if (compiled.unsupported) return formatGeneral(value);
      return section.map((p) => p.kind == _K.text ? p.text : '').join();
    }
    return _formatNumber(shown, section);
  }

  static _Compiled _compile(String code) =>
      _cache.putIfAbsent(code, () => _Compiled.parse(code));

  static String _formatNumber(double value, List<_Part> section) {
    final String digits = section
        .where((p) => p.kind == _K.digits)
        .map((p) => p.text)
        .join();
    final bool percent = section.any((p) => p.kind == _K.percent);
    double number = percent ? value * 100 : value;

    String body;
    final int exponentAt = digits.toUpperCase().indexOf('E');
    if (exponentAt >= 0) {
      final String mantissa = digits.substring(0, exponentAt);
      final int decimals = mantissa.contains('.')
          ? mantissa.split('.').last.replaceAll(RegExp('[^0#?]'), '').length
          : 0;
      final List<String> parts = number
          .toStringAsExponential(decimals)
          .split('e');
      final int exponent = int.parse(parts[1]);
      final int width = digits
          .substring(exponentAt)
          .replaceAll(RegExp('[^0]'), '')
          .length;
      body =
          '${parts[0]}E${exponent < 0 ? '-' : '+'}'
          '${exponent.abs().toString().padLeft(width, '0')}';
    } else {
      final List<String> halves = digits.split('.');
      final String whole = halves.first;
      final String fraction = halves.length > 1 ? halves[1] : '';
      // Commas after the last digit each divide by a thousand.
      final int scaling = RegExp(r',+$').firstMatch(whole)?.group(0)?.length ?? 0;
      for (int i = 0; i < scaling; i++) {
        number /= 1000;
      }
      final bool grouped = whole
          .replaceFirst(RegExp(r',+$'), '')
          .contains(',');
      final int minWhole = whole.replaceAll(RegExp('[^0]'), '').length;
      final int maxDecimals = fraction.replaceAll(RegExp('[^0#?]'), '').length;
      final int minDecimals = fraction.replaceAll(RegExp('[^0]'), '').length;

      final bool negative = number < 0;
      String fixed = number.abs().toStringAsFixed(maxDecimals);
      String wholeText = fixed;
      String fractionText = '';
      final int dot = fixed.indexOf('.');
      if (dot >= 0) {
        wholeText = fixed.substring(0, dot);
        fractionText = fixed.substring(dot + 1);
        while (fractionText.length > minDecimals && fractionText.endsWith('0')) {
          fractionText = fractionText.substring(0, fractionText.length - 1);
        }
      }
      if (minWhole == 0 && wholeText == '0' && fractionText.isNotEmpty) {
        wholeText = '';
      }
      wholeText = wholeText.padLeft(minWhole, '0');
      if (grouped) wholeText = _group(wholeText);
      fixed = fractionText.isEmpty ? wholeText : '$wholeText.$fractionText';
      // "-0.00" for something that rounded to nothing reads as a mistake.
      final bool nonZero = RegExp('[1-9]').hasMatch(fixed);
      body = negative && nonZero ? '-$fixed' : fixed;
    }

    final StringBuffer out = StringBuffer();
    bool placed = false;
    for (final _Part part in section) {
      switch (part.kind) {
        case _K.digits:
          if (!placed) out.write(body);
          placed = true;
        case _K.percent:
          out.write('%');
        case _K.text:
          out.write(part.text);
        case _K.date:
          break;
      }
    }
    return out.toString();
  }

  static String _group(String digits) {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  /// The moment a day number stands for, read as wall-clock time.
  static DateTime dateOf(double serial, {bool date1904 = false}) {
    // Day 0 is 30 December 1899, so that day 60 can be the 29 February
    // 1900 that never existed and every later date still lines up.
    final DateTime base = date1904
        ? DateTime.utc(1904, 1, 1)
        : DateTime.utc(1899, 12, 30);
    return base.add(Duration(milliseconds: (serial * 86400000).round()));
  }

  /// The day number of [date], taken as wall-clock time.
  static double serialOf(DateTime date, {bool date1904 = false}) {
    final DateTime base = date1904
        ? DateTime.utc(1904, 1, 1)
        : DateTime.utc(1899, 12, 30);
    final DateTime wall = DateTime.utc(
      date.year,
      date.month,
      date.day,
      date.hour,
      date.minute,
      date.second,
    );
    return wall.difference(base).inMilliseconds / 86400000;
  }

  static String _formatDate(double value, List<_Part> section, bool date1904) {
    final DateTime date = dateOf(value, date1904: date1904);
    final bool twelveHour = section.any(
      (p) => p.kind == _K.date && p.text.toUpperCase().contains('A'),
    );
    final StringBuffer out = StringBuffer();
    String two(int n) => n.toString().padLeft(2, '0');
    for (int i = 0; i < section.length; i++) {
      final _Part part = section[i];
      if (part.kind != _K.date) {
        if (part.kind == _K.text) out.write(part.text);
        continue;
      }
      final String token = part.text.toLowerCase();
      switch (token) {
        case 'yyyy' || 'yyy':
          out.write(date.year);
        case 'yy' || 'y':
          out.write(two(date.year % 100));
        case 'mmmmm':
          out.write(_months[date.month - 1][0]);
        case 'mmmm':
          out.write(_months[date.month - 1]);
        case 'mmm':
          out.write(_months[date.month - 1].substring(0, 3));
        case 'mm' || 'm':
          // Minutes when it follows hours or leads into seconds.
          final bool minutes = _isMinutes(section, i);
          final int n = minutes ? date.minute : date.month;
          out.write(token.length == 2 ? two(n) : n);
        case 'dddd':
          out.write(_days[date.weekday - 1]);
        case 'ddd':
          out.write(_days[date.weekday - 1].substring(0, 3));
        case 'dd':
          out.write(two(date.day));
        case 'd':
          out.write(date.day);
        case 'hh' || 'h':
          int hour = date.hour;
          if (twelveHour) hour = hour % 12 == 0 ? 12 : hour % 12;
          out.write(token.length == 2 ? two(hour) : hour);
        case '[h]' || '[hh]':
          out.write((value * 24).floor());
        case 'ss':
          out.write(two(date.second));
        case 's':
          out.write(date.second);
        case 'am/pm':
          out.write(date.hour < 12 ? 'AM' : 'PM');
        case 'a/p':
          out.write(date.hour < 12 ? 'A' : 'P');
        default:
          break;
      }
    }
    return out.toString();
  }

  static bool _isMinutes(List<_Part> section, int index) {
    for (int i = index - 1; i >= 0; i--) {
      if (section[i].kind != _K.date) continue;
      final String t = section[i].text.toLowerCase();
      if (t.startsWith('h') || t.startsWith('[h')) return true;
      break;
    }
    for (int i = index + 1; i < section.length; i++) {
      if (section[i].kind != _K.date) continue;
      return section[i].text.toLowerCase().startsWith('s');
    }
    return false;
  }
}

enum _K { digits, percent, text, date }

class _Part {
  final _K kind;
  final String text;
  const _Part(this.kind, this.text);
}

class _Compiled {
  final List<List<_Part>> sections;
  final bool isGeneral;
  final bool isDate;

  /// Holds something this does not lay out (a fraction, a condition).
  final bool unsupported;

  const _Compiled(
    this.sections, {
    this.isGeneral = false,
    this.isDate = false,
    this.unsupported = false,
  });

  static final RegExp _dateToken = RegExp(
    r'^(\[hh?\]|yyyy|yyy|yy|y|mmmmm|mmmm|mmm|mm|m|dddd|ddd|dd|d|hh|h|ss|s|AM/PM|A/P)',
    caseSensitive: false,
  );

  static _Compiled parse(String code) {
    if (code.trim().isEmpty || code.trim().toLowerCase() == 'general') {
      return const _Compiled([[]], isGeneral: true);
    }
    final List<List<_Part>> sections = [[]];
    bool unsupported = false;
    bool sawDate = false;
    bool sawDigits = false;
    int i = 0;
    void text(String s) {
      final List<_Part> section = sections.last;
      if (section.isNotEmpty && section.last.kind == _K.text) {
        section[section.length - 1] = _Part(_K.text, section.last.text + s);
      } else {
        section.add(_Part(_K.text, s));
      }
    }

    while (i < code.length) {
      final String ch = code[i];
      if (ch == ';') {
        sections.add([]);
        i++;
      } else if (ch == '"') {
        final int end = code.indexOf('"', i + 1);
        if (end < 0) {
          text(code.substring(i + 1));
          break;
        }
        text(code.substring(i + 1, end));
        i = end + 1;
      } else if (ch == r'\') {
        if (i + 1 < code.length) text(code[i + 1]);
        i += 2;
      } else if (ch == '_') {
        // Leaves the width of the next character; a space is close enough.
        text(' ');
        i += 2;
      } else if (ch == '*') {
        i += 2; // Fill character: nothing to fill here.
      } else if (ch == '[') {
        final int end = code.indexOf(']', i);
        if (end < 0) {
          i++;
          continue;
        }
        final String inner = code.substring(i + 1, end);
        final String lower = inner.toLowerCase();
        if (lower == 'h' || lower == 'hh') {
          sections.last.add(_Part(_K.date, '[$lower]'));
          sawDate = true;
        } else if (inner.startsWith(r'$')) {
          // [$€-407]: the currency sign, then a locale to ignore.
          final int dash = inner.indexOf('-');
          text(inner.substring(1, dash < 0 ? inner.length : dash));
        } else if (RegExp(r'^[<>=]').hasMatch(inner)) {
          unsupported = true;
        }
        // Colours ([Red]) and anything else in brackets show nothing.
        i = end + 1;
      } else if (ch == '@') {
        text('');
        i++;
      } else if ('0#?'.contains(ch) || (ch == '.' && sawDigits) ||
          (ch == '.' && i + 1 < code.length && '0#?'.contains(code[i + 1]))) {
        final StringBuffer run = StringBuffer();
        while (i < code.length) {
          final String c = code[i];
          if ('0#?.,'.contains(c)) {
            run.write(c);
            i++;
          } else if ((c == 'E' || c == 'e') &&
              i + 1 < code.length &&
              '+-'.contains(code[i + 1])) {
            run
              ..write('E')
              ..write(code[i + 1]);
            i += 2;
          } else {
            break;
          }
        }
        if (i < code.length && code[i] == '/') unsupported = true;
        sections.last.add(_Part(_K.digits, run.toString()));
        sawDigits = true;
      } else if (ch == '%') {
        sections.last.add(const _Part(_K.percent, '%'));
        i++;
      } else {
        final RegExpMatch? date = _dateToken.firstMatch(code.substring(i));
        if (date != null && !sawDigits) {
          sections.last.add(_Part(_K.date, date.group(0)!));
          sawDate = true;
          i += date.end;
        } else {
          text(ch);
          i++;
        }
      }
    }
    return _Compiled(sections, isDate: sawDate, unsupported: unsupported);
  }
}
