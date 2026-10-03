import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A document the user opened, and how to write back to it.
///
/// On Android [uri] is a Storage Access Framework `content://` URI the app
/// holds a persistable read/write grant on, and [path] is a cache copy used
/// only so the viewer has a `File` to render. Saving goes through [uri], which
/// is what makes edits actually reach the user's document.
///
/// On other platforms [uri] is null and [path] is the real file.
///
/// A document converted from something else on the way in is neither: see
/// [DocumentRef.unsaved].
@immutable
class DocumentRef {
  final String? uri;
  final String path;
  final String name;
  final bool canWrite;

  const DocumentRef({
    required this.path,
    required this.name,
    this.uri,
    this.canWrite = true,
  });

  /// A PDF the app built itself — out of a Word or a text file — that has
  /// not been saved anywhere yet.
  ///
  /// [path] is a temporary file and there is no document behind it to write
  /// back to, so the only way to keep it is Save a copy, which is what turns
  /// it into an ordinary document.
  const DocumentRef.unsaved({required this.path, required this.name})
    : uri = null,
      canWrite = false;

  File get file => File(path);

  /// See [DocumentRef.unsaved].
  bool get isUnsaved => uri == null && !canWrite;

  /// True when saving writes to the document the user actually chose, rather
  /// than to a private copy the app will eventually discard.
  bool get savesInPlace => canWrite;

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'path': path,
    'name': name,
    'canWrite': canWrite,
  };

  static DocumentRef? fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final name = json['name'];
    if (path is! String || name is! String) return null;
    return DocumentRef(
      path: path,
      name: name,
      uri: json['uri'] as String?,
      canWrite: json['canWrite'] as bool? ?? true,
    );
  }

  String encode() => jsonEncode(toJson());

  /// Decodes an entry, tolerating the bare-path strings written by versions
  /// before Recent Files stored URIs.
  static DocumentRef? decode(String raw) {
    if (!raw.startsWith('{')) {
      if (raw.isEmpty) return null;
      return DocumentRef(
        path: raw,
        name: raw.split(Platform.pathSeparator).last,
      );
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  DocumentRef copyWith({
    String? path,
    bool? canWrite,
    String? uri,
    String? name,
  }) => DocumentRef(
    path: path ?? this.path,
    name: name ?? this.name,
    uri: uri ?? this.uri,
    canWrite: canWrite ?? this.canWrite,
  );

  /// Recent Files identity. Two cache copies of the same document share a URI
  /// but not a path, so the URI is the stable key where there is one.
  String get key => uri ?? path;
}

/// A document picked only to read from once, such as a file to merge in.
///
/// No lasting grant is taken on these; [path] is a cache copy made while the
/// picker's temporary grant was still good.
@immutable
class PickedDocument {
  final String path;
  final String name;
  const PickedDocument({required this.path, required this.name});
}

/// A file another app asked this one to open, before anyone has looked at
/// what it is.
///
/// The app is offered under "Open with" for more than PDFs, so [ref] may
/// point at a Word file, a picture or plain text; `DocumentImport` decides
/// which and what to do about it.
@immutable
class IncomingDocument {
  final DocumentRef ref;

  /// What the sending app said the file is. A hint, and often a wrong one.
  final String? mimeType;

  const IncomingDocument(this.ref, {this.mimeType});
}

/// What the platform knows about a document beyond its bytes.
@immutable
class DocumentFacts {
  /// Size in bytes, if the provider reports one.
  final int? size;
  final DateTime? modified;

  /// Something a person can read: a real path where one can be derived from
  /// the URI, otherwise the name of the app that holds the file.
  final String? location;
  final bool canRename;
  final bool canDelete;

  const DocumentFacts({
    this.size,
    this.modified,
    this.location,
    this.canRename = false,
    this.canDelete = false,
  });
}

/// Where exported files can be delivered.
enum ExportTarget {
  /// A folder the user picks. Works everywhere.
  folder,

  /// Pictures/ProPDF Studio, through MediaStore. Android 10 and later.
  gallery,

  /// Download/ProPDF Studio, through MediaStore. Android 10 and later.
  downloads,
}

/// Bridges to the platform document APIs.
class DocumentService {
  static const MethodChannel _channel = MethodChannel('propdf/documents');

  /// Documents handed to the app by another app ("Open with").
  ///
  /// The launch intent is consumed once at startup; later ones arrive here as
  /// the platform pushes them, because the activity is singleTop and does not
  /// restart for a second document.
  static final StreamController<IncomingDocument> _incoming =
      StreamController<IncomingDocument>.broadcast();

  static Stream<IncomingDocument> get incoming => _incoming.stream;

  static bool _listening = false;

  /// Starts relaying documents opened from other apps, and returns the one the
  /// app was launched with, if any.
  ///
  /// Safe to call more than once; only the first call installs the handler.
  static Future<IncomingDocument?> startListening() async {
    if (!supportsSaf) return null;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'documentOpened') return null;
        final IncomingDocument? document = _incomingFrom(call.arguments);
        if (document != null) _incoming.add(document);
        return null;
      });
    }
    try {
      final Map<String, dynamic>? launch = await _channel
          .invokeMapMethod<String, dynamic>('consumeLaunchDocument');
      return _incomingFrom(launch);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static IncomingDocument? _incomingFrom(Object? payload) {
    if (payload is! Map) return null;
    final Object? path = payload['path'];
    if (path is! String) return null;
    return IncomingDocument(
      DocumentRef(
        uri: payload['uri'] as String?,
        path: path,
        name: payload['name'] as String? ?? 'document.pdf',
        canWrite: payload['canWrite'] as bool? ?? false,
      ),
      mimeType: payload['mime'] as String?,
    );
  }

  /// Whether the Storage Access Framework path is available. Everything else
  /// falls back to `file_picker`, which cannot write back to the original.
  static bool get supportsSaf => !kIsWeb && Platform.isAndroid;

  /// Opens the system document picker. Returns null if the user cancelled.
  static Future<DocumentRef?> pick() async {
    if (supportsSaf) {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'pickDocument',
      );
      if (result == null) return null;
      return DocumentRef(
        uri: result['uri'] as String?,
        path: result['path'] as String,
        name: result['name'] as String? ?? 'document.pdf',
        canWrite: result['canWrite'] as bool? ?? false,
      );
    }

    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (picked.isEmpty) return null;
    final path = picked.first.path;
    if (path == null) return null;
    return DocumentRef(path: path, name: picked.first.name);
  }

  /// Re-opens a document from a stored reference, refreshing its cache copy.
  ///
  /// Returns null when the document is gone or the persisted grant was
  /// revoked, which is the signal to drop it from Recent Files.
  static Future<DocumentRef?> reopen(DocumentRef ref) async {
    final uri = ref.uri;
    if (uri == null && supportsSaf) {
      // A URI-less entry on Android is a legacy record holding a file_picker
      // cache path. Even if that path still resolves it is a throwaway copy,
      // and treating it as the real document would silently reintroduce the
      // save-goes-nowhere bug. Force the user to re-pick it.
      return null;
    }
    if (uri == null) {
      return ref.file.existsSync() ? ref : null;
    }
    try {
      final path = await _channel.invokeMethod<String>('copyToCache', {
        'uri': uri,
      });
      if (path == null) return null;
      final canWrite =
          await _channel.invokeMethod<bool>('canWrite', {'uri': uri}) ?? false;
      return ref.copyWith(path: path, canWrite: canWrite);
    } on PlatformException {
      return null;
    }
  }

  /// Writes [source] back to the document [ref] points at.
  static Future<void> write(DocumentRef ref, File source) async {
    final uri = ref.uri;
    if (uri == null || !supportsSaf) {
      await source.copy(ref.path);
      return;
    }
    await _channel.invokeMethod<void>('writeDocument', {
      'uri': uri,
      'sourcePath': source.path,
    });
  }

  /// Prompts for a location and saves a copy there. Returns the new reference,
  /// or null if the user cancelled.
  static Future<DocumentRef?> saveCopy(
    String suggestedName,
    File source, {
    String mimeType = 'application/pdf',
  }) async {
    if (!supportsSaf) return null;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'createDocument',
      {'name': suggestedName, 'sourcePath': source.path, 'mime': mimeType},
    );
    if (result == null) return null;
    return DocumentRef(
      uri: result['uri'] as String?,
      path: result['path'] as String,
      name: result['name'] as String? ?? suggestedName,
      canWrite: result['canWrite'] as bool? ?? false,
    );
  }

  /// Gives up the persisted grant on a document being removed from Recent Files.
  static Future<void> release(DocumentRef ref) async {
    final uri = ref.uri;
    if (uri == null || !supportsSaf) return;
    try {
      await _channel.invokeMethod<void>('releaseDocument', {'uri': uri});
    } on PlatformException {
      // Nothing to release.
    }
  }

  /// Rasterises one page to a PNG for the thumbnail strip.
  ///
  /// Returns null when the platform cannot render, so callers fall back to a
  /// plain page-number tile rather than showing an error. [jpegQuality]
  /// switches the encoding to JPEG, which is far smaller for photographs.
  static Future<Uint8List?> renderPage(
    String path,
    int pageIndex, {
    int width = 160,
    int? jpegQuality,
  }) async {
    if (!supportsSaf) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('renderPage', {
        'path': path,
        'page': pageIndex,
        'width': width,
        'quality': ?jpegQuality,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Whether the native renderer is there at all. Everything that turns pages
  /// into pixels — images, printing previews, raster compression — needs it.
  static bool get canRender => supportsSaf;

  /// Renders [pages] (0-based) of the PDF at [path] to image files in
  /// [outDir], one per page, and returns their paths in order.
  ///
  /// Each page is rendered [width] pixels wide, or at [dpi] of its physical
  /// size when [dpi] is given. [format] is `jpeg` or `png`.
  static Future<List<String>> renderPagesToFiles(
    String path,
    List<int> pages, {
    required String outDir,
    required String baseName,
    int width = 1600,
    double? dpi,
    String format = 'jpeg',
    int quality = 90,
  }) async {
    final List<Object?>? result = await _channel.invokeListMethod<Object?>(
      'renderPages',
      {
        'path': path,
        'pages': pages,
        'outDir': outDir,
        'baseName': baseName,
        'width': width,
        'dpi': ?dpi,
        'format': format,
        'quality': quality,
      },
    );
    return (result ?? const []).whereType<String>().toList(growable: false);
  }

  /// Renders every page of [path] into one tall JPEG at [outPath].
  ///
  /// The native side shrinks [width] if the stitched image would not fit in
  /// memory or exceed JPEG's size limit, so long documents still work.
  static Future<String?> renderLongImage(
    String path, {
    required String outPath,
    int width = 1080,
    int quality = 88,
  }) {
    return _channel.invokeMethod<String>('renderLongImage', {
      'path': path,
      'outPath': outPath,
      'width': width,
      'quality': quality,
    });
  }

  /// Every type the app can do something with, for [pickAny].
  static const List<String> openableTypes = [
    'application/pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.oasis.opendocument.text',
    'application/rtf',
    'text/rtf',
    'text/plain',
    'text/csv',
    'text/comma-separated-values',
    'text/html',
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'image/bmp',
  ];

  /// Opens the system picker for anything in [types], and returns what was
  /// chosen with the type its provider gave it. Null if cancelled.
  ///
  /// A lasting grant is taken, as for a PDF; the caller releases it for a
  /// file that is only read once.
  static Future<IncomingDocument?> pickAny({
    List<String> types = openableTypes,
  }) async {
    if (!supportsSaf) {
      final DocumentRef? ref = await pick();
      return ref == null ? null : IncomingDocument(ref);
    }
    return _incomingFrom(
      await _channel.invokeMapMethod<String, dynamic>('pickDocument', {
        'mimes': types,
      }),
    );
  }

  /// Hands [text] to whichever app on the device translates.
  ///
  /// Throws a [PlatformException] when there is none.
  static Future<void> translate(String text) {
    return _channel.invokeMethod<void>('translateText', {'text': text});
  }

  /// Looks [text] up on the web, in the browser or search app.
  static Future<void> webSearch(String text) {
    return _channel.invokeMethod<void>('webSearch', {'text': text});
  }

  /// Lays [html] out on pages and writes the PDF to [outPath].
  ///
  /// Rendered by the system web view with scripts off and the network
  /// blocked, so only what the HTML itself carries appears.
  static Future<void> htmlToPdf(
    String html, {
    required String outPath,
    bool landscape = false,
    bool letter = false,
    bool margins = true,
  }) {
    return _channel.invokeMethod<void>('htmlToPdf', {
      'html': html,
      'outPath': outPath,
      'landscape': landscape,
      'letter': letter,
      'margins': margins,
    });
  }

  /// Opens the system picker for one or more PDFs to read from.
  static Future<List<PickedDocument>> pickMany() async {
    if (supportsSaf) {
      final List<Object?>? result = await _channel.invokeListMethod<Object?>(
        'pickDocuments',
      );
      return (result ?? const [])
          .whereType<Map<Object?, Object?>>()
          .map(
            (m) => PickedDocument(
              path: m['path']! as String,
              name: m['name'] as String? ?? 'document.pdf',
            ),
          )
          .toList(growable: false);
    }
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    return picked
        .where((f) => f.path != null)
        .map((f) => PickedDocument(path: f.path!, name: f.name))
        .toList(growable: false);
  }

  /// Prompts for a location and writes [source] there as [mimeType], without
  /// adopting it as a document. Returns the new URI, or null if cancelled.
  ///
  /// For outputs that are not PDFs the app will reopen — a .docx, an image —
  /// so no lasting grant is taken and nothing is copied back into the cache.
  static Future<String?> exportAs(
    String suggestedName,
    File source,
    String mimeType,
  ) async {
    if (!supportsSaf) return null;
    final Map<String, dynamic>? result = await _channel
        .invokeMapMethod<String, dynamic>('createDocument', {
          'name': suggestedName,
          'sourcePath': source.path,
          'mime': mimeType,
          'keep': false,
        });
    return result?['uri'] as String?;
  }

  /// Delivers [files] to [target]. Returns how many were written, or null if
  /// the user cancelled the folder picker.
  static Future<int?> exportFiles(
    List<File> files,
    String mimeType,
    ExportTarget target,
  ) {
    return _channel.invokeMethod<int>('exportFiles', {
      'paths': files.map((f) => f.path).toList(growable: false),
      'mime': mimeType,
      'target': target.name,
    });
  }

  /// Android API level, or 0 off Android.
  static Future<int> sdkInt() async {
    if (!supportsSaf) return 0;
    try {
      return await _channel.invokeMethod<int>('sdkInt') ?? 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// Looks up size, date, location and what the provider allows.
  static Future<DocumentFacts> facts(DocumentRef ref) async {
    final String? uri = ref.uri;
    if (uri == null || !supportsSaf) {
      final File file = ref.file;
      if (!file.existsSync()) return const DocumentFacts();
      final FileStat stat = await file.stat();
      // An unsaved document lives in a temporary folder, which is neither a
      // place worth showing nor a file worth renaming.
      final bool real = !ref.isUnsaved;
      return DocumentFacts(
        size: stat.size,
        modified: stat.modified,
        location: real ? file.path : null,
        canRename: real,
        canDelete: real,
      );
    }
    try {
      final Map<String, dynamic>? result = await _channel
          .invokeMapMethod<String, dynamic>('documentInfo', {'uri': uri});
      if (result == null) return const DocumentFacts();
      final int? modified = (result['modified'] as num?)?.toInt();
      return DocumentFacts(
        size: (result['size'] as num?)?.toInt(),
        modified: modified == null || modified <= 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(modified),
        location: result['location'] as String?,
        canRename: result['canRename'] as bool? ?? false,
        canDelete: result['canDelete'] as bool? ?? false,
      );
    } on PlatformException {
      return const DocumentFacts();
    }
  }

  /// Renames the document itself. Returns the updated reference; the URI can
  /// change, since some providers encode the name in it.
  ///
  /// Throws a [PlatformException] when the provider refuses.
  static Future<DocumentRef> rename(DocumentRef ref, String newName) async {
    final String? uri = ref.uri;
    if (uri == null || !supportsSaf) {
      final File file = ref.file;
      final String target =
          '${file.parent.path}${Platform.pathSeparator}$newName';
      // File.rename replaces whatever is already there without a word.
      if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
        throw PlatformException(
          code: 'exists',
          message: 'A file named $newName already exists there.',
        );
      }
      final File renamed = await file.rename(target);
      return ref.copyWith(path: renamed.path, name: newName);
    }
    final Map<String, dynamic>? result = await _channel
        .invokeMapMethod<String, dynamic>('renameDocument', {
          'uri': uri,
          'name': newName,
        });
    if (result == null) {
      throw PlatformException(code: 'failed', message: 'Rename failed.');
    }
    return ref.copyWith(
      uri: result['uri'] as String? ?? uri,
      name: result['name'] as String? ?? newName,
      canWrite: result['canWrite'] as bool? ?? ref.canWrite,
    );
  }

  /// Deletes the document itself, not just the app's copy. Returns false when
  /// the app holding it does not allow that.
  static Future<bool> delete(DocumentRef ref) async {
    final String? uri = ref.uri;
    if (uri == null || !supportsSaf) {
      final File file = ref.file;
      if (!file.existsSync()) return false;
      await file.delete();
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('deleteDocument', {
            'uri': uri,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  /// Hands [file] to the system print dialog under [jobName].
  static Future<void> printFile(File file, String jobName) {
    return _channel.invokeMethod<void>('printDocument', {
      'path': file.path,
      'name': jobName,
    });
  }

  static Future<void> setKeepScreenOn(bool on) async {
    if (!supportsSaf) return;
    try {
      await _channel.invokeMethod<void>('keepScreenOn', {'on': on});
    } on MissingPluginException {
      // Nothing to hold awake.
    }
  }

  /// Opens a web page in the browser.
  static Future<void> openUrl(String url) {
    return _channel.invokeMethod<void>('openUrl', {'url': url});
  }

  /// Offers [uri] to whichever app handles [mimeType].
  static Future<void> viewUri(String uri, String mimeType) {
    return _channel.invokeMethod<void>('viewUri', {
      'uri': uri,
      'mime': mimeType,
    });
  }
}
