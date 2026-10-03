import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Rect, Size;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'document_service.dart';
import 'docx_writer.dart';
import 'pdf_page_geometry.dart';
import 'pdf_service.dart';

/// One line of text found on a page.
@immutable
class PdfTextLine {
  final String text;

  /// In the page's own unrotated space, as extraction reports it.
  final Rect bounds;
  final double fontSize;
  final String fontName;
  final bool bold;
  final bool italic;

  const PdfTextLine({
    required this.text,
    required this.bounds,
    required this.fontSize,
    this.fontName = '',
    this.bold = false,
    this.italic = false,
  });
}

/// The text of one page.
@immutable
class PdfTextPage {
  final int index;

  /// The page's own unrotated size.
  final Size size;
  final PdfPageTurn turn;
  final List<PdfTextLine> lines;

  const PdfTextPage({
    required this.index,
    required this.size,
    required this.turn,
    required this.lines,
  });

  Size get displaySize => turn.swapsAxes ? size.flipped : size;
}

/// Consecutive lines that read as one block.
@immutable
class PdfParagraph {
  final List<PdfTextLine> lines;
  const PdfParagraph(this.lines);

  PdfTextLine get first => lines.first;
  double get top => lines.first.bounds.top;
  double get bottom => lines.last.bounds.bottom;
  double get left => lines.map((l) => l.bounds.left).reduce(math.min);

  /// The lines joined back into running text. A line ending in a hyphen is
  /// joined without a space, which is right for words broken across lines
  /// and harmless for the rest.
  String get text {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i].text.trim();
      out.write(line);
      if (i < lines.length - 1 && !line.endsWith('-')) out.write(' ');
    }
    return out.toString();
  }
}

/// Metadata and geometry of a document.
@immutable
class PdfFacts {
  final int pageCount;

  /// Every page's size as displayed, in points.
  final List<Size> pageSizes;
  final String? title;
  final String? author;
  final String? subject;
  final String? keywords;
  final String? creator;
  final String? producer;
  final DateTime? created;
  final DateTime? modified;
  final String version;

  const PdfFacts({
    required this.pageCount,
    required this.pageSizes,
    this.title,
    this.author,
    this.subject,
    this.keywords,
    this.creator,
    this.producer,
    this.created,
    this.modified,
    this.version = '',
  });
}

enum CompressLevel {
  /// Re-saved with maximum compression. Nothing is lost.
  low,

  /// Pages rasterised at 150 dpi. Text stops being selectable.
  medium,

  /// Pages rasterised at 100 dpi, lower JPEG quality.
  high,
}

@immutable
class CompressResult {
  final File file;
  final int originalBytes;
  final int compressedBytes;

  const CompressResult(this.file, this.originalBytes, this.compressedBytes);

  bool get isSmaller => compressedBytes < originalBytes;

  /// Fraction saved, 0..1.
  double get saving =>
      originalBytes == 0 ? 0 : 1 - compressedBytes / originalBytes;
}

@immutable
class WordExport {
  final File file;

  /// Pages that had extractable text. Zero means a scan, and the document is
  /// pictures only.
  final int textPages;
  final int pageCount;

  const WordExport(this.file, this.textPages, this.pageCount);
}

/// Document-level tools that produce new files rather than editing the open
/// one: split, merge, extract, compress, and conversion to images and Word.
///
/// Outputs go to a fresh "outbox" folder in temporary storage, named after
/// the document, so sharing or saving them hands over a sensible file name.
class PdfTools {
  // --- Reading ---------------------------------------------------------------

