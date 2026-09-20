import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset, Rect, Size;
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// How a captured page is cleaned up before it goes into the PDF.
enum ScanFilter {
  /// The photo as taken, only cropped and straightened.
  original('Original'),

  /// Per-channel level stretch. Paper goes white, ink goes dark, the colour
  /// of the ink survives. This is the default because a raw phone photo of a
  /// document is almost always grey and yellow-tinted.
  enhance('Enhance'),

  /// Enhance, then drop the colour.
  grayscale('Grayscale'),

  /// Adaptive threshold. Produces a two-tone scan that survives uneven
  /// lighting, where a single global threshold would black out the shadowed
  /// half of the page.
  blackAndWhite('B&W');

  final String label;
  const ScanFilter(this.label);
}

/// The four corners of the document inside the photo, in normalised
/// coordinates (0..1 of the image's width and height), in clockwise order
/// starting from the top-left.
///
/// Normalised rather than pixels so the same quad describes the preview, the
/// full-resolution render, and anything persisted, without carrying the source
/// image's dimensions alongside it.
@immutable
class ScanQuad {
  final Offset topLeft;
  final Offset topRight;
  final Offset bottomRight;
  final Offset bottomLeft;

  const ScanQuad({
    required this.topLeft,
    required this.topRight,
    required this.bottomRight,
    required this.bottomLeft,
  });

  /// The whole image, uncropped.
  static const ScanQuad full = ScanQuad(
    topLeft: Offset.zero,
    topRight: Offset(1, 0),
    bottomRight: Offset(1, 1),
    bottomLeft: Offset(0, 1),
  );

  static ScanQuad fromRect(double l, double t, double r, double b) => ScanQuad(
    topLeft: Offset(l, t),
    topRight: Offset(r, t),
    bottomRight: Offset(r, b),
    bottomLeft: Offset(l, b),
  );

  List<Offset> get corners => [topLeft, topRight, bottomRight, bottomLeft];

  ScanQuad withCorner(int index, Offset value) => ScanQuad(
    topLeft: index == 0 ? value : topLeft,
    topRight: index == 1 ? value : topRight,
    bottomRight: index == 2 ? value : bottomRight,
    bottomLeft: index == 3 ? value : bottomLeft,
  );

  /// True when the quad is (near enough) the untouched full image, which lets
  /// the UI say "no crop" and lets the renderer skip the warp entirely.
  bool get isFull {
    const double e = 0.005;
    final List<Offset> f = ScanQuad.full.corners;
    final List<Offset> c = corners;
    for (int i = 0; i < 4; i++) {
      if ((c[i].dx - f[i].dx).abs() > e || (c[i].dy - f[i].dy).abs() > e) {
        return false;
      }
    }
    return true;
  }

  /// Flat form, for crossing an isolate boundary as plain numbers.
  List<double> toList() => [
    topLeft.dx, topLeft.dy, //
    topRight.dx, topRight.dy,
    bottomRight.dx, bottomRight.dy,
    bottomLeft.dx, bottomLeft.dy,
  ];

  static ScanQuad fromList(List<double> v) => ScanQuad(
    topLeft: Offset(v[0], v[1]),
    topRight: Offset(v[2], v[3]),
    bottomRight: Offset(v[4], v[5]),
    bottomLeft: Offset(v[6], v[7]),
  );

  @override
  bool operator ==(Object other) =>
      other is ScanQuad &&
      other.topLeft == topLeft &&
      other.topRight == topRight &&
      other.bottomRight == bottomRight &&
      other.bottomLeft == bottomLeft;

  @override
  int get hashCode => Object.hash(topLeft, topRight, bottomRight, bottomLeft);
}

/// One captured page, before it becomes a PDF page.
///
/// The photo on disk is never modified: the crop, the rotation and the filter
/// are all stored as intent and re-applied on every render. That is what makes
/// every adjustment in the review screen reversible.
@immutable
class ScanPage {
  /// The captured photo. Owned by the scan session and deleted with it.
  final String sourcePath;
  final ScanQuad quad;
  final ScanFilter filter;

  /// Extra rotation the user applied, in clockwise quarter turns.
  final int quarterTurns;

