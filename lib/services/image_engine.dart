import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// One thing about a picture that a slider changes.
enum AdjustKind {
  brightness('Brightness'),
  contrast('Contrast'),
  exposure('Exposure'),
  highlights('Highlights'),
  shadows('Shadows'),
  saturation('Saturation'),
  vibrance('Vibrance'),
  warmth('Warmth'),
  tint('Tint'),
  hue('Hue'),
  fade('Fade', oneSided: true),
  sharpen('Sharpen', oneSided: true),
  vignette('Vignette', oneSided: true);

  final String label;

  /// Runs from 0 to 1 rather than from -1 to 1.
  final bool oneSided;

  const AdjustKind(this.label, {this.oneSided = false});
}

/// Every adjustment at once. Zero everywhere leaves a picture as it is.
class Adjustments {
  final List<double> _values;

  const Adjustments._(this._values);

  static const Adjustments none = Adjustments._([
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  ]);

  factory Adjustments({
    double brightness = 0,
    double contrast = 0,
    double exposure = 0,
    double highlights = 0,
    double shadows = 0,
    double saturation = 0,
    double vibrance = 0,
    double warmth = 0,
    double tint = 0,
    double hue = 0,
    double fade = 0,
    double sharpen = 0,
    double vignette = 0,
  }) => Adjustments._([
    brightness, contrast, exposure, highlights, shadows, saturation, //
    vibrance, warmth, tint, hue, fade, sharpen, vignette,
  ]);

  double operator [](AdjustKind kind) => _values[kind.index];

  Adjustments withValue(AdjustKind kind, double value) {
    final List<double> next = List<double>.of(_values);
    next[kind.index] = value.clamp(kind.oneSided ? 0.0 : -1.0, 1.0);
    return Adjustments._(next);
  }

  bool get isNeutral => _values.every((v) => v == 0);

  List<double> toList() => List<double>.of(_values);

  factory Adjustments.fromList(List<double> values) =>
      Adjustments._(List<double>.of(values));

