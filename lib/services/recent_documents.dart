import 'package:shared_preferences/shared_preferences.dart';

import 'document_service.dart';

/// A persisted list of documents, most recent first.
///
/// Both lists hold documents the app keeps a persistable grant on, and the
/// grant is shared: it is handed back only once neither list mentions the
/// document any more.
class _DocumentList {
  final String prefsKey;
  final int? maxEntries;

  const _DocumentList(this.prefsKey, {this.maxEntries});

  Future<List<DocumentRef>> load() async {
    final prefs = await SharedPreferences.getInstance();
    // Entries written before Recent Files stored URIs are bare paths; decode
    // tolerates them so upgrading does not wipe the list.
    return (prefs.getStringList(prefsKey) ?? [])
        .map(DocumentRef.decode)
        .whereType<DocumentRef>()
        .toList(growable: false);
  }

  Future<bool> contains(DocumentRef ref) async =>
      (await load()).any((r) => r.key == ref.key);

  Future<List<DocumentRef>> add(DocumentRef ref) async {
    final recent = List<DocumentRef>.of(await load())
      ..removeWhere((r) => r.key == ref.key)
      ..insert(0, ref);
    final int? cap = maxEntries;
    final trimmed = cap == null
        ? recent
        : recent.take(cap).toList(growable: false);
    await _save(trimmed);
    return trimmed;
  }

  /// Drops [ref] without touching its grant.
  Future<List<DocumentRef>> drop(DocumentRef ref) async {
    final recent = List<DocumentRef>.of(await load())
      ..removeWhere((r) => r.key == ref.key);
    await _save(recent);
    return recent;
  }

  /// Swaps the entry for [previous] for [current] in place, if present.
  Future<void> replace(DocumentRef previous, DocumentRef current) async {
    final List<DocumentRef> refs = List<DocumentRef>.of(await load());
    final int index = refs.indexWhere((r) => r.key == previous.key);
    if (index < 0) return;
    refs[index] = current;
    await _save(refs);
  }

  Future<void> _save(List<DocumentRef> refs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      prefsKey,
      refs.map((r) => r.encode()).toList(growable: false),
    );
  }
}

const _DocumentList _recent = _DocumentList('recent_files', maxEntries: 10);
const _DocumentList _favorites = _DocumentList('favorite_files');

/// Gives the grant on [ref] back unless some list still refers to it.
Future<void> _releaseIfUnused(DocumentRef ref) async {
  if (await _recent.contains(ref) || await _favorites.contains(ref)) return;
  // Hand the long-lived permission back rather than hoarding grants; Android
  // caps how many a single app can hold.
  await DocumentService.release(ref);
}

/// The Recent Files list.
///
/// Shared rather than owned by `HomeScreen`, because the editor also adds to it
/// (saving a copy produces a new document the app holds a permission grant on,
/// and dropping that on the floor would leak the grant).
class RecentDocuments {
  static const String prefsKey = 'recent_files';
  static const int maxEntries = 10;

  static Future<List<DocumentRef>> load() => _recent.load();

  static Future<List<DocumentRef>> add(DocumentRef ref) async {
    final List<DocumentRef> before = await _recent.load();
    final List<DocumentRef> after = await _recent.add(ref);
    // Whatever fell off the end of the list may have been its last holder.
    for (final DocumentRef evicted in before) {
      if (!after.any((r) => r.key == evicted.key)) {
        await _releaseIfUnused(evicted);
      }
    }
    return after;
  }

  static Future<List<DocumentRef>> remove(DocumentRef ref) async {
    final List<DocumentRef> recent = await _recent.drop(ref);
    await _releaseIfUnused(ref);
    return recent;
  }

  /// Points every list at a document's new identity after a rename.
  static Future<void> replace(DocumentRef previous, DocumentRef current) async {
    await _recent.replace(previous, current);
    await _favorites.replace(previous, current);
  }

  /// Removes a document that no longer exists from every list.
  static Future<void> forget(DocumentRef ref) async {
    await _recent.drop(ref);
    await _favorites.drop(ref);
    await DocumentService.release(ref);
  }
}

/// Documents the user starred. Unlike Recent Files this list is not capped:
/// the user put everything on it deliberately.
class FavoriteDocuments {
  static const String prefsKey = 'favorite_files';

  static Future<List<DocumentRef>> load() => _favorites.load();

  static Future<bool> contains(DocumentRef ref) => _favorites.contains(ref);

  static Future<List<DocumentRef>> add(DocumentRef ref) => _favorites.add(ref);

  static Future<List<DocumentRef>> remove(DocumentRef ref) async {
    final List<DocumentRef> favorites = await _favorites.drop(ref);
    await _releaseIfUnused(ref);
    return favorites;
  }

  /// Flips [ref] in or out of the list and returns whether it is now in.
  static Future<bool> toggle(DocumentRef ref) async {
    if (await contains(ref)) {
      await remove(ref);
      return false;
    }
    await add(ref);
    return true;
  }
}
