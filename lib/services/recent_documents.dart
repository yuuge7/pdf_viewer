import 'package:shared_preferences/shared_preferences.dart';

import 'document_service.dart';

/// The Recent Files list.
///
/// Shared rather than owned by `HomeScreen`, because the editor also adds to it
/// (saving a copy produces a new document the app holds a permission grant on,
/// and dropping that on the floor would leak the grant).
class RecentDocuments {
  static const String prefsKey = 'recent_files';
  static const int maxEntries = 10;

  static Future<List<DocumentRef>> load() async {
    final prefs = await SharedPreferences.getInstance();
    // Entries written before Recent Files stored URIs are bare paths; decode
    // tolerates them so upgrading does not wipe the list.
    return (prefs.getStringList(prefsKey) ?? [])
        .map(DocumentRef.decode)
        .whereType<DocumentRef>()
        .toList(growable: false);
  }

  static Future<List<DocumentRef>> add(DocumentRef ref) async {
    final prefs = await SharedPreferences.getInstance();
    final recent = List<DocumentRef>.of(await load())
      ..removeWhere((r) => r.key == ref.key)
      ..insert(0, ref);
    final trimmed = recent.take(maxEntries).toList(growable: false);
    await _save(prefs, trimmed);
    return trimmed;
  }

  static Future<List<DocumentRef>> remove(DocumentRef ref) async {
    final prefs = await SharedPreferences.getInstance();
    final recent = List<DocumentRef>.of(await load())
      ..removeWhere((r) => r.key == ref.key);
    await _save(prefs, recent);
    // Hand the long-lived permission back rather than hoarding grants; Android
    // caps how many a single app can hold.
    await DocumentService.release(ref);
    return recent;
  }

  static Future<void> _save(
    SharedPreferences prefs,
    List<DocumentRef> refs,
  ) {
    return prefs.setStringList(
      prefsKey,
      refs.map((r) => r.encode()).toList(growable: false),
    );
  }
}
