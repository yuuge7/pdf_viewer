import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/document_service.dart';
import '../services/docx_writer.dart';
import '../services/recent_documents.dart';
import 'formatting.dart';

/// Hands finished outputs to the user: save them somewhere lasting, or share.
///
/// Returns the saved document when a single PDF was saved as one the app can
/// reopen, so the caller can offer to open it.
class ExportSheet extends StatefulWidget {
  final List<File> files;
  final String mimeType;
  final String title;
  final String? note;

  const ExportSheet({
    super.key,
    required this.files,
    required this.mimeType,
    required this.title,
    this.note,
  });

  static Future<DocumentRef?> show(
    BuildContext context, {
    required List<File> files,
    required String mimeType,
    required String title,
    String? note,
  }) {
    return showModalBottomSheet<DocumentRef>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ExportSheet(
        files: files,
        mimeType: mimeType,
        title: title,
        note: note,
      ),
    );
  }

  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<ExportSheet> {
  int _sdk = 0;
  bool _busy = false;
  /// Held rather than looked up: messages are also shown after the sheet
  /// has closed, when its context is gone.
  late ScaffoldMessengerState _messenger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.of(context);
  }

  bool get _isPdf => widget.mimeType == 'application/pdf';
  bool get _isImage => widget.mimeType.startsWith('image/');
  bool get _single => widget.files.length == 1;

  @override
  void initState() {
    super.initState();
    DocumentService.sdkInt().then((sdk) {
      if (mounted) setState(() => _sdk = sdk);
    });
  }

  void _say(String message, {SnackBarAction? action}) {
    _messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on PlatformException catch (e) {
      _say(e.message ?? 'Could not save.');
    } catch (e) {
      _say('Could not save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _nameOf(File file) => file.uri.pathSegments.last;

  Future<void> _saveAs() => _run(() async {
    final File file = widget.files.single;
    if (_isPdf) {
      final DocumentRef? saved = await DocumentService.saveCopy(
        _nameOf(file),
        file,
      );
      if (saved == null) return;
      // A lasting grant was taken on it; recording it is what stops the
      // grant from leaking.
      await RecentDocuments.add(saved);
      _say('Saved as ${saved.name}');
      if (mounted) Navigator.of(context).pop(saved);
      return;
    }
    final String? uri = await DocumentService.exportAs(
      _nameOf(file),
      file,
      widget.mimeType,
    );
    if (uri == null) return;
    _say(
      'Saved ${_nameOf(file)}',
      action: SnackBarAction(
        label: 'Open',
        onPressed: () => DocumentService.viewUri(uri, widget.mimeType).catchError(
          (Object e) => _say(
            e is PlatformException
                ? e.message ?? 'No app can open it.'
                : 'No app can open it.',
          ),
        ),
      ),
    );
    if (mounted) Navigator.of(context).pop();
  });

  Future<void> _export(ExportTarget target) => _run(() async {
    final int? written = await DocumentService.exportFiles(
      widget.files,
      widget.mimeType,
      target,
    );
    if (written == null) return; // Cancelled at the folder picker.
    final String where = switch (target) {
      ExportTarget.gallery => 'Pictures/ProPDF Studio',
      ExportTarget.downloads => 'Download/ProPDF Studio',
      ExportTarget.folder => 'the chosen folder',
    };
    _say(
      written == widget.files.length
          ? 'Saved ${written == 1 ? '1 file' : '$written files'} to $where'
          : 'Saved $written of ${widget.files.length} files to $where',
    );
    if (mounted) Navigator.of(context).pop();
  });

  Future<void> _share() => _run(() async {
    await SharePlus.instance.share(
      ShareParams(
        files: [
          for (final File file in widget.files)
            XFile(file.path, mimeType: widget.mimeType),
        ],
      ),
    );
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool saf = DocumentService.supportsSaf;
    final bool mediaStore = _sdk >= 29;
    final int total = widget.files.fold<int>(
      0,
      (sum, f) => sum + (f.existsSync() ? f.lengthSync() : 0),
    );
    final List<File> preview = widget.files.take(3).toList();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.files.length == 1 ? '1 file' : '${widget.files.length} files'}'
              ' · ${formatBytes(total)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            for (final File file in preview)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      _isPdf
                          ? Icons.picture_as_pdf_outlined
                          : _isImage
                          ? Icons.image_outlined
                          : Icons.description_outlined,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _nameOf(file),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            if (widget.files.length > preview.length)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2),
                child: Text(
                  'and ${widget.files.length - preview.length} more',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            if (widget.note != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  widget.note!,
                  style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (_busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (saf && _single && (_isPdf || widget.mimeType == DocxWriter.mimeType))
                _action(Icons.save_alt_rounded, 'Save as…', _saveAs),
              if (mediaStore && _isImage)
                _action(
                  Icons.photo_library_outlined,
                  'Save to Gallery',
                  () => _export(ExportTarget.gallery),
                ),
              if (mediaStore && !_isImage)
                _action(
                  Icons.download_rounded,
                  'Save to Downloads',
                  () => _export(ExportTarget.downloads),
                ),
              if (saf)
                _action(
                  Icons.folder_open_rounded,
                  'Save to folder…',
                  () => _export(ExportTarget.folder),
                ),
              _action(Icons.ios_share_rounded, 'Share', _share),
            ],
          ],
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
      onTap: onTap,
    );
  }
}
