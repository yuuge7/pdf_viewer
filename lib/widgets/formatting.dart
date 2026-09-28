import 'package:flutter/widgets.dart';

import '../services/pdf_service.dart';

/// Small display helpers shared by the sheets.

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const List<String> units = ['KB', 'MB', 'GB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

String formatDateTime(DateTime date) {
  String two(int n) => n.toString().padLeft(2, '0');
  final DateTime local = date.toLocal();
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "28 Sep 2026": unambiguous whatever order the reader's locale puts day
/// and month in.
String formatDate(DateTime date) =>
    '${date.day} ${_months[date.month - 1]} ${date.year}';

/// "A4 · 210 × 297 mm", or just the millimetres for a size with no name.
String describePageSize(Size points) {
  const double mmPerPoint = 25.4 / 72;
  final int w = (points.width * mmPerPoint).round();
  final int h = (points.height * mmPerPoint).round();
  for (final PaperSize paper in PaperSize.values) {
    final Size p = paper.portrait;
    bool near(double a, double b) => (a - b).abs() < 3;
    if ((near(points.width, p.width) && near(points.height, p.height)) ||
        (near(points.width, p.height) && near(points.height, p.width))) {
      return '${paper.label} · $w × $h mm';
    }
  }
  return '$w × $h mm';
}