  static Future<PdfFacts> readFacts(File file) async {
    final Uint8List bytes = await file.readAsBytes();
    return Isolate.run(() {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        final List<Size> sizes = [];
        for (int i = 0; i < document.pages.count; i++) {
          final PdfPage page = document.pages[i];
          final int turns = page.rotation.index;
          sizes.add(turns.isOdd ? page.size.flipped : page.size);
        }
        final PdfDocumentInformation info = document.documentInformation;
        String? text(String Function() read) {
          try {
            final String value = read().trim();
            return value.isEmpty ? null : value;
          } catch (_) {
            return null;
          }
        }

        // Syncfusion answers "now" for a date the document does not have, so
        // a date within a moment of the read is treated as missing.
        final DateTime readAt = DateTime.now();
        DateTime? date(DateTime Function() read) {
          try {
            final DateTime value = read();
            return value.difference(readAt).inSeconds.abs() < 5 ? null : value;
          } catch (_) {
            return null;
          }
        }

        final String version = document.fileStructure.version.name
            .replaceFirst('version', '')
            .replaceAll('_', '.');
        return PdfFacts(
          pageCount: document.pages.count,
          pageSizes: sizes,
          title: text(() => info.title),
          author: text(() => info.author),
          subject: text(() => info.subject),
          keywords: text(() => info.keywords),
          creator: text(() => info.creator),
          producer: text(() => info.producer),
          created: date(() => info.creationDate),
          modified: date(() => info.modificationDate),
          version: version,
        );
      } finally {
        document.dispose();
      }
    });
  }

  /// Extracts the text of pages [first]..[last] (inclusive, 0-based; all
  /// pages by default), line by line with position and font.
  static Future<List<PdfTextPage>> extractText(
    File file, {
    int? first,
    int? last,
  }) async {
    final Uint8List bytes = await file.readAsBytes();
    return Isolate.run(() {
      final PdfDocument document = PdfDocument(inputBytes: bytes);
      try {
        final int count = document.pages.count;
        if (count == 0) return const <PdfTextPage>[];
        final int start = (first ?? 0).clamp(0, count - 1);
        final int end = (last ?? count - 1).clamp(start, count - 1);
        final PdfTextExtractor extractor = PdfTextExtractor(document);
        final List<PdfTextPage> pages = [];
        for (int i = start; i <= end; i++) {
          List<TextLine> lines;
          try {
            lines = extractor.extractTextLines(
              startPageIndex: i,
              endPageIndex: i,
            );
          } catch (_) {
            // One unreadable page should not sink the whole document.
            lines = const [];
          }
          final PdfPage page = document.pages[i];
          pages.add(
            PdfTextPage(
              index: i,
              size: page.size,
              turn: PdfPageTurn.values[page.rotation.index],
              lines: [
                for (final TextLine line in lines)
                  if (line.text.trim().isNotEmpty)
                    PdfTextLine(
                      text: line.text,
                      bounds: line.bounds,
                      fontSize: line.fontSize,
                      fontName: line.fontName,
                      bold: line.fontStyle.contains(PdfFontStyle.bold),
                      italic: line.fontStyle.contains(PdfFontStyle.italic),
                    ),
              ],
            ),
          );
        }
        return pages;
      } finally {
        document.dispose();
      }
    });
  }

  /// Groups a page's lines into blocks: a new block starts at a vertical gap
  /// of more than half a line, a jump back up the page (a new column), a
  /// change of indent or a change of font size.
  static List<PdfParagraph> paragraphsOf(PdfTextPage page) {
    final List<PdfParagraph> paragraphs = [];
    List<PdfTextLine> current = [];
    for (final PdfTextLine line in page.lines) {
      if (current.isNotEmpty) {
        final PdfTextLine previous = current.last;
        final double height = math.max(
          previous.bounds.height,
          line.bounds.height,
        );
        final double gap = line.bounds.top - previous.bounds.bottom;
        final double unit = math.max(previous.fontSize, 6);
        final bool breaks =
            gap > height * 0.5 ||
            line.bounds.top < previous.bounds.top - 1 ||
            (line.bounds.left - previous.bounds.left).abs() > unit * 1.5 ||
            (line.fontSize - previous.fontSize).abs() > 1.5;
        if (breaks) {
          paragraphs.add(PdfParagraph(current));
          current = [];
        }
      }
      current.add(line);
    }
    if (current.isNotEmpty) paragraphs.add(PdfParagraph(current));
    return paragraphs;
  }

  // --- Page ranges -----------------------------------------------------------

  /// Parses "1-3, 5, 8-10" into 0-based page groups, one per comma-separated
  /// part, in the order written.
  ///
  /// Throws a [FormatException] with a message fit to show the user.
  static List<List<int>> parseRanges(String input, int pageCount) {
    final List<List<int>> groups = [];
    for (final String rawPart in input.split(RegExp(r'[,;]'))) {
      final String part = rawPart.trim();
      if (part.isEmpty) continue;
      final Match? match = RegExp(r'^(\d+)\s*(?:-\s*(\d+))?$').firstMatch(part);
      if (match == null) {
        throw FormatException('"$part" is not a page or a range like 2-5.');
      }
      final int from = int.parse(match.group(1)!);
      final int to = match.group(2) == null ? from : int.parse(match.group(2)!);
      if (from < 1 || to < 1 || from > pageCount || to > pageCount) {
        throw FormatException(
          '"$part" is outside this document (1-$pageCount).',
        );
      }
      final int low = math.min(from, to);
      final int high = math.max(from, to);
      groups.add([for (int p = low; p <= high; p++) p - 1]);
    }
    if (groups.isEmpty) {
      throw const FormatException('Enter at least one page or range.');
    }
    return groups;
  }

  /// Consecutive groups of [size] pages covering the whole document.
  static List<List<int>> chunk(int pageCount, int size) {
    final int step = math.max(1, size);
    return [
      for (int start = 0; start < pageCount; start += step)
        [for (int p = start; p < math.min(pageCount, start + step); p++) p],
    ];
  }

  // --- Outputs ---------------------------------------------------------------

  /// Splits [file] into one document per group of 0-based page indices.
  ///
  /// Pages are removed rather than copied, so every part keeps its pages
  /// exactly as they were, links and all.
  static Future<List<File>> split(
    File file,
    List<List<int>> groups,
    String documentName,
  ) async {
    final List<Uint8List> parts = await PdfService.renderSplit(
      await file.readAsBytes(),
      groups,
    );

    final Directory outbox = await newOutbox();
    final String base = baseNameOf(documentName);
    final List<File> files = [];
    final Set<String> used = {};
    for (int i = 0; i < parts.length; i++) {
      final List<int> group = groups[i];
      final String label = group.length == 1
          ? 'p${group.first + 1}'
          : 'p${group.first + 1}-${group.last + 1}';
      // Ranges can repeat ("1-3, 1-3"); a repeat must not overwrite its twin.
      String name = safeFileName('${base}_$label');
      for (int n = 2; !used.add(name); n++) {
        name = safeFileName('${base}_$label ($n)');
      }
      final File out = File('${outbox.path}/$name.pdf');
      await out.writeAsBytes(parts[i], flush: true);
      files.add(out);
    }
    return files;
  }

  /// Builds a new document from [specs] of [file] (see
  /// [PdfService.renderLayout]) without touching [file].
  static Future<File> extract(
    File file,
    List<PageSpec> specs,
    String outputName,
  ) async {
    final Uint8List bytes = await file.readAsBytes();
    final Uint8List built = await PdfService.renderLayout(
      bytes,
      specs,
      await PdfService.readForeignSources(specs),
    );
    return _writeOut(built, outputName, 'pdf');
  }

  static Future<File> merge(List<File> files, String outputName) async {
    final List<Uint8List> documents = [
      for (final File file in files) await file.readAsBytes(),
    ];
    return _writeOut(await PdfService.renderMerge(documents), outputName, 'pdf');
  }

  static Future<CompressResult> compress(
    File file,
    CompressLevel level,
    String documentName,
  ) async {
    final int originalBytes = await file.length();
    final Uint8List output;
    if (level == CompressLevel.low || !DocumentService.canRender) {
      output = await PdfService.renderCompact(await file.readAsBytes());
    } else {
      final double dpi = level == CompressLevel.medium ? 150 : 100;
      final int quality = level == CompressLevel.medium ? 70 : 50;
      final PdfFacts facts = await readFacts(file);
      final int pageCount = facts.pageCount;
      final Directory scratch = await newOutbox();
      try {
        final List<String> pages = await DocumentService.renderPagesToFiles(
          file.path,
          [for (int i = 0; i < pageCount; i++) i],
          outDir: scratch.path,
          baseName: 'page',
          dpi: dpi,
          format: 'jpeg',
          quality: quality,
        );
        if (pages.length != pageCount) {
          throw const PdfEditException('Some pages could not be rendered.');
        }
        // Each page keeps its displayed size; the renders are displayed
        // orientation too, since the renderer applies /Rotate.
        output = await PdfService.renderImagePages([
          for (final String path in pages) await File(path).readAsBytes(),
        ], facts.pageSizes);
      } finally {
        await _deleteQuietly(scratch);
      }
    }
    final File out = await _writeOut(output, documentName, 'pdf');
    return CompressResult(out, originalBytes, output.length);
  }

  /// Renders [pages] to image files, [width] pixels wide.
  static Future<List<File>> toImages(
    File file,
    List<int> pages, {
    required String documentName,
    required int width,
    bool png = false,
  }) async {
    final Directory outbox = await newOutbox();
    final List<String> paths = await DocumentService.renderPagesToFiles(
      file.path,
      pages,
      outDir: outbox.path,
      baseName: safeFileName(baseNameOf(documentName)),
      width: width,
      format: png ? 'png' : 'jpeg',
      quality: 92,
    );
    return paths.map(File.new).toList(growable: false);
  }

  /// Renders the whole document as one tall image.
  static Future<File?> toLongImage(
    File file, {
    required String documentName,
    int width = 1080,
  }) async {
    final Directory outbox = await newOutbox();
    final String? path = await DocumentService.renderLongImage(
      file.path,
      outPath:
          '${outbox.path}/${safeFileName('${baseNameOf(documentName)}_long')}.jpg',
      width: width,
    );
    return path == null ? null : File(path);
  }

  /// Converts [file] to a Word document.
  ///
  /// Text keeps its size, weight and rough indentation; each PDF page starts
  /// a new Word page. A page with no text at all is a scan, and goes in as a
  /// picture of the page instead of coming out blank.
  static Future<WordExport> toWord(File file, String documentName) async {
    final List<PdfTextPage> pages = await extractText(file);
    final List<DocxBlock> blocks = [];
    int textPages = 0;

    for (final PdfTextPage page in pages) {
      if (blocks.isNotEmpty) blocks.add(const DocxPageBreak());
      final List<PdfParagraph> paragraphs = paragraphsOf(page);
      if (paragraphs.isEmpty) {
        if (!DocumentService.canRender) continue;
        const int width = 1400;
        final Uint8List? picture = await DocumentService.renderPage(
          file.path,
          page.index,
          width: width,
          jpegQuality: 85,
        );
        if (picture == null) continue;
        final Size display = page.displaySize;
        blocks.add(
          DocxImage(
            picture,
            format: 'jpeg',
            widthPx: width,
            heightPx: (width * display.height / display.width).round(),
          ),
        );
        continue;
      }

      textPages++;
      final double margin = paragraphs.map((p) => p.left).reduce(math.min);
      double? previousBottom;
      for (final PdfParagraph paragraph in paragraphs) {
        final double spaceBefore = previousBottom == null
            ? 0
            : (paragraph.top - previousBottom - paragraph.first.fontSize * 0.3)
                  .clamp(0, 36)
                  .toDouble();
        previousBottom = paragraph.bottom;
        blocks.add(
          DocxParagraph(
            [
              for (int i = 0; i < paragraph.lines.length; i++)
                _runFor(
                  paragraph.lines[i],
                  last: i == paragraph.lines.length - 1,
                ),
            ],
            indentPt: math.min(paragraph.left - margin, 216),
            spaceBeforePt: spaceBefore,
          ),
        );
      }
    }

    final String title = baseNameOf(documentName);
    final Uint8List docx = await Isolate.run(
      () => DocxWriter.build(blocks, title: title),
    );
    final File out = await _writeOut(docx, documentName, 'docx');
    return WordExport(out, textPages, pages.length);
  }

  static DocxRun _runFor(PdfTextLine line, {required bool last}) {
    final String text = line.text.trim();
    return DocxRun(
      last || text.endsWith('-') ? text : '$text ',
      sizePt: line.fontSize > 0 ? line.fontSize : 11,
      bold: line.bold,
      italic: line.italic,
      font: wordFontFor(line.fontName),
    );
  }

  /// The Word font closest to an embedded PDF font, or null to leave the
  /// document default. Embedded names carry subset prefixes and style
  /// suffixes ("ABCDEF+Arial-BoldMT"), so this matches on families only.
  static String? wordFontFor(String pdfFontName) {
    final String name = pdfFontName.toLowerCase();
    if (name.contains('courier') || name.contains('mono')) {
      return 'Courier New';
    }
    if (name.contains('consol')) return 'Consolas';
    if (name.contains('times')) return 'Times New Roman';
    if (name.contains('georgia')) return 'Georgia';
    if (name.contains('cambria')) return 'Cambria';
    if (name.contains('arial') || name.contains('helvetica')) return 'Arial';
    if (name.contains('verdana')) return 'Verdana';
    if (name.contains('tahoma')) return 'Tahoma';
    if (name.contains('calibri')) return 'Calibri';
    return null;
  }

  // --- Files -----------------------------------------------------------------

  /// A fresh folder for one batch of outputs.
  static Future<Directory> newOutbox() async {
    final Directory temp = await getTemporaryDirectory();
    final Directory outbox = Directory(
      '${temp.path}/exports/${DateTime.now().microsecondsSinceEpoch}',
    );
    await outbox.create(recursive: true);
    return outbox;
  }

  /// Removes outboxes older than a day. Nothing in them is the user's only
  /// copy: an output is either saved somewhere else or was never wanted.
  static Future<void> sweepOutboxes() async {
    try {
      final Directory temp = await getTemporaryDirectory();
      final Directory exports = Directory('${temp.path}/exports');
      if (!exports.existsSync()) return;
      final DateTime cutoff = DateTime.now().subtract(const Duration(days: 1));
      await for (final FileSystemEntity entity in exports.list()) {
        final FileStat stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete(recursive: true);
        }
      }
    } catch (_) {
      // Housekeeping only.
    }
  }

  /// Removes every outbox now. Returns how many there were.
  ///
  /// Only safe with no document open: one converted on the way in lives in
  /// an outbox until it is saved.
  static Future<int> clearOutboxes() async {
    int removed = 0;
    try {
      final Directory temp = await getTemporaryDirectory();
      final Directory exports = Directory('${temp.path}/exports');
      if (!exports.existsSync()) return 0;
      await for (final FileSystemEntity entity in exports.list()) {
        await entity.delete(recursive: true);
        removed++;
      }
    } catch (_) {
      // Whatever could not go now goes with the daily sweep.
    }
    return removed;
  }

  static String baseNameOf(String name) {
    final int dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Strips what cannot go in a file name. Never empty.
  static String safeFileName(String name) {
    final String cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .trim();
    return cleaned.isEmpty ? 'document' : cleaned;
  }

  static Future<File> _writeOut(
    Uint8List bytes,
    String name,
    String extension,
  ) async {
    final Directory outbox = await newOutbox();
    final File out = File(
      '${outbox.path}/${safeFileName(baseNameOf(name))}.$extension',
    );
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  static Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      await entity.delete(recursive: true);
    } catch (_) {
      // Best effort.
    }
  }
}
