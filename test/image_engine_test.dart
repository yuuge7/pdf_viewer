import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_viewer/services/image_engine.dart';

/// A picture of one colour.
Uint8List solid(int width, int height, int r, int g, int b, [int a = 255]) {
  final Uint8List px = Uint8List(width * height * 4);
  for (int at = 0; at < px.length; at += 4) {
    px[at] = r;
    px[at + 1] = g;
    px[at + 2] = b;
    px[at + 3] = a;
  }
  return px;
}

List<int> pixel(Uint8List px, int width, int x, int y) =>
    px.sublist((y * width + x) * 4, (y * width + x) * 4 + 4);

void main() {
  group('adjustments', () {
    test('none of them leaves every pixel as it was', () {
      final Uint8List px = solid(4, 4, 10, 120, 240);
      expect(ImageEngine.apply(px, 4, 4, Adjustments.none), px);
      expect(Adjustments.none.isNeutral, isTrue);
      expect(Adjustments(contrast: 0.1).isNeutral, isFalse);
    });

    test('the input is never written to', () {
      final Uint8List px = solid(4, 4, 100, 100, 100);
      ImageEngine.apply(px, 4, 4, Adjustments(brightness: 1, sharpen: 1));
      expect(px, solid(4, 4, 100, 100, 100));
    });

    test('each one moves a mid grey the way its name says', () {
      List<int> grey(Adjustments a) =>
          pixel(ImageEngine.apply(solid(3, 3, 128, 128, 128), 3, 3, a), 3, 1, 1);
      expect(grey(Adjustments(brightness: 0.5))[0], greaterThan(128));
      expect(grey(Adjustments(brightness: -0.5))[0], lessThan(128));
      expect(grey(Adjustments(exposure: 0.5))[0], greaterThan(128));
      expect(grey(Adjustments(shadows: 0.8))[0], greaterThan(128));
      expect(grey(Adjustments(highlights: -0.8))[0], lessThan(128));
      // Warm is more red and less blue; tint is away from green.
      final List<int> warm = grey(Adjustments(warmth: 0.6));
      expect(warm[0], greaterThan(warm[2]));
      final List<int> pink = grey(Adjustments(tint: 0.6));
      expect(pink[1], lessThan(pink[0]));
      // A grey has no colour to saturate or to turn.
      expect(grey(Adjustments(saturation: 1))[0], closeTo(128, 1));
      expect(grey(Adjustments(hue: 0.5)).sublist(0, 3), everyElement(closeTo(128, 2)));
    });

    test('contrast spreads tones apart about the middle', () {
      List<int> at(int v, double c) => pixel(
        ImageEngine.apply(solid(2, 2, v, v, v), 2, 2, Adjustments(contrast: c)),
        2,
        0,
        0,
      );
      expect(at(200, 0.5)[0], greaterThan(200));
      expect(at(60, 0.5)[0], lessThan(60));
      expect(at(200, -0.5)[0], lessThan(200));
    });

    test('saturation takes colour away and puts it back', () {
      final Uint8List px = solid(2, 2, 200, 100, 50);
      final List<int> none = pixel(
        ImageEngine.apply(px, 2, 2, Adjustments(saturation: -1)),
        2,
        0,
        0,
      );
      expect(none[0], closeTo(none[1], 1));
      expect(none[1], closeTo(none[2], 1));
      final List<int> more = pixel(
        ImageEngine.apply(px, 2, 2, Adjustments(saturation: 0.5)),
        2,
        0,
        0,
      );
      expect(more[0] - more[2], greaterThan(150));
    });

    test('vignette darkens the corners and spares the middle', () {
      final Uint8List out = ImageEngine.apply(
        solid(21, 21, 200, 200, 200),
        21,
        21,
        Adjustments(vignette: 1),
      );
      expect(pixel(out, 21, 10, 10)[0], 200);
      expect(pixel(out, 21, 0, 0)[0], lessThan(80));
    });

    test('sharpen raises an edge and leaves flat areas flat', () {
      final Uint8List px = solid(6, 3, 100, 100, 100);
      for (int y = 0; y < 3; y++) {
        for (int x = 3; x < 6; x++) {
          px[(y * 6 + x) * 4] = 160;
        }
      }
      final Uint8List out = ImageEngine.apply(
        px,
        6,
        3,
        Adjustments(sharpen: 1),
      );
      expect(pixel(out, 6, 3, 1)[0], greaterThan(160));
      expect(pixel(out, 6, 2, 1)[0], lessThan(100));
      expect(pixel(out, 6, 1, 1)[0], 100);
    });

    test('alpha is never touched', () {
      final Uint8List out = ImageEngine.apply(
        solid(3, 3, 50, 60, 70, 99),
        3,
        3,
        Adjustments(brightness: 0.4, saturation: 0.4, vignette: 0.5, sharpen: 1),
        filter: photoLooks.last,
      );
      for (int at = 3; at < out.length; at += 4) {
        expect(out[at], 99);
      }
    });
  });

  group('looks', () {
    test('there are twenty-two besides the original, each with its own name', () {
      expect(photoLooks.first.name, 'Original');
      expect(photoLooks.length - 1, 22);
      expect(photoLooks.map((l) => l.name).toSet(), hasLength(photoLooks.length));
    });

    test('the original changes nothing and the rest change something', () {
      final Uint8List px = Uint8List(8 * 8 * 4);
      for (int i = 0; i < 64; i++) {
        px[i * 4] = i * 4;
        px[i * 4 + 1] = 255 - i * 3;
        px[i * 4 + 2] = (i * 7) % 256;
        px[i * 4 + 3] = 255;
      }
      expect(
        ImageEngine.apply(px, 8, 8, Adjustments.none, filter: photoLooks.first),
        px,
      );
      for (final PhotoLook look in photoLooks.skip(1)) {
        expect(
          ImageEngine.apply(px, 8, 8, Adjustments.none, filter: look),
          isNot(px),
          reason: look.name,
        );
      }
    });

    test('mono has no colour left', () {
      final PhotoLook mono = photoLooks.firstWhere((l) => l.name == 'Mono');
      final List<int> out = pixel(
        ImageEngine.apply(
          solid(2, 2, 220, 40, 90),
          2,
          2,
          Adjustments.none,
          filter: mono,
        ),
        2,
        0,
        0,
      );
      expect(out[0], closeTo(out[1], 1));
      expect(out[1], closeTo(out[2], 1));
    });
  });

  group('hiding part of a picture', () {
    Uint8List checker() {
      final Uint8List px = Uint8List(16 * 16 * 4);
      for (int y = 0; y < 16; y++) {
        for (int x = 0; x < 16; x++) {
          final int v = (x + y).isEven ? 255 : 0;
          final int at = (y * 16 + x) * 4;
          px[at] = v;
          px[at + 1] = v;
          px[at + 2] = v;
          px[at + 3] = 255;
        }
      }
      return px;
    }

    test('blur smooths inside the block and nothing outside it', () {
      final Uint8List px = checker();
      ImageEngine.blur(px, 16, 16, 4, 4, 12, 12, 3);
      expect(pixel(px, 16, 8, 8)[0], inInclusiveRange(90, 165));
      expect(pixel(px, 16, 0, 0)[0], 255);
      expect(pixel(px, 16, 13, 12)[0], 0);
    });

    test('pixelate makes squares of one colour', () {
      final Uint8List px = checker();
      ImageEngine.pixelate(px, 16, 16, 0, 0, 8, 8, 4);
      final List<int> first = pixel(px, 16, 0, 0);
      for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
          expect(pixel(px, 16, x, y), first);
        }
      }
      expect(first[0], inInclusiveRange(120, 135));
      expect(pixel(px, 16, 9, 0)[0], 0);
    });

    test('a block that hangs off the picture is clipped, not an error', () {
      final Uint8List px = checker();
      ImageEngine.blur(px, 16, 16, -5, 10, 40, 40, 4);
      ImageEngine.pixelate(px, 16, 16, 12, -3, 99, 6, 5);
      expect(px.length, 16 * 16 * 4);
    });
  });

  group('background removal', () {
    /// A dark square in the middle of a light, slightly uneven backdrop.
    Uint8List subject() {
      final Uint8List px = Uint8List(40 * 40 * 4);
      for (int y = 0; y < 40; y++) {
        for (int x = 0; x < 40; x++) {
          final bool inside = x >= 12 && x < 28 && y >= 12 && y < 28;
          final int at = (y * 40 + x) * 4;
          final int shade = 235 + (x % 3) * 4;
          px[at] = inside ? 30 : shade;
          px[at + 1] = inside ? 60 : shade;
          px[at + 2] = inside ? 160 : shade;
          px[at + 3] = 255;
        }
      }
      return px;
    }

    test('clears the backdrop and keeps what stands on it', () {
      final Uint8List px = subject();
      final double removed = ImageEngine.removeBackground(px, 40, 40);
      expect(removed, closeTo(1 - (16 * 16) / (40 * 40), 0.02));
      expect(pixel(px, 40, 0, 0)[3], 0);
      expect(pixel(px, 40, 39, 20)[3], 0);
      expect(pixel(px, 40, 20, 20)[3], 255);
      expect(pixel(px, 40, 20, 20).sublist(0, 3), [30, 60, 160]);
    });

    test('light areas the edges cannot reach are kept', () {
      final Uint8List px = subject();
      // A light hole inside the subject.
      for (int y = 18; y < 22; y++) {
        for (int x = 18; x < 22; x++) {
          final int at = (y * 40 + x) * 4;
          px[at] = 240;
          px[at + 1] = 240;
          px[at + 2] = 240;
        }
      }
      ImageEngine.removeBackground(px, 40, 40);
      expect(pixel(px, 40, 19, 19)[3], 255);
    });

    test('a low tolerance removes less', () {
      final Uint8List strict = subject(), loose = subject();
      final double a = ImageEngine.removeBackground(strict, 40, 40, tolerance: 0.02);
      final double b = ImageEngine.removeBackground(loose, 40, 40, tolerance: 0.5);
      expect(a, lessThan(b));
    });
  });

  group('sizes and files', () {
    test('downscaling averages, and never upscales', () {
      final Uint8List px = solid(8, 8, 0, 0, 0);
      for (int at = 0; at < px.length; at += 8) {
        px[at] = 200; // Every other pixel.
      }
      final Uint8List half = ImageEngine.downscale(px, 8, 8, 4, 4);
      expect(half.length, 4 * 4 * 4);
      expect(pixel(half, 4, 1, 1)[0], inInclusiveRange(60, 140));
      expect(ImageEngine.downscale(px, 8, 8, 16, 16), px);
    });

    test('premultiplying scales colour by alpha', () {
      final Uint8List out = ImageEngine.premultiplied(solid(1, 1, 200, 100, 50, 128));
      expect(out, [100, 50, 25, 128]);
    });

    test('PNG keeps transparency; JPEG lays the picture on white', () {
      final Uint8List px = solid(4, 4, 255, 0, 0, 0);
      final img.Image png = img.decodePng(
        ImageEngine.encode(px, 4, 4, png: true),
      )!;
      expect(png.getPixel(0, 0).a, 0);
      final img.Image jpg = img.decodeJpg(
        ImageEngine.encode(px, 4, 4, png: false, quality: 95),
      )!;
      expect(jpg.getPixel(1, 1).r, greaterThan(240));
      expect(jpg.getPixel(1, 1).g, greaterThan(240));
    });

    test('a file with no camera data has none to show', () {
      final Uint8List jpg = ImageEngine.encode(
        solid(4, 4, 1, 2, 3),
        4,
        4,
        png: false,
      );
      expect(ImageEngine.readExif(jpg), isEmpty);
      expect(ImageEngine.readExif(Uint8List.fromList([1, 2, 3])), isEmpty);
    });

    test('camera data is read out under plain labels', () {
      final img.Image image = img.Image(width: 4, height: 4);
      image.exif.imageIfd['Make'] = 'Acme';
      image.exif.imageIfd['Model'] = 'Snap 2';
      final List<(String, String)> exif = ImageEngine.readExif(
        img.encodeJpg(image),
      );
      expect(exif, contains(('Camera make', 'Acme')));
      expect(exif, contains(('Camera model', 'Snap 2')));
      expect(ImageEngine.hasLocation(exif), isFalse);
    });
  });
}
