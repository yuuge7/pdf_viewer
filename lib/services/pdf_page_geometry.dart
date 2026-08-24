import 'package:flutter/widgets.dart';

/// Quarter-turns a page is rotated by for display, from its `/Rotate` entry.
enum PdfPageTurn {
  none,
  quarter, // 90 degrees clockwise
  half, // 180 degrees
  threeQuarter; // 270 degrees clockwise

  /// Whether display width and height are swapped relative to the page's own
  /// unrotated size.
  bool get swapsAxes => this == quarter || this == threeQuarter;
}

/// Converts a point in *displayed* page space back into the page's own
/// unrotated coordinate space.
///
/// The viewer lays a rotated page out already turned, so gestures land in
/// display space. Everything written into the document — `drawString` bounds,
/// annotation rectangles — is interpreted in the page's unrotated space, so
/// annotations on a `/Rotate 90` or `/Rotate 270` page come out transposed
/// unless they are turned back first.
///
/// [unrotatedSize] is the page's own size, before any display rotation.
Offset unrotatePagePoint(
  Offset displayPoint,
  Size unrotatedSize,
  PdfPageTurn turn,
) {
  final double w = unrotatedSize.width;
  final double h = unrotatedSize.height;
  switch (turn) {
    case PdfPageTurn.none:
      return displayPoint;
    case PdfPageTurn.quarter:
      // Display is (h x w). Unrotated (x, y) shows at (h - y, x).
      return Offset(displayPoint.dy, h - displayPoint.dx);
    case PdfPageTurn.half:
      return Offset(w - displayPoint.dx, h - displayPoint.dy);
    case PdfPageTurn.threeQuarter:
      // Display is (h x w). Unrotated (x, y) shows at (y, w - x).
      return Offset(w - displayPoint.dy, displayPoint.dx);
  }
}

/// Converts a rectangle in displayed page space into the page's unrotated
/// space, normalised so left <= right and top <= bottom.
Rect unrotatePageRect(Rect displayRect, Size unrotatedSize, PdfPageTurn turn) {
  if (turn == PdfPageTurn.none) return displayRect;
  final Offset a =
      unrotatePagePoint(displayRect.topLeft, unrotatedSize, turn);
  final Offset b =
      unrotatePagePoint(displayRect.bottomRight, unrotatedSize, turn);
  return Rect.fromLTRB(
    a.dx < b.dx ? a.dx : b.dx,
    a.dy < b.dy ? a.dy : b.dy,
    a.dx < b.dx ? b.dx : a.dx,
    a.dy < b.dy ? b.dy : a.dy,
  );
}

/// A point resolved onto a specific PDF page.
@immutable
class PdfPagePoint {
  /// 0-based page index, ready to hand to `PdfDocument.pages[...]`.
  final int pageIndex;

  /// Position within that page, in PDF units, origin at the page's top-left.
  final Offset pagePoint;

  const PdfPagePoint(this.pageIndex, this.pagePoint);

  @override
  bool operator ==(Object other) =>
      other is PdfPagePoint &&
      other.pageIndex == pageIndex &&
      other.pagePoint == pagePoint;

  @override
  int get hashCode => Object.hash(pageIndex, pagePoint);

  @override
  String toString() => 'PdfPagePoint($pageIndex, $pagePoint)';
}

/// Converts viewer screen coordinates into PDF page coordinates.
///
/// This mirrors the layout `SfPdfViewer` performs internally for the default
/// continuous / vertical configuration:
///
///  * Every page is scaled independently to fit the viewport width
///    (`fitScale = viewportWidth / pageWidth`), preserving aspect ratio.
///  * Pages are stacked top to bottom with `pageSpacing` between them, and no
///    spacing after the last page.
///  * That stack is "scene" space. The viewer then applies the zoom transform
///    on top of it.
///
/// The distinction between scene space and screen space is the important part.
/// [PdfViewerController.scrollOffset] is reported in **scene** units (it is
/// `transformationController.toScene(Offset.zero)`), while gesture positions
/// arrive in **screen** pixels. Mixing the two without dividing by the zoom
/// factor first only happens to be correct at `zoom == 1.0`.
@immutable
class PdfPageGeometry {
  /// Size of every page, in PDF units, in document order.
  final List<Size> pageSizes;

  /// Width of the viewer widget, in logical pixels.
  final double viewportWidth;

  /// Gap between consecutive pages, in scene units. Must match the
  /// `pageSpacing` given to `SfPdfViewer`.
  final double pageSpacing;

