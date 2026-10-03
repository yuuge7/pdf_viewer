import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'document_service.dart';
import 'docx_reader.dart';
import 'flow_document.dart';
import 'flow_renderer.dart';
import 'pdf_service.dart';
import 'pdf_tools.dart';

/// What a file handed over by another app turned out to be.
enum ImportKind {
  /// Opened as it is.
  pdf,

  /// A .docx, converted to a PDF.
  word,

  /// Plain text, converted to a PDF.
  text,

  /// A picture, taken into a scan session to become a PDF page.
  image,

  unsupported,
}

/// A file that could not be brought in, with a reason fit to show.
class ImportException implements Exception {
  final String message;
  const ImportException(this.message);
  @override
  String toString() => message;
}

/// Turns the files "Open with" delivers into something the editor can show.
///
/// The app registers for more than PDFs, and the editor only reads PDFs, so
/// everything else is converted on the way in. A converted document is a
/// new PDF that exists nowhere but temporary storage: the file the user
/// opened is never written to, and the result is theirs to keep only once
/// they save a copy (see [DocumentRef.unsaved]).
class DocumentImport {
  /// A text file past this is a log or a data dump, and would come out as
  /// thousands of pages.
  static const int _maxTextBytes = 4 * 1024 * 1024;

  /// Longest edge of a picture taken into a scan session, matching what
  /// the session's own camera and gallery captures are held to.
  static const int _maxPhotoEdge = 2600;

  /// How much of a file [kindOf] looks at.
  static const int _headBytes = 1024;

  static FlowFonts? _fonts;

  /// Works out what a file is from how it begins.
  ///
  /// The type the sending app declares is only a hint: mail clients and
  /// messengers hand over PDFs as `application/octet-stream`, and file
  /// managers guess from the name. [name] and [mimeType] decide only what
  /// the bytes cannot — text has no signature.
  static ImportKind sniff(
    Uint8List head, {
    String name = '',
    String? mimeType,
  }) {
    bool at(int offset, List<int> magic) {
      if (head.length < offset + magic.length) return false;
      for (int i = 0; i < magic.length; i++) {
        if (head[offset + i] != magic[i]) return false;
      }
      return true;
    }

    final String lower = name.toLowerCase();
    final String mime = (mimeType ?? '').toLowerCase();

    // "%PDF-". A PDF may carry junk ahead of its header, so anywhere in
    // the first kilobyte counts.
    for (int i = 0; i + 5 <= head.length; i++) {
      if (at(i, const [0x25, 0x50, 0x44, 0x46, 0x2D])) return ImportKind.pdf;
    }
    // A zip container. Whether it is really a Word file is for the reader
    // to say, with a better message than "unsupported".
    if (at(0, const [0x50, 0x4B, 0x03, 0x04])) return ImportKind.word;
    if (at(0, const [0xFF, 0xD8, 0xFF]) || // JPEG
        at(0, const [0x89, 0x50, 0x4E, 0x47]) || // PNG
        at(0, const [0x47, 0x49, 0x46, 0x38]) || // GIF
        (at(0, const [0x52, 0x49, 0x46, 0x46]) &&
            at(8, const [0x57, 0x45, 0x42, 0x50]))) {
      return ImportKind.image; // …and WebP
    }
    // "BM" is too short a signature to trust on its own.
    if (at(0, const [0x42, 0x4D]) &&
        (mime.startsWith('image/') || lower.endsWith('.bmp'))) {
      return ImportKind.image;
    }

    if (mime == 'application/pdf' || lower.endsWith('.pdf')) {
      // No header where one belongs; the viewer gets to report that.
      return ImportKind.pdf;
    }
    if (mime.startsWith('text/') || lower.endsWith('.txt')) {
      final bool utf16 =
          at(0, const [0xFF, 0xFE]) || at(0, const [0xFE, 0xFF]);
      // A zero byte is the mark of a binary file wearing a text label.
      if (utf16 || !head.contains(0)) return ImportKind.text;
    }
    return ImportKind.unsupported;
  }

