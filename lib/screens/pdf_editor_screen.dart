import 'dart:io';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfPage, PdfPageRotateAngle;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../services/document_service.dart';
import '../services/pdf_page_geometry.dart';
import '../services/pdf_service.dart';
import '../services/recent_documents.dart';
import '../widgets/page_thumbnails.dart';

enum EditTool { none, text, highlight, draw }

/// Gap between pages, shared by the viewer and the coordinate mapping.
///
/// These must agree or annotations land on the wrong page, so the value lives
/// in exactly one place.
const double kPageSpacing = 4.0;

/// A stroke the user has drawn but not yet written into the PDF.
///
/// Both representations are kept: [screenPoints] drives the live preview
/// overlay, [pagePoints] is what gets written. The mapping is done at the
/// moment the stroke is finished, while the viewer transform is guaranteed to
/// be the one the user drew against.
class _PendingStroke {
  final List<Offset> screenPoints;
  final List<Offset> pagePoints;
  final int pageIndex;
  final Color color;
  final double width;

  const _PendingStroke({
    required this.screenPoints,
    required this.pagePoints,
    required this.pageIndex,
    required this.color,
    required this.width,
  });
}

/// A highlight the user has drawn but not yet written into the PDF.
class _PendingHighlight {
  final Rect screenBounds;
  final Rect pageBounds;
  final int pageIndex;
  final Color color;

  const _PendingHighlight({
    required this.screenBounds,
    required this.pageBounds,
    required this.pageIndex,
    required this.color,
  });
}

class PdfEditorScreen extends StatefulWidget {
  final DocumentRef document;

  const PdfEditorScreen({super.key, required this.document});

  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  late File _currentFile;
  PdfViewerController _pdfViewerController = PdfViewerController();
  GlobalKey<SfPdfViewerState> _pdfViewerKey = GlobalKey();
  bool _isLoading = false;

  /// Every edit produces a new file; undo/redo just moves [_historyIndex].
  final List<File> _history = [];
  int _historyIndex = 0;

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  PdfTextSearchResult? _searchResult;

  EditTool _activeTool = EditTool.none;
  List<Offset> _currentDrawing = [];
  final List<_PendingStroke> _pendingDrawStrokes = [];
  final List<_PendingHighlight> _pendingHighlights = [];

  Offset? _textPosition;
  PdfPagePoint? _textTarget;
  bool _isEnteringText = false;
  final TextEditingController _textOverlayController = TextEditingController();

  Offset? _targetScrollOffset;
  double? _targetZoom;

  /// Actual laid-out width of the viewer, from a LayoutBuilder rather than
  /// MediaQuery, which reports the whole screen including the app bar and
  /// bottom bar insets.
  double _viewportWidth = 0;

  /// Size of every page *as displayed*, captured on load. Pages in a document
  /// are not necessarily uniform, and assuming they are misplaces annotations.
  List<Size> _pageSizes = const [];

  /// Each page's own size and rotation, needed to turn a point picked in
  /// display space back into the space the document is actually written in.
  List<Size> _unrotatedPageSizes = const [];
  List<PdfPageTurn> _pageTurns = const [];

  int _currentPage = 1;

  Color _selectedTextColor = Colors.red;
  double _selectedTextSize = 24.0;
  Color _selectedDrawColor = Colors.blue;
  double _selectedDrawWidth = 3.0;
  Color _selectedHighlightColor = Colors.yellow;

  @override
  void initState() {
    super.initState();
    _currentFile = widget.document.file;
    _savedPath = _currentFile.path;
    _history.add(_currentFile);
    _sweepStaleTempFiles();
  }

  @override
  void dispose() {
    _searchResult?.removeListener(_onSearchResultChanged);
    _searchResult?.clear();
    _searchController.dispose();
    _textOverlayController.dispose();
    _pdfViewerController.dispose();
    super.dispose();
  }

