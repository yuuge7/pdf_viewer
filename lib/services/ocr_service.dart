import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'document_import.dart';
import 'document_service.dart';
import 'pdf_service.dart';
import 'pdf_stamps.dart';
import 'pdf_tools.dart';

/// The text read off one picture.
@immutable
class OcrPage {
  /// Lines in reading order, with bounds in the picture's own pixels.
  final List<TextLayerLine> lines;
  final Size imageSize;

  const OcrPage(this.lines, this.imageSize);

  String get text => lines.map((l) => l.text).join('\n');
}

/// What making a document searchable did.
@immutable
class OcrOutcome {
  /// The document with its text layer; null when nothing was recognised.
  final Uint8List? bytes;

  /// Pages text was found on and written to.
  final int recognisedPages;

  /// Pages left alone because they already had text.
  final int textPages;
  final int pageCount;

  const OcrOutcome({
    required this.bytes,
    required this.recognisedPages,
    required this.textPages,
    required this.pageCount,
  });
}

/// Text recognition, on the device.
///
/// ML Kit's Latin-script model ships inside the app, so nothing is
/// downloaded and no page leaves the phone. It reads the Latin alphabet and
/// its accents; other scripts come back as nonsense or nothing.
class OcrService {
  /// Wide enough for ML Kit to read body text on an A4 page, small enough to
  /// stay inside the renderer's bitmap budget.
  static const int _renderWidth = 1800;

  static bool get isAvailable => !kIsWeb && Platform.isAndroid;

  /// Reads the text in the picture at [path].
  static Future<OcrPage> recogniseImage(String path) async {
    final TextRecognizer recognizer = TextRecognizer(
      script: TextRecognitionScript.latin,
    );
    try {
      final RecognizedText result = await recognizer.processImage(
        InputImage.fromFilePath(path),
      );
      final List<TextLayerLine> lines = [
        for (final TextBlock block in result.blocks)
          for (final TextLine line in block.lines)
            if (line.text.trim().isNotEmpty)
              TextLayerLine(line.text, line.boundingBox),
      ];
      return OcrPage(lines, await _sizeOf(path));
    } finally {
      await recognizer.close();
    }
  }

  static Future<Size> _sizeOf(String path) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromFilePath(
      path,
    );
    final ui.ImageDescriptor descriptor = await ui.ImageDescriptor.encoded(
      buffer,
    );
    final Size size = Size(
      descriptor.width.toDouble(),
      descriptor.height.toDouble(),
    );
    descriptor.dispose();
    buffer.dispose();
    return size;
  }

  /// Reads [pages] (0-based) of the PDF at [file] and returns their lines in
  /// displayed page space, keyed by page.
  ///
  /// [displaySizes] is every page's size as displayed, in points.
  static Future<Map<int, List<TextLayerLine>>> recognisePages(
    File file,
    List<int> pages,
    List<Size> displaySizes, {
    void Function(int done, int total)? onProgress,
  }) async {
    final Map<int, List<TextLayerLine>> found = {};
    if (pages.isEmpty) return found;
    final Directory scratch = await PdfTools.newOutbox();
    try {
      for (int n = 0; n < pages.length; n++) {
        onProgress?.call(n, pages.length);
        final int page = pages[n];
        // One page at a time: a long scan rendered up front would fill the
        // cache with pictures that are each read once.
        final List<String> rendered = await DocumentService.renderPagesToFiles(
          file.path,
          [page],
          outDir: scratch.path,
          baseName: 'ocr',
          width: _renderWidth,
          format: 'jpeg',
          quality: 90,
        );
        if (rendered.isEmpty) continue;
        final OcrPage read = await recogniseImage(rendered.single);
        await File(rendered.single).delete();
        if (read.lines.isEmpty || read.imageSize.width <= 0) continue;
        final double scale = displaySizes[page].width / read.imageSize.width;
        found[page] = [
          for (final TextLayerLine line in read.lines)
            TextLayerLine(
              line.text,
              Rect.fromLTRB(
                line.bounds.left * scale,
                line.bounds.top * scale,
                line.bounds.right * scale,
                line.bounds.bottom * scale,
              ),
            ),
        ];
      }
      onProgress?.call(pages.length, pages.length);
    } finally {
      try {
        await scratch.delete(recursive: true);
      } catch (_) {
        // Swept with the other outboxes.
      }
    }
    return found;
  }

  /// Adds an invisible text layer to every page of [file] that has no text
  /// of its own, which is what makes a scan searchable and selectable.
  static Future<OcrOutcome> makeSearchable(
    File file, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (!isAvailable) {
      throw const PdfEditException('Text recognition needs Android.');
    }
    final PdfFacts facts = await PdfTools.readFacts(file);
    final List<PdfTextPage> text = await PdfTools.extractText(file);
    final List<int> scans = [
      for (final PdfTextPage page in text)
        if (page.lines.isEmpty) page.index,
    ];
    final Map<int, List<TextLayerLine>> lines = await recognisePages(
      file,
      scans,
      facts.pageSizes,
      onProgress: onProgress,
    );
    Uint8List? bytes;
    if (lines.isNotEmpty) {
      bytes = await PdfStamps.renderTextLayer(
        await file.readAsBytes(),
        lines,
        (await DocumentImport.loadFonts()).regular,
      );
    }
    return OcrOutcome(
      bytes: bytes,
      recognisedPages: lines.length,
      textPages: facts.pageCount - scans.length,
      pageCount: facts.pageCount,
    );
  }
}
