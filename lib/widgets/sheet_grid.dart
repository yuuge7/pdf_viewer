import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import '../services/sheet/formula.dart';
import '../services/sheet/sheet_styles.dart';
import '../services/sheet/workbook.dart';

/// Where every row and column of a sheet sits, in pixels at 100% zoom.
class SheetMetrics {
  /// `colLeft[c]` is the left edge of column `c`; one more entry than
  /// there are columns, so the last is the total width.
  final List<double> colLeft;
  final List<double> rowTop;
  final int frozenRows;
  final int frozenCols;

  SheetMetrics._(this.colLeft, this.rowTop, this.frozenRows, this.frozenCols);

  static const double headerWidth = 44;
  static const double headerHeight = 26;

  /// Rows and columns shown past the last one in use, so there is always
  /// somewhere to type next.
  static const int _spareRows = 40;
  static const int _spareCols = 8;

  factory SheetMetrics.of(Sheet sheet) {
    final int cols = math.max(26, sheet.usedCols + _spareCols);
    final int rows = math.max(60, sheet.usedRows + _spareRows);
    final List<double> colLeft = List<double>.filled(cols + 1, 0);
    for (int c = 0; c < cols; c++) {
      colLeft[c + 1] = colLeft[c] + widthOf(sheet, c);
    }
    final List<double> rowTop = List<double>.filled(rows + 1, 0);
    for (int r = 0; r < rows; r++) {
      rowTop[r + 1] = rowTop[r] + heightOf(sheet, r);
    }
    return SheetMetrics._(
      colLeft,
      rowTop,
      math.min(sheet.frozenRows, rows - 1),
      math.min(sheet.frozenCols, cols - 1),
    );
  }

  /// A width in characters is seven pixels each, plus five of padding.
  static double widthOf(Sheet sheet, int col) {
    final double chars = sheet.colWidths[col] ?? sheet.defaultColWidth;
    return chars <= 0 ? 0 : (chars * 7 + 5).roundToDouble();
  }

  /// A height in points, at 96 pixels to the inch.
  static double heightOf(Sheet sheet, int row) {
    final double points = sheet.rowHeights[row] ?? sheet.defaultRowHeight;
    return points <= 0 ? 0 : (points * 96 / 72).roundToDouble();
  }

  int get cols => colLeft.length - 1;
  int get rows => rowTop.length - 1;
  double get width => colLeft.last;
  double get height => rowTop.last;
  double get frozenWidth => colLeft[frozenCols];
  double get frozenHeight => rowTop[frozenRows];

