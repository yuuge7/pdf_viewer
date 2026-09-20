import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/document_service.dart';
import '../services/scan_service.dart';

/// Grid of page thumbnails for jumping around a document.
///
/// Thumbnails are rasterised on demand by the platform. Where that is not
/// available the tile degrades to a plain numbered card, so the picker still
/// works as a jump-to-page control rather than showing an error.
class PageThumbnails extends StatefulWidget {
  /// Path to the document being viewed. Every edit produces a new file, so
  /// this doubles as the cache key.
  final String path;
  final int pageCount;
  final int currentPage;
  final ValueChanged<int> onSelect;

  /// Page operations, given 0-based page indices.
  ///
  /// Each of these replaces the document, which makes [path] and [pageCount]
  /// stale, so the sheet closes itself before handing the work over rather
  /// than trying to stay in sync with a file it no longer describes.
  final ValueChanged<List<int>>? onRotate;
  final ValueChanged<List<int>>? onDelete;
  final ValueChanged<ScanSource>? onAddPages;

  const PageThumbnails({
    super.key,
    required this.path,
    required this.pageCount,
    required this.currentPage,
    required this.onSelect,
    this.onRotate,
    this.onDelete,
    this.onAddPages,
  });

  /// Opens the picker as a bottom sheet, scrolled to the current page.
  static Future<void> show(
    BuildContext context, {
    required String path,
    required int pageCount,
    required int currentPage,
    required ValueChanged<int> onSelect,
    ValueChanged<List<int>>? onRotate,
    ValueChanged<List<int>>? onDelete,
    ValueChanged<ScanSource>? onAddPages,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => PageThumbnails(
        path: path,
        pageCount: pageCount,
        currentPage: currentPage,
        onSelect: onSelect,
        onRotate: onRotate,
        onDelete: onDelete,
        onAddPages: onAddPages,
      ),
    );
  }

  @override
  State<PageThumbnails> createState() => _PageThumbnailsState();
}

class _PageThumbnailsState extends State<PageThumbnails> {
  /// Rendered PNGs by page index. A present-but-null entry means rendering was
  /// attempted and is unavailable, so it is not retried on every rebuild.
  final Map<int, Uint8List?> _cache = {};
  final Set<int> _inFlight = {};
  late final ScrollController _scrollController;
  bool _hasScrolled = false;

  /// 0-based indices of the pages picked for a bulk operation. Empty means
  /// the sheet is in its ordinary jump-to-page mode.
  final Set<int> _selected = {};

  bool get _canEditPages => widget.onRotate != null || widget.onDelete != null;
  bool get _isSelecting => _selected.isNotEmpty;

