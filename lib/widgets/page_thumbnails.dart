import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/document_service.dart';

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

  const PageThumbnails({
    super.key,
    required this.path,
    required this.pageCount,
    required this.currentPage,
    required this.onSelect,
  });

  /// Opens the picker as a bottom sheet, scrolled to the current page.
  static Future<void> show(
    BuildContext context, {
    required String path,
    required int pageCount,
    required int currentPage,
    required ValueChanged<int> onSelect,
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
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Text(
                    'Pages',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${widget.pageCount} page${widget.pageCount == 1 ? '' : 's'}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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
          ],
        ),
      ),
    );
  }

  Widget _buildTile(ThemeData theme, int index) {
    final int pageNumber = index + 1;
    final bool isCurrent = pageNumber == widget.currentPage;

    // GridView.builder only builds visible tiles, so this renders lazily.
    if (!_cache.containsKey(index)) _load(index);
    final Uint8List? bytes = _cache[index];

    return InkWell(
      onTap: () {
        widget.onSelect(pageNumber);
        Navigator.of(context).pop();
      },
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isCurrent
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                  width: isCurrent ? 2.5 : 1,
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
