import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/services/pdf_page_geometry.dart';

/// A4 in PDF units, the size Syncfusion reports for a default page.
const Size a4 = Size(595.0, 842.0);

PdfPageGeometry geometryOf({
  List<Size> pages = const [a4, a4, a4],
  double viewportWidth = 595.0,
  double zoom = 1.0,
  Offset scrollOffset = Offset.zero,
  double pageSpacing = 4.0,
}) {
  return PdfPageGeometry(
    pageSizes: pages,
    viewportWidth: viewportWidth,
    pageSpacing: pageSpacing,
    zoom: zoom,
    scrollOffset: scrollOffset,
  );
}

void main() {
  group('layout', () {
    test('scales each page independently to fit the viewport width', () {
      final g = geometryOf(
        pages: const [Size(595, 842), Size(1190, 842)],
        viewportWidth: 595,
      );
      expect(g.fitScaleFor(0), 1.0);
      expect(g.fitScaleFor(1), 0.5);
      expect(g.sceneHeightFor(0), 842.0);
      expect(g.sceneHeightFor(1), 421.0);
    });

    test('stacks pages with spacing between but not before the first', () {
      final g = geometryOf();
      expect(g.sceneTopFor(0), 0.0);
      expect(g.sceneTopFor(1), 842.0 + 4.0);
      expect(g.sceneTopFor(2), 2 * (842.0 + 4.0));
    });

    test('is unusable until the document has been measured', () {
      expect(geometryOf(pages: const []).isUsable, isFalse);
      expect(geometryOf(viewportWidth: 0).isUsable, isFalse);
      expect(geometryOf().isUsable, isTrue);
    });
  });

  group('resolve at zoom 1', () {
    test('maps a point on the first page one-to-one', () {
      final g = geometryOf();
      final r = g.resolve(const Offset(100, 200));
      expect(r.pageIndex, 0);
      expect(r.pagePoint.dx, closeTo(100, 0.001));
      expect(r.pagePoint.dy, closeTo(200, 0.001));
    });

    test('finds the second page once scrolled past the first', () {
      final g = geometryOf(scrollOffset: const Offset(0, 846));
      final r = g.resolve(const Offset(50, 10));
      expect(r.pageIndex, 1);
      expect(r.pagePoint.dy, closeTo(10, 0.001));
    });

    test('picks the right page for a point deep in the document', () {
      final g = geometryOf();
      // 100pt into page 3 (index 2).
      final r = g.resolve(Offset(0, 2 * (842 + 4) + 100));
      expect(r.pageIndex, 2);
      expect(r.pagePoint.dy, closeTo(100, 0.001));
    });
  });

  group('resolve while zoomed', () {
    // This is the case the previous implementation got wrong: scrollOffset is
    // reported in unzoomed scene units, but gesture positions arrive in screen
    // pixels. Adding them together before dividing by (fitScale * zoom) is only
    // correct when zoom == 1.
    test('a screen point maps back to the page point it was drawn on', () {
      const double zoom = 2.0;
      const Offset scroll = Offset(0, 400);
      final g = geometryOf(zoom: zoom, scrollOffset: scroll);

      // Page point (120, 500) sits at scene (120, 500); on screen that is
      // (scene - scroll) * zoom.
      const Offset scene = Offset(120, 500);
      final Offset screen = (scene - scroll) * zoom;

      final r = g.resolve(screen);
      expect(r.pageIndex, 0);
      expect(r.pagePoint.dx, closeTo(120, 0.001));
      expect(r.pagePoint.dy, closeTo(500, 0.001));
    });

    test('the old screen/scene mix-up would have been wrong here', () {
      const double zoom = 2.0;
      const Offset scroll = Offset(0, 400);
      final g = geometryOf(zoom: zoom, scrollOffset: scroll);
      const Offset screen = Offset(240, 200);

      final double correct = g.resolve(screen).pagePoint.dy;
      // What the previous code computed: (screenY + scrollY) / (fitScale*zoom).
      final double legacy = (screen.dy + scroll.dy) / (1.0 * zoom);

      expect(correct, closeTo(500, 0.001));
      expect(legacy, closeTo(300, 0.001));
      expect((correct - legacy).abs(), greaterThan(100));
    });

    test('resolves onto a later page while zoomed', () {
      const double zoom = 1.5;
      final g = geometryOf(zoom: zoom, scrollOffset: const Offset(0, 900));
      // Scene y 900 is 54pt into page 2 (page 2 starts at 846).
      final r = g.resolve(Offset.zero);
      expect(r.pageIndex, 1);
      expect(r.pagePoint.dy, closeTo(54, 0.001));
    });
  });

  group('clamping', () {
    test('a point past the end of the document lands on the last page', () {
      final g = geometryOf();
      final r = g.resolve(const Offset(0, 999999));
      expect(r.pageIndex, 2);
      expect(r.pagePoint.dy, lessThanOrEqualTo(842.0));
    });

    test('a point in the gap between pages snaps into the page above', () {
      final g = geometryOf();
      // 2pt into the 4pt gap after page 1.
      final r = g.resolve(const Offset(0, 844));
      expect(r.pageIndex, 0);
      expect(r.pagePoint.dy, closeTo(842, 0.001));
    });

    test('a point left of the page is clamped to the page edge', () {
      final g = geometryOf(scrollOffset: const Offset(-50, 0));
      final r = g.resolve(Offset.zero);
      expect(r.pagePoint.dx, 0.0);
    });
  });

  group('unrotatePagePoint', () {
    // A page is laid out already turned, so points are picked in display
    // space, but everything written into the document is interpreted in the
    // page's own unrotated space.
    const Size portrait = Size(595, 842);

    test('is a no-op for an unrotated page', () {
      const p = Offset(100, 200);
      expect(unrotatePagePoint(p, portrait, PdfPageTurn.none), p);
    });

    test('round-trips every corner for a quarter turn', () {
      // Display space for a 90-degree page is 842 wide by 595 tall.
      // Unrotated (0,0) displays at (842, 0).
      expect(
        unrotatePagePoint(const Offset(842, 0), portrait, PdfPageTurn.quarter),
        const Offset(0, 0),
      );
      // Unrotated (595, 0) displays at (842, 595).
      expect(
        unrotatePagePoint(
            const Offset(842, 595), portrait, PdfPageTurn.quarter),
        const Offset(595, 0),
      );
      // Unrotated (0, 842) displays at (0, 0).
      expect(
        unrotatePagePoint(Offset.zero, portrait, PdfPageTurn.quarter),
        const Offset(0, 842),
      );
    });

    test('round-trips every corner for a three-quarter turn', () {
      // Unrotated (0,0) displays at (0, 595).
      expect(
        unrotatePagePoint(
            const Offset(0, 595), portrait, PdfPageTurn.threeQuarter),
        const Offset(0, 0),
      );
      // Unrotated (595, 842) displays at (842, 0).
      expect(
        unrotatePagePoint(
            const Offset(842, 0), portrait, PdfPageTurn.threeQuarter),
        const Offset(595, 842),
      );
    });

    test('maps a half turn to the opposite corner', () {
      expect(
        unrotatePagePoint(Offset.zero, portrait, PdfPageTurn.half),
        const Offset(595, 842),
      );
      expect(
        unrotatePagePoint(const Offset(595, 842), portrait, PdfPageTurn.half),
        const Offset(0, 0),
      );
    });

    test('keeps every turned point inside the unrotated page', () {
      for (final turn in PdfPageTurn.values) {
        final Size display = turn.swapsAxes
            ? Size(portrait.height, portrait.width)
            : portrait;
        for (final p in [
          Offset.zero,
          Offset(display.width, 0),
          Offset(0, display.height),
          Offset(display.width, display.height),
          Offset(display.width / 2, display.height / 2),
        ]) {
          final r = unrotatePagePoint(p, portrait, turn);
          expect(r.dx, inInclusiveRange(0, portrait.width), reason: '$turn $p');
          expect(r.dy, inInclusiveRange(0, portrait.height), reason: '$turn $p');
        }
      }
    });

    test('swapsAxes is set for exactly the quarter turns', () {
      expect(PdfPageTurn.none.swapsAxes, isFalse);
      expect(PdfPageTurn.quarter.swapsAxes, isTrue);
      expect(PdfPageTurn.half.swapsAxes, isFalse);
      expect(PdfPageTurn.threeQuarter.swapsAxes, isTrue);
    });
  });

  group('unrotatePageRect', () {
    const Size portrait = Size(595, 842);

    test('is a no-op for an unrotated page', () {
      const r = Rect.fromLTRB(10, 20, 30, 40);
      expect(unrotatePageRect(r, portrait, PdfPageTurn.none), r);
    });

    test('stays normalised after a quarter turn', () {
      final r = unrotatePageRect(
        const Rect.fromLTRB(100, 50, 300, 200),
        portrait,
        PdfPageTurn.quarter,
      );
      expect(r.left, lessThan(r.right));
      expect(r.top, lessThan(r.bottom));
      expect(r.width, greaterThan(0));
      expect(r.height, greaterThan(0));
    });

    test('a quarter turn transposes the rect dimensions', () {
      final r = unrotatePageRect(
        const Rect.fromLTRB(100, 50, 300, 150),
        portrait,
        PdfPageTurn.quarter,
      );
      // A 200x100 display rect becomes 100x200 on the page.
      expect(r.width, closeTo(100, 0.001));
      expect(r.height, closeTo(200, 0.001));
    });
  });

  group('resolveRect', () {
    test('normalises a rect dragged bottom-right to top-left', () {
      final g = geometryOf();
      final r = g.resolveRect(const Rect.fromLTRB(300, 400, 100, 200));
      expect(r.pageIndex, 0);
      expect(r.bounds.left, closeTo(100, 0.001));
      expect(r.bounds.top, closeTo(200, 0.001));
      expect(r.bounds.right, closeTo(300, 0.001));
      expect(r.bounds.bottom, closeTo(400, 0.001));
      expect(r.bounds.width, greaterThan(0));
      expect(r.bounds.height, greaterThan(0));
    });

    test('assigns the rect to the page under its centre', () {
      final g = geometryOf(scrollOffset: const Offset(0, 846));
      final r = g.resolveRect(const Rect.fromLTRB(10, 10, 200, 100));
      expect(r.pageIndex, 1);
    });

    test('clamps a rect that overhangs the page bottom', () {
      final g = geometryOf(pages: const [a4]);
      final r = g.resolveRect(const Rect.fromLTRB(10, 800, 200, 5000));
      expect(r.pageIndex, 0);
      expect(r.bounds.bottom, closeTo(842, 0.001));
    });
  });
}