  /// Deletes edit scratch files left behind by previous sessions.
  ///
  /// Every edit writes a new `edited_*.pdf` next to the last one and nothing
  /// ever removed them, so the app's storage grew without bound. Only files
  /// older than a day are touched, so nothing in play is removed.
  Future<void> _sweepStaleTempFiles() async {
    try {
      // Must be the app documents directory, which is where PdfService writes.
      // Sweeping the opened document's own folder would both miss the scratch
      // files and risk deleting the user's files that happen to match.
      final Directory directory = await getApplicationDocumentsDirectory();
      final DateTime cutoff =
          DateTime.now().subtract(const Duration(days: 1));
      await for (final FileSystemEntity entity in directory.list()) {
        if (entity is! File) continue;
        final String name = entity.uri.pathSegments.last;
        if (!name.startsWith('edited_') || !name.endsWith('.pdf')) continue;
        if (entity.path == _currentFile.path) continue;
        final FileStat stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
        }
      }
    } catch (_) {
      // Housekeeping only; never let it break opening a document.
    }
  }

  PdfPageGeometry? get _geometry {
    if (_pageSizes.isEmpty || _viewportWidth <= 0) return null;
    final geometry = PdfPageGeometry(
      pageSizes: _pageSizes,
      viewportWidth: _viewportWidth,
      pageSpacing: kPageSpacing,
      zoom: _pdfViewerController.zoomLevel,
      scrollOffset: _pdfViewerController.scrollOffset,
    );
    return geometry.isUsable ? geometry : null;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Text ------------------------------------------------------------------

  Future<void> _commitTextAnnotation(String text) async {
    final PdfPagePoint? target = _textTarget;
    if (target == null || text.trim().isEmpty) {
      setState(() {
        _textPosition = null;
        _textTarget = null;
        _isEnteringText = false;
        _textOverlayController.clear();
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _textPosition = null;
      _textTarget = null;
      _isEnteringText = false;
      _textOverlayController.clear();
    });

    final PdfEditResult result = await PdfService.addTextAnnotation(
      _currentFile,
      target.pageIndex,
      text,
      target.pagePoint,
      _selectedTextColor,
      _selectedTextSize,
    );

    if (!mounted) return;
    _handleResult(result, 'Text added');
    setState(() => _activeTool = EditTool.none);
  }

  // --- Draw / highlight ------------------------------------------------------

  Future<void> _commitPendingHighlights() async {
    if (_pendingHighlights.isEmpty) return;
    setState(() => _isLoading = true);

    // Group by page: a batch can span several pages, and forcing all of them
    // onto the first one put annotations on the wrong page.
    final Map<int, List<HighlightRect>> byPage = {};
    for (final _PendingHighlight h in _pendingHighlights) {
      byPage
          .putIfAbsent(h.pageIndex, () => [])
          .add(HighlightRect(bounds: h.pageBounds, color: h.color));
    }

    final PdfEditResult result = await _applyPerPage(
      byPage.keys,
      (file, pageIndex) =>
          PdfService.addHighlightAnnotation(file, pageIndex, byPage[pageIndex]!),
    );

    if (!mounted) return;
    // Only discard the pending work once it is safely in the document.
    if (result.isSuccess) _pendingHighlights.clear();
    _handleResult(result, 'Highlight added');
  }

  Future<void> _commitPendingDrawStrokes() async {
    if (_pendingDrawStrokes.isEmpty) return;
    setState(() => _isLoading = true);

    final Map<int, List<DrawStroke>> byPage = {};
    for (final _PendingStroke s in _pendingDrawStrokes) {
      byPage.putIfAbsent(s.pageIndex, () => []).add(
            DrawStroke(
              points: s.pagePoints,
              color: s.color,
              width: s.width,
            ),
          );
    }

    final PdfEditResult result = await _applyPerPage(
      byPage.keys,
      (file, pageIndex) =>
          PdfService.addDrawAnnotation(file, pageIndex, byPage[pageIndex]!),
    );

    if (!mounted) return;
    if (result.isSuccess) _pendingDrawStrokes.clear();
    _handleResult(result, 'Drawing added');
  }

  /// Applies [operation] once per page, chaining the output of each step into
  /// the next so the batch lands as a single history entry.
  Future<PdfEditResult> _applyPerPage(
    Iterable<int> pageIndices,
    Future<PdfEditResult> Function(File file, int pageIndex) operation,
  ) async {
    File source = _currentFile;
    final List<File> intermediates = [];

    for (final int pageIndex in pageIndices) {
      final PdfEditResult result = await operation(source, pageIndex);
      // Register the input as disposable before bailing out, or a mid-batch
      // failure strands the previous step's output on disk.
      if (source != _currentFile) intermediates.add(source);
      if (!result.isSuccess) {
        await _deleteAll(intermediates);
        return result;
      }
      source = result.file!;
    }

    await _deleteAll(intermediates);
    return PdfEditResult.success(source);
  }

  Future<void> _deleteAll(Iterable<File> files) async {
    for (final File file in files) {
      try {
        await file.delete();
      } catch (_) {
        // Best effort.
      }
    }
  }

  // --- History ---------------------------------------------------------------

  void _handleResult(PdfEditResult result, String successMessage) {
    if (!result.isSuccess) {
      setState(() => _isLoading = false);
      _showMessage(result.error!);
      return;
    }
    _swapDocument(result.file!, addToHistory: true);
    _showMessage(successMessage);
  }

  /// Points the viewer at [file].
  ///
  /// `SfPdfViewer` caches by document, so the widget and its controller have to
  /// be recreated for the new bytes to be picked up. Scroll position and zoom
  /// are carried across so the view does not jump back to page one.
  void _swapDocument(File file, {required bool addToHistory}) {
    _targetScrollOffset = _pdfViewerController.scrollOffset;
    _targetZoom = _pdfViewerController.zoomLevel;

    final PdfViewerController oldController = _pdfViewerController;
    final List<File> orphaned = [];

    setState(() {
      if (addToHistory) {
        if (_historyIndex < _history.length - 1) {
          // The redo branch is being replaced; its files are now unreachable.
          orphaned.addAll(_history.sublist(_historyIndex + 1));
          _history.removeRange(_historyIndex + 1, _history.length);
        }
        _history.add(file);
        _historyIndex++;
      }

      _currentFile = file;
      _pdfViewerKey = GlobalKey();
      _pdfViewerController = PdfViewerController();
      _isLoading = false;

      // The fresh controller reports zoom 1.0 and offset zero until the new
      // document finishes loading. Dropping the page sizes makes _geometry
      // null for that window, so a stroke drawn mid-reload is refused instead
      // of being silently mapped onto page one.
      _pageSizes = const [];
      _unrotatedPageSizes = const [];
      _pageTurns = const [];

      // A search belongs to the controller that ran it.
      _searchResult?.removeListener(_onSearchResultChanged);
      _searchResult = null;
    });

    // Deferred: the outgoing SfPdfViewer stays mounted until the end of this
    // frame and would throw if it notified an already-disposed controller.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => oldController.dispose());
    // Never delete the file the user opened.
    _deleteAll(orphaned.where((f) => f.path != widget.document.path));
  }

  void _undo() {
    if (_historyIndex <= 0) return;
    _historyIndex--;
    _swapDocument(_history[_historyIndex], addToHistory: false);
  }

  void _redo() {
    if (_historyIndex >= _history.length - 1) return;
    _historyIndex++;
    _swapDocument(_history[_historyIndex], addToHistory: false);
  }

  // --- Save / share ----------------------------------------------------------

  /// Path the document on disk currently matches. Starts as the file that was
  /// opened and moves forward on each successful save.
  late String _savedPath;

  bool get _hasUnsavedChanges => _currentFile.path != _savedPath;

  Future<void> _savePdf() async {
    if (!_hasUnsavedChanges) {
      _showMessage('No changes to save.');
      return;
    }
    // Without a write grant the only honest option is Save a copy: writing to
    // the cache path would report success and change nothing the user can see.
    if (!widget.document.savesInPlace) {
      _showMessage('This document is read-only. Use Save a copy.');
      await _saveCopy();
      return;
    }

    setState(() => _isLoading = true);
    try {
      await DocumentService.write(widget.document, _currentFile);
      if (!mounted) return;
      // The document on disk now matches this file, so Save reports "no
      // changes" until the next edit. History is deliberately left alone --
      // rewriting _history[0] would make Undo jump to a file the user never
      // navigated to.
      setState(() => _savedPath = _currentFile.path);
      _showMessage('Saved to ${widget.document.name}');
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to save: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveCopy() async {
    if (!DocumentService.supportsSaf) {
      _showMessage('Saving a copy is not supported on this platform.');
      return;
    }
    setState(() => _isLoading = true);
    try {
      final DocumentRef? saved = await DocumentService.saveCopy(
        _suggestedCopyName(),
        _currentFile,
      );
      if (!mounted) return;
      if (saved == null) return; // Cancelled.
      // The native side took a persistable grant on the new document. Record
      // it, or that grant leaks and the copy never appears in Recent Files.
      await RecentDocuments.add(saved);
      _showMessage('Saved a copy as ${saved.name}');
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to save a copy: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // --- Navigation ------------------------------------------------------------

  Future<void> _showThumbnails() async {
    // Captured up front: flushing swaps the document, which clears _pageSizes
    // until the replacement finishes loading. Annotations never change the page
    // count, so the pre-flush value stays correct for the new file.
    final int pageCount = _pageSizes.length;
    if (pageCount == 0) return;
    // Any tool holding unmapped work must be flushed first: jumping pages
    // moves the viewer transform the pending strokes were captured against.
    await _changeTool(EditTool.none);
    if (!mounted) return;
    await PageThumbnails.show(
      context,
      path: _currentFile.path,
      pageCount: pageCount,
      currentPage: _currentPage,
      onSelect: (page) => _pdfViewerController.jumpToPage(page),
    );
  }

  String _suggestedCopyName() {
    final String name = widget.document.name;
    final int dot = name.lastIndexOf('.');
    if (dot <= 0) return '$name (edited).pdf';
    return '${name.substring(0, dot)} (edited)${name.substring(dot)}';
  }

  Future<void> _sharePdf() async {
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(_currentFile.path)],
          text: 'Here is my document from ProPDF Studio',
        ),
      );
    } catch (e) {
      _showMessage('Could not share: $e');
    }
  }

  // --- Search ----------------------------------------------------------------

  /// `PdfTextSearchResult` is a ChangeNotifier that fills in asynchronously.
  /// Without this listener the match counter and the next/previous buttons
  /// appeared to do nothing until some unrelated rebuild happened.
  void _onSearchResultChanged() {
    if (mounted) setState(() {});
  }

  void _runSearch(String value) {
    if (value.isEmpty) return;
    _searchResult?.removeListener(_onSearchResultChanged);
    _searchResult?.clear();
    final PdfTextSearchResult result = _pdfViewerController.searchText(value);
    result.addListener(_onSearchResultChanged);
    setState(() => _searchResult = result);
  }

  void _closeSearch() {
    _searchController.clear();
    _searchResult?.removeListener(_onSearchResultChanged);
    _searchResult?.clear();
    setState(() {
      _searchResult = null;
      _isSearching = false;
    });
  }

  // --- Tools -----------------------------------------------------------------

  Future<void> _changeTool(EditTool newTool) async {
    if (_activeTool == newTool) newTool = EditTool.none;

    // Flush anything drawn with the tool being left behind. If the flush
    // fails the work is still pending, and switching away would hide its
    // overlay while leaving it queued against a view that has since moved --
    // so stay on the tool and let the user retry or redraw.
    if (_activeTool == EditTool.draw && _pendingDrawStrokes.isNotEmpty) {
      await _commitPendingDrawStrokes();
      if (_pendingDrawStrokes.isNotEmpty) return;
    } else if (_activeTool == EditTool.highlight &&
        _pendingHighlights.isNotEmpty) {
      await _commitPendingHighlights();
      if (_pendingHighlights.isNotEmpty) return;
    }
    if (!mounted) return;
    setState(() {
      _activeTool = newTool;
      _currentDrawing = [];
    });
  }

  void _onDrawEnd() {
    final PdfPageGeometry? geometry = _geometry;
    final bool hadStroke = _currentDrawing.length > 1;
    if (!hadStroke || geometry == null) {
      setState(() => _currentDrawing = []);
      // Checked before the list is cleared, or this never fires and the
      // stroke is dropped with no explanation.
      if (hadStroke && geometry == null) {
        _showMessage('Document is still loading.');
      }
      return;
    }

    final List<Offset> screenPoints = List<Offset>.of(_currentDrawing);

    setState(() {
      if (_activeTool == EditTool.draw) {
        // Resolve against the page under the first point so a stroke that
        // strays over a page boundary stays whole.
        final int pageIndex = geometry.resolve(screenPoints.first).pageIndex;
        final double scale = geometry.fitScaleFor(pageIndex);
        final double pageTop = geometry.sceneTopFor(pageIndex);
        final Size pageSize = geometry.pageSizes[pageIndex];

        final List<Offset> pagePoints = screenPoints.map((p) {
          final Offset scene = geometry.toScene(p);
          final Offset displayPoint = Offset(
            (scene.dx / scale).clamp(0.0, pageSize.width),
            ((scene.dy - pageTop) / scale).clamp(0.0, pageSize.height),
          );
          return _toPdfSpace(pageIndex, displayPoint);
        }).toList(growable: false);

        _pendingDrawStrokes.add(
          _PendingStroke(
            screenPoints: screenPoints,
            pagePoints: pagePoints,
            pageIndex: pageIndex,
            color: _selectedDrawColor,
            width: _selectedDrawWidth,
          ),
        );
      } else if (_activeTool == EditTool.highlight) {
        final Rect screenBounds = _boundsOf(screenPoints);
        final PdfPageRect mapped = geometry.resolveRect(screenBounds);
        _pendingHighlights.add(
          _PendingHighlight(
            screenBounds: screenBounds,
            pageBounds: _rectToPdfSpace(mapped.pageIndex, mapped.bounds),
            pageIndex: mapped.pageIndex,
            color: _selectedHighlightColor,
          ),
        );
      }
      _currentDrawing = [];
    });
  }

  static PdfPageTurn _turnOf(PdfPage page) {
    switch (page.rotation) {
      case PdfPageRotateAngle.rotateAngle90:
        return PdfPageTurn.quarter;
      case PdfPageRotateAngle.rotateAngle180:
        return PdfPageTurn.half;
      case PdfPageRotateAngle.rotateAngle270:
        return PdfPageTurn.threeQuarter;
      case PdfPageRotateAngle.rotateAngle0:
        return PdfPageTurn.none;
    }
  }

  /// Turns a point picked in displayed page space into the page's own space.
  Offset _toPdfSpace(int pageIndex, Offset displayPoint) {
    if (pageIndex >= _pageTurns.length) return displayPoint;
    return unrotatePagePoint(
      displayPoint,
      _unrotatedPageSizes[pageIndex],
      _pageTurns[pageIndex],
    );
  }

  Rect _rectToPdfSpace(int pageIndex, Rect displayRect) {
    if (pageIndex >= _pageTurns.length) return displayRect;
    return unrotatePageRect(
      displayRect,
      _unrotatedPageSizes[pageIndex],
      _pageTurns[pageIndex],
    );
  }

  static Rect _boundsOf(List<Offset> points) {
    double minX = points.first.dx, maxX = points.first.dx;
    double minY = points.first.dy, maxY = points.first.dy;
    for (final Offset p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bool isDrawingTool =
        _activeTool == EditTool.draw || _activeTool == EditTool.highlight;
    final bool hasPending =
        _pendingDrawStrokes.isNotEmpty || _pendingHighlights.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: _isSearching ? _buildSearchField() : _buildTitle(),
        actions: _buildActions(),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // The viewer fills the Stack, so these constraints are exactly the
          // ones SfPdfViewer lays its pages out against.
          _viewportWidth = constraints.maxWidth;
          return Stack(
            children: [
              SfPdfViewer.file(
                _currentFile,
                key: _pdfViewerKey,
                controller: _pdfViewerController,
                initialScrollOffset: _targetScrollOffset ?? Offset.zero,
                initialZoomLevel: _targetZoom ?? 1.0,
                canShowScrollHead: false,
                canShowScrollStatus: false,
                pageSpacing: kPageSpacing,
                onDocumentLoaded: (details) {
                  // The viewer lays out a page rotated 90 or 270 degrees with
                  // its width and height swapped, so the geometry has to use
                  // the same orientation or annotations resolve to the wrong
                  // page and position on rotated documents.
                  final int count = details.document.pages.count;
                  final turns = <PdfPageTurn>[];
                  final unrotated = <Size>[];
                  final sizes = <Size>[];
                  for (int i = 0; i < count; i++) {
                    final PdfPage page = details.document.pages[i];
                    final PdfPageTurn turn = _turnOf(page);
                    turns.add(turn);
                    unrotated.add(page.size);
                    sizes.add(
                      turn.swapsAxes
                          ? Size(page.size.height, page.size.width)
                          : page.size,
                    );
                  }
                  if (!mounted) return;
                  setState(() {
                    _pageSizes = sizes;
                    _unrotatedPageSizes = unrotated;
                    _pageTurns = turns;
                    _currentPage = _pdfViewerController.pageNumber;
                  });
                },
                onDocumentLoadFailed: (details) {
                  _showMessage('Could not open document: ${details.error}');
                },
                onPageChanged: (details) {
                  // Nothing observes the controller, so without this the page
                  // indicator stayed frozen on the page the document opened at.
                  if (mounted) {
                    setState(() => _currentPage = details.newPageNumber);
                  }
                },
                onTap: _activeTool == EditTool.text ? _onViewerTap : null,
              ),
              if (isDrawingTool) _buildDrawingOverlay(),
              if (_isEnteringText && _textPosition != null) _buildTextEntry(),
              if (_pageSizes.isNotEmpty) _buildPageIndicator(),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildToolSettingsBar(theme, hasPending),
              ),
              // Kept last so the scrim actually covers the tool bar and blocks
              // input while an edit is being written.
              if (_isLoading)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black45,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          );
        },
      ),
      bottomNavigationBar: _buildToolBar(theme),
    );
  }

  void _onViewerTap(PdfGestureDetails details) {
    // pageNumber is 1-based, and is -1 when the tap landed outside every page.
    // Feeding it straight to the 0-based PdfDocument.pages[...] put text one
    // page late and failed outright on the last page.
    if (details.pageNumber < 1) return;
    final int pageIndex = details.pageNumber - 1;
    setState(() {
      // pagePosition is reported in displayed page space, so it needs the same
      // unrotation as gesture-drawn annotations.
      _textTarget = PdfPagePoint(
        pageIndex,
        _toPdfSpace(pageIndex, details.pagePosition),
      );
      _textPosition = details.position;
      _isEnteringText = true;
      _textOverlayController.clear();
    });
  }

  Widget _buildTitle() => Text(
        widget.document.name,
        style: const TextStyle(fontSize: 16),
        overflow: TextOverflow.ellipsis,
      );

  Widget _buildSearchField() => TextField(
        controller: _searchController,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Search...',
          border: InputBorder.none,
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: _runSearch,
      );

  List<Widget> _buildActions() {
    if (_isSearching) {
      final PdfTextSearchResult? result = _searchResult;
      final bool hasMatches = result != null && result.totalInstanceCount > 0;
      return [
        if (result != null && result.hasResult)
          Center(
            child: Text(
              hasMatches
                  ? '${result.currentInstanceIndex}/${result.totalInstanceCount}'
                  : 'No matches',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
          onPressed: hasMatches ? () => result.previousInstance() : null,
          tooltip: 'Previous match',
        ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: hasMatches ? () => result.nextInstance() : null,
          tooltip: 'Next match',
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: _closeSearch,
          tooltip: 'Close search',
        ),
      ];
    }

    return [
      // Undo/redo must be blocked while a write is in flight: the loading
      // scrim does not cover the AppBar, and the completing edit would append
      // to history and silently undo the undo.
      IconButton(
        icon: const Icon(Icons.undo_rounded),
        onPressed: (!_isLoading && _historyIndex > 0) ? _undo : null,
        tooltip: 'Undo',
      ),
      IconButton(
        icon: const Icon(Icons.redo_rounded),
        onPressed: (!_isLoading && _historyIndex < _history.length - 1)
            ? _redo
            : null,
        tooltip: 'Redo',
      ),
      IconButton(
        icon: const Icon(Icons.save_rounded),
        onPressed: _isLoading ? null : _savePdf,
        tooltip: 'Save',
      ),
      IconButton(
        icon: const Icon(Icons.grid_view_rounded),
        onPressed: _pageSizes.isEmpty ? null : _showThumbnails,
        tooltip: 'Pages',
      ),
      PopupMenuButton<String>(
        tooltip: 'More',
        onSelected: (value) {
          switch (value) {
            case 'copy':
              _saveCopy();
            case 'share':
              _sharePdf();
            case 'bookmarks':
              _pdfViewerKey.currentState?.openBookmarkView();
          }
        },
        itemBuilder: (context) => [
          if (DocumentService.supportsSaf)
            const PopupMenuItem(
              value: 'copy',
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.save_as_rounded),
                title: Text('Save a copy'),
              ),
            ),
          const PopupMenuItem(
            value: 'share',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.share_rounded),
              title: Text('Share'),
            ),
          ),
          const PopupMenuItem(
            value: 'bookmarks',
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.bookmark_border_rounded),
              title: Text('Bookmarks'),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _buildDrawingOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) =>
            setState(() => _currentDrawing = [details.localPosition]),
        onPanUpdate: (details) =>
            setState(() => _currentDrawing.add(details.localPosition)),
        onPanEnd: (_) => _onDrawEnd(),
        child: CustomPaint(
          size: Size.infinite,
          painter: _DrawingPainter(
            points: _currentDrawing,
            tool: _activeTool,
            drawColor: _selectedDrawColor,
            drawWidth: _selectedDrawWidth,
            highlightColor: _selectedHighlightColor,
            strokes: _pendingDrawStrokes,
            highlights: _pendingHighlights,
          ),
        ),
      ),
    );
  }

  Widget _buildTextEntry() {
    return Positioned(
      left: _textPosition!.dx,
      top: _textPosition!.dy - 20,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 200,
          color: Colors.white.withAlpha(230),
          child: TextField(
            controller: _textOverlayController,
            autofocus: true,
            style: const TextStyle(color: Colors.black),
            decoration: InputDecoration(
              hintText: 'Type text...',
              hintStyle: const TextStyle(color: Colors.black54),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.check, color: Colors.green),
                onPressed: () =>
                    _commitTextAnnotation(_textOverlayController.text),
                tooltip: 'Add text',
              ),
            ),
            onSubmitted: _commitTextAnnotation,
          ),
        ),
      ),
    );
  }

  Widget _buildPageIndicator() {
    return Positioned(
      bottom: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _isLoading ? null : _showThumbnails,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withAlpha(178),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.grid_view_rounded,
                    color: Colors.white, size: 14),
                const SizedBox(width: 6),
                Text(
                  '$_currentPage/${_pageSizes.length}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolBar(ThemeData theme) {
    return BottomAppBar(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      height: 80,
      color: theme.colorScheme.surface,
      elevation: 20,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildToolBtn(
            Icons.text_fields_rounded,
            'Text',
            () => _changeTool(EditTool.text),
            theme,
            isActive: _activeTool == EditTool.text,
          ),
          _buildToolBtn(
            Icons.highlight_rounded,
            'Highlight',
            () => _changeTool(EditTool.highlight),
            theme,
            isActive: _activeTool == EditTool.highlight,
          ),
          _buildToolBtn(
            Icons.draw_rounded,
            'Draw',
            () => _changeTool(EditTool.draw),
            theme,
            isActive: _activeTool == EditTool.draw,
          ),
          _buildToolBtn(
            Icons.search_rounded,
            'Search',
            () async {
              // Searching scrolls the viewer, so any tool holding unmapped
              // work has to be flushed before the transform moves.
              await _changeTool(EditTool.none);
              if (mounted) setState(() => _isSearching = true);
            },
            theme,
            isActive: _isSearching,
          ),
        ],
      ),
    );
  }

  Widget _buildToolBtn(
    IconData icon,
    String label,
    VoidCallback onTap,
    ThemeData theme, {
    bool isActive = false,
  }) {
    final Color foreground = isActive
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.primary;
    return InkWell(
      onTap: _isLoading ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: isActive ? theme.colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: foreground),
            const SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: foreground, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolSettingsBar(ThemeData theme, bool hasPending) {
    if (_activeTool == EditTool.none) return const SizedBox.shrink();

    Widget content;
    switch (_activeTool) {
      case EditTool.text:
        content = Row(
          children: [
            const Text('Size:'),
            Expanded(
              child: Slider(
                value: _selectedTextSize,
                min: 12.0,
                max: 72.0,
                divisions: 30,
                label: _selectedTextSize.round().toString(),
                onChanged: (val) => setState(() => _selectedTextSize = val),
              ),
            ),
            for (final color in const [Colors.black, Colors.red, Colors.blue])
              _buildColorPicker(
                color,
                (c) => setState(() => _selectedTextColor = c),
                _selectedTextColor,
              ),
          ],
        );
      case EditTool.draw:
        content = Row(
          children: [
            const Text('Width:'),
            Expanded(
              child: Slider(
                value: _selectedDrawWidth,
                min: 1.0,
                max: 20.0,
                divisions: 19,
                label: _selectedDrawWidth.round().toString(),
                onChanged: (val) => setState(() => _selectedDrawWidth = val),
              ),
            ),
            for (final color in const [Colors.black, Colors.blue, Colors.red])
              _buildColorPicker(
                color,
                (c) => setState(() => _selectedDrawColor = c),
                _selectedDrawColor,
              ),
            if (_pendingDrawStrokes.isNotEmpty)
              _buildApplyButton(_commitPendingDrawStrokes),
          ],
        );
      case EditTool.highlight:
        content = Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final color in const [
              Colors.yellow,
              Colors.greenAccent,
              Colors.lightBlueAccent,
              Colors.pinkAccent,
            ])
              _buildColorPicker(
                color,
                (c) => setState(() => _selectedHighlightColor = c),
                _selectedHighlightColor,
              ),
            if (_pendingHighlights.isNotEmpty)
              _buildApplyButton(_commitPendingHighlights),
          ],
        );
      case EditTool.none:
        content = const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(20),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(top: false, child: content),
    );
  }

  Widget _buildApplyButton(VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.only(left: 8.0),
      child: FilledButton(
        onPressed: _isLoading ? null : onPressed,
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          minimumSize: const Size(0, 36),
        ),
        child: const Text('Apply'),
      ),
    );
  }

  Widget _buildColorPicker(
    Color color,
    ValueChanged<Color> onSelect,
    Color selectedColor,
  ) {
    final bool isSelected = color.toARGB32() == selectedColor.toARGB32();
    return GestureDetector(
      onTap: () => onSelect(color),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: isSelected ? Colors.white : Colors.transparent,
            width: 3,
          ),
          boxShadow: [
            if (isSelected)
              BoxShadow(
                color: Colors.black.withAlpha(80),
                blurRadius: 4,
                spreadRadius: 1,
              ),
          ],
        ),
      ),
    );
  }
}