  @override
  bool operator ==(Object other) {
    if (other is! Adjustments) return false;
    for (int i = 0; i < _values.length; i++) {
      if (other._values[i] != _values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_values);
}

/// A ready-made look: adjustments, and optionally a colour mix on top.
class PhotoLook {
  final String name;
  final Adjustments adjust;

  /// Three rows of red, green, blue and an offset: how each output channel
  /// is mixed from the input. Null leaves colours as the adjustments made
  /// them.
  final List<double>? mix;

  const PhotoLook(this.name, this.adjust, [this.mix]);
}

const List<double> _mono = [
  0.299, 0.587, 0.114, 0, //
  0.299, 0.587, 0.114, 0,
  0.299, 0.587, 0.114, 0,
];
const List<double> _sepia = [
  0.393, 0.769, 0.189, 0, //
  0.349, 0.686, 0.168, 0,
  0.272, 0.534, 0.131, 0,
];

/// A mix that leans every colour toward the given balance of channels.
List<double> _cast(double r, double g, double b) => [
  r, 0, 0, 0, //
  0, g, 0, 0,
  0, 0, b, 0,
];

/// The looks on offer, the first being "as it is".
final List<PhotoLook> photoLooks = [
  const PhotoLook('Original', Adjustments.none),
  PhotoLook('Vivid', Adjustments(saturation: 0.35, contrast: 0.15, vibrance: 0.3)),
  PhotoLook('Pop', Adjustments(saturation: 0.5, contrast: 0.3, sharpen: 0.3)),
  PhotoLook('Bright', Adjustments(exposure: 0.25, shadows: 0.3, vibrance: 0.2)),
  PhotoLook('Soft', Adjustments(contrast: -0.2, fade: 0.25, warmth: 0.1)),
  PhotoLook('Matte', Adjustments(fade: 0.5, contrast: -0.1, saturation: -0.15)),
  PhotoLook('Warm', Adjustments(warmth: 0.45, saturation: 0.1)),
  PhotoLook('Cool', Adjustments(warmth: -0.45, tint: -0.1)),
  PhotoLook('Dawn', Adjustments(warmth: 0.25, tint: 0.2, fade: 0.2, exposure: 0.1)),
  PhotoLook('Dusk', Adjustments(warmth: -0.15, tint: 0.25, contrast: 0.15, exposure: -0.1)),
  PhotoLook('Amber', Adjustments(contrast: 0.1), _cast(1.12, 1.0, 0.8)),
  PhotoLook('Rose', Adjustments(fade: 0.15), _cast(1.1, 0.93, 0.98)),
  PhotoLook('Forest', Adjustments(contrast: 0.1, saturation: -0.1), _cast(0.92, 1.06, 0.9)),
  PhotoLook('Ocean', Adjustments(contrast: 0.1), _cast(0.88, 1.0, 1.14)),
  PhotoLook('Film', Adjustments(contrast: 0.2, saturation: -0.2, fade: 0.2, vignette: 0.3)),
  PhotoLook('Retro', Adjustments(fade: 0.3, warmth: 0.3, saturation: -0.25, vignette: 0.25)),
  PhotoLook('Chrome', Adjustments(contrast: 0.35, saturation: -0.3, highlights: 0.2)),
  PhotoLook('Dramatic', Adjustments(contrast: 0.5, shadows: -0.3, vignette: 0.45, saturation: -0.1)),
  PhotoLook('Cinema', Adjustments(contrast: 0.25, warmth: 0.15, vignette: 0.35), _cast(1.04, 1.0, 0.92)),
  PhotoLook('Mono', Adjustments(contrast: 0.1), _mono),
  PhotoLook('Noir', Adjustments(contrast: 0.55, vignette: 0.4), _mono),
  PhotoLook('Silver', Adjustments(fade: 0.3, exposure: 0.1), _mono),
  PhotoLook('Sepia', Adjustments(fade: 0.1), _sepia),
];

/// Pixel work on pictures held as flat RGBA bytes.
///
/// Everything here is plain arithmetic on a `Uint8List`, free of Flutter
/// and of platform channels, so it runs in an isolate and under test. The
/// `image` package's per-pixel API is not used for the loops: it is an
/// order of magnitude slower than indexing the bytes.
class ImageEngine {
  /// [rgba] with [adjust] and then [filter] applied, as a new buffer.
  static Uint8List apply(
    Uint8List rgba,
    int width,
    int height,
    Adjustments adjust, {
    PhotoLook? filter,
  }) {
    Uint8List out = Uint8List.fromList(rgba);
    if (!adjust.isNeutral) out = _adjust(out, width, height, adjust);
    if (filter != null) {
      if (!filter.adjust.isNeutral) {
        out = _adjust(out, width, height, filter.adjust);
      }
      final List<double>? mix = filter.mix;
      if (mix != null) _mix(out, mix);
    }
    return out;
  }

  static int _byte(double v) => v <= 0
      ? 0
      : v >= 255
      ? 255
      : v.round();

  static Uint8List _adjust(Uint8List px, int width, int height, Adjustments a) {
    final double brightness = a[AdjustKind.brightness];
    final double contrast = a[AdjustKind.contrast];
    final double exposure = a[AdjustKind.exposure];
    final double fade = a[AdjustKind.fade];
    final double highlights = a[AdjustKind.highlights];
    final double shadows = a[AdjustKind.shadows];
    final double saturation = a[AdjustKind.saturation];
    final double vibrance = a[AdjustKind.vibrance];
    final double warmth = a[AdjustKind.warmth];
    final double tint = a[AdjustKind.tint];
    final double hue = a[AdjustKind.hue];
    final double vignette = a[AdjustKind.vignette];
    final double sharpen = a[AdjustKind.sharpen];

    // What treats every channel alike goes into one table, looked up
    // three times per pixel instead of being worked out three times.
    final Float32List tone = Float32List(256);
    final double gain = math.pow(2, exposure * 1.5).toDouble();
    final double slope = contrast >= 0 ? 1 + contrast * 1.5 : 1 + contrast * 0.75;
    for (int i = 0; i < 256; i++) {
      double v = i * gain;
      v += brightness * 90;
      v = (v - 127.5) * slope + 127.5;
      // Fade lifts the blacks and takes the edge off the whites.
      v = v * (1 - fade * 0.35) + fade * 52;
      tone[i] = v;
    }

    final bool tonal = highlights != 0 || shadows != 0;
    final bool chroma = saturation != 0 || vibrance != 0;
    final bool cast = warmth != 0 || tint != 0;
    final bool turn = hue != 0;
    final bool dim = vignette != 0;

    // Rotating hue is a rotation about the grey axis.
    final double angle = hue * math.pi;
    final double cosA = math.cos(angle), sinA = math.sin(angle);
    const double k = 0.57735; // 1/sqrt(3)
    final double t = (1 - cosA) / 3;
    final double h00 = cosA + t, h01 = t - k * sinA, h02 = t + k * sinA;
    final double h10 = t + k * sinA, h11 = cosA + t, h12 = t - k * sinA;
    final double h20 = t - k * sinA, h21 = t + k * sinA, h22 = cosA + t;

    final double cx = (width - 1) / 2, cy = (height - 1) / 2;
    final double reach = math.sqrt(cx * cx + cy * cy);

    int at = 0;
    for (int y = 0; y < height; y++) {
      final double dy = (y - cy);
      for (int x = 0; x < width; x++, at += 4) {
        double r = tone[px[at]];
        double g = tone[px[at + 1]];
        double b = tone[px[at + 2]];

        if (tonal || chroma) {
          final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
          if (tonal) {
            final double l = (luma / 255).clamp(0.0, 1.0);
            // Each acts where its name says and tails off elsewhere.
            final double lift =
                shadows * 110 * (1 - l) * (1 - l) + highlights * 110 * l * l;
            r += lift;
            g += lift;
            b += lift;
          }
          if (chroma) {
            final double grey = tonal
                ? 0.299 * r + 0.587 * g + 0.114 * b
                : luma;
            double amount = 1 + saturation;
            if (vibrance != 0) {
              final double hi = math.max(r, math.max(g, b));
              final double lo = math.min(r, math.min(g, b));
              // Vibrance leaves what is already vivid alone.
              amount *= 1 + vibrance * (1 - ((hi - lo) / 255).clamp(0.0, 1.0));
            }
            r = grey + (r - grey) * amount;
            g = grey + (g - grey) * amount;
            b = grey + (b - grey) * amount;
          }
        }
        if (cast) {
          r += warmth * 30 + tint * 12;
          g -= tint * 22;
          b += tint * 12 - warmth * 30;
        }
        if (turn) {
          final double nr = r * h00 + g * h01 + b * h02;
          final double ng = r * h10 + g * h11 + b * h12;
          final double nb = r * h20 + g * h21 + b * h22;
          r = nr;
          g = ng;
          b = nb;
        }
        if (dim) {
          final double dx = (x - cx);
          final double d = reach == 0 ? 0 : math.sqrt(dx * dx + dy * dy) / reach;
          // Clear in the middle, falling away toward the corners.
          final double edge = ((d - 0.35) / 0.65).clamp(0.0, 1.0);
          final double f = 1 - vignette * 0.85 * edge * edge * (3 - 2 * edge);
          r *= f;
          g *= f;
          b *= f;
        }
        px[at] = _byte(r);
        px[at + 1] = _byte(g);
        px[at + 2] = _byte(b);
      }
    }
    return sharpen > 0 ? _sharpen(px, width, height, sharpen) : px;
  }

  static void _mix(Uint8List px, List<double> m) {
    for (int at = 0; at < px.length; at += 4) {
      final int r = px[at], g = px[at + 1], b = px[at + 2];
      px[at] = _byte(r * m[0] + g * m[1] + b * m[2] + m[3]);
      px[at + 1] = _byte(r * m[4] + g * m[5] + b * m[6] + m[7]);
      px[at + 2] = _byte(r * m[8] + g * m[9] + b * m[10] + m[11]);
    }
  }

  /// Each pixel pushed away from the average of its four neighbours.
  static Uint8List _sharpen(Uint8List px, int width, int height, double amount) {
    final Uint8List out = Uint8List.fromList(px);
    final double a = amount * 0.7;
    final int stride = width * 4;
    for (int y = 1; y < height - 1; y++) {
      int at = y * stride + 4;
      for (int x = 1; x < width - 1; x++, at += 4) {
        for (int c = 0; c < 3; c++) {
          final int i = at + c;
          final double v =
              px[i] * (1 + 4 * a) -
              a * (px[i - 4] + px[i + 4] + px[i - stride] + px[i + stride]);
          out[i] = _byte(v);
        }
      }
    }
    return out;
  }

  /// [px] shrunk to [outWidth] by [outHeight], each new pixel the average
  /// of the block it stands for.
  static Uint8List downscale(
    Uint8List px,
    int width,
    int height,
    int outWidth,
    int outHeight,
  ) {
    if (outWidth >= width && outHeight >= height) return Uint8List.fromList(px);
    final Uint8List out = Uint8List(outWidth * outHeight * 4);
    for (int oy = 0; oy < outHeight; oy++) {
      final int y0 = oy * height ~/ outHeight;
      final int y1 = math.max(y0 + 1, (oy + 1) * height ~/ outHeight);
      for (int ox = 0; ox < outWidth; ox++) {
        final int x0 = ox * width ~/ outWidth;
        final int x1 = math.max(x0 + 1, (ox + 1) * width ~/ outWidth);
        int r = 0, g = 0, b = 0, a = 0, n = 0;
        // A few samples a block is as good as all of them at this size.
        final int stepY = math.max(1, (y1 - y0) ~/ 3);
        final int stepX = math.max(1, (x1 - x0) ~/ 3);
        for (int y = y0; y < y1; y += stepY) {
          for (int x = x0; x < x1; x += stepX) {
            final int at = (y * width + x) * 4;
            r += px[at];
            g += px[at + 1];
            b += px[at + 2];
            a += px[at + 3];
            n++;
          }
        }
        final int to = (oy * outWidth + ox) * 4;
        out[to] = r ~/ n;
        out[to + 1] = g ~/ n;
        out[to + 2] = b ~/ n;
        out[to + 3] = a ~/ n;
      }
    }
    return out;
  }

  /// [px] with colour scaled by alpha, which is how a screen wants pixels
  /// and not how a file stores them.
  static Uint8List premultiplied(Uint8List px) {
    final Uint8List out = Uint8List.fromList(px);
    for (int at = 0; at < out.length; at += 4) {
      final int a = out[at + 3];
      if (a == 255) continue;
      out[at] = out[at] * a ~/ 255;
      out[at + 1] = out[at + 1] * a ~/ 255;
      out[at + 2] = out[at + 2] * a ~/ 255;
    }
    return out;
  }

  /// Encodes straight RGBA as a PNG, or as a JPEG of [quality] laid on
  /// white, since a JPEG has no transparency to keep.
  static Uint8List encode(
    Uint8List px,
    int width,
    int height, {
    required bool png,
    int quality = 90,
  }) {
    final img.Image image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: px.buffer,
      bytesOffset: px.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    if (png) return img.encodePng(image);
    final img.Image flat = img.Image(width: width, height: height);
    img.fill(flat, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(flat, image);
    return img.encodeJpg(flat, quality: quality.clamp(10, 100));
  }

  /// Blurs the block of pixels from ([left], [top]) up to but not including
  /// ([right], [bottom]), in place. [radius] is how far each pixel spreads.
  static void blur(
    Uint8List px,
    int width,
    int height,
    int left,
    int top,
    int right,
    int bottom,
    int radius,
  ) {
    final int l = left.clamp(0, width), r = right.clamp(0, width);
    final int t = top.clamp(0, height), b = bottom.clamp(0, height);
    final int w = r - l, h = b - t;
    if (w < 2 || h < 2 || radius < 1) return;
    final Uint8List line = Uint8List(math.max(w, h) * 4);
    // Three box passes each way come close to a true Gaussian.
    for (int pass = 0; pass < 3; pass++) {
      for (int y = t; y < b; y++) {
        _boxLine(px, (y * width + l) * 4, 4, w, radius, line);
      }
      for (int x = l; x < r; x++) {
        _boxLine(px, (t * width + x) * 4, width * 4, h, radius, line);
      }
    }
  }

  /// A running average along one row or column of [count] pixels, [step]
  /// bytes apart, starting at [start].
  static void _boxLine(
    Uint8List px,
    int start,
    int step,
    int count,
    int radius,
    Uint8List scratch,
  ) {
    for (int c = 0; c < 4; c++) {
      for (int i = 0; i < count; i++) {
        scratch[i * 4 + c] = px[start + i * step + c];
      }
    }
    for (int c = 0; c < 4; c++) {
      int sum = 0;
      int n = 0;
      for (int i = 0; i <= radius && i < count; i++) {
        sum += scratch[i * 4 + c];
        n++;
      }
      for (int i = 0; i < count; i++) {
        px[start + i * step + c] = (sum / n).round();
        final int add = i + radius + 1;
        if (add < count) {
          sum += scratch[add * 4 + c];
          n++;
        }
        final int drop = i - radius;
        if (drop >= 0) {
          sum -= scratch[drop * 4 + c];
          n--;
        }
      }
    }
  }

  /// Replaces the block with squares [block] pixels across, each the
  /// average of what it covers. In place.
  static void pixelate(
    Uint8List px,
    int width,
    int height,
    int left,
    int top,
    int right,
    int bottom,
    int block,
  ) {
    final int l = left.clamp(0, width), r = right.clamp(0, width);
    final int t = top.clamp(0, height), b = bottom.clamp(0, height);
    final int size = math.max(2, block);
    for (int by = t; by < b; by += size) {
      for (int bx = l; bx < r; bx += size) {
        final int ex = math.min(r, bx + size), ey = math.min(b, by + size);
        int sr = 0, sg = 0, sb = 0, sa = 0, n = 0;
        for (int y = by; y < ey; y++) {
          int at = (y * width + bx) * 4;
          for (int x = bx; x < ex; x++, at += 4) {
            sr += px[at];
            sg += px[at + 1];
            sb += px[at + 2];
            sa += px[at + 3];
            n++;
          }
        }
        if (n == 0) continue;
        final int ar = sr ~/ n, ag = sg ~/ n, ab = sb ~/ n, aa = sa ~/ n;
        for (int y = by; y < ey; y++) {
          int at = (y * width + bx) * 4;
          for (int x = bx; x < ex; x++, at += 4) {
            px[at] = ar;
            px[at + 1] = ag;
            px[at + 2] = ab;
            px[at + 3] = aa;
          }
        }
      }
    }
  }

  /// Makes the background transparent: everything that can be reached from
  /// the picture's edges through pixels close in colour to the edges.
  ///
  /// This is colour, not understanding. A product on a plain backdrop comes
  /// out clean; a person in a busy room does not. [tolerance] (0..1) is
  /// how different from the backdrop a pixel may be and still go. Returns
  /// the fraction of the picture that was removed.
  static double removeBackground(
    Uint8List px,
    int width,
    int height, {
    double tolerance = 0.25,
  }) {
    if (width < 3 || height < 3) return 0;
    // The backdrop's colour, as the edges show it.
    int sr = 0, sg = 0, sb = 0, n = 0;
    void sample(int x, int y) {
      final int at = (y * width + x) * 4;
      sr += px[at];
      sg += px[at + 1];
      sb += px[at + 2];
      n++;
    }

    for (int x = 0; x < width; x++) {
      sample(x, 0);
      sample(x, height - 1);
    }
    for (int y = 0; y < height; y++) {
      sample(0, y);
      sample(width - 1, y);
    }
    final int mr = sr ~/ n, mg = sg ~/ n, mb = sb ~/ n;

    final double t = tolerance.clamp(0.02, 1.0);
    // Squared distances: far from the backdrop overall, and a jump from the
    // neighbour that was already taken.
    final int farLimit = (t * 300 * t * 300).round();
    final int stepLimit = (t * 110 * t * 110).round();

    final Uint8List state = Uint8List(width * height); // 1 queued, 2 removed
    final Int32List stack = Int32List(width * height);
    int top = 0;

    bool near(int at) {
      final int dr = px[at] - mr, dg = px[at + 1] - mg, db = px[at + 2] - mb;
      return dr * dr + dg * dg + db * db <= farLimit;
    }

    void seed(int x, int y) {
      final int i = y * width + x;
      if (state[i] != 0 || !near(i * 4)) return;
      state[i] = 1;
      stack[top++] = i;
    }

    for (int x = 0; x < width; x++) {
      seed(x, 0);
      seed(x, height - 1);
    }
    for (int y = 0; y < height; y++) {
      seed(0, y);
      seed(width - 1, y);
    }

    int removed = 0;
    while (top > 0) {
      final int i = stack[--top];
      state[i] = 2;
      removed++;
      final int at = i * 4;
      final int x = i % width, y = i ~/ width;
      void visit(int nx, int ny) {
        if (nx < 0 || ny < 0 || nx >= width || ny >= height) return;
        final int j = ny * width + nx;
        if (state[j] != 0) return;
        final int nat = j * 4;
        final int dr = px[nat] - px[at];
        final int dg = px[nat + 1] - px[at + 1];
        final int db = px[nat + 2] - px[at + 2];
        if (dr * dr + dg * dg + db * db > stepLimit || !near(nat)) return;
        state[j] = 1;
        stack[top++] = j;
      }

      visit(x - 1, y);
      visit(x + 1, y);
      visit(x, y - 1);
      visit(x, y + 1);
    }

    for (int i = 0; i < state.length; i++) {
      if (state[i] != 2) continue;
      px[i * 4 + 3] = 0;
    }
    // Soften the cut by one pixel, so the edge is not a staircase.
    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        final int i = y * width + x;
        if (state[i] == 2) continue;
        final int gone =
            (state[i - 1] == 2 ? 1 : 0) +
            (state[i + 1] == 2 ? 1 : 0) +
            (state[i - width] == 2 ? 1 : 0) +
            (state[i + width] == 2 ? 1 : 0);
        if (gone > 0) {
          px[i * 4 + 3] = (px[i * 4 + 3] * (4 - gone) / 4).round();
        }
      }
    }
    return removed / (width * height);
  }

  /// What the camera wrote into a JPEG about itself, as label and value,
  /// in an order worth reading. Empty for a file with none.
  static List<(String, String)> readExif(Uint8List file) {
    final img.ExifData? exif;
    try {
      exif = img.decodeJpgExif(file);
    } catch (_) {
      return const [];
    }
    if (exif == null || exif.isEmpty) return const [];

    final Map<String, String> found = {};
    void collect(img.IfdDirectory directory, Map<int, img.ExifTag> names) {
      for (final int id in directory.keys) {
        final String? name = names[id]?.name;
        final String value = directory[id]?.toString().trim() ?? '';
        if (name == null || value.isEmpty || value.length > 120) continue;
        found.putIfAbsent(name, () => value);
      }
    }

    try {
      collect(exif.imageIfd, img.exifImageTags);
      collect(exif.exifIfd, img.exifImageTags);
      collect(exif.gpsIfd, img.exifGpsTags);
    } catch (_) {
      // A damaged block: show what was read before it gave out.
    }

    const Map<String, String> wanted = {
      'Make': 'Camera make',
      'Model': 'Camera model',
      'LensModel': 'Lens',
      'DateTimeOriginal': 'Taken',
      'DateTime': 'Changed',
      'ExposureTime': 'Shutter',
      'FNumber': 'Aperture',
      'ISOSpeedRatings': 'ISO',
      'ISOSpeed': 'ISO',
      'FocalLength': 'Focal length',
      'Flash': 'Flash',
      'Orientation': 'Orientation',
      'Software': 'Software',
      'Artist': 'Artist',
      'Copyright': 'Copyright',
      'GPSLatitude': 'Latitude',
      'GPSLatitudeRef': 'Latitude side',
      'GPSLongitude': 'Longitude',
      'GPSLongitudeRef': 'Longitude side',
      'GPSAltitude': 'Altitude',
    };
    final List<(String, String)> out = [];
    final Set<String> used = {};
    wanted.forEach((tag, label) {
      final String? value = found[tag];
      if (value != null && used.add(label)) out.add((label, value));
    });
    return out;
  }

  /// Whether [file] says where it was taken.
  static bool hasLocation(List<(String, String)> exif) =>
      exif.any((e) => e.$1 == 'Latitude' || e.$1 == 'Longitude');
}