  /// [sniff], on the first bytes of [file].
  static Future<ImportKind> kindOf(
    File file, {
    String name = '',
    String? mimeType,
  }) async {
    final RandomAccessFile reader = await file.open();
    try {
      final Uint8List head = await reader.read(_headBytes);
      return sniff(head, name: name, mimeType: mimeType);
    } finally {
      await reader.close();
    }
  }

  // --- Pure byte-level operations -------------------------------------------

  /// Converts a Word document to a PDF.
  ///
  /// Throws a [FormatException] when [bytes] is not one.
  static Future<Uint8List> renderWord(
    Uint8List bytes,
    FlowFonts fonts, {
    String title = '',
  }) {
    return Isolate.run(
      () => FlowRenderer.render(DocxReader.read(bytes), fonts, title: title),
    );
  }

  /// Converts a text file to a PDF, one paragraph per line.
  static Future<Uint8List> renderText(
    Uint8List bytes,
    FlowFonts fonts, {
    String title = '',
  }) {
    return Isolate.run(
      () => FlowRenderer.render(
        FlowDocument.plainText(FlowDocument.decodeText(bytes)),
        fonts,
        title: title,
      ),
    );
  }

  // --- Files -----------------------------------------------------------------

  /// The typeface converted documents are set in, read from the app bundle
  /// once.
  static Future<FlowFonts> loadFonts() async {
    final FlowFonts? loaded = _fonts;
    if (loaded != null) return loaded;
    Future<Uint8List> cut(String name) async {
      final ByteData data = await rootBundle.load('assets/fonts/Roboto-$name.ttf');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }

    return _fonts = FlowFonts(
      regular: await cut('Regular'),
      bold: await cut('Bold'),
      italic: await cut('Italic'),
      boldItalic: await cut('BoldItalic'),
    );
  }

  /// Converts [source] — a [ImportKind.word] or [ImportKind.text] file — to
  /// a PDF in temporary storage and returns it as an unsaved document.
  ///
  /// Throws an [ImportException] when the file cannot be converted.
  static Future<DocumentRef> toPdf(DocumentRef source, ImportKind kind) async {
    final File file = source.file;
    if (kind == ImportKind.text && await file.length() > _maxTextBytes) {
      throw const ImportException('This text file is too large to convert.');
    }
    final Uint8List bytes = await file.readAsBytes();
    final FlowFonts fonts = await loadFonts();
    final String title = PdfTools.baseNameOf(source.name);

    final Uint8List pdf;
    try {
      pdf = kind == ImportKind.word
          ? await renderWord(bytes, fonts, title: title)
          : await renderText(bytes, fonts, title: title);
    } on FormatException catch (e) {
      throw ImportException(e.message);
    }

    // An outbox, like every other file the app makes: swept after a day,
    // by which time the document has been saved somewhere or was not wanted.
    final Directory outbox = await PdfTools.newOutbox();
    final String name = '${PdfTools.safeFileName(title)}.pdf';
    final File out = File('${outbox.path}/$name');
    await out.writeAsBytes(pdf, flush: true);
    return DocumentRef.unsaved(path: out.path, name: name);
  }

  /// Readies a picture for a scan session: upright, no larger than the
  /// session's own captures, and in a format every step after can decode.
  ///
  /// A photo opened from a gallery arrives at full sensor resolution with
  /// its orientation in EXIF, where the session's camera path would have
  /// handed over something already scaled down.
  static Future<File> preparePhoto(File source) async {
    final Uint8List photo;
    try {
      photo = await PdfService.normalizePhoto(
        await source.readAsBytes(),
        maxEdge: _maxPhotoEdge,
      );
    } on PdfEditException catch (e) {
      throw ImportException(e.message);
    }
    final Directory outbox = await PdfTools.newOutbox();
    final bool png = photo.length > 1 && photo[0] == 0x89;
    final File out = File('${outbox.path}/photo.${png ? 'png' : 'jpg'}');
    await out.writeAsBytes(photo, flush: true);
    return out;
  }
}