class _DrawingPainter extends CustomPainter {
  final List<Offset> points;
  final EditTool tool;
  final Color drawColor;
  final double drawWidth;
  final Color highlightColor;
  final List<_PendingStroke> strokes;
  final List<_PendingHighlight> highlights;

  const _DrawingPainter({
    required this.points,
    required this.tool,
    required this.drawColor,
    required this.drawWidth,
    required this.highlightColor,
    required this.strokes,
    required this.highlights,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final h in highlights) {
      canvas.drawRect(
        h.screenBounds,
        Paint()
          ..color = h.color.withAlpha(128)
          ..style = PaintingStyle.fill,
      );
    }

    for (final stroke in strokes) {
      _drawPolyline(canvas, stroke.screenPoints, stroke.color, stroke.width);
    }

    if (points.isEmpty) return;

    if (tool == EditTool.draw) {
      _drawPolyline(canvas, points, drawColor, drawWidth);
    } else if (tool == EditTool.highlight) {
      canvas.drawRect(
        _PdfEditorScreenState._boundsOf(points),
        Paint()
          ..color = highlightColor.withAlpha(128)
          ..style = PaintingStyle.fill,
      );
    }
  }

  static void _drawPolyline(
    Canvas canvas,
    List<Offset> points,
    Color color,
    double width,
  ) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color
      ..strokeWidth = width;

    if (points.length == 1) {
      canvas.drawPoints(PointMode.points, points, paint);
      return;
    }

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      path.lineTo(points[i].dx, points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  // These lists are mutated in place rather than replaced, so the painter's
  // old and new delegates hold the very same instances and any comparison
  // between them is always equal. Repainting unconditionally is the only
  // correct option here; the painter only runs while a drawing tool is active
  // and the widget already rebuilds on every pan update.
  @override
  bool shouldRepaint(covariant _DrawingPainter oldDelegate) => true;
}