  static const double _tileWidth = 110;
  static const double _tileAspect = 0.72;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  /// Scrolls the current page into view once the real column count is known.
  ///
  /// The grid sizes itself with maxCrossAxisExtent, so the number of columns
  /// depends on the sheet width; assuming a fixed count lands several rows off
  /// on most screens.
  void _scrollToCurrent(double viewportWidth) {
    if (_hasScrolled || widget.currentPage <= 1) return;
    _hasScrolled = true;
    const double spacing = 12;
    final double usable = viewportWidth - 32; // horizontal padding
    final int columns = ((usable + spacing) / (_tileWidth + spacing))
        .floor()
        .clamp(1, 99);
    final double tileHeight =
        (usable - (columns - 1) * spacing) / columns / _tileAspect;
    final int row = (widget.currentPage - 1) ~/ columns;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final double target = row * (tileHeight + spacing);
      _scrollController.jumpTo(
        target.clamp(0.0, _scrollController.position.maxScrollExtent),
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load(int pageIndex) async {
    if (_cache.containsKey(pageIndex) || _inFlight.contains(pageIndex)) return;
    _inFlight.add(pageIndex);
    final bytes = await DocumentService.renderPage(
      widget.path,
      pageIndex,
      width: 220,
    );
    _inFlight.remove(pageIndex);
    if (!mounted) return;
    setState(() => _cache[pageIndex] = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
              child: Row(
                children: [
                  Text(
                    _isSelecting ? '${_selected.length} selected' : 'Pages',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (_isSelecting)
                    TextButton(
                      onPressed: () => setState(_selected.clear),
                      child: const Text('Clear'),
                    )
                  else ...[
                    Text(
                      '${widget.pageCount} '
                      'page${widget.pageCount == 1 ? '' : 's'}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (widget.onAddPages != null)
                      PopupMenuButton<ScanSource>(
                        icon: const Icon(Icons.add_a_photo_outlined),
                        tooltip: 'Add pages',
                        onSelected: (source) {
                          Navigator.of(context).pop();
                          widget.onAddPages!(source);
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: ScanSource.camera,
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.photo_camera_rounded),
                              title: Text('Scan with camera'),
                            ),
                          ),
                          PopupMenuItem(
                            value: ScanSource.gallery,
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.photo_library_rounded),
                              title: Text('Add from gallery'),
                            ),
                          ),
                        ],
                      ),
                  ],
                ],
              ),
            ),
            if (_canEditPages && !_isSelecting)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.touch_app_outlined,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Tap to jump, long-press to select and edit pages',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _scrollToCurrent(constraints.maxWidth);
                  return GridView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: _tileWidth,
                          childAspectRatio: _tileAspect,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                    itemCount: widget.pageCount,
                    itemBuilder: (context, index) => _buildTile(theme, index),
                  );
                },
              ),
            ),
            if (_isSelecting) _buildSelectionActions(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionActions(ThemeData theme) {
    final List<int> selected = _selected.toList()..sort();
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            if (widget.onRotate != null)
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onRotate!(selected);
                },
                icon: const Icon(Icons.rotate_right_rounded),
                label: const Text('Rotate'),
              ),
            if (widget.onDelete != null)
              TextButton.icon(
                // Deleting every page would leave no document at all, so the
                // service refuses it; disabling here says so before the tap.
                onPressed: selected.length >= widget.pageCount
                    ? null
                    : () {
                        Navigator.of(context).pop();
                        widget.onDelete!(selected);
                      },
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Delete'),
              ),
          ],
        ),
      ),
    );
  }

  void _toggleSelection(int index) {
    setState(() {
      if (!_selected.remove(index)) _selected.add(index);
    });
  }

  Widget _buildTile(ThemeData theme, int index) {
    final int pageNumber = index + 1;
    final bool isCurrent = pageNumber == widget.currentPage;
    final bool isSelected = _selected.contains(index);

    // GridView.builder only builds visible tiles, so this renders lazily.
    if (!_cache.containsKey(index)) _load(index);
    final Uint8List? bytes = _cache[index];

    return InkWell(
      onTap: () {
        // Once a selection exists every tap extends or shrinks it; jumping
        // away mid-selection would close the sheet and lose the choice.
        if (_isSelecting) {
          _toggleSelection(index);
          return;
        }
        widget.onSelect(pageNumber);
        Navigator.of(context).pop();
      },
      onLongPress: _canEditPages ? () => _toggleSelection(index) : null,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  width: double.infinity,
                  height: double.infinity,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? theme.colorScheme.primary
                          : isCurrent
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                      width: (isSelected || isCurrent) ? 2.5 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: bytes != null
                      ? Image.memory(
                          bytes,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) =>
                              _placeholder(theme, pageNumber),
                        )
                      : _placeholder(
                          theme,
                          pageNumber,
                          // Distinguish "still rendering" from "cannot render".
                          showSpinner: !_cache.containsKey(index),
                        ),
                ),
                if (isSelected)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.22,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.check_circle_rounded,
                            size: 20,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$pageNumber',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(
    ThemeData theme,
    int pageNumber, {
    bool showSpinner = false,
  }) {
    return Center(
      child: showSpinner
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              Icons.description_outlined,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
    );
  }
}
