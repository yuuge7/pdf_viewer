import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf_viewer/services/scan_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Draws a bright rectangle on a dark background, which is what a photo of a
/// page on a desk looks like to the detector.
Uint8List syntheticPhoto({
  int width = 400,
  int height = 300,
  required int left,
  required int top,
  required int right,
  required int bottom,
}) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(20, 20, 24));
  img.fillRect(
    image,
    x1: left,
    y1: top,
    x2: right,
    y2: bottom,
    color: img.ColorRgb8(238, 238, 236),
  );
  return img.encodePng(image);
}

Future<File> writeTemp(Directory dir, String name, Uint8List bytes) async {
  final File file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('scan_service_test');
    // ScanService writes finished PDFs to the app documents directory, which
    // has no implementation under `flutter test`; point it at the scratch
    // directory so the file-writing half of buildPdf is exercised too.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => temp.path,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  group('ScanQuad', () {
    test('survives the round trip through its flat form', () {
      const ScanQuad quad = ScanQuad(
        topLeft: Offset(0.1, 0.2),
        topRight: Offset(0.9, 0.15),
        bottomRight: Offset(0.85, 0.95),
        bottomLeft: Offset(0.05, 0.9),
      );

      expect(ScanQuad.fromList(quad.toList()), quad);
    });

    test('recognises the untouched full image', () {
      expect(ScanQuad.full.isFull, isTrue);
      expect(ScanQuad.fromRect(0, 0, 1, 1).isFull, isTrue);
      expect(ScanQuad.fromRect(0.1, 0, 1, 1).isFull, isFalse);
    });

    test('replaces one corner and leaves the rest alone', () {
      final ScanQuad moved = ScanQuad.full.withCorner(
        2,
        const Offset(0.5, 0.5),
      );

      expect(moved.bottomRight, const Offset(0.5, 0.5));
      expect(moved.topLeft, ScanQuad.full.topLeft);
      expect(moved.topRight, ScanQuad.full.topRight);
      expect(moved.bottomLeft, ScanQuad.full.bottomLeft);
    });
  });

  group('render', () {
    test('crops to the quad and keeps its proportions', () async {
      // A 400x300 photo; the quad selects a 200x100 axis-aligned region, so
      // the straightened result must come out twice as wide as it is tall.
      final File photo = await writeTemp(
        temp,
        'photo.png',
        syntheticPhoto(left: 100, top: 100, right: 299, bottom: 199),
      );

      final Uint8List? rendered = await ScanService.render(
        ScanPage(
          sourcePath: photo.path,
          quad: ScanQuad.fromRect(0.25, 1 / 3, 0.75, 2 / 3),
          filter: ScanFilter.original,
        ),
      );

      expect(rendered, isNotNull);
      final img.Image decoded = img.decodeImage(rendered!)!;
      expect(decoded.width / decoded.height, closeTo(2.0, 0.05));
    });

    test('rotating a quarter turn swaps the output axes', () async {
      final File photo = await writeTemp(
        temp,
        'photo.png',
        syntheticPhoto(left: 100, top: 100, right: 299, bottom: 199),
      );
      final ScanPage page = ScanPage(
        sourcePath: photo.path,
        quad: ScanQuad.fromRect(0.25, 1 / 3, 0.75, 2 / 3),
        filter: ScanFilter.original,
      );

      final img.Image upright = img.decodeImage(
        (await ScanService.render(page))!,
      )!;
      final img.Image turned = img.decodeImage(
        (await ScanService.render(page.copyWith(quarterTurns: 1)))!,
      )!;

      expect(turned.width, upright.height);
      expect(turned.height, upright.width);
    });

    test('never scales past the requested longest edge', () async {
      final File photo = await writeTemp(
        temp,
        'photo.png',
        syntheticPhoto(
          width: 1200,
          height: 900,
          left: 0,
          top: 0,
          right: 1199,
          bottom: 899,
        ),
      );

      final Uint8List? rendered = await ScanService.render(
        ScanPage(sourcePath: photo.path, filter: ScanFilter.original),
        maxEdge: 300,
      );

      final img.Image decoded = img.decodeImage(rendered!)!;
      expect(decoded.width, lessThanOrEqualTo(300));
      expect(decoded.height, lessThanOrEqualTo(300));
    });

    test('black and white leaves only two tones', () async {
      final File photo = await writeTemp(
        temp,
        'photo.png',
        syntheticPhoto(left: 40, top: 40, right: 359, bottom: 259),
      );

      final Uint8List? rendered = await ScanService.render(
        ScanPage(sourcePath: photo.path, filter: ScanFilter.blackAndWhite),
        maxEdge: 200,
      );

      final img.Image decoded = img.decodeImage(rendered!)!;
      // JPEG is lossy, so the tones cluster near 0 and 255 rather than
      // landing on them exactly; anything in the middle would mean the
      // threshold never ran.
      int midtones = 0;
      int total = 0;
      for (final img.Pixel pixel in decoded) {
        total++;
        final int value = pixel.r.round();
        if (value > 70 && value < 185) midtones++;
      }
      expect(midtones / total, lessThan(0.1));
    });

    test(
      'reports failure rather than throwing on a file that is not an image',
      () async {
        final File notAnImage = await writeTemp(
          temp,
          'notes.txt',
          Uint8List.fromList('this is not a photograph'.codeUnits),
        );

        expect(
          await ScanService.render(ScanPage(sourcePath: notAnImage.path)),
          isNull,
        );
      },
    );
  });

  group('detectDocument', () {
    test('finds a page that fills part of the frame', () async {
      final File photo = await writeTemp(
        temp,
        'photo.png',
        syntheticPhoto(left: 80, top: 60, right: 319, bottom: 239),
      );

      final ScanQuad? quad = await ScanService.detectDocument(photo.path);

      expect(quad, isNotNull);
      // 80/400 = 0.2, 60/300 = 0.2, 320/400 = 0.8, 240/300 = 0.8, give or take
      // the working-resolution downscale and the deliberate outward bleed.
      expect(quad!.topLeft.dx, closeTo(0.2, 0.05));
      expect(quad.topLeft.dy, closeTo(0.2, 0.05));
      expect(quad.bottomRight.dx, closeTo(0.8, 0.05));
      expect(quad.bottomRight.dy, closeTo(0.8, 0.05));
    });

    test('declines when the page already fills the frame', () async {
      final File photo = await writeTemp(
        temp,
        'photo.png',
        syntheticPhoto(left: 0, top: 0, right: 399, bottom: 299),
      );

      // Cropping here could only shave a margin off a page that is already
      // framed, so leaving the crop alone is the right answer.
      expect(await ScanService.detectDocument(photo.path), isNull);
    });

    test('declines on a speck too small to be a page', () async {
      final File photo = await writeTemp(
        temp,
        'photo.png',
        syntheticPhoto(left: 190, top: 140, right: 210, bottom: 160),
      );

      expect(await ScanService.detectDocument(photo.path), isNull);
    });
  });

  group('buildPdf', () {
    /// Renders a page so the bytes are a real JPEG of known proportions.
    Future<Uint8List> page(int width, int height) async {
      final File photo = await writeTemp(
        temp,
        'p_${width}x$height.png',
        syntheticPhoto(
          width: width,
          height: height,
          left: 0,
          top: 0,
          right: width - 1,
          bottom: height - 1,
        ),
      );
      return (await ScanService.render(
        ScanPage(sourcePath: photo.path, filter: ScanFilter.original),
        maxEdge: 200,
      ))!;
    }

    test('writes one page per image', () async {
      final File? pdf = await ScanService.buildPdf([
        await page(200, 300),
        await page(300, 200),
      ], ScanPageSize.a4);

      expect(pdf, isNotNull);
      final PdfDocument document = PdfDocument(
        inputBytes: await pdf!.readAsBytes(),
      );
      addTearDown(document.dispose);
      expect(document.pages.count, 2);
    });

    test('A4 turns the sheet to match a landscape scan', () async {
      final File? pdf = await ScanService.buildPdf([
        await page(300, 200),
      ], ScanPageSize.a4);

      final PdfDocument document = PdfDocument(
        inputBytes: await pdf!.readAsBytes(),
      );
      addTearDown(document.dispose);
      final Size size = document.pages[0].size;
      expect(size.width, greaterThan(size.height));
      expect(size.width, closeTo(841.89, 1));
    });

    test('fit-to-scan gives the page the proportions of the image', () async {
      final File? pdf = await ScanService.buildPdf([
        await page(200, 400),
      ], ScanPageSize.fitImage);

      final PdfDocument document = PdfDocument(
        inputBytes: await pdf!.readAsBytes(),
      );
      addTearDown(document.dispose);
      final Size size = document.pages[0].size;
      expect(size.height / size.width, closeTo(2.0, 0.05));
    });

    test('returns null rather than an empty document', () async {
      expect(await ScanService.buildPdf([], ScanPageSize.a4), isNull);
    });
  });
}
