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

  File get file => File(path);

  /// True when saving writes to the document the user actually chose, rather
  /// than to a private copy the app will eventually discard.
  bool get savesInPlace => uri != null ? canWrite : true;

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
  static final StreamController<DocumentRef> _incoming =
      StreamController<DocumentRef>.broadcast();

  static Stream<DocumentRef> get incoming => _incoming.stream;

  static bool _listening = false;

  /// Starts relaying documents opened from other apps, and returns the one the
  /// app was launched with, if any.
  ///
  /// Safe to call more than once; only the first call installs the handler.
  static Future<DocumentRef?> startListening() async {
    if (!supportsSaf) return null;
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method != 'documentOpened') return null;
        final DocumentRef? ref = _refFrom(call.arguments);
        if (ref != null) _incoming.add(ref);
        return null;
      });
    }
    try {
      final Map<String, dynamic>? launch = await _channel
          .invokeMapMethod<String, dynamic>('consumeLaunchDocument');
      return _refFrom(launch);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static DocumentRef? _refFrom(Object? payload) {
    if (payload is! Map) return null;
    final Object? path = payload['path'];
    if (path is! String) return null;
    return DocumentRef(
      uri: payload['uri'] as String?,
      path: path,
      name: payload['name'] as String? ?? 'document.pdf',
      canWrite: payload['canWrite'] as bool? ?? false,
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
    File source,
  ) async {
    if (!supportsSaf) return null;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'createDocument',
      {'name': suggestedName, 'sourcePath': source.path},
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
      return DocumentFacts(
        size: stat.size,
        modified: stat.modified,
        location: file.path,
        canRename: true,
        canDelete: true,
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
