import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/document_import.dart';
import '../services/document_service.dart';
import '../services/recent_documents.dart';
import '../services/scan_service.dart';
import '../widgets/document_actions.dart';
import '../widgets/document_details_sheet.dart';
import '../widgets/export_sheet.dart';
import 'merge_screen.dart';
import 'pdf_editor_screen.dart';
import 'scan_screen.dart';

enum _Shelf { recent, favorites }

enum _TileAction { rename, share, print, favorite, details, forget, delete }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isLoading = false;
  List<DocumentRef> _recentFiles = [];
  List<DocumentRef> _favorites = [];
  _Shelf _shelf = _Shelf.recent;

  StreamSubscription<IncomingDocument>? _incoming;

  /// True while the editor is already on screen, so a second "Open with"
  /// intent does not stack another editor on top of it.
  bool _isEditorOpen = false;

  /// True while a file that is not a PDF is being converted or reviewed on
  /// its way in, for the same reason.
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _loadRecentFiles();
    _incoming = DocumentService.incoming.listen(_openIncoming);
    _consumeLaunchDocument();
  }

  @override
  void dispose() {
    _incoming?.cancel();
    super.dispose();
  }

  /// Opens the document the app was launched with, if another app handed it
  /// one through "Open with".
  Future<void> _consumeLaunchDocument() async {
    final IncomingDocument? launched = await DocumentService.startListening();
    if (launched == null || !mounted) return;
    await _openIncoming(launched);
  }

  Future<void> _openIncoming(IncomingDocument incoming) async {
    if (!mounted || _isEditorOpen || _isImporting) return;
    final DocumentRef ref = incoming.ref;
    ImportKind kind;
    try {
      kind = await DocumentImport.kindOf(
        ref.file,
        name: ref.name,
        mimeType: incoming.mimeType,
      );
    } catch (_) {
      // Unreadable; let the viewer be the one to say so.
      kind = ImportKind.pdf;
    }
    if (!mounted) return;
    if (kind != ImportKind.pdf) {
      await _import(ref, kind);
      return;
    }
    // Only documents the app holds a lasting grant on are worth remembering:
    // the temporary grant on a shared document is gone by the next launch, and
    // the entry would only ever resolve to "File no longer exists".
    if (ref.canWrite) await _addRecentFile(ref);
    await _open(ref);
  }

  /// Brings in a file that is not a PDF: a Word or text file is converted
  /// and opened as an unsaved document, a picture starts a scan session.
  Future<void> _import(DocumentRef source, ImportKind kind) async {
    // The file is read once, here. Nothing will reopen it, so a lasting
    // grant on it, where the sending app offered one, goes straight back.
    unawaited(DocumentService.release(source));
    if (kind == ImportKind.unsupported) {
      _showMessage('ProPDF Studio cannot open "${source.name}".');
      return;
    }

    _isImporting = true;
    try {
      if (kind == ImportKind.image) {
        final File photo = await _withProgress(
          'Preparing ${source.name}',
          () => DocumentImport.preparePhoto(source.file),
        );
        if (!mounted) return;
        await _scan(ScanSource.gallery, initialImages: [photo.path]);
        return;
      }

      final DocumentRef converted = await _withProgress(
        'Converting ${source.name} to PDF',
        () => DocumentImport.toPdf(source, kind),
      );
      if (!mounted) return;
      _showMessage(
        kind == ImportKind.word
            ? 'Converted from Word with a simplified layout. '
                  'Use Save a copy to keep the PDF.'
            : 'Converted to PDF. Use Save a copy to keep it.',
      );
      await _open(converted);
    } on ImportException catch (e) {
      _showMessage('Could not open "${source.name}". ${e.message}');
    } catch (e) {
      _showMessage('Could not open "${source.name}": $e');
    } finally {
      _isImporting = false;
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Runs [task] behind a dialog that says what is taking the time.
  ///
  /// A conversion is seconds of work with nothing on screen but a home page
  /// the user did not ask for, so it needs saying.
  Future<T> _withProgress<T>(String label, Future<T> Function() task) async {
    final NavigatorState navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 24),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      return await task();
    } finally {
      navigator.pop();
    }
  }

  Future<void> _loadRecentFiles() async {
    final refs = await RecentDocuments.load();
    final favorites = await FavoriteDocuments.load();
    if (!mounted) return;
    setState(() {
      _recentFiles = refs;
      _favorites = favorites;
    });
  }

  Future<void> _addRecentFile(DocumentRef ref) async {
    final refs = await RecentDocuments.add(ref);
    if (!mounted) return;
    setState(() => _recentFiles = refs);
  }

  Future<void> _removeRecentFile(DocumentRef ref) async {
    final refs = await RecentDocuments.remove(ref);
    if (!mounted) return;
    setState(() => _recentFiles = refs);
  }

  /// Drops a document that turned out to be gone from both shelves.
  Future<void> _forgetMissing(DocumentRef ref) async {
    await RecentDocuments.forget(ref);
    await _loadRecentFiles();
  }

  Future<void> _open(DocumentRef ref) async {
    if (!mounted) return;
    _isEditorOpen = true;
    try {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PdfEditorScreen(document: ref)),
      );
    } finally {
      _isEditorOpen = false;
    }
    if (!mounted) return;
    // The document may have been saved, renamed or starred while it was open.
    await _loadRecentFiles();
  }

  /// Re-resolves [ref] to a fresh cache copy. Reports and forgets it when it
  /// is gone.
  Future<DocumentRef?> _resolve(DocumentRef ref) async {
    // Re-resolves the URI and refreshes the cache copy. Null means the file
    // is gone or the persisted grant was revoked.
    final DocumentRef? resolved = await DocumentService.reopen(ref);
    if (!mounted) return null;
    if (resolved == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('File no longer exists')));
      await _forgetMissing(ref);
    }
    return resolved;
  }

  Future<void> _openRecentFile(DocumentRef ref) async {
    setState(() => _isLoading = true);
    try {
      final DocumentRef? resolved = await _resolve(ref);
      if (resolved == null || !mounted) return;
      await _addRecentFile(resolved);
      await _open(resolved);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickPDF() async {
    setState(() => _isLoading = true);
    try {
      final DocumentRef? ref = await DocumentService.pick();
      if (!mounted || ref == null) return;
      await _addRecentFile(ref);
      await _open(ref);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error selecting file: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Runs a scan session and opens whatever it produced.
  ///
  /// The session saves through the system picker itself and records the
  /// result in Recent Files, so there is nothing to add here — only the list
  /// on screen needs refreshing.
  Future<void> _scan(
    ScanSource source, {
    List<String> initialImages = const [],
  }) async {
    final DocumentRef? created = await ScanScreen.createDocument(
      context,
      source: source,
      initialImages: initialImages,
    );
    if (!mounted) return;
    await _loadRecentFiles();
    if (created == null || !mounted) return;
    await _open(created);
  }

  Future<void> _merge() async {
    final File? merged = await MergeScreen.open(context);
    if (merged == null || !mounted) return;
    final DocumentRef? saved = await ExportSheet.show(
      context,
      files: [merged],
      mimeType: 'application/pdf',
      title: 'Merged PDF ready',
    );
    if (!mounted) return;
    await _loadRecentFiles();
    if (saved != null && mounted) await _open(saved);
  }

  Future<void> _onTileAction(DocumentRef ref, _TileAction action) async {
    switch (action) {
      case _TileAction.rename:
        final DocumentRef? renamed = await DocumentActions.rename(context, ref);
        if (renamed != null) await _loadRecentFiles();
      case _TileAction.favorite:
        await DocumentActions.toggleFavorite(context, ref);
        await _loadRecentFiles();
      case _TileAction.forget:
        await _removeRecentFile(ref);
      case _TileAction.delete:
        if (await DocumentActions.delete(context, ref)) await _loadRecentFiles();
      case _TileAction.share:
      case _TileAction.print:
      case _TileAction.details:
        // These need the bytes, which means a fresh cache copy.
        setState(() => _isLoading = true);
        try {
          final DocumentRef? resolved = await _resolve(ref);
          if (resolved == null || !mounted) return;
          setState(() => _isLoading = false);
          switch (action) {
            case _TileAction.share:
              await DocumentActions.share(context, resolved.file, resolved.name);
            case _TileAction.print:
              await DocumentActions.printFile(
                context,
                resolved.file,
                resolved.name,
              );
            default:
              await DocumentDetailsSheet.show(
                context,
                document: resolved,
                file: resolved.file,
              );
          }
        } finally {
          if (mounted) setState(() => _isLoading = false);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final List<DocumentRef> shelf = _shelf == _Shelf.recent
        ? _recentFiles
        : _favorites;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text(
          'ProPDF Studio',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Welcome back!',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Manage and annotate your PDFs like a pro.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 40),
              _buildOpenCard(theme),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _buildQuickAction(
                      theme,
                      icon: Icons.document_scanner_rounded,
                      title: 'Scan',
                      subtitle: 'Camera to PDF',
                      onTap: () => _scan(ScanSource.camera),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildQuickAction(
                      theme,
                      icon: Icons.photo_library_rounded,
                      title: 'Images',
                      subtitle: 'Photos to PDF',
                      onTap: () => _scan(ScanSource.gallery),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _buildQuickAction(
                      theme,
                      icon: Icons.library_add_rounded,
                      title: 'Merge',
                      subtitle: 'PDFs into one',
                      onTap: _merge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 40),
              Row(
                children: [
                  _buildShelfTab(theme, _Shelf.recent, 'Recent Files'),
                  const SizedBox(width: 20),
                  _buildShelfTab(theme, _Shelf.favorites, 'Favorites'),
                ],
              ),
              const SizedBox(height: 16),
              if (shelf.isEmpty)
                _buildEmptyState(theme)
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: shelf.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, index) =>
                      _buildRecentTile(theme, shelf[index]),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShelfTab(ThemeData theme, _Shelf shelf, String label) {
    final bool selected = _shelf == shelf;
    return InkWell(
      onTap: () => setState(() => _shelf = shelf),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: selected
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 3,
              width: selected ? 32 : 0,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOpenCard(ThemeData theme) {
    return InkWell(
      onTap: _isLoading ? null : _pickPDF,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [theme.colorScheme.primary, theme.colorScheme.tertiary],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.primary.withValues(alpha: 0.3),
              blurRadius: 15,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          children: [
            if (_isLoading)
              const CircularProgressIndicator(color: Colors.white)
            else
              const Icon(
                Icons.upload_file_rounded,
                size: 64,
                color: Colors.white,
              ),
            const SizedBox(height: 16),
            Text(
              'Open a Document',
              style: theme.textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap to select a PDF from your device',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Three of these share a row, so the icon sits above the text rather
  /// than beside it, where the subtitle would be cut to nothing.
  Widget _buildQuickAction(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: _isLoading ? null : onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.5,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(height: 8),
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    final bool favorites = _shelf == _Shelf.favorites;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        children: [
          Icon(
            favorites ? Icons.star_border_rounded : Icons.folder_open_rounded,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            favorites ? 'No favorites yet' : 'No recent files yet',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            favorites
                ? 'Star a document from its menu to keep it here'
                : 'Files you open will appear here',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentTile(ThemeData theme, DocumentRef ref) {
    final bool favorite = _favorites.any((f) => f.key == ref.key);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Badge(
        isLabelVisible: favorite,
        backgroundColor: Colors.transparent,
        alignment: AlignmentDirectional.topEnd,
        label: const Icon(Icons.star_rounded, size: 16, color: Colors.amber),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.picture_as_pdf_rounded,
            color: theme.colorScheme.primary,
          ),
        ),
      ),
      title: Text(
        ref.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        // The content URI is opaque and meaningless to a person; say something
        // useful about the document instead.
        ref.savesInPlace ? 'Saves to the original file' : 'Read-only copy',
        style: TextStyle(
          fontSize: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: _isLoading ? null : () => _openRecentFile(ref),
      trailing: PopupMenuButton<_TileAction>(
        icon: const Icon(Icons.more_vert_rounded),
        tooltip: 'More',
        enabled: !_isLoading,
        onSelected: (action) => _onTileAction(ref, action),
        itemBuilder: (_) => [
          _menuItem(_TileAction.rename, Icons.drive_file_rename_outline, 'Rename'),
          _menuItem(_TileAction.share, Icons.ios_share_rounded, 'Share'),
          if (DocumentService.supportsSaf)
            _menuItem(_TileAction.print, Icons.print_outlined, 'Print'),
          _menuItem(
            _TileAction.favorite,
            favorite ? Icons.star_rounded : Icons.star_border_rounded,
            favorite ? 'Remove from Favorites' : 'Add to Favorites',
          ),
          _menuItem(_TileAction.details, Icons.info_outline_rounded, 'Details'),
          if (_shelf == _Shelf.recent)
            _menuItem(
              _TileAction.forget,
              Icons.playlist_remove_rounded,
              'Remove from recents',
            ),
          _menuItem(
            _TileAction.delete,
            Icons.delete_outline_rounded,
            'Delete file',
            color: theme.colorScheme.error,
          ),
        ],
      ),
    );
  }

  PopupMenuItem<_TileAction> _menuItem(
    _TileAction value,
    IconData icon,
    String label, {
    Color? color,
  }) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          // Menus are capped in width; a long label ellipsises, not overflows.
          Flexible(
            child: Text(
              label,
              style: TextStyle(color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
