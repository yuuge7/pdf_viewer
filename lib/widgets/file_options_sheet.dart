import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/document_service.dart';

enum FileAction {
  details,
  rename,
  share,
  print,
  favorite,
  saveCopy,
  bookmarks,
  toImage,
  toLongImage,
  toWord,
  merge,
  split,
  compress,
  delete,
  feedback,
}

/// The "more" sheet for one document: a header that opens its details,
/// quick actions, conversions, page tools and the destructive end.
class FileOptionsSheet extends StatefulWidget {
  final DocumentRef document;

  /// File to draw the header thumbnail from; the viewer's current copy.
  final String renderPath;
  final bool isFavorite;

  /// Actions to leave out, for places where they make no sense.
  final Set<FileAction> hidden;

  const FileOptionsSheet({
    super.key,
    required this.document,
    required this.renderPath,
    required this.isFavorite,
    this.hidden = const {},
  });

  static Future<FileAction?> show(
    BuildContext context, {
    required DocumentRef document,
    required String renderPath,
    required bool isFavorite,
    Set<FileAction> hidden = const {},
  }) {
    return showModalBottomSheet<FileAction>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FileOptionsSheet(
        document: document,
        renderPath: renderPath,
        isFavorite: isFavorite,
        hidden: hidden,
      ),
    );
  }

  @override
  State<FileOptionsSheet> createState() => _FileOptionsSheetState();
}

class _FileOptionsSheetState extends State<FileOptionsSheet> {
  Uint8List? _thumbnail;
  String? _location;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Future<Uint8List?> thumbnail = DocumentService.renderPage(
      widget.renderPath,
      0,
      width: 160,
    );
    final DocumentFacts facts = await DocumentService.facts(widget.document);
    final Uint8List? bytes = await thumbnail;
    if (!mounted) return;
    setState(() {
      _thumbnail = bytes;
      _location = facts.location;
    });
  }

  void _pick(FileAction action) => Navigator.of(context).pop(action);

  bool _shows(FileAction action) => !widget.hidden.contains(action);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;

    final List<List<Widget>> groups = [
      [
        if (_shows(FileAction.saveCopy))
          _row(Icons.save_as_outlined, 'Save a copy', FileAction.saveCopy),
        if (_shows(FileAction.bookmarks))
          _row(Icons.bookmarks_outlined, 'Bookmarks', FileAction.bookmarks),
      ],
      [
        if (_shows(FileAction.toImage))
          _row(Icons.image_outlined, 'PDF to image', FileAction.toImage),
        if (_shows(FileAction.toLongImage))
          _row(
            Icons.view_day_outlined,
            'PDF to long image',
            FileAction.toLongImage,
          ),
        if (_shows(FileAction.toWord))
          _row(Icons.description_outlined, 'PDF to Word', FileAction.toWord),
      ],
      [
        if (_shows(FileAction.merge))
          _row(Icons.library_add_outlined, 'Merge PDF', FileAction.merge),
        if (_shows(FileAction.split))
          _row(Icons.call_split_rounded, 'Split PDF', FileAction.split),
        if (_shows(FileAction.compress))
          _row(Icons.compress_rounded, 'Compress PDF', FileAction.compress),
      ],
      [
        if (_shows(FileAction.delete))
          _row(
            Icons.delete_outline_rounded,
            'Delete',
            FileAction.delete,
            color: colors.error,
          ),
        if (_shows(FileAction.feedback))
          _row(Icons.feedback_outlined, 'Feedback', FileAction.feedback),
      ],
    ].where((group) => group.isNotEmpty).toList();

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(theme),
              const Divider(indent: 20, endIndent: 20),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    if (_shows(FileAction.rename))
                      _quick(Icons.drive_file_rename_outline, 'Rename', FileAction.rename),
                    if (_shows(FileAction.share))
                      _quick(Icons.ios_share_rounded, 'Share', FileAction.share),
                    if (_shows(FileAction.print))
                      _quick(Icons.print_outlined, 'Print', FileAction.print),
                    if (_shows(FileAction.favorite))
                      _quick(
                        widget.isFavorite
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        'Favorite',
                        FileAction.favorite,
                        color: widget.isFavorite ? Colors.amber : null,
                      ),
                  ],
                ),
              ),
              for (final List<Widget> group in groups) ...[
                const Divider(indent: 20, endIndent: 20),
                ...group,
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final ColorScheme colors = theme.colorScheme;
    return InkWell(
      onTap: _shows(FileAction.details) ? () => _pick(FileAction.details) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 64,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: colors.outlineVariant),
              ),
              clipBehavior: Clip.antiAlias,
              child: _thumbnail != null
                  ? Image.memory(_thumbnail!, fit: BoxFit.cover)
                  : Icon(
                      Icons.picture_as_pdf_rounded,
                      color: colors.primary,
                    ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.document.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_location != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      _location!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (_shows(FileAction.details))
              Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _quick(
    IconData icon,
    String label,
    FileAction action, {
    Color? color,
  }) {
    final ThemeData theme = Theme.of(context);
    return Expanded(
      child: InkWell(
        onTap: () => _pick(action),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 28, color: color ?? theme.colorScheme.onSurface),
              const SizedBox(height: 6),
              Text(label, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(IconData icon, String label, FileAction action, {Color? color}) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      onTap: () => _pick(action),
    );
  }
}
