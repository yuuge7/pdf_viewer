import 'package:flutter/material.dart';

import '../services/document_service.dart';
import '../services/recent_documents.dart';
import 'pdf_editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isLoading = false;
  List<DocumentRef> _recentFiles = [];

  @override
  void initState() {
    super.initState();
    _loadRecentFiles();
  }

  Future<void> _loadRecentFiles() async {
    final refs = await RecentDocuments.load();
    if (!mounted) return;
    setState(() => _recentFiles = refs);
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

  Future<void> _open(DocumentRef ref) async {
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PdfEditorScreen(document: ref)),
    );
    // The document may have been saved while it was open.
    await _loadRecentFiles();
  }

  Future<void> _openRecentFile(DocumentRef ref) async {
    setState(() => _isLoading = true);
    try {
      // Re-resolves the URI and refreshes the cache copy. Null means the file
      // is gone or the persisted grant was revoked.
      final DocumentRef? resolved = await DocumentService.reopen(ref);
      if (!mounted) return;
      if (resolved == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File no longer exists')),
        );
        await _removeRecentFile(ref);
        return;
      }
      await _addRecentFile(resolved);
      await _open(resolved);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open: $e')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error selecting file: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
              const SizedBox(height: 40),
              Text(
                'Recent Files',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              if (_recentFiles.isEmpty)
                _buildEmptyState(theme)
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _recentFiles.length,
                  separatorBuilder: (_, _) => const Divider(),
                  itemBuilder: (context, index) =>
                      _buildRecentTile(theme, _recentFiles[index]),
                ),
            ],
          ),
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
              const Icon(Icons.upload_file_rounded, size: 64, color: Colors.white),
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

  Widget _buildEmptyState(ThemeData theme) {
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
            Icons.folder_open_rounded,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No recent files yet',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Files you open will appear here',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentTile(ThemeData theme, DocumentRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
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
      trailing: IconButton(
        icon: const Icon(Icons.close_rounded, size: 20),
        onPressed: () => _removeRecentFile(ref),
        tooltip: 'Remove from recents',
      ),
    );
  }
}