  const ScanPage({
    required this.sourcePath,
    this.quad = ScanQuad.full,
    this.filter = ScanFilter.enhance,
    this.quarterTurns = 0,
  });

  ScanPage copyWith({ScanQuad? quad, ScanFilter? filter, int? quarterTurns}) =>
      ScanPage(
        sourcePath: sourcePath,
        quad: quad ?? this.quad,
        filter: filter ?? this.filter,
        quarterTurns: quarterTurns ?? this.quarterTurns,
      );

  /// Identifies a rendered result. Anything that changes the pixels changes
  /// this, so the review screen can cache previews against it.
  String get renderKey =>
      '$sourcePath|${quad.toList().join(',')}|${filter.index}|$quarterTurns';
}

/// Where a batch of captured pages comes from.
enum ScanSource { camera, gallery }

/// Paper size for the generated PDF.
enum ScanPageSize {
  /// The page takes the proportions of the scan, so nothing is letterboxed.
  fitImage('Fit to scan'),
  a4('A4'),
  letter('Letter');

  final String label;
  const ScanPageSize(this.label);
}

/// Turns photographs into PDF pages.
///
/// Everything expensive runs inside [Isolate.run]: decoding a 12 MP phone
/// photo and warping it is hundreds of milliseconds at best, and on the main
/// isolate that is a visible freeze on every thumbnail.
class ScanService {
  /// Longest edge of a rendered page, in pixels. 1800 keeps A4 at roughly
  /// 150 dpi, which is legible for text and still a sane file size; going to
  /// the sensor's full resolution multiplies the PDF size for no readability.
  static const int fullResolutionEdge = 1800;

  /// Longest edge used for review thumbnails.
  static const int previewEdge = 720;

  /// Renders one page to JPEG bytes, cropped, straightened and filtered.
  static Future<Uint8List?> render(
    ScanPage page, {
    int maxEdge = fullResolutionEdge,
  }) async {
    try {
      final Uint8List bytes = await File(page.sourcePath).readAsBytes();
      final List<double> quad = page.quad.toList();
      final int filter = page.filter.index;
      final int turns = page.quarterTurns;
      return await Isolate.run(
        () => _renderInIsolate(bytes, quad, filter, turns, maxEdge),
      );
    } catch (e) {
      debugPrint('Could not render scan page: $e');
      return null;
    }
  }

  /// Finds the document inside the photo.
  ///
  /// Returns null when nothing convincing is found, which the caller should
  /// read as "leave the crop alone" rather than as an error — a wrong
  /// automatic crop that silently eats a margin is worse than none.
  static Future<ScanQuad?> detectDocument(String path) async {
    try {
      final Uint8List bytes = await File(path).readAsBytes();
      final List<double>? quad = await Isolate.run(
        () => _detectInIsolate(bytes),
      );
      return quad == null ? null : ScanQuad.fromList(quad);
    } catch (e) {
      debugPrint('Could not detect document bounds: $e');
      return null;
    }
  }

  /// Assembles rendered pages into a PDF in the app documents directory.
  static Future<File?> buildPdf(
    List<Uint8List> pages,
    ScanPageSize pageSize,
  ) async {
    if (pages.isEmpty) return null;
    try {
      final int sizeIndex = pageSize.index;
      final Uint8List bytes = await Isolate.run(
        () => _buildPdfInIsolate(pages, sizeIndex),
      );
      final Directory directory = await getApplicationDocumentsDirectory();
      final File file = File(
        '${directory.path}/scan_${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (e) {
      debugPrint('Could not build the scanned PDF: $e');
      return null;
    }
  }

  /// Copies a picked photo into a private directory the session owns.
  ///
  /// `image_picker` hands back a file in a shared cache that Android is free
  /// to clear while the review screen is still open, so a scan that sat on
  /// screen for a while would render as a blank page.
  static Future<File> retainCapture(String pickedPath) async {
    final Directory directory = await getApplicationDocumentsDirectory();
    final Directory scans = Directory('${directory.path}/scans');
    if (!scans.existsSync()) await scans.create(recursive: true);
    final String basename = pickedPath
        .split('/')
        .last
        .split(Platform.pathSeparator)
        .last;
    final int dot = basename.lastIndexOf('.');
    final String extension = dot > 0 ? basename.substring(dot) : '.jpg';
    final File target = File(
      '${scans.path}/capture_${DateTime.now().microsecondsSinceEpoch}$extension',
    );
    return File(pickedPath).copy(target.path);
  }

  /// Removes captures left behind by sessions that were abandoned.
  static Future<void> sweepStaleCaptures() async {
    try {
      final Directory directory = await getApplicationDocumentsDirectory();
      final Directory scans = Directory('${directory.path}/scans');
      if (!scans.existsSync()) return;
      final DateTime cutoff = DateTime.now().subtract(const Duration(days: 1));
      await for (final FileSystemEntity entity in scans.list()) {
        if (entity is! File) continue;
        final FileStat stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) await entity.delete();
      }
    } catch (_) {
      // Housekeeping only.
    }
  }
}

