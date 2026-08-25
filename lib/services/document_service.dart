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

  DocumentRef copyWith({String? path, bool? canWrite}) => DocumentRef(
        path: path ?? this.path,
        name: name,
        uri: uri,
        canWrite: canWrite ?? this.canWrite,
      );

  /// Recent Files identity. Two cache copies of the same document share a URI
  /// but not a path, so the URI is the stable key where there is one.
  String get key => uri ?? path;
}

/// Bridges to the platform document APIs.
class DocumentService {
  static const MethodChannel _channel = MethodChannel('propdf/documents');

  /// Whether the Storage Access Framework path is available. Everything else
  /// falls back to `file_picker`, which cannot write back to the original.
  static bool get supportsSaf => !kIsWeb && Platform.isAndroid;

  /// Opens the system document picker. Returns null if the user cancelled.
  static Future<DocumentRef?> pick() async {
    if (supportsSaf) {
      final result = await _channel.invokeMapMethod<String, dynamic>('pickDocument');
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
    return DocumentRef(
      path: path,
      name: picked.first.name,
    );
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
      final path = await _channel.invokeMethod<String>('copyToCache', {'uri': uri});
      if (path == null) return null;
      final canWrite = await _channel.invokeMethod<bool>('canWrite', {'uri': uri}) ?? false;
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
  static Future<DocumentRef?> saveCopy(String suggestedName, File source) async {
    if (!supportsSaf) return null;
    final result = await _channel.invokeMapMethod<String, dynamic>('createDocument', {
      'name': suggestedName,
      'sourcePath': source.path,
    });
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
  /// plain page-number tile rather than showing an error.
  static Future<Uint8List?> renderPage(
    String path,
    int pageIndex, {
    int width = 160,
  }) async {
    if (!supportsSaf) return null;
    try {
      return await _channel.invokeMethod<Uint8List>('renderPage', {
        'path': path,
        'page': pageIndex,
        'width': width,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