  /// Current zoom level of the viewer.
  final double zoom;

  /// Current scroll offset of the viewer, in scene units.
  final Offset scrollOffset;

  const PdfPageGeometry({
    required this.pageSizes,
    required this.viewportWidth,
    required this.pageSpacing,
    required this.zoom,
    required this.scrollOffset,
  });

  int get pageCount => pageSizes.length;

  bool get isUsable =>
      pageSizes.isNotEmpty &&
      viewportWidth > 0 &&
      zoom > 0 &&
      pageSizes.every((s) => s.width > 0 && s.height > 0);

  /// Scale applied to page [index] to fit the viewport width.
  double fitScaleFor(int index) => viewportWidth / pageSizes[index].width;

  /// Height page [index] occupies in scene space.
  double sceneHeightFor(int index) =>
      pageSizes[index].height * fitScaleFor(index);

  /// Distance from the top of the document to the top of page [index], in
  /// scene units.
  double sceneTopFor(int index) {
    double top = 0;
    for (int i = 0; i < index; i++) {
      top += sceneHeightFor(i) + pageSpacing;
    }
    return top;
  }

  /// Converts a screen-space point in the viewer to scene space.
  Offset toScene(Offset screenPoint) => screenPoint / zoom + scrollOffset;

  /// Resolves a screen-space point onto a page.
  ///
  /// Points landing in the gap between two pages, or past either end of the
  /// document, are attached to the nearest page and clamped inside it, so an
  /// annotation dragged slightly off a page still lands somewhere sensible
  /// instead of being dropped.
  PdfPagePoint resolve(Offset screenPoint) {
    assert(isUsable, 'PdfPageGeometry used before the document was measured');
    final Offset scene = toScene(screenPoint);

    int pageIndex = pageCount - 1;
    double top = 0;
    for (int i = 0; i < pageCount; i++) {
      final double height = sceneHeightFor(i);
      // The gap below a page is attributed to that page, so a point in the
      // spacing snaps up to the page above it rather than jumping down.
      if (scene.dy < top + height + pageSpacing) {
        pageIndex = i;
        break;
      }
      top += height + pageSpacing;
    }

    final double scale = fitScaleFor(pageIndex);
    final Size pageSize = pageSizes[pageIndex];
    final double pageTop = sceneTopFor(pageIndex);

    final double x = (scene.dx / scale).clamp(0.0, pageSize.width);
    final double y =
        ((scene.dy - pageTop) / scale).clamp(0.0, pageSize.height);

    return PdfPagePoint(pageIndex, Offset(x, y));
  }

  /// Resolves a screen-space rectangle onto a single page.
  ///
  /// The page is chosen from the rectangle's centre, then both corners are
  /// clamped into that page. The returned rect is normalised so
  /// `left <= right` and `top <= bottom`.
  PdfPageRect resolveRect(Rect screenRect) {
    final PdfPagePoint centre = resolve(screenRect.center);
    final int pageIndex = centre.pageIndex;

    final double scale = fitScaleFor(pageIndex);
    final Size pageSize = pageSizes[pageIndex];
    final double pageTop = sceneTopFor(pageIndex);

    Offset toPage(Offset screenPoint) {
      final Offset scene = toScene(screenPoint);
      return Offset(
        (scene.dx / scale).clamp(0.0, pageSize.width),
        ((scene.dy - pageTop) / scale).clamp(0.0, pageSize.height),
      );
    }

    final Offset a = toPage(screenRect.topLeft);
    final Offset b = toPage(screenRect.bottomRight);

    return PdfPageRect(
      pageIndex,
      Rect.fromLTRB(
        a.dx < b.dx ? a.dx : b.dx,
        a.dy < b.dy ? a.dy : b.dy,
        a.dx < b.dx ? b.dx : a.dx,
        a.dy < b.dy ? b.dy : a.dy,
      ),
    );
  }
}

/// A rectangle resolved onto a specific PDF page.
@immutable
class PdfPageRect {
  /// 0-based page index.
  final int pageIndex;

  /// Bounds within that page, in PDF units, origin at the page's top-left.
  final Rect bounds;

  const PdfPageRect(this.pageIndex, this.bounds);

  @override
  bool operator ==(Object other) =>
      other is PdfPageRect &&
      other.pageIndex == pageIndex &&
      other.bounds == bounds;

  @override
  int get hashCode => Object.hash(pageIndex, bounds);

  @override
  String toString() => 'PdfPageRect($pageIndex, $bounds)';
}