// --- Isolate bodies ---------------------------------------------------------
//
// Top-level so they capture nothing but their arguments.

Uint8List? _renderInIsolate(
  Uint8List bytes,
  List<double> quad,
  int filterIndex,
  int quarterTurns,
  int maxEdge,
) {
  final img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  // Phone cameras record orientation in EXIF instead of rotating the pixels.
  // Everything downstream works in pixel space, so bake it in first or a
  // portrait capture is cropped as though it were landscape.
  img.Image source = img.bakeOrientation(decoded);

  source = _warp(source, quad, maxEdge);

  final int turns = ((quarterTurns % 4) + 4) % 4;
  if (turns != 0) {
    source = img.copyRotate(source, angle: turns * 90);
  }

  final ScanFilter filter = ScanFilter.values[filterIndex];
  if (filter != ScanFilter.original) {
    source = _applyFilter(source, filter);
  }

  return img.encodeJpg(source, quality: 88);
}

/// Perspective-corrects the region [quad] of [source] into a flat rectangle.
///
/// A phone photo of a page is taken at an angle, so the page is a trapezium in
/// the image. Cropping to its bounding box keeps the distortion; only a
/// projective transform actually flattens it, which is the whole point of
/// letting the user place four corners rather than drag a rectangle.
img.Image _warp(img.Image source, List<double> quad, int maxEdge) {
  final double w = source.width.toDouble();
  final double h = source.height.toDouble();

  // Source corners, in pixels, clockwise from the top-left.
  final List<double> sx = [quad[0] * w, quad[2] * w, quad[4] * w, quad[6] * w];
  final List<double> sy = [quad[1] * h, quad[3] * h, quad[5] * h, quad[7] * h];

  double edge(int a, int b) =>
      math.sqrt(math.pow(sx[a] - sx[b], 2) + math.pow(sy[a] - sy[b], 2));

  double outWidth = math.max(edge(0, 1), edge(3, 2));
  double outHeight = math.max(edge(0, 3), edge(1, 2));
  if (outWidth < 8 || outHeight < 8) return source;

  final double longest = math.max(outWidth, outHeight);
  if (longest > maxEdge) {
    final double k = maxEdge / longest;
    outWidth *= k;
    outHeight *= k;
  }

  final int outW = outWidth.round().clamp(8, 20000);
  final int outH = outHeight.round().clamp(8, 20000);

  // Homography mapping destination pixels back into the source, so every
  // output pixel is filled exactly once (a forward map leaves holes).
  final List<double>? m = _solveHomography(
    [
      0,
      0,
      outW.toDouble(),
      0,
      outW.toDouble(),
      outH.toDouble(),
      0,
      outH.toDouble(),
    ],
    [sx[0], sy[0], sx[1], sy[1], sx[2], sy[2], sx[3], sy[3]],
  );
  if (m == null) return source;

  final Uint8List src = source.getBytes(order: img.ChannelOrder.rgb);
  final int srcW = source.width;
  final int srcH = source.height;
  final Uint8List out = Uint8List(outW * outH * 3);

  for (int y = 0; y < outH; y++) {
    final double v = y + 0.5;
    for (int x = 0; x < outW; x++) {
      final double u = x + 0.5;
      final double denominator = m[6] * u + m[7] * v + 1.0;
      if (denominator == 0) continue;
      final double fx = (m[0] * u + m[1] * v + m[2]) / denominator;
      final double fy = (m[3] * u + m[4] * v + m[5]) / denominator;

      final int outIndex = (y * outW + x) * 3;
      if (fx < 0 || fy < 0 || fx > srcW - 1 || fy > srcH - 1) {
        // Outside the photo: white, which reads as page margin rather than as
        // the black a zeroed buffer would give.
        out[outIndex] = 255;
        out[outIndex + 1] = 255;
        out[outIndex + 2] = 255;
        continue;
      }

      // Bilinear, so a quad that magnifies part of the photo does not come out
      // visibly blocky.
      final int x0 = fx.floor();
      final int y0 = fy.floor();
      final int x1 = math.min(x0 + 1, srcW - 1);
      final int y1 = math.min(y0 + 1, srcH - 1);
      final double ax = fx - x0;
      final double ay = fy - y0;

      final int i00 = (y0 * srcW + x0) * 3;
      final int i10 = (y0 * srcW + x1) * 3;
      final int i01 = (y1 * srcW + x0) * 3;
      final int i11 = (y1 * srcW + x1) * 3;

      for (int c = 0; c < 3; c++) {
        final double top = src[i00 + c] * (1 - ax) + src[i10 + c] * ax;
        final double bottom = src[i01 + c] * (1 - ax) + src[i11 + c] * ax;
        out[outIndex + c] = (top * (1 - ay) + bottom * ay).round().clamp(
          0,
          255,
        );
      }
    }
  }

  return img.Image.fromBytes(
    width: outW,
    height: outH,
    bytes: out.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
}

/// Solves the 8 coefficients of the projective transform taking [from] to
/// [to], both given as four interleaved x,y pairs.
///
/// Returns null when the four points are degenerate (three of them collinear),
/// which happens if the user collapses the crop quad onto a line.
List<double>? _solveHomography(List<double> from, List<double> to) {
  // x' = (a·x + b·y + c) / (g·x + h·y + 1)
  // y' = (d·x + e·y + f) / (g·x + h·y + 1)
  final List<List<double>> a = List.generate(8, (_) => List.filled(9, 0.0));
  for (int i = 0; i < 4; i++) {
    final double x = from[i * 2];
    final double y = from[i * 2 + 1];
    final double u = to[i * 2];
    final double v = to[i * 2 + 1];

    a[i * 2]
      ..[0] = x
      ..[1] = y
      ..[2] = 1
      ..[6] = -x * u
      ..[7] = -y * u
      ..[8] = u;
    a[i * 2 + 1]
      ..[3] = x
      ..[4] = y
      ..[5] = 1
      ..[6] = -x * v
      ..[7] = -y * v
      ..[8] = v;
  }

  // Gaussian elimination with partial pivoting.
  for (int col = 0; col < 8; col++) {
    int pivot = col;
    for (int row = col + 1; row < 8; row++) {
      if (a[row][col].abs() > a[pivot][col].abs()) pivot = row;
    }
    if (a[pivot][col].abs() < 1e-10) return null;
    final List<double> swap = a[col];
    a[col] = a[pivot];
    a[pivot] = swap;

    final double lead = a[col][col];
    for (int k = col; k < 9; k++) {
      a[col][k] /= lead;
    }
    for (int row = 0; row < 8; row++) {
      if (row == col) continue;
      final double factor = a[row][col];
      if (factor == 0) continue;
      for (int k = col; k < 9; k++) {
        a[row][k] -= factor * a[col][k];
      }
    }
  }

  return List<double>.generate(8, (i) => a[i][8]);
}

img.Image _applyFilter(img.Image source, ScanFilter filter) {
  final Uint8List pixels = source.getBytes(order: img.ChannelOrder.rgb);
  final int width = source.width;
  final int height = source.height;

  switch (filter) {
    case ScanFilter.original:
      return source;
    case ScanFilter.enhance:
      _stretchLevels(pixels, perChannel: true);
      break;
    case ScanFilter.grayscale:
      _toGray(pixels);
      _stretchLevels(pixels, perChannel: false);
      break;
    case ScanFilter.blackAndWhite:
      _toGray(pixels);
      _adaptiveThreshold(pixels, width, height);
      break;
  }

  return img.Image.fromBytes(
    width: width,
    height: height,
    bytes: pixels.buffer,
    bytesOffset: pixels.offsetInBytes,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
}

void _toGray(Uint8List pixels) {
  for (int i = 0; i < pixels.length; i += 3) {
    final int y =
        (pixels[i] * 0.299 + pixels[i + 1] * 0.587 + pixels[i + 2] * 0.114)
            .round()
            .clamp(0, 255);
    pixels[i] = y;
    pixels[i + 1] = y;
    pixels[i + 2] = y;
  }
}

/// Maps the 1st and 99th percentile of the image onto black and white.
///
/// This is what turns a grey, yellow-cast phone photo into something that
/// reads as a scan. Percentiles rather than min/max, so a single blown-out
/// highlight or a speck of dust does not anchor the whole range.
///
/// [perChannel] stretches red, green and blue independently, which also
/// removes the colour cast of indoor lighting. For an already grey image that
/// would be a no-op with extra work, so grayscale uses the joint histogram.
void _stretchLevels(Uint8List pixels, {required bool perChannel}) {
  const double lowPercentile = 0.01;
  const double highPercentile = 0.99;
  final int channels = perChannel ? 3 : 1;

  for (int c = 0; c < channels; c++) {
    final Int32List histogram = Int32List(256);
    for (int i = c; i < pixels.length; i += 3) {
      histogram[pixels[i]]++;
    }
    final int total = pixels.length ~/ 3;
    if (total == 0) continue;

    int low = 0;
    int high = 255;
    int seen = 0;
    for (int v = 0; v < 256; v++) {
      seen += histogram[v];
      if (seen >= total * lowPercentile) {
        low = v;
        break;
      }
    }
    seen = 0;
    for (int v = 255; v >= 0; v--) {
      seen += histogram[v];
      if (seen >= total * (1 - highPercentile)) {
        high = v;
        break;
      }
    }
    if (high - low < 16) continue; // Flat image; stretching would be noise.

    final Uint8List lut = Uint8List(256);
    final double scale = 255.0 / (high - low);
    for (int v = 0; v < 256; v++) {
      // Slight S-curve on top of the stretch: lifts the paper the rest of the
      // way to white and deepens the ink, which is the difference between
      // "brighter photo" and "scan".
      final double normalised = ((v - low) * scale / 255.0).clamp(0.0, 1.0);
      final double curved =
          normalised * normalised * (3 - 2 * normalised) * 0.35 +
          normalised * 0.65;
      lut[v] = (curved * 255).round().clamp(0, 255);
    }

    if (perChannel) {
      for (int i = c; i < pixels.length; i += 3) {
        pixels[i] = lut[pixels[i]];
      }
    } else {
      for (int i = 0; i < pixels.length; i++) {
        pixels[i] = lut[pixels[i]];
      }
    }
  }
}

/// Bradley-Roth adaptive threshold over an integral image.
///
/// A global threshold splits a photo lit from one side into a clean half and a
/// solid black half. Comparing each pixel to the mean of its own neighbourhood
/// keeps text legible right across that gradient, and costs two passes.
void _adaptiveThreshold(Uint8List pixels, int width, int height) {
  if (width < 3 || height < 3) return;

  // 64-bit sums: a 1800x2400 page of white pixels overflows 32 bits.
  final Int64List integral = Int64List((width + 1) * (height + 1));
  for (int y = 0; y < height; y++) {
    int rowSum = 0;
    for (int x = 0; x < width; x++) {
      rowSum += pixels[(y * width + x) * 3];
      integral[(y + 1) * (width + 1) + (x + 1)] =
          integral[y * (width + 1) + (x + 1)] + rowSum;
    }
  }

  final int radius = math.max(8, width ~/ 24);
  // Pixels this much darker than their neighbourhood become ink. Too small and
  // blank paper turns to noise; too large and thin strokes disappear.
  const double tolerance = 0.86;

  for (int y = 0; y < height; y++) {
    final int y0 = math.max(0, y - radius);
    final int y1 = math.min(height - 1, y + radius);
    for (int x = 0; x < width; x++) {
      final int x0 = math.max(0, x - radius);
      final int x1 = math.min(width - 1, x + radius);
      final int count = (x1 - x0 + 1) * (y1 - y0 + 1);
      final int sum =
          integral[(y1 + 1) * (width + 1) + (x1 + 1)] -
          integral[y0 * (width + 1) + (x1 + 1)] -
          integral[(y1 + 1) * (width + 1) + x0] +
          integral[y0 * (width + 1) + x0];

      final int index = (y * width + x) * 3;
      final int value = pixels[index] * count < sum * tolerance ? 0 : 255;
      pixels[index] = value;
      pixels[index + 1] = value;
      pixels[index + 2] = value;
    }
  }
}

/// Locates the page in a photo by separating it from its background.
///
/// Documents are photographed as a bright rectangle on a darker surface, so an
/// Otsu split followed by the largest bright blob finds them without any edge
/// tracing. The result is the blob's bounding box, i.e. an upright rectangle —
/// it removes the surrounding desk, and the user adjusts the corners by hand
/// when the shot was taken at a real angle.
List<double>? _detectInIsolate(Uint8List bytes) {
  final img.Image? decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final img.Image baked = img.bakeOrientation(decoded);

  const int workingEdge = 320;
  final int longest = math.max(baked.width, baked.height);
  final double scale = longest > workingEdge ? workingEdge / longest : 1.0;
  final img.Image small = scale < 1.0
      ? img.copyResize(
          baked,
          width: math.max(2, (baked.width * scale).round()),
          height: math.max(2, (baked.height * scale).round()),
        )
      : baked;

  final int w = small.width;
  final int h = small.height;
  final Uint8List rgb = small.getBytes(order: img.ChannelOrder.rgb);
  final Uint8List gray = Uint8List(w * h);
  final Int32List histogram = Int32List(256);
  for (int i = 0, p = 0; i < rgb.length; i += 3, p++) {
    final int y = (rgb[i] * 0.299 + rgb[i + 1] * 0.587 + rgb[i + 2] * 0.114)
        .round()
        .clamp(0, 255);
    gray[p] = y;
    histogram[y]++;
  }

  final int threshold = _otsu(histogram, w * h);

  // Largest connected bright region, found with an explicit stack: a photo can
  // be 100k working pixels and recursion would blow the isolate's stack.
  final Uint8List visited = Uint8List(w * h);
  final Int32List stack = Int32List(w * h);
  int bestArea = 0;
  List<int>? bestBox;

  for (int start = 0; start < w * h; start++) {
    if (visited[start] == 1 || gray[start] <= threshold) continue;
    int top = 0;
    stack[top++] = start;
    visited[start] = 1;
    int area = 0;
    int minX = w, maxX = -1, minY = h, maxY = -1;

    while (top > 0) {
      final int p = stack[--top];
      final int px = p % w;
      final int py = p ~/ w;
      area++;
      if (px < minX) minX = px;
      if (px > maxX) maxX = px;
      if (py < minY) minY = py;
      if (py > maxY) maxY = py;

      if (px > 0 && visited[p - 1] == 0 && gray[p - 1] > threshold) {
        visited[p - 1] = 1;
        stack[top++] = p - 1;
      }
      if (px < w - 1 && visited[p + 1] == 0 && gray[p + 1] > threshold) {
        visited[p + 1] = 1;
        stack[top++] = p + 1;
      }
      if (py > 0 && visited[p - w] == 0 && gray[p - w] > threshold) {
        visited[p - w] = 1;
        stack[top++] = p - w;
      }
      if (py < h - 1 && visited[p + w] == 0 && gray[p + w] > threshold) {
        visited[p + w] = 1;
        stack[top++] = p + w;
      }
    }

    if (area > bestArea) {
      bestArea = area;
      bestBox = [minX, minY, maxX, maxY];
    }
  }

  if (bestBox == null) return null;

  final double boxWidth = (bestBox[2] - bestBox[0] + 1).toDouble();
  final double boxHeight = (bestBox[3] - bestBox[1] + 1).toDouble();
  final double coverage = (boxWidth * boxHeight) / (w * h);
  // Too small and it is a highlight, not a page; too large and it is the whole
  // photo, so cropping to it would gain nothing and risk shaving a margin.
  if (coverage < 0.12 || coverage > 0.97) return null;
  // The blob has to actually fill its own bounding box, or it is a scattering
  // of bright specks rather than a sheet of paper.
  if (bestArea / (boxWidth * boxHeight) < 0.65) return null;

  // Nudge outwards by half a percent so the page edge itself is not shaved off.
  const double bleed = 0.005;
  final double left = (bestBox[0] / w - bleed).clamp(0.0, 1.0);
  final double top = (bestBox[1] / h - bleed).clamp(0.0, 1.0);
  final double right = ((bestBox[2] + 1) / w + bleed).clamp(0.0, 1.0);
  final double bottom = ((bestBox[3] + 1) / h + bleed).clamp(0.0, 1.0);

  return ScanQuad.fromRect(left, top, right, bottom).toList();
}

/// Otsu's method: the grey level that best separates the histogram into two
/// classes.
int _otsu(Int32List histogram, int total) {
  if (total == 0) return 128;
  double sum = 0;
  for (int i = 0; i < 256; i++) {
    sum += i * histogram[i];
  }

  double sumBackground = 0;
  int weightBackground = 0;
  double bestVariance = -1;
  int best = 128;

  for (int t = 0; t < 256; t++) {
    weightBackground += histogram[t];
    if (weightBackground == 0) continue;
    final int weightForeground = total - weightBackground;
    if (weightForeground == 0) break;

    sumBackground += t * histogram[t];
    final double meanBackground = sumBackground / weightBackground;
    final double meanForeground = (sum - sumBackground) / weightForeground;
    final double variance =
        weightBackground *
        weightForeground *
        (meanBackground - meanForeground) *
        (meanBackground - meanForeground);
    if (variance > bestVariance) {
      bestVariance = variance;
      best = t;
    }
  }
  return best;
}

Future<Uint8List> _buildPdfInIsolate(
  List<Uint8List> pages,
  int sizeIndex,
) async {
  final ScanPageSize pageSize = ScanPageSize.values[sizeIndex];
  final PdfDocument document = PdfDocument();
  try {
    for (final Uint8List bytes in pages) {
      final PdfBitmap bitmap = PdfBitmap(bytes);
      final double imageWidth = bitmap.width.toDouble();
      final double imageHeight = bitmap.height.toDouble();
      final bool landscape = imageWidth > imageHeight;

      late final Size sheet;
      switch (pageSize) {
        case ScanPageSize.fitImage:
          // A4's long edge in points, so a scan lands at a familiar physical
          // size whatever the camera's pixel count was.
          const double longEdge = 842.0;
          final double k = longEdge / math.max(imageWidth, imageHeight);
          sheet = Size(imageWidth * k, imageHeight * k);
        case ScanPageSize.a4:
          sheet = landscape
              ? const Size(841.89, 595.28)
              : const Size(595.28, 841.89);
        case ScanPageSize.letter:
          sheet = landscape ? const Size(792, 612) : const Size(612, 792);
      }

      // One section per page, rather than one `document.pageSettings` for the
      // lot: those settings are frozen once the document has a page, and are
      // normalised to the document's orientation, so a batch mixing portrait
      // and landscape scans came out with every page shaped like the first.
      // Orientation is set before the size for the same reason — the size
      // setter sorts width and height to match the current orientation.
      final PdfSection section = document.sections!.add();
      section.pageSettings.margins.all = 0;
      section.pageSettings.orientation = landscape
          ? PdfPageOrientation.landscape
          : PdfPageOrientation.portrait;
      section.pageSettings.size = sheet;
      final PdfPage page = section.pages.add();

      // Contain rather than stretch, and centre what is left over: a scan of a
      // slightly different aspect ratio must not be squashed.
      final double fit = math.min(
        sheet.width / imageWidth,
        sheet.height / imageHeight,
      );
      final double drawWidth = imageWidth * fit;
      final double drawHeight = imageHeight * fit;
      page.graphics.drawImage(
        bitmap,
        Rect.fromLTWH(
          (sheet.width - drawWidth) / 2,
          (sheet.height - drawHeight) / 2,
          drawWidth,
          drawHeight,
        ),
      );
    }

    return Uint8List.fromList(await document.save());
  } finally {
    document.dispose();
  }
}
