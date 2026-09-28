import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Signatures the user has drawn, kept as transparent PNGs so they can be
/// placed again without redrawing.
class SignatureStore {
  static Future<Directory> _directory() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    final Directory directory = Directory('${documents.path}/signatures');
    if (!directory.existsSync()) await directory.create(recursive: true);
    return directory;
  }

  /// Saved signatures, newest first.
  static Future<List<File>> list() async {
    try {
      final Directory directory = await _directory();
      final List<File> files = directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.png'))
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return const [];
    }
  }

  static Future<File> save(Uint8List png) async {
    final Directory directory = await _directory();
    final File file = File(
      '${directory.path}/signature_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    return file.writeAsBytes(png, flush: true);
  }

  static Future<void> delete(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Already gone.
    }
  }
}