  static int _find(List<double> edges, double at) {
    int lo = 0, hi = edges.length - 2;
    while (lo < hi) {
      final int mid = (lo + hi + 1) >> 1;
      if (edges[mid] <= at) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  int colAt(double x) => _find(colLeft, x);
  int rowAt(double y) => _find(rowTop, y);

  Rect cellRect(int row, int col) => Rect.fromLTRB(
    colLeft[col.clamp(0, cols)],
    rowTop[row.clamp(0, rows)],
    colLeft[(col + 1).clamp(0, cols)],
    rowTop[(row + 1).clamp(0, rows)],
  );

  Rect rangeRect(CellRange range) => Rect.fromLTRB(
    colLeft[range.left.clamp(0, cols)],
    rowTop[range.top.clamp(0, rows)],
    colLeft[(range.right + 1).clamp(0, cols)],
    rowTop[(range.bottom + 1).clamp(0, rows)],
  );
}

/// A sheet drawn as a grid: scrolls both ways with headers and frozen panes
/// held in place, pinches to zoom, taps to select and long-presses to
/// select a block.
///
/// Painted rather than built from widgets, because a sheet is thousands of
/// cells and only the ones on screen are worth touching.
class SheetGrid extends StatefulWidget {
  final Workbook book;
  final int sheetIndex;

  /// The selected block; the cell being edited is its [anchorRow] and
  /// [anchorCol].
  final CellRange selection;
  final int anchorRow;
  final int anchorCol;

  /// Bumped whenever the workbook changes, which is what repaints.
  final int revision;
  final void Function(CellRange range, int anchorRow, int anchorCol) onSelect;

  /// The selected cell was tapped again, or double-tapped.
  final VoidCallback onEdit;

  const SheetGrid({
    super.key,
    required this.book,
    required this.sheetIndex,
    required this.selection,
    required this.anchorRow,
    required this.anchorCol,
    required this.revision,
    required this.onSelect,
    required this.onEdit,
  });

  @override
  State<SheetGrid> createState() => SheetGridState();
}

class SheetGridState extends State<SheetGrid>
    with SingleTickerProviderStateMixin {
  Offset _scroll = Offset.zero;
  double _zoom = 1;
  double _zoomAtStart = 1;
  Size _viewport = Size.zero;

  SheetMetrics? _metrics;
  int _metricsFor = -1;

  late final Ticker _ticker;
  FrictionSimulation? _flingX;
  FrictionSimulation? _flingY;

  /// Where a long-press selection started.
  (int, int)? _dragFrom;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(SheetGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sheetIndex != widget.sheetIndex ||
        oldWidget.book != widget.book) {
      _ticker.stop();
      _scroll = Offset.zero;
    }
  }

  Sheet get _sheet => widget.book.sheets[widget.sheetIndex];

  SheetMetrics get metrics {
    final int key = Object.hash(widget.sheetIndex, widget.revision, widget.book);
    if (_metrics == null || _metricsFor != key) {
      _metrics = SheetMetrics.of(_sheet);
      _metricsFor = key;
    }
    return _metrics!;
  }

  Offset _clamp(Offset scroll) {
    final SheetMetrics m = metrics;
    final double roomX =
        _viewport.width - (SheetMetrics.headerWidth + m.frozenWidth) * _zoom;
    final double roomY =
        _viewport.height - (SheetMetrics.headerHeight + m.frozenHeight) * _zoom;
    final double maxX = (m.width - m.frozenWidth) * _zoom - roomX;
    final double maxY = (m.height - m.frozenHeight) * _zoom - roomY;
    return Offset(
      scroll.dx.clamp(0.0, math.max(0.0, maxX)),
      scroll.dy.clamp(0.0, math.max(0.0, maxY)),
    );
  }

  void _onTick(Duration elapsed) {
    final double t = elapsed.inMicroseconds / 1e6;
    final FrictionSimulation? fx = _flingX, fy = _flingY;
    if (fx == null || fy == null || (fx.isDone(t) && fy.isDone(t))) {
      _ticker.stop();
      return;
    }
    setState(() => _scroll = _clamp(Offset(fx.x(t), fy.x(t))));
  }

  /// The cell under a point of the widget, or null over the corner.
  /// A row of -1 means a column header was hit, and the other way round.
  (int, int)? _cellAt(Offset local) {
    final SheetMetrics m = metrics;
    final double hx = SheetMetrics.headerWidth * _zoom;
    final double hy = SheetMetrics.headerHeight * _zoom;
    if (local.dx < hx && local.dy < hy) return null;
    final double fx = m.frozenWidth * _zoom, fy = m.frozenHeight * _zoom;
    int col = -1, row = -1;
    if (local.dx >= hx) {
      final double x = local.dx - hx;
      col = x < fx
          ? m.colAt(x / _zoom)
          : m.colAt((x + _scroll.dx) / _zoom);
    }
    if (local.dy >= hy) {
      final double y = local.dy - hy;
      row = y < fy
          ? m.rowAt(y / _zoom)
          : m.rowAt((y + _scroll.dy) / _zoom);
    }
    return (row, col);
  }

  void _select(Offset local) {
    final (int, int)? hit = _cellAt(local);
    if (hit == null) return;
    final (int row, int col) = hit;
    final SheetMetrics m = metrics;
    if (row < 0) {
      // A column header: the whole column, as far as the sheet goes.
      final int last = math.max(0, _sheet.usedRows - 1);
      widget.onSelect(CellRange(0, col, last, col), 0, col);
      return;
    }
    if (col < 0) {
      final int last = math.max(0, _sheet.usedCols - 1);
      widget.onSelect(CellRange(row, 0, row, last), row, 0);
      return;
    }
    // A tap anywhere in a merged block is a tap on the block.
    final CellRange merge =
        _sheet.mergeAt(row, col) ?? CellRange(row, col, row, col);
    if (widget.selection.isSingle &&
        widget.anchorRow == merge.top &&
        widget.anchorCol == merge.left) {
      widget.onEdit();
      return;
    }
    widget.onSelect(
      CellRange(
        merge.top,
        merge.left,
        math.min(merge.bottom, m.rows - 1),
        math.min(merge.right, m.cols - 1),
      ),
      merge.top,
      merge.left,
    );
  }

  /// Scrolls just far enough to bring a cell fully into view.
  void ensureVisible(int row, int col) {
    final SheetMetrics m = metrics;
    if (_viewport.isEmpty) return;
    final Rect cell = m.cellRect(
      row.clamp(0, m.rows - 1),
      col.clamp(0, m.cols - 1),
    );
    double dx = _scroll.dx, dy = _scroll.dy;
    final double roomX =
        _viewport.width - (SheetMetrics.headerWidth + m.frozenWidth) * _zoom;
    final double roomY =
        _viewport.height - (SheetMetrics.headerHeight + m.frozenHeight) * _zoom;
    if (col >= m.frozenCols) {
      final double left = (cell.left - m.frozenWidth) * _zoom;
      final double right = (cell.right - m.frozenWidth) * _zoom;
      if (left < dx) dx = left;
      if (right > dx + roomX) dx = right - roomX;
    }
    if (row >= m.frozenRows) {
      final double top = (cell.top - m.frozenHeight) * _zoom;
      final double bottom = (cell.bottom - m.frozenHeight) * _zoom;
      if (top < dy) dy = top;
      if (bottom > dy + roomY) dy = bottom - roomY;
    }
    _ticker.stop();
    setState(() => _scroll = _clamp(Offset(dx, dy)));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        _scroll = _clamp(_scroll);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _select(details.localPosition),
          onScaleStart: (details) {
            _ticker.stop();
            _zoomAtStart = _zoom;
          },
          onScaleUpdate: (details) {
            setState(() {
              if (details.pointerCount > 1) {
                final double next = (_zoomAtStart * details.scale).clamp(
                  0.5,
                  3.0,
                );
                // Keep the point between the fingers where it is.
                final Offset focal = details.localFocalPoint;
                final Offset content = (focal + _scroll) / _zoom;
                _zoom = next;
                _scroll = content * _zoom - focal;
              }
              _scroll = _clamp(_scroll - details.focalPointDelta);
            });
          },
          onScaleEnd: (details) {
            final Velocity velocity = details.velocity;
            if (velocity.pixelsPerSecond.distance < 80) return;
            _flingX = FrictionSimulation(
              0.02,
              _scroll.dx,
              -velocity.pixelsPerSecond.dx,
            );
            _flingY = FrictionSimulation(
              0.02,
              _scroll.dy,
              -velocity.pixelsPerSecond.dy,
            );
            _ticker
              ..stop()
              ..start();
          },
          onLongPressStart: (details) {
            final (int, int)? hit = _cellAt(details.localPosition);
            if (hit == null || hit.$1 < 0 || hit.$2 < 0) return;
            _dragFrom = hit;
            widget.onSelect(
              CellRange(hit.$1, hit.$2, hit.$1, hit.$2),
              hit.$1,
              hit.$2,
            );
          },
          onLongPressMoveUpdate: (details) {
            final (int, int)? from = _dragFrom;
            final (int, int)? hit = _cellAt(details.localPosition);
            if (from == null || hit == null || hit.$1 < 0 || hit.$2 < 0) return;
            widget.onSelect(
              CellRange(
                math.min(from.$1, hit.$1),
                math.min(from.$2, hit.$2),
                math.max(from.$1, hit.$1),
                math.max(from.$2, hit.$2),
              ),
              from.$1,
              from.$2,
            );
          },
          onLongPressEnd: (_) => _dragFrom = null,
          child: ClipRect(
            child: CustomPaint(
              size: Size.infinite,
              painter: _GridPainter(
                book: widget.book,
                sheetIndex: widget.sheetIndex,
                metrics: metrics,
                scroll: _scroll,
                zoom: _zoom,
                selection: widget.selection,
                revision: widget.revision,
                accent: theme.colorScheme.primary,
                headerColor: theme.colorScheme.surfaceContainerHigh,
                headerText: theme.colorScheme.onSurfaceVariant,
                headerSelected: theme.colorScheme.primaryContainer,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _GridPainter extends CustomPainter {
  final Workbook book;
  final int sheetIndex;
  final SheetMetrics metrics;
  final Offset scroll;
  final double zoom;
  final CellRange selection;
  final int revision;
  final Color accent;
  final Color headerColor;
  final Color headerText;
  final Color headerSelected;

  _GridPainter({
    required this.book,
    required this.sheetIndex,
    required this.metrics,
    required this.scroll,
    required this.zoom,
    required this.selection,
    required this.revision,
    required this.accent,
    required this.headerColor,
    required this.headerText,
    required this.headerSelected,
  });

  static const Color _paper = Color(0xFFFFFFFF);
  static const Color _ink = Color(0xFF000000);
  static const Color _gridLine = Color(0xFFD9D9D9);

  Sheet get _sheet => book.sheets[sheetIndex];

  @override
  void paint(Canvas canvas, Size size) {
    final SheetMetrics m = metrics;
    final double hx = SheetMetrics.headerWidth * zoom;
    final double hy = SheetMetrics.headerHeight * zoom;
    final double fx = m.frozenWidth * zoom, fy = m.frozenHeight * zoom;

    canvas.drawRect(Offset.zero & size, Paint()..color = _paper);

    // Four panes: the frozen corner, the frozen rows, the frozen columns
    // and the body, each scrolled on the axes that are free for it.
    void pane(Rect clip, bool scrollX, bool scrollY) {
      if (clip.isEmpty) return;
      canvas.save();
      canvas.clipRect(clip);
      final Offset origin = Offset(
        hx - (scrollX ? scroll.dx : 0),
        hy - (scrollY ? scroll.dy : 0),
      );
      _paintCells(canvas, clip, origin);
      canvas.restore();
    }

    final Rect body = Rect.fromLTRB(hx + fx, hy + fy, size.width, size.height);
    pane(body, true, true);
    pane(Rect.fromLTRB(hx, hy + fy, hx + fx, size.height), false, true);
    pane(Rect.fromLTRB(hx + fx, hy, size.width, hy + fy), true, false);
    pane(Rect.fromLTRB(hx, hy, hx + fx, hy + fy), false, false);

    // The edge of what is frozen.
    final Paint freeze = Paint()
      ..color = const Color(0xFF9E9E9E)
      ..strokeWidth = 1;
    if (m.frozenCols > 0) {
      canvas.drawLine(Offset(hx + fx, hy), Offset(hx + fx, size.height), freeze);
    }
    if (m.frozenRows > 0) {
      canvas.drawLine(Offset(hx, hy + fy), Offset(size.width, hy + fy), freeze);
    }

    _paintHeaders(canvas, size);
  }

  /// The screen rectangle of a block of cells, for a pane whose cell (0, 0)
  /// would sit at [origin].
  Rect _onScreen(Rect content, Offset origin) => Rect.fromLTRB(
    origin.dx + content.left * zoom,
    origin.dy + content.top * zoom,
    origin.dx + content.right * zoom,
    origin.dy + content.bottom * zoom,
  );

  void _paintCells(Canvas canvas, Rect clip, Offset origin) {
    final SheetMetrics m = metrics;
    final Sheet sheet = _sheet;
    final int firstCol = m.colAt((clip.left - origin.dx) / zoom);
    final int lastCol = m.colAt((clip.right - origin.dx) / zoom);
    final int firstRow = m.rowAt((clip.top - origin.dy) / zoom);
    final int lastRow = m.rowAt((clip.bottom - origin.dy) / zoom);

    // Fills first, so that grid lines and text sit on top of them.
    for (int r = firstRow; r <= lastRow; r++) {
      final Map<int, SheetCell>? cells = sheet.rows[r];
      if (cells == null) continue;
      for (int c = firstCol; c <= lastCol; c++) {
        final SheetCell? cell = cells[c];
        if (cell == null || cell.style == 0) continue;
        final int? fill = book.styles.at(cell.style).fill;
        if (fill == null) continue;
        canvas.drawRect(
          _onScreen(m.cellRect(r, c), origin),
          Paint()..color = Color(fill),
        );
      }
    }

    final Paint line = Paint()
      ..color = _gridLine
      ..strokeWidth = 1;
    for (int c = firstCol; c <= lastCol + 1 && c <= m.cols; c++) {
      final double x = origin.dx + m.colLeft[c] * zoom;
      canvas.drawLine(Offset(x, clip.top), Offset(x, clip.bottom), line);
    }
    for (int r = firstRow; r <= lastRow + 1 && r <= m.rows; r++) {
      final double y = origin.dy + m.rowTop[r] * zoom;
      canvas.drawLine(Offset(clip.left, y), Offset(clip.right, y), line);
    }

    // A merged block is one cell: paper over the lines inside it.
    final Set<int> covered = {};
    for (final CellRange merge in sheet.merges) {
      if (merge.bottom < firstRow ||
          merge.top > lastRow ||
          merge.right < firstCol ||
          merge.left > lastCol) {
        continue;
      }
      final SheetCell? lead = sheet.cell(merge.top, merge.left);
      final int? fill = lead == null ? null : book.styles.at(lead.style).fill;
      final Rect rect = _onScreen(m.rangeRect(merge), origin);
      canvas.drawRect(
        rect.deflate(0.5),
        Paint()..color = fill == null ? _paper : Color(fill),
      );
      for (int r = merge.top; r <= merge.bottom; r++) {
        for (int c = merge.left; c <= merge.right; c++) {
          if (r != merge.top || c != merge.left) covered.add((r << 20) | c);
        }
      }
      _paintCell(canvas, merge.top, merge.left, rect, rect);
    }

    for (int r = firstRow; r <= lastRow; r++) {
      final Map<int, SheetCell>? cells = sheet.rows[r];
      if (cells == null) continue;
      for (int c = firstCol; c <= lastCol; c++) {
        if (!cells.containsKey(c)) continue;
        if (covered.contains((r << 20) | c)) continue;
        if (sheet.mergeAt(r, c) != null) continue; // Painted above.
        final Rect rect = _onScreen(m.cellRect(r, c), origin);
        if (rect.width <= 0 || rect.height <= 0) continue;
        // Text may run on over empty neighbours, as far as the next cell
        // that holds something.
        int reach = c;
        while (reach < m.cols - 1 &&
            reach < c + 12 &&
            (cells[reach + 1]?.isBlank ?? true)) {
          reach++;
        }
        final Rect room = Rect.fromLTRB(
          rect.left,
          rect.top,
          origin.dx + m.colLeft[reach + 1] * zoom,
          rect.bottom,
        );
        _paintCell(canvas, r, c, rect, room);
      }
    }

    final Rect selected = _onScreen(m.rangeRect(selection), origin);
    if (selected.overlaps(clip.inflate(4))) {
      if (!selection.isSingle) {
        canvas.drawRect(selected, Paint()..color = accent.withValues(alpha: 0.12));
      }
      canvas.drawRect(
        selected.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent,
      );
    }
  }

  void _paintCell(Canvas canvas, int row, int col, Rect rect, Rect room) {
    final SheetCell? cell = _sheet.cell(row, col);
    if (cell == null) return;
    final CellStyle style = book.styles.at(cell.style);

    void edge(CellBorder? border, Offset from, Offset to) {
      if (border == null) return;
      canvas.drawLine(
        from,
        to,
        Paint()
          ..color = Color(border.color)
          ..strokeWidth = math.max(1, border.width * zoom),
      );
    }

    edge(style.left, rect.topLeft, rect.bottomLeft);
    edge(style.top, rect.topLeft, rect.topRight);
    edge(style.right, rect.topRight, rect.bottomRight);
    edge(style.bottom, rect.bottomLeft, rect.bottomRight);

    final String text = book.display(sheetIndex, row, col);
    if (text.isEmpty) return;
    final Object? value = book.valueAt(sheetIndex, row, col);
    final HAlign align = style.hAlign != HAlign.general
        ? style.hAlign
        : value is double
        ? HAlign.right
        : value is String
        ? HAlign.left
        : HAlign.center;

    final double padding = 3 * zoom;
    final TextStyle textStyle = TextStyle(
      color: value is SheetError
          ? const Color(0xFFC62828)
          : Color(style.color ?? _ink.toARGB32()),
      // Points to pixels, like the row heights.
      fontSize: style.fontSize * 96 / 72 * zoom,
      fontWeight: style.bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
      decoration: TextDecoration.combine([
        if (style.underline) TextDecoration.underline,
        if (style.strike) TextDecoration.lineThrough,
      ]),
      height: 1.15,
    );
    TextPainter layout(String shown, double maxWidth) => TextPainter(
      text: TextSpan(text: shown, style: textStyle),
      textDirection: TextDirection.ltr,
      maxLines: style.wrap ? null : 1,
    )..layout(maxWidth: math.max(1, maxWidth));

    final double inner = rect.width - padding * 2;
    TextPainter painter = layout(text, style.wrap ? inner : double.infinity);
    Rect clip = rect;
    if (!style.wrap && painter.width > inner) {
      if (value is double) {
        // A number cut short would read as a different number.
        painter = layout('#' * math.max(1, (inner / (7 * zoom)).floor()), inner);
      } else if (align == HAlign.left) {
        clip = room;
      }
    }

    final double x = switch (align) {
      HAlign.right => rect.right - padding - painter.width,
      HAlign.center => rect.left + (rect.width - painter.width) / 2,
      _ => rect.left + padding,
    };
    final double y = switch (style.vAlign) {
      VAlign.top => rect.top + 1,
      VAlign.center => rect.top + (rect.height - painter.height) / 2,
      VAlign.bottom => rect.bottom - painter.height - 1,
    };
    canvas.save();
    canvas.clipRect(clip.deflate(0.5));
    painter.paint(canvas, Offset(x, math.max(rect.top, y)));
    canvas.restore();
    painter.dispose();
  }

  void _paintHeaders(Canvas canvas, Size size) {
    final SheetMetrics m = metrics;
    final double hx = SheetMetrics.headerWidth * zoom;
    final double hy = SheetMetrics.headerHeight * zoom;
    final double fx = m.frozenWidth * zoom, fy = m.frozenHeight * zoom;
    final Paint background = Paint()..color = headerColor;
    final Paint chosen = Paint()..color = headerSelected;
    final Paint line = Paint()
      ..color = _gridLine
      ..strokeWidth = 1;
    final TextStyle style = TextStyle(
      color: headerText,
      fontSize: 12 * zoom,
      fontWeight: FontWeight.w500,
    );

    void label(String text, Rect rect) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      painter.paint(
        canvas,
        Offset(
          rect.left + (rect.width - painter.width) / 2,
          rect.top + (rect.height - painter.height) / 2,
        ),
      );
      painter.dispose();
    }

    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, hy), background);
    canvas.drawRect(Rect.fromLTWH(0, 0, hx, size.height), background);

    void columns(Rect clip, double originX) {
      if (clip.isEmpty) return;
      canvas.save();
      canvas.clipRect(clip);
      final int first = m.colAt((clip.left - originX) / zoom);
      final int last = m.colAt((clip.right - originX) / zoom);
      for (int c = first; c <= last && c < m.cols; c++) {
        final Rect rect = Rect.fromLTRB(
          originX + m.colLeft[c] * zoom,
          0,
          originX + m.colLeft[c + 1] * zoom,
          hy,
        );
        if (rect.width <= 0) continue;
        if (c >= selection.left && c <= selection.right) {
          canvas.drawRect(rect, chosen);
        }
        label(columnName(c), rect);
        canvas.drawLine(rect.topRight, rect.bottomRight, line);
      }
      canvas.restore();
    }

    void rows(Rect clip, double originY) {
      if (clip.isEmpty) return;
      canvas.save();
      canvas.clipRect(clip);
      final int first = m.rowAt((clip.top - originY) / zoom);
      final int last = m.rowAt((clip.bottom - originY) / zoom);
      for (int r = first; r <= last && r < m.rows; r++) {
        final Rect rect = Rect.fromLTRB(
          0,
          originY + m.rowTop[r] * zoom,
          hx,
          originY + m.rowTop[r + 1] * zoom,
        );
        if (rect.height <= 0) continue;
        if (r >= selection.top && r <= selection.bottom) {
          canvas.drawRect(rect, chosen);
        }
        label('${r + 1}', rect);
        canvas.drawLine(rect.bottomLeft, rect.bottomRight, line);
      }
      canvas.restore();
    }

    columns(Rect.fromLTRB(hx, 0, hx + fx, hy), hx);
    columns(Rect.fromLTRB(hx + fx, 0, size.width, hy), hx - scroll.dx);
    rows(Rect.fromLTRB(0, hy, hx, hy + fy), hy);
    rows(Rect.fromLTRB(0, hy + fy, hx, size.height), hy - scroll.dy);

    canvas.drawRect(Rect.fromLTWH(0, 0, hx, hy), background);
    canvas.drawLine(Offset(hx, 0), Offset(hx, size.height), line);
    canvas.drawLine(Offset(0, hy), Offset(size.width, hy), line);
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.revision != revision ||
      old.scroll != scroll ||
      old.zoom != zoom ||
      old.selection != selection ||
      old.sheetIndex != sheetIndex ||
      old.book != book ||
      old.accent != accent ||
      old.headerColor != headerColor;
}
