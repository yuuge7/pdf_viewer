import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageDescriptor, ImmutableBuffer, PointMode;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart'
    show SchedulerBinding, SchedulerPhase, Ticker;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_core/theme.dart'
    show SfPdfViewerTheme, SfPdfViewerThemeData;
import 'package:syncfusion_flutter_pdf/pdf.dart'
    show PdfPage, PdfPageRotateAngle;
// The viewer exports its own PdfTextLine (search results); ours is the
// extracted-text model.
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart' hide PdfTextLine;
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart'
    as viewer
    show PdfTextLine;

import '../services/document_import.dart';
import '../services/document_service.dart';
import '../services/docx_writer.dart';
import '../services/ocr_service.dart';
import '../services/pdf_annotations.dart';
import '../services/pdf_page_geometry.dart';
import '../services/pdf_service.dart';
import '../services/pdf_stamps.dart';
import '../services/pdf_tools.dart';
import '../services/reader_settings.dart';
import '../services/recent_documents.dart';
import '../widgets/document_actions.dart';
import '../widgets/document_details_sheet.dart';
import '../widgets/export_sheet.dart';
import '../widgets/file_options_sheet.dart';
import '../widgets/formatting.dart';
import '../widgets/page_thumbnails.dart';
import '../widgets/placement_box.dart';
import '../widgets/reflow_view.dart';
import '../widgets/tool_option_sheets.dart';
import '../widgets/tools_sheet.dart';
import '../widgets/view_settings_sheet.dart';
import 'manage_pages_screen.dart';
import 'merge_screen.dart';
import 'signature_screen.dart';
import 'text_extract_screen.dart';

enum EditTool {
  none,
  editText,
  text,

  /// The text tool, pre-filled with today's date.
  date,
  highlight,
  underline,
  strikethrough,
  draw,

  /// A wide, see-through pen.
  marker,

  /// A line, arrow, rectangle or ellipse, dragged out corner to corner.
  shape,
  note,
  eraser,
}

enum EditTab {
  edit('Edit'),
  annotate('Annotate'),
  sign('Sign');

  final String label;
  const EditTab(this.label);
}

/// Gap between pages, shared by the viewer and the coordinate mapping.
///
/// These must agree or annotations land on the wrong page, so the value lives
/// in exactly one place.
const double kPageSpacing = 4.0;

/// A stroke the user has drawn but not yet written into the PDF.
///
/// Two representations are kept: [scenePoints] drives the live preview
/// overlay, [pagePoints] is what gets written. Both are resolved the moment
/// the stroke is finished, while the viewer transform is guaranteed to be the
/// one the user drew against.
///
/// The preview is stored in *scene* space, not screen space, so that panning
/// or zooming with pending work on screen moves the preview with the page
/// instead of leaving it pinned to the glass.
class _PendingStroke {
  final List<Offset> scenePoints;
  final List<Offset> pagePoints;
  final int pageIndex;
  final Color color;
  final double width;

  /// Below 1 for the marker.
  final double opacity;

  /// Set for a shape, whose two points are the ends of the drag.
  final ShapeKind? shape;

  const _PendingStroke({
    required this.scenePoints,
    required this.pagePoints,
    required this.pageIndex,
    required this.color,
    required this.width,
    this.opacity = 1,
    this.shape,
  });
}

/// A highlight, underline or strikethrough drawn but not yet written.
class _PendingHighlight {
  final Rect sceneBounds;
  final Rect pageBounds;
  final int pageIndex;
  final Color color;
  final MarkupKind kind;

  const _PendingHighlight({
    required this.sceneBounds,
    required this.pageBounds,
    required this.pageIndex,
    required this.color,
    required this.kind,
  });
}

/// A line of text the Edit text tool can change, with its box in displayed
/// page space for drawing and hit-testing.
class _TextBox {
  final int pageIndex;
  final Rect displayRect;
  final PdfTextLine line;
  const _TextBox(this.pageIndex, this.displayRect, this.line);
}

/// A line replaced in this session.
///
/// Replacing text paints over the old glyphs rather than removing them, so
/// extraction keeps finding the old line underneath. Remembering what was
/// covered keeps its box from coming back on top of the new text.
class _Covered {
  final int pageIndex;
  final Rect bounds;
  final String text;
  const _Covered(this.pageIndex, this.bounds, this.text);

  bool hides(int page, PdfTextLine line) =>
      page == pageIndex &&
      bounds.inflate(2).contains(line.bounds.center) &&
      line.text.trim() != text;
}

/// An image or signature being positioned before it is written.
class _Placement {
  final Uint8List bytes;
  final double aspect;
  final bool isSignature;
  Rect rect;
  _Placement(this.bytes, this.aspect, this.rect, {required this.isSignature});
}

class PdfEditorScreen extends StatefulWidget {
  final DocumentRef document;

  /// Opens with the tools sheet already up, for a document picked from the
  /// home screen in order to do something to it.
  final bool openTools;

  const PdfEditorScreen({
    super.key,
    required this.document,
    this.openTools = false,
  });

  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends State<PdfEditorScreen>
    with SingleTickerProviderStateMixin {
  /// The document being edited. Renaming replaces it, so it is state rather
  /// than `widget.document`.
  late DocumentRef _doc;

  late File _currentFile;
  PdfViewerController _pdfViewerController = PdfViewerController();
  GlobalKey<SfPdfViewerState> _pdfViewerKey = GlobalKey();
  bool _isLoading = false;

  /// What the loading scrim says, for work long enough to need explaining.
  String? _busyLabel;

  /// Every edit produces a new file; undo/redo just moves [_historyIndex].
  final List<File> _history = [];
  int _historyIndex = 0;

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  PdfTextSearchResult? _searchResult;

  /// The term currently being searched for.
  ///
  /// A search belongs to the controller that ran it, so applying an edit —
  /// which replaces the viewer — drops the results. Keeping the term lets the
  /// search be re-run against the new document instead of leaving the search
  /// bar open over nothing.
  String _searchQuery = '';

  EditTool _activeTool = EditTool.none;
  List<Offset> _currentDrawing = [];
  final List<_PendingStroke> _pendingDrawStrokes = [];
  final List<_PendingHighlight> _pendingHighlights = [];

  /// While true the drawing overlay stops taking input, so the viewer's own
  /// pan and pinch reach it.
  ///
  /// A full-screen gesture overlay has to claim every touch to draw with one,
  /// which left no way to scroll to the next page without putting the tool
  /// away — and putting the tool away flushes the batch. An explicit toggle
  /// keeps both possible and keeps which one is active unambiguous.
  bool _panMode = false;

  /// Bumped once per frame while an overlay has to follow the document
  /// during a pan, since the viewer reports scrolling to nobody.
  final ValueNotifier<int> _overlayTick = ValueNotifier<int>(0);
  late final Ticker _overlayTicker;

  Offset? _textPosition;
  PdfPagePoint? _textTarget;
  bool _isEnteringText = false;
  final TextEditingController _textOverlayController = TextEditingController();

  /// Text the text tool starts with; set by the Date tool.
  String? _textPrefill;

  /// Where a recreated viewer should open. A history move replays scroll
  /// offset and zoom; a layout change replays the page instead, because
  /// offsets mean nothing across a change of reading direction.
  Offset? _targetScrollOffset;
  double? _targetZoom;
  int? _targetPage;

  /// Actual laid-out width of the viewer, from a LayoutBuilder rather than
  /// MediaQuery, which reports the whole screen including the app bar and
  /// bottom bar insets.
  double _viewportWidth = 0;

  /// Laid-out height of the viewer, used to keep the text entry box on screen.
  double _viewportHeight = 0;

  /// Size of every page *as displayed*, captured on load. Pages in a document
  /// are not necessarily uniform, and assuming they are misplaces annotations.
  List<Size> _pageSizes = const [];

  /// Each page's own size and rotation, needed to turn a point picked in
  /// display space back into the space the document is actually written in.
  List<Size> _unrotatedPageSizes = const [];
  List<PdfPageTurn> _pageTurns = const [];

  /// Page count of the last document that loaded. Unlike [_pageSizes] it
  /// survives a viewer reset, so tools can ask for it from reflow mode.
  int _pageCount = 0;

  int _currentPage = 1;

  Color _selectedTextColor = Colors.red;
  double _selectedTextSize = 24.0;
  Color _selectedDrawColor = Colors.blue;
  double _selectedDrawWidth = 3.0;
  final Map<MarkupKind, Color> _markupColors = {
    MarkupKind.highlight: Colors.yellow,
    MarkupKind.underline: Colors.blue,
    MarkupKind.strikethrough: Colors.red,
  };

  /// How much of what is under the marker shows through it.
  static const double _markerOpacity = 0.4;
  static const Map<String, double> _markerWidths = {
    'S': 8,
    'M': 14,
    'L': 20,
    'XL': 28,
  };
  Color _markerColor = Colors.yellow;
  double _markerWidth = 14;
  ShapeKind _shapeKind = ShapeKind.rectangle;
  Color _shapeColor = Colors.red;
  double _shapeWidth = 2;

  /// Annotations the eraser can remove, for the file they were read from.
  List<PdfMark> _marks = const [];
  String? _marksPath;
  bool _loadingMarks = false;

  // --- Passwords and what the viewer holds -----------------------------------

  /// The password the document is saved with, or null for none.
  ///
  /// A protected document is decrypted once on the way in and worked on as a
  /// plain copy, because nothing else here — the page renderer, text
  /// extraction, every edit — reads an encrypted file. It is encrypted
  /// again on its way out: see [_fileToWrite].
  String? _password;

  /// True when [_password] no longer matches the document on disk.
  bool _securityChanged = false;

  /// True while the viewer holds something [_currentFile] does not: a form
  /// field filled in, a note reworded. See [_flushViewer].
  bool _viewerDirty = false;

  /// Text the user has selected in the viewer, and where it is on screen.
  String? _selectedText;
  Rect? _selectionRegion;
  final GlobalKey _viewportKey = GlobalKey();

  // --- Reading ---------------------------------------------------------------

  ReaderSettings _settings = const ReaderSettings();
  bool _settingsLoaded = false;
  bool _reflow = false;
  bool _isFavorite = false;
  bool _rotationLocked = false;

  // --- Edit mode -------------------------------------------------------------

  bool _editMode = false;
  EditTab _editTab = EditTab.edit;

  /// History position when edit mode was entered, which is what the close
  /// button goes back to.
  int _editStartIndex = 0;

  List<_TextBox> _textBoxes = const [];
  String? _textBoxesPath;
  bool _loadingText = false;
  final Map<String, List<_Covered>> _covered = {};

  _Placement? _placement;

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
    _currentFile = _doc.file;
    _savedPath = _currentFile.path;
    _history.add(_currentFile);
    _overlayTicker = createTicker((_) => _overlayTick.value++);
    _sweepStaleTempFiles();
    PdfTools.sweepOutboxes();
    _loadPreferences();
  }

  @override
  void dispose() {
    _overlayTicker.dispose();
    _overlayTick.dispose();
    _searchResult?.removeListener(_onSearchResultChanged);
    _searchResult?.clear();
    _searchController.dispose();
    _textOverlayController.dispose();
    _pdfViewerController.dispose();
    if (_settings.keepScreenOn) DocumentService.setKeepScreenOn(false);
    if (_rotationLocked) SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final ReaderSettings settings = await ReaderSettings.load();
    final bool favorite = await FavoriteDocuments.contains(_doc);
    if (!mounted) return;
    if (!await _unlockIfNeeded()) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    // The viewer is not built until this lands, so it opens in the saved
    // layout instead of opening once and being rebuilt.
    setState(() {
      _settings = settings;
      _isFavorite = favorite;
      _settingsLoaded = true;
    });
    if (settings.keepScreenOn) DocumentService.setKeepScreenOn(true);
    if (widget.openTools) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showTools();
      });
    }
  }

  /// Asks for the password of a protected document and swaps in a decrypted
  /// working copy. Returns false when the user gives up.
  Future<bool> _unlockIfNeeded() async {
    final Uint8List bytes;
    try {
      bytes = await _currentFile.readAsBytes();
      if (await PdfStamps.probe(bytes) != PdfLock.locked) return true;
    } catch (_) {
      // Unreadable; the viewer gets to say so.
      return true;
    }
    bool wrong = false;
    while (true) {
      if (!mounted) return false;
      final String? password = await askPassword(
        context,
        _doc.name,
        wrong: wrong,
      );
      if (password == null) return false;
      try {
        final Uint8List open = await PdfStamps.renderUnlock(bytes, password);
        final Directory directory = await getApplicationDocumentsDirectory();
        final File copy = File(
          '${directory.path}/edited_${DateTime.now().microsecondsSinceEpoch}.pdf',
        );
        await copy.writeAsBytes(open, flush: true);
        _password = password;
        _currentFile = copy;
        _history[0] = copy;
        _savedPath = copy.path;
        return true;
      } on PdfEditException {
        wrong = true;
      } catch (e) {
        _showMessage('Could not open ${_doc.name}: $e');
        return false;
      }
    }
  }

  /// [_currentFile] as it should leave the app: encrypted when the document
  /// has a password.
  Future<File> _fileToWrite() async {
    final String? password = _password;
    if (password == null) return _currentFile;
    final Uint8List locked = await PdfStamps.renderProtect(
      await _currentFile.readAsBytes(),
      password,
    );
    final Directory outbox = await PdfTools.newOutbox();
    final File out = File('${outbox.path}/protected.pdf');
    await out.writeAsBytes(locked, flush: true);
    return out;
  }

  /// Writes what only the viewer holds — form fields filled in, a note
  /// reworded through its own popup — into a new history file.
  ///
  /// Every edit and every export reads [_currentFile], so this runs before
  /// any of them, or the form would silently go back to how it was opened.
  /// Returns false when it could not be kept.
  Future<bool> _flushViewer() async {
    if (!_viewerDirty) return true;
    setState(() => _isLoading = true);
    try {
      final List<int> bytes = await _pdfViewerController.saveDocument();
      final Directory directory = await getApplicationDocumentsDirectory();
      final File file = File(
        '${directory.path}/edited_${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      if (!mounted) return false;
      _viewerDirty = false;
      _swapDocument(file, addToHistory: true);
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('Could not keep what you filled in: $e');
      }
      return false;
    }
  }

  void _markViewerDirty() {
    if (!_viewerDirty && mounted) setState(() => _viewerDirty = true);
  }

  bool get _hasPendingAnnotations =>
      _pendingDrawStrokes.isNotEmpty || _pendingHighlights.isNotEmpty;

  /// Draw, marker and shapes share one pending batch, as the markup tools
  /// share theirs.
  static bool _isPen(EditTool tool) =>
      tool == EditTool.draw ||
      tool == EditTool.marker ||
      tool == EditTool.shape;

  Color get _penColor => switch (_activeTool) {
    EditTool.marker => _markerColor,
    EditTool.shape => _shapeColor,
    _ => _selectedDrawColor,
  };

  double get _penWidth => switch (_activeTool) {
    EditTool.marker => _markerWidth,
    EditTool.shape => _shapeWidth,
    _ => _selectedDrawWidth,
  };

  double get _penOpacity =>
      _activeTool == EditTool.marker ? _markerOpacity : 1;

  static bool _isMarkup(EditTool tool) =>
      tool == EditTool.highlight ||
      tool == EditTool.underline ||
      tool == EditTool.strikethrough;

  static MarkupKind _markupKindOf(EditTool tool) => switch (tool) {
    EditTool.underline => MarkupKind.underline,
    EditTool.strikethrough => MarkupKind.strikethrough,
    _ => MarkupKind.highlight,
  };

  bool get _isTextTool =>
      _activeTool == EditTool.text || _activeTool == EditTool.date;

  /// Runs the per-frame repaint only while it actually buys something: an
  /// overlay that has to track a view the user is moving.
  void _syncOverlayTicker() {
    final bool shouldTick =
        (_panMode && _hasPendingAnnotations) ||
        _activeTool == EditTool.editText ||
        _activeTool == EditTool.eraser;
    if (shouldTick == _overlayTicker.isActive) return;
    if (shouldTick) {
      _overlayTicker.start();
    } else {
      _overlayTicker.stop();
    }
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
      final DateTime cutoff = DateTime.now().subtract(const Duration(days: 1));
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

  /// Whether pages are laid out continuously and vertically, which is the
  /// only layout the gesture-to-page mapping understands. Edit mode forces it.
  bool get _continuousVertical => _editMode || _settings.isContinuousVertical;

  PdfPageGeometry? get _geometry {
    if (!_continuousVertical) return null;
    if (_pageSizes.isEmpty || _viewportWidth <= 0) return null;
    final geometry = PdfPageGeometry(
      pageSizes: _pageSizes,
      viewportWidth: _viewportWidth,
      pageSpacing: kPageSpacing,
      zoom: _pdfViewerController.zoomLevel,
      scrollOffset: _pdfViewerController.scrollOffset,
      viewportHeight: _viewportHeight,
    );
    return geometry.isUsable ? geometry : null;
  }

  void _showMessage(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: action,
          // One with an action would otherwise sit over the tool bar until
          // swiped away.
          persist: false,
        ),
      );
  }

  /// Runs [task] behind the loading scrim and reports failure, returning null
  /// for it. For the document tools, which read the current file and write
  /// new ones elsewhere.
  Future<T?> _runBusy<T>(String label, Future<T> Function() task) async {
    setState(() {
      _isLoading = true;
      _busyLabel = label;
    });
    try {
      return await task();
    } on PdfEditException catch (e) {
      _showMessage(e.message);
    } on PlatformException catch (e) {
      _showMessage(e.message ?? 'Something went wrong.');
    } catch (e) {
      _showMessage('$label failed: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _busyLabel = null;
        });
      }
    }
    return null;
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

  // --- Draw / markup ---------------------------------------------------------

  Future<void> _commitPendingHighlights() async {
    if (_pendingHighlights.isEmpty) return;
    setState(() => _isLoading = true);

    // Group by page: a batch can span several pages, and forcing all of them
    // onto the first one put annotations on the wrong page.
    final Map<int, List<HighlightRect>> byPage = {};
    for (final _PendingHighlight h in _pendingHighlights) {
      byPage
          .putIfAbsent(h.pageIndex, () => [])
          .add(
            HighlightRect(bounds: h.pageBounds, color: h.color, kind: h.kind),
          );
    }

    final PdfEditResult result = await _applyPerPage(
      byPage.keys,
      (file, pageIndex) => PdfService.addHighlightAnnotation(
        file,
        pageIndex,
        byPage[pageIndex]!,
      ),
    );

    if (!mounted) return;
    // Only discard the pending work once it is safely in the document.
    if (result.isSuccess) _pendingHighlights.clear();
    _handleResult(result, 'Markup added');
    _syncOverlayTicker();
  }

  Future<void> _commitPendingDrawStrokes() async {
    if (_pendingDrawStrokes.isEmpty) return;
    setState(() => _isLoading = true);

    final Map<int, List<DrawStroke>> strokes = {};
    final Map<int, List<ShapeMark>> shapes = {};
    for (final _PendingStroke s in _pendingDrawStrokes) {
      final ShapeKind? kind = s.shape;
      if (kind == null) {
        strokes
            .putIfAbsent(s.pageIndex, () => [])
            .add(
              DrawStroke(
                points: s.pagePoints,
                color: s.color,
                width: s.width,
                opacity: s.opacity,
              ),
            );
      } else {
        shapes
            .putIfAbsent(s.pageIndex, () => [])
            .add(
              ShapeMark(
                kind: kind,
                start: s.pagePoints.first,
                end: s.pagePoints.last,
                color: s.color,
                width: s.width,
              ),
            );
      }
    }

    final PdfEditResult result = await _applyPerPage(
      {...strokes.keys, ...shapes.keys},
      (file, pageIndex) async {
        final List<DrawStroke>? drawn = strokes[pageIndex];
        final List<ShapeMark>? shaped = shapes[pageIndex];
        PdfEditResult step = PdfEditResult.success(file);
        if (drawn != null) {
          step = await PdfService.addDrawAnnotation(file, pageIndex, drawn);
          if (!step.isSuccess || shaped == null) return step;
        }
        // Two passes for a page with both, each through its own writer.
        final File between = step.file!;
        step = await PdfAnnotations.addShapes(between, pageIndex, shaped!);
        if (between.path != file.path) await _deleteAll([between]);
        return step;
      },
    );

    if (!mounted) return;
    if (result.isSuccess) _pendingDrawStrokes.clear();
    _handleResult(result, 'Drawing added');
    _syncOverlayTicker();
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

  void _discardLastPending(List<Object> pending) {
    if (pending.isEmpty) return;
    setState(pending.removeLast);
    _syncOverlayTicker();
  }

  void _discardAllPending(List<Object> pending) {
    if (pending.isEmpty) return;
    setState(pending.clear);
    _syncOverlayTicker();
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

  /// [undoable] offers Undo with the message, for edits made from read
  /// mode, where there is no undo button on screen.
  void _handleResult(
    PdfEditResult result,
    String successMessage, {
    bool undoable = false,
  }) {
    if (!result.isSuccess) {
      setState(() {
        _isLoading = false;
        _busyLabel = null;
      });
      _showMessage(result.error!);
      return;
    }
    _swapDocument(result.file!, addToHistory: true);
    _showMessage(
      successMessage,
      action: undoable
          ? SnackBarAction(label: 'Undo', onPressed: _undo)
          : null,
    );
  }

  void _swapDocument(File file, {required bool addToHistory}) =>
      _resetViewer(file: file, addToHistory: addToHistory);

  /// Recreates the viewer, optionally pointing it at a different [file].
  ///
  /// `SfPdfViewer` caches by document, so the widget and its controller have
  /// to be recreated for new bytes to be picked up. With [keepPage] the new
  /// viewer reopens at the current page — for a change of layout, where
  /// scroll offsets do not carry over; otherwise scroll position and zoom are
  /// carried across so the view does not jump back to page one.
  void _resetViewer({
    File? file,
    bool addToHistory = false,
    bool keepPage = false,
  }) {
    if (keepPage) {
      _targetPage = _currentPage;
      _targetScrollOffset = null;
      _targetZoom = null;
    } else {
      _targetPage = null;
      _targetScrollOffset = _pdfViewerController.scrollOffset;
      _targetZoom = _pdfViewerController.zoomLevel;
    }

    final PdfViewerController oldController = _pdfViewerController;
    final List<File> orphaned = [];

    setState(() {
      if (file != null) {
        if (addToHistory) {
          if (_historyIndex < _history.length - 1) {
            // The redo branch is being replaced; its files are now unreachable.
            orphaned.addAll(_history.sublist(_historyIndex + 1));
            _history.removeRange(_historyIndex + 1, _history.length);
          }
          _history.add(file);
          _historyIndex++;
          // Lines covered in the previous version stay covered in this one.
          _covered[file.path] = [...?_covered[_currentFile.path]];
        }
        _currentFile = file;
      }

      _pdfViewerKey = GlobalKey();
      _pdfViewerController = PdfViewerController();
      _isLoading = false;
      _busyLabel = null;

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

      // So does a selection, and anything typed into the old viewer that
      // was not flushed first is gone with it.
      _selectedText = null;
      _selectionRegion = null;
      _viewerDirty = false;
    });

    // Deferred: the outgoing SfPdfViewer stays mounted until the end of this
    // frame and would throw if it notified an already-disposed controller.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => oldController.dispose(),
    );
    // Never delete the file the user opened.
    _deleteAll(orphaned.where((f) => f.path != _doc.path));
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

  // --- Save ------------------------------------------------------------------

  /// Path the document on disk currently matches. Starts as the file that was
  /// opened and moves forward on each successful save.
  late String _savedPath;

  bool get _hasUnsavedChanges =>
      _currentFile.path != _savedPath || _securityChanged || _viewerDirty;

  Future<void> _savePdf() async {
    if (!await _flushViewer() || !mounted) return;
    // A document converted on the way in exists nowhere yet, edited or not:
    // saving it means choosing where it goes.
    if (_doc.isUnsaved) {
      await _saveCopy();
      return;
    }
    if (!_hasUnsavedChanges) {
      _showMessage('No changes to save.');
      return;
    }
    // Without a write grant the only honest option is Save a copy: writing to
    // the cache path would report success and change nothing the user can see.
    if (!_doc.savesInPlace) {
      _showMessage('This document is read-only. Use Save a copy.');
      await _saveCopy();
      return;
    }

    setState(() => _isLoading = true);
    try {
      await DocumentService.write(_doc, await _fileToWrite());
      if (!mounted) return;
      // The document on disk now matches this file, so Save reports "no
      // changes" until the next edit. History is deliberately left alone --
      // rewriting _history[0] would make Undo jump to a file the user never
      // navigated to.
      setState(() {
        _savedPath = _currentFile.path;
        _securityChanged = false;
      });
      _showMessage('Saved to ${_doc.name}');
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
    if (!await _flushViewer() || !mounted) return;
    setState(() => _isLoading = true);
    try {
      final DocumentRef? saved = await DocumentService.saveCopy(
        _suggestedCopyName(),
        await _fileToWrite(),
      );
      if (!mounted) return;
      if (saved == null) return; // Cancelled.
      // The native side took a persistable grant on the new document. Record
      // it, or that grant leaks and the copy never appears in Recent Files.
      await RecentDocuments.add(saved);
      if (!mounted) return;
      if (_doc.isUnsaved) {
        // The copy is the first real home this document has had, so it
        // becomes the document: later saves go to it, and there is nothing
        // left unsaved to warn about on the way out.
        setState(() {
          _doc = saved;
          _savedPath = _currentFile.path;
          _securityChanged = false;
        });
        _showMessage('Saved as ${saved.name}');
        return;
      }
      _showMessage('Saved a copy as ${saved.name}');
    } catch (e) {
      if (!mounted) return;
      _showMessage('Failed to save a copy: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _suggestedCopyName() {
    final String name = _doc.name;
    // Nothing exists under this name yet for a copy to be told apart from.
    if (_doc.isUnsaved) return name;
    final int dot = name.lastIndexOf('.');
    if (dot <= 0) return '$name (edited).pdf';
    return '${name.substring(0, dot)} (edited)${name.substring(dot)}';
  }

  /// Asks before throwing away work, and returns whether leaving may proceed.
  ///
  /// Backing out of the editor used to discard every edit without a word: the
  /// user's file is only touched by Save, so everything from the session was
  /// simply gone.
  Future<bool> _confirmLeave() async {
    if (!_hasUnsavedChanges && !_hasPendingAnnotations) return true;

    final String? choice = await showDialog<String>(
      context: context,
      // Dismissing by tapping outside would otherwise mean "discard", which is
      // the one outcome that cannot be taken back.
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave without saving?'),
        content: Text(
          _hasPendingAnnotations
              ? 'Annotations you have drawn but not applied, and any edits '
                    'you have not saved, will be lost.'
              : _doc.isUnsaved
              ? '${_doc.name} has not been saved anywhere yet.'
              : 'Your edits have not been saved to ${_doc.name}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('keep'),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('discard'),
            child: const Text('Discard'),
          ),
          if (_doc.savesInPlace || _doc.isUnsaved)
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop('save'),
              child: const Text('Save'),
            ),
        ],
      ),
    );

    if (choice == 'discard') return true;
    if (choice == 'save' && mounted) {
      await _savePdf();
      return !_hasUnsavedChanges;
    }
    return false;
  }

  /// Replaces this editor with one on [ref], after the usual check for
  /// unsaved work.
  Future<void> _openOther(DocumentRef ref) async {
    if (!await _confirmLeave() || !mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => PdfEditorScreen(document: ref)),
    );
  }

  // --- Edit mode -------------------------------------------------------------

  Future<void> _enterEditMode(EditTab tab, {EditTool? tool}) async {
    if (!await _flushViewer() || !mounted) return;
    if (_isSearching) _closeSearch();
    // Annotation placement maps gestures onto a continuous vertical stack of
    // pages; any other layout has to give way while editing.
    final bool relayout = !_settings.isContinuousVertical || _reflow;
    setState(() {
      _editMode = true;
      _editTab = tab;
      _reflow = false;
      _editStartIndex = _historyIndex;
    });
    if (relayout) _resetViewer(keepPage: true);
    if (tool != null) await _changeTool(tool);
  }

  /// Leaves edit mode. Without [keepChanges] everything done since entering
  /// is rolled back, after asking.
  Future<void> _exitEditMode({required bool keepChanges}) async {
    final bool changed = _historyIndex != _editStartIndex;
    if (!keepChanges && (changed || _hasPendingAnnotations)) {
      final bool? discard = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Discard your changes?'),
          content: const Text(
            'Everything you did since tapping Edit will be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep editing'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }

    final bool relayout = !_settings.isContinuousVertical;
    setState(() {
      _editMode = false;
      _activeTool = EditTool.none;
      _placement = null;
      _panMode = false;
      _currentDrawing = [];
      _isEnteringText = false;
      _textPosition = null;
      _textTarget = null;
      _textOverlayController.clear();
      if (!keepChanges) {
        _pendingDrawStrokes.clear();
        _pendingHighlights.clear();
      }
    });
    _syncOverlayTicker();

    if (!keepChanges && changed) {
      _historyIndex = _editStartIndex;
      _resetViewer(file: _history[_historyIndex], keepPage: relayout);
    } else if (relayout) {
      _resetViewer(keepPage: true);
    }
  }

  /// Done: applies anything still pending, saves, and leaves edit mode.
  Future<void> _finishEditing() async {
    if (_placement != null) {
      await _commitPlacement();
      if (_placement != null) return;
    }
    await _changeTool(EditTool.none);
    // A flush that failed leaves the work pending; stay so it is not lost.
    if (_hasPendingAnnotations || !mounted) return;
    if (_hasUnsavedChanges) {
      await _savePdf();
      if (!mounted) return;
      // A failed save to a writable document keeps the user here to retry.
      // A read-only one has been through Save a copy, which is all it can do.
      if (_hasUnsavedChanges && _doc.savesInPlace) return;
    }
    await _exitEditMode(keepChanges: true);
  }

  Future<void> _switchTab(EditTab tab) async {
    if (tab == _editTab) return;
    await _changeTool(EditTool.none);
    if (!mounted) return;
    setState(() {
      _placement = null;
      _editTab = tab;
    });
  }

  Future<void> _showHelp() {
    final ThemeData theme = Theme.of(context);
    Widget item(IconData icon, String title, String body) =>
        ListTile(leading: Icon(icon), title: Text(title), subtitle: Text(body));
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Editing',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              item(
                Icons.edit_note_rounded,
                'Edit text',
                'Tap a dashed line to change or remove it. PDFs have no '
                    'editable text, so the old line is covered in white and '
                    'the new one written on top. The old text is still in '
                    'the file and can be found by search or copy — do not '
                    'rely on this to hide sensitive information.',
              ),
              item(
                Icons.title_rounded,
                'Add text',
                'Tap where the text should go, type, and confirm.',
              ),
              item(
                Icons.add_photo_alternate_outlined,
                'Add image / Signature',
                'Drag the image to move it and the corner handle to resize '
                    'it. Scroll the page underneath to get it in place, then '
                    'tap Place.',
              ),
              item(
                Icons.highlight_rounded,
                'Annotate',
                'Drag over the page to highlight, underline or strike '
                    'through; draw freehand with the pen. Use the hand to '
                    'scroll without drawing. Nothing is written until you '
                    'tap Apply or switch tools.',
              ),
              item(
                Icons.category_outlined,
                'Shapes and notes',
                'Drag out a line, arrow, rectangle or ellipse. Tap to pin '
                    'a note; tap the note later to read it.',
              ),
              item(
                Icons.auto_fix_normal_outlined,
                'Eraser',
                'Tap a highlight, underline, strikethrough or note to '
                    'remove it. Pen strokes, marker and shapes are painted '
                    'into the page when applied; use Undo for those.',
              ),
              item(
                Icons.check_circle_outline_rounded,
                'Done and close',
                'Done saves your changes to the file. The X undoes '
                    'everything since you started editing.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Edit text -------------------------------------------------------------

  Future<void> _loadTextBoxes() async {
    final File file = _currentFile;
    if (_textBoxesPath == file.path || _loadingText) return;
    setState(() => _loadingText = true);
    List<_TextBox> boxes = const [];
    try {
      final List<PdfTextPage> pages = await PdfTools.extractText(file);
      final List<_Covered> covered = _covered[file.path] ?? const [];
      boxes = [
        for (final PdfTextPage page in pages)
          for (final PdfTextLine line in page.lines)
            if (!covered.any((c) => c.hides(page.index, line)))
              _TextBox(
                page.index,
                rotatePageRect(line.bounds, page.size, page.turn),
                line,
              ),
      ];
      if (boxes.isEmpty && mounted && file.path == _currentFile.path) {
        _showMessage(
          'No editable text found. Scanned pages are pictures, not text.',
        );
      }
    } catch (e) {
      _showMessage('Could not read the text: $e');
    } finally {
      if (mounted) {
        setState(() {
          _loadingText = false;
          // Recorded even on failure, so a bad file is not retried forever.
          _textBoxes = boxes;
          _textBoxesPath = file.path;
        });
        // The document changed while this was running; catch up.
        if (_activeTool == EditTool.editText &&
            file.path != _currentFile.path) {
          _loadTextBoxes();
        }
      }
    }
  }

  void _onEditTextTap(TapUpDetails details) {
    if (_loadingText || _textBoxesPath != _currentFile.path) return;
    final PdfPageGeometry? geometry = _geometry;
    if (geometry == null) return;
    final PdfPagePoint hit = geometry.resolve(details.localPosition);
    _TextBox? best;
    for (final _TextBox box in _textBoxes) {
      if (box.pageIndex != hit.pageIndex) continue;
      if (!box.displayRect.inflate(4).contains(hit.pagePoint)) continue;
      final double area = box.displayRect.width * box.displayRect.height;
      if (best == null ||
          area < best.displayRect.width * best.displayRect.height) {
        best = box;
      }
    }
    if (best == null) {
      _showMessage('Tap on a line of text to edit it.');
      return;
    }
    _editLine(best);
  }

  Future<void> _editLine(_TextBox box) async {
    final _LineEdit? edit = await showModalBottomSheet<_LineEdit>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LineEditorSheet(line: box.line),
    );
    if (edit == null || !mounted) return;

    setState(() => _isLoading = true);
    final PdfEditResult result = await PdfService.replaceText(
      _currentFile,
      box.pageIndex,
      box.line.bounds,
      edit.text,
      edit.fontSize,
      fontName: box.line.fontName,
      bold: edit.bold,
      italic: edit.italic,
      color: edit.color,
    );
    if (!mounted) return;
    _handleResult(
      result,
      edit.text.trim().isEmpty ? 'Line removed' : 'Text updated',
    );
    if (result.isSuccess) {
      (_covered[result.file!.path] ??= []).add(
        _Covered(box.pageIndex, box.line.bounds, edit.text.trim()),
      );
    }
  }

  // --- Images and signatures -------------------------------------------------

  Future<void> _pickImageToPlace() async {
    await _changeTool(EditTool.none);
    if (!mounted) return;
    final XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    } on PlatformException catch (e) {
      _showMessage(e.message ?? 'Could not open the gallery.');
      return;
    }
    if (picked == null || !mounted) return;
    final Uint8List? bytes = await _runBusy(
      'Preparing image',
      () async =>
          PdfService.normalizePhoto(await picked!.readAsBytes(), maxEdge: 2000),
    );
    if (bytes != null && mounted) await _startPlacement(bytes);
  }

  Future<void> _openSignatures() async {
    await _changeTool(EditTool.none);
    if (!mounted) return;
    final Uint8List? png = await SignatureSheet.show(context);
    if (png != null && mounted) await _startPlacement(png, isSignature: true);
  }

  Future<void> _startPlacement(
    Uint8List bytes, {
    bool isSignature = false,
  }) async {
    final ImmutableBuffer buffer = await ImmutableBuffer.fromUint8List(bytes);
    final ImageDescriptor descriptor = await ImageDescriptor.encoded(buffer);
    final double aspect = descriptor.width / descriptor.height;
    descriptor.dispose();
    buffer.dispose();
    if (!mounted) return;

    final double maxWidth = _viewportWidth * (isSignature ? 0.5 : 0.7);
    final double maxHeight = _viewportHeight * 0.45;
    double width = maxWidth;
    double height = width / aspect;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * aspect;
    }
    setState(() {
      _placement = _Placement(
        bytes,
        aspect,
        Rect.fromCenter(
          center: Offset(_viewportWidth / 2, _viewportHeight / 2),
          width: width,
          height: height,
        ),
        isSignature: isSignature,
      );
    });
  }

  void _movePlacement(Offset delta) {
    final _Placement? p = _placement;
    if (p == null) return;
    final Rect moved = p.rect.shift(delta);
    // Keep at least a corner on screen so it can always be grabbed again.
    const double keep = 32;
    final double dx = moved.left.clamp(
      keep - moved.width,
      _viewportWidth - keep,
    );
    final double dy = moved.top.clamp(
      keep - moved.height,
      _viewportHeight - keep,
    );
    setState(() => p.rect = Offset(dx, dy) & moved.size);
  }

  void _resizePlacement(Offset delta) {
    final _Placement? p = _placement;
    if (p == null) return;
    final double width = (p.rect.width + delta.dx).clamp(
      32.0,
      _viewportWidth * 1.5,
    );
    setState(() => p.rect = p.rect.topLeft & Size(width, width / p.aspect));
  }

  Future<void> _commitPlacement() async {
    final _Placement? p = _placement;
    if (p == null) return;
    final PdfPageGeometry? geometry = _geometry;
    if (geometry == null) {
      _showMessage('Document is still loading.');
      return;
    }
    final PdfPageRect mapped = geometry.resolveRect(p.rect);
    // Clamping into the page squashes a box that hangs over the edge. Fit the
    // image inside what landed on the page instead, keeping its proportions.
    Rect display = mapped.bounds;
    if (display.width <= 1 || display.height <= 1) {
      _showMessage('Move the image over a page first.');
      return;
    }
    if (display.width / display.height > p.aspect) {
      final double w = display.height * p.aspect;
      display = Rect.fromLTWH(
        display.center.dx - w / 2,
        display.top,
        w,
        display.height,
      );
    } else {
      final double h = display.width / p.aspect;
      display = Rect.fromLTWH(
        display.left,
        display.center.dy - h / 2,
        display.width,
        h,
      );
    }
    final int pageIndex = mapped.pageIndex;
    final int turns = pageIndex < _pageTurns.length
        ? _pageTurns[pageIndex].index
        : 0;

    setState(() => _isLoading = true);
    final PdfEditResult result = await PdfService.addImage(
      _currentFile,
      pageIndex,
      p.bytes,
      _rectToPdfSpace(pageIndex, display),
      counterTurns: turns,
    );
    if (!mounted) return;
    if (result.isSuccess) _placement = null;
    _handleResult(result, p.isSignature ? 'Signature added' : 'Image added');
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
      onManage: _editMode
          ? null
          : () => _openManagePages(ManagePagesIntent.manage),
    );
  }

  // --- Document tools --------------------------------------------------------

  Future<void> _openManagePages(ManagePagesIntent intent) async {
    final List<PageSpec>? specs = await ManagePagesScreen.open(
      context,
      file: _currentFile,
      documentName: _doc.name,
      intent: intent,
    );
    if (specs == null || !mounted) return;
    setState(() {
      _isLoading = true;
      _busyLabel = 'Updating pages';
    });
    final List<_Covered> covered = _covered[_currentFile.path] ?? const [];
    final PdfEditResult result = await PdfService.applyLayout(
      _currentFile,
      specs,
    );
    if (!mounted) return;
    _handleResult(result, 'Pages updated');
    if (result.isSuccess) {
      // Covered lines are remembered by page index, which the new order
      // changes. Follow each page to wherever it went; a page re-laid onto
      // other paper has moved its content, so its entries no longer fit.
      _covered[result.file!.path] = [
        for (int i = 0; i < specs.length; i++)
          if (specs[i].setup == null)
            if (specs[i].source case OriginalPageSource(:final int index))
              for (final _Covered c in covered)
                if (c.pageIndex == index) _Covered(i, c.bounds, c.text),
      ];
    }
    // Done in Manage pages means done, as in edit mode: write it through.
    if (result.isSuccess) await _savePdf();
  }

  Future<int> _knownPageCount() async {
    if (_pageCount > 0) return _pageCount;
    final PdfFacts? facts = await _runBusy(
      'Reading',
      () => PdfTools.readFacts(_currentFile),
    );
    return facts?.pageCount ?? 0;
  }

  Future<void> _convertToWord() async {
    if (!await _flushViewer() || !mounted) return;
    final WordExport? export = await _runBusy(
      'Converting to Word',
      () => PdfTools.toWord(_currentFile, _doc.name),
    );
    if (export == null || !mounted) return;
    final int pictures = export.pageCount - export.textPages;
    await ExportSheet.show(
      context,
      files: [export.file],
      mimeType: DocxWriter.mimeType,
      title: 'Word document ready',
      note: export.textPages == 0
          ? 'No selectable text was found, so the pages went in as pictures. '
                'A scanned document needs text recognition (OCR) to become '
                'editable.'
          : pictures > 0
          ? '$pictures page${pictures == 1 ? '' : 's'} had no text and '
                'went in as pictures.'
          : null,
    );
  }

  Future<void> _exportImages({required bool long}) async {
    if (!DocumentService.canRender) {
      _showMessage('Turning pages into images needs Android.');
      return;
    }
    final int count = await _knownPageCount();
    if (count == 0 || !mounted) return;
    final ImageExportOptions? options = await ImageExportSheet.show(
      context,
      pageCount: count,
      currentPage: _currentPage.clamp(1, count),
      long: long,
    );
    if (options == null || !mounted) return;

    if (long) {
      final File? image = await _runBusy<File?>(
        'Creating long image',
        () => PdfTools.toLongImage(
          _currentFile,
          documentName: _doc.name,
          width: options.width,
        ),
      );
      if (image == null || !mounted) return;
      await ExportSheet.show(
        context,
        files: [image],
        mimeType: 'image/jpeg',
        title: 'Long image ready',
      );
      return;
    }

    final List<File>? images = await _runBusy(
      'Converting ${options.pages.length} '
      'page${options.pages.length == 1 ? '' : 's'}',
      () => PdfTools.toImages(
        _currentFile,
        options.pages,
        documentName: _doc.name,
        width: options.width,
        png: options.png,
      ),
    );
    if (images == null || images.isEmpty || !mounted) return;
    await ExportSheet.show(
      context,
      files: images,
      mimeType: options.png ? 'image/png' : 'image/jpeg',
      title: images.length == 1
          ? 'Image ready'
          : '${images.length} images ready',
    );
  }

  Future<void> _compress() async {
    final CompressLevel? level = await CompressSheet.show(
      context,
      canRasterize: DocumentService.canRender,
    );
    if (level == null || !mounted) return;
    final CompressResult? result = await _runBusy(
      'Compressing',
      () => PdfTools.compress(_currentFile, level, _doc.name),
    );
    if (result == null || !mounted) return;

    final String sizes =
        '${formatBytes(result.originalBytes)} → '
        '${formatBytes(result.compressedBytes)}';
    final String? choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(result.isSmaller ? 'Compressed' : 'No saving'),
        content: Text(
          result.isSmaller
              ? '$sizes\n${(result.saving * 100).round()}% smaller.'
              : '$sizes\nThis document is already about as small as this '
                    'level can make it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
          if (result.isSmaller) ...[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('export'),
              child: const Text('Save or share'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop('replace'),
              child: const Text('Replace original'),
            ),
          ],
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'export') {
      await ExportSheet.show(
        context,
        files: [result.file],
        mimeType: 'application/pdf',
        title: 'Compressed PDF',
      );
    } else if (choice == 'replace') {
      // Into the documents directory with the other history files, so it
      // lives as long as they do rather than as long as the outbox.
      final Directory directory = await getApplicationDocumentsDirectory();
      final File copy = await result.file.copy(
        '${directory.path}/edited_${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      if (!mounted) return;
      _swapDocument(copy, addToHistory: true);
      await _savePdf();
    }
  }

  Future<void> _split() async {
    final int count = await _knownPageCount();
    if (!mounted) return;
    if (count < 2) {
      _showMessage('There is only one page; nothing to split.');
      return;
    }
    final List<List<int>>? groups = await SplitSheet.show(context, count);
    if (groups == null || !mounted) return;
    final List<File>? parts = await _runBusy(
      'Splitting',
      () => PdfTools.split(_currentFile, groups, _doc.name),
    );
    if (parts == null || !mounted) return;
    await ExportSheet.show(
      context,
      files: parts,
      mimeType: 'application/pdf',
      title: 'Split into ${parts.length} files',
    );
  }

  Future<void> _merge() async {
    final File? merged = await MergeScreen.open(
      context,
      initial: [MergeItem(path: _currentFile.path, name: _doc.name)],
    );
    if (merged == null || !mounted) return;
    final DocumentRef? saved = await ExportSheet.show(
      context,
      files: [merged],
      mimeType: 'application/pdf',
      title: 'Merged PDF ready',
    );
    if (saved != null && mounted) {
      _showMessage(
        'Saved ${saved.name}',
        action: SnackBarAction(
          label: 'Open',
          onPressed: () => _openOther(saved),
        ),
      );
    }
  }

  /// Applies a document-wide stamp as one history entry.
  Future<void> _stamp(
    String label,
    String done,
    Future<Uint8List> Function(Uint8List bytes, Uint8List font) render,
  ) async {
    setState(() {
      _isLoading = true;
      _busyLabel = label;
    });
    final Uint8List font = (await DocumentImport.loadFonts()).regular;
    final PdfEditResult result = await PdfService.edit(
      _currentFile,
      label.toLowerCase(),
      (bytes) => render(bytes, font),
    );
    if (!mounted) return;
    _handleResult(result, done, undoable: !_editMode);
  }

  Future<void> _addWatermark() async {
    final int count = await _knownPageCount();
    if (count == 0 || !mounted) return;
    final WatermarkOptions? options = await WatermarkSheet.show(
      context,
      pageCount: count,
      currentPage: _currentPage.clamp(1, count),
    );
    if (options == null || !mounted) return;
    await _stamp(
      'Adding watermark',
      'Watermark added',
      (bytes, font) => PdfStamps.renderWatermark(bytes, options, font),
    );
  }

  Future<void> _addPageNumbers() async {
    final int count = await _knownPageCount();
    if (count == 0 || !mounted) return;
    final PageNumberOptions? options = await PageNumbersSheet.show(
      context,
      pageCount: count,
      currentPage: _currentPage.clamp(1, count),
    );
    if (options == null || !mounted) return;
    await _stamp(
      'Adding page numbers',
      'Page numbers added',
      (bytes, font) => PdfStamps.renderPageNumbers(bytes, options, font),
    );
  }

  Future<void> _flatten() async {
    final (int, int)? found = await _runBusy(
      'Reading',
      () async => PdfStamps.countInteractive(await _currentFile.readAsBytes()),
    );
    if (found == null || !mounted) return;
    final (int annotations, int fields) = found;
    if (annotations == 0 && fields == 0) {
      _showMessage('Nothing to flatten: no annotations or form fields.');
      return;
    }
    final List<String> parts = [
      if (annotations > 0)
        '$annotations annotation${annotations == 1 ? '' : 's'}',
      if (fields > 0) '$fields form field${fields == 1 ? '' : 's'}',
    ];
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Flatten this document?'),
        content: Text(
          '${parts.join(' and ')} will become part of the page${annotations + fields == 1 ? '' : 's'}: '
          'they look the same in every reader and can no longer be edited, '
          'erased or filled in. Links are flattened too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Flatten'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _stamp(
      'Flattening',
      'Flattened',
      (bytes, _) => PdfStamps.renderFlatten(bytes),
    );
  }

  /// Sets or removes the password the document is saved with.
  Future<void> _protect() async {
    final SnackBarAction save = SnackBarAction(
      label: 'Save',
      onPressed: _savePdf,
    );
    if (_password != null) {
      final bool? remove = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Remove the password?'),
          content: const Text(
            'Once saved, anyone will be able to open this document.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (remove != true || !mounted) return;
      setState(() {
        _password = null;
        _securityChanged = true;
      });
      _showMessage('Password removed. Save to apply.', action: save);
      return;
    }
    final String? password = await ProtectSheet.show(context);
    if (password == null || !mounted) return;
    setState(() {
      _password = password;
      _securityChanged = true;
    });
    _showMessage('Password set. Save to apply.', action: save);
  }

  Future<void> _recogniseText() async {
    if (!OcrService.isAvailable) {
      _showMessage('Text recognition needs Android.');
      return;
    }
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Recognise text?'),
        content: const Text(
          'Scanned pages are read on this device and get an invisible text '
          'layer, so they can be searched, selected and copied. Pages that '
          'already have text are left alone.\n\n'
          'Works for the Latin alphabet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Recognise'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    final OcrOutcome? outcome = await _runBusy(
      'Recognising text',
      () => OcrService.makeSearchable(
        _currentFile,
        onProgress: (done, total) {
          if (!mounted || total == 0) return;
          setState(
            () => _busyLabel =
                'Recognising text, page ${(done + 1).clamp(1, total)} '
                'of $total',
          );
        },
      ),
    );
    if (outcome == null || !mounted) return;
    final Uint8List? bytes = outcome.bytes;
    if (bytes == null) {
      _showMessage(
        outcome.textPages == outcome.pageCount
            ? 'Every page already has text.'
            : 'No text could be recognised.',
      );
      return;
    }
    final Directory directory = await getApplicationDocumentsDirectory();
    final File file = File(
      '${directory.path}/edited_${DateTime.now().microsecondsSinceEpoch}.pdf',
    );
    await file.writeAsBytes(bytes, flush: true);
    if (!mounted) return;
    _handleResult(
      PdfEditResult.success(file),
      'Recognised text on ${outcome.recognisedPages} '
      'page${outcome.recognisedPages == 1 ? '' : 's'}',
      undoable: true,
    );
  }

  Future<void> _showTools() async {
    if (!await _flushViewer() || !mounted) return;
    final ToolAction? action = await ToolsSheet.show(
      context,
      isProtected: _password != null,
    );
    if (action == null || !mounted) return;
    switch (action) {
      case ToolAction.managePages:
        await _openManagePages(ManagePagesIntent.manage);
      case ToolAction.deletePages:
        await _openManagePages(ManagePagesIntent.delete);
      case ToolAction.extractPages:
        await _openManagePages(ManagePagesIntent.extract);
      case ToolAction.insertPages:
        await _openManagePages(ManagePagesIntent.insert);
      case ToolAction.toWord:
        await _convertToWord();
      case ToolAction.toImage:
        await _exportImages(long: false);
      case ToolAction.compress:
        await _compress();
      case ToolAction.split:
        await _split();
      case ToolAction.merge:
        await _merge();
      case ToolAction.watermark:
        await _addWatermark();
      case ToolAction.pageNumbers:
        await _addPageNumbers();
      case ToolAction.flatten:
        await _flatten();
      case ToolAction.protect:
        await _protect();
      case ToolAction.extractText:
        await TextExtractScreen.open(
          context,
          file: _currentFile,
          documentName: _doc.name,
        );
      case ToolAction.ocr:
        await _recogniseText();
      case ToolAction.editText:
        await _enterEditMode(EditTab.edit, tool: EditTool.editText);
      case ToolAction.addText:
        await _enterEditMode(EditTab.edit, tool: EditTool.text);
      case ToolAction.addImage:
        await _enterEditMode(EditTab.edit);
        await _pickImageToPlace();
      case ToolAction.highlight:
        await _enterEditMode(EditTab.annotate, tool: EditTool.highlight);
      case ToolAction.underline:
        await _enterEditMode(EditTab.annotate, tool: EditTool.underline);
      case ToolAction.strikethrough:
        await _enterEditMode(EditTab.annotate, tool: EditTool.strikethrough);
      case ToolAction.draw:
        await _enterEditMode(EditTab.annotate, tool: EditTool.draw);
      case ToolAction.marker:
        await _enterEditMode(EditTab.annotate, tool: EditTool.marker);
      case ToolAction.shapes:
        await _enterEditMode(EditTab.annotate, tool: EditTool.shape);
      case ToolAction.note:
        await _enterEditMode(EditTab.annotate, tool: EditTool.note);
      case ToolAction.eraser:
        await _enterEditMode(EditTab.annotate, tool: EditTool.eraser);
      case ToolAction.signature:
        await _enterEditMode(EditTab.sign);
        await _openSignatures();
    }
  }

  Future<void> _showFileOptions() async {
    if (!await _flushViewer() || !mounted) return;
    final FileAction? action = await FileOptionsSheet.show(
      context,
      document: _doc,
      renderPath: _currentFile.path,
      isFavorite: _isFavorite,
      hidden: {
        if (!DocumentService.supportsSaf) FileAction.saveCopy,
        if (!DocumentService.canRender) ...{
          FileAction.toImage,
          FileAction.toLongImage,
        },
        if (_reflow) FileAction.bookmarks,
        // There is no file behind an unsaved document to rename, delete or
        // find again later.
        if (_doc.isUnsaved) ...{
          FileAction.rename,
          FileAction.delete,
          FileAction.favorite,
        },
      },
    );
    if (action == null || !mounted) return;
    switch (action) {
      case FileAction.details:
        await DocumentDetailsSheet.show(
          context,
          document: _doc,
          file: _currentFile,
        );
      case FileAction.rename:
        final DocumentRef? renamed = await DocumentActions.rename(
          context,
          _doc,
        );
        if (renamed == null || !mounted) return;
        setState(() {
          // Where there is no document provider the path *is* the document,
          // so renaming moved the file history and the viewer point at.
          if (renamed.path != _doc.path) {
            for (int i = 0; i < _history.length; i++) {
              if (_history[i].path == _doc.path) _history[i] = renamed.file;
            }
            if (_currentFile.path == _doc.path) _currentFile = renamed.file;
            if (_savedPath == _doc.path) _savedPath = renamed.path;
          }
          _doc = renamed;
        });
      case FileAction.share:
        // Shared as it would be saved: a protected document stays protected.
        final File? outgoing = await _runBusy('Preparing', _fileToWrite);
        if (outgoing == null || !mounted) return;
        await DocumentActions.share(context, outgoing, _doc.name);
      case FileAction.print:
        await DocumentActions.printFile(context, _currentFile, _doc.name);
      case FileAction.favorite:
        final bool? starred = await DocumentActions.toggleFavorite(
          context,
          _doc,
        );
        if (starred != null && mounted) setState(() => _isFavorite = starred);
      case FileAction.saveCopy:
        await _saveCopy();
      case FileAction.bookmarks:
        _pdfViewerKey.currentState?.openBookmarkView();
      case FileAction.toImage:
        await _exportImages(long: false);
      case FileAction.toLongImage:
        await _exportImages(long: true);
      case FileAction.toWord:
        await _convertToWord();
      case FileAction.merge:
        await _merge();
      case FileAction.split:
        await _split();
      case FileAction.compress:
        await _compress();
      case FileAction.delete:
        if (await DocumentActions.delete(context, _doc) && mounted) {
          // The file is gone; there is nothing left to save or to ask about.
          Navigator.of(context).pop();
        }
      case FileAction.feedback:
        await DocumentActions.feedback(context);
    }
  }

  Future<void> _showViewSettings() async {
    // A change of layout recreates the viewer.
    if (!await _flushViewer() || !mounted) return;
    return ViewSettingsSheet.show(
      context,
      settings: _settings,
      reflow: _reflow,
      onChanged: _applyViewSettings,
    );
  }

  void _applyViewSettings(ReaderSettings next, bool reflow) {
    final bool leavingReflow = _reflow && !reflow;
    final bool relayout =
        next.direction != _settings.direction ||
        next.pageByPage != _settings.pageByPage ||
        leavingReflow;
    if (next.keepScreenOn != _settings.keepScreenOn) {
      DocumentService.setKeepScreenOn(next.keepScreenOn);
    }
    if (reflow && _isSearching) _closeSearch();
    setState(() {
      _settings = next;
      _reflow = reflow;
    });
    next.save();
    // Reflow unmounts the viewer; coming back needs a fresh one, as does any
    // change of layout.
    if (relayout && !reflow) _resetViewer(keepPage: true);
  }

  void _toggleRotation() {
    final bool landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    SystemChrome.setPreferredOrientations(
      landscape
          ? const [DeviceOrientation.portraitUp]
          : const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ],
    );
    _rotationLocked = true;
  }

  // --- Search ----------------------------------------------------------------

  /// `PdfTextSearchResult` is a ChangeNotifier that fills in asynchronously.
  /// Without this listener the match counter and the next/previous buttons
  /// appeared to do nothing until some unrelated rebuild happened.
  void _onSearchResultChanged() {
    if (mounted) setState(() {});
  }

  void _startSearch() {
    if (_reflow) _applyViewSettings(_settings, false);
    setState(() => _isSearching = true);
  }

  void _runSearch(String value) {
    if (value.isEmpty) return;
    _searchResult?.removeListener(_onSearchResultChanged);
    _searchResult?.clear();
    final PdfTextSearchResult result = _pdfViewerController.searchText(value);
    result.addListener(_onSearchResultChanged);
    setState(() {
      _searchQuery = value;
      _searchResult = result;
    });
  }

  void _closeSearch() {
    _searchController.clear();
    _searchResult?.removeListener(_onSearchResultChanged);
    _searchResult?.clear();
    setState(() {
      _searchQuery = '';
      _searchResult = null;
      _isSearching = false;
    });
  }

  // --- Tools -----------------------------------------------------------------

  Future<void> _changeTool(EditTool newTool) async {
    if (_activeTool == newTool) newTool = EditTool.none;
    // Every tool reads the file, not the viewer.
    if (!await _flushViewer() || !mounted) return;

    // Flush anything drawn with the tool being left behind. If the flush
    // fails the work is still pending, and switching away would hide its
    // overlay while leaving it queued against a view that has since moved --
    // so stay on the tool and let the user retry or redraw. Markup tools
    // share one batch, each item keeping its own kind, so moving between
    // them does not flush.
    if (_isPen(_activeTool) &&
        !_isPen(newTool) &&
        _pendingDrawStrokes.isNotEmpty) {
      await _commitPendingDrawStrokes();
      if (_pendingDrawStrokes.isNotEmpty) return;
    } else if (_isMarkup(_activeTool) &&
        !_isMarkup(newTool) &&
        _pendingHighlights.isNotEmpty) {
      await _commitPendingHighlights();
      if (_pendingHighlights.isNotEmpty) return;
    }
    if (!mounted) return;
    setState(() {
      _activeTool = newTool;
      _currentDrawing = [];
      _placement = null;
      // Each tool starts ready to use. Leaving pan latched from a previous
      // session with the tool made the overlay look active while swallowing
      // nothing, which reads as the tool being broken.
      _panMode = false;
      // A tool change abandons a half-typed annotation; leaving the field
      // floating over the new tool's overlay is just a stuck widget.
      _isEnteringText = false;
      _textPosition = null;
      _textTarget = null;
      _textOverlayController.clear();
      _textPrefill = newTool == EditTool.date
          ? formatDate(DateTime.now())
          : null;
    });
    _syncOverlayTicker();
    if (newTool == EditTool.editText) _loadTextBoxes();
    if (newTool == EditTool.eraser) _loadMarks();
  }

  // --- Notes and the eraser --------------------------------------------------

  Future<void> _addNoteAt(int pageIndex, Offset pagePoint) async {
    final String? text = await askNoteText(context);
    if (text == null || text.trim().isEmpty || !mounted) return;
    setState(() => _isLoading = true);
    final PdfEditResult result = await PdfAnnotations.addNote(
      _currentFile,
      pageIndex,
      pagePoint,
      text,
    );
    if (!mounted) return;
    _handleResult(result, 'Note added');
  }

  Future<void> _loadMarks() async {
    final File file = _currentFile;
    if (_marksPath == file.path || _loadingMarks) return;
    setState(() => _loadingMarks = true);
    List<PdfMark> marks = const [];
    try {
      marks = await PdfAnnotations.list(await file.readAsBytes());
    } catch (e) {
      _showMessage('Could not read the annotations: $e');
    } finally {
      if (mounted) {
        setState(() {
          _loadingMarks = false;
          _marks = marks;
          _marksPath = file.path;
        });
        // The document changed while this was running; catch up.
        if (_activeTool == EditTool.eraser && file.path != _currentFile.path) {
          _loadMarks();
        }
      }
    }
  }

  /// Where [mark] shows on its page as displayed.
  Rect _markDisplayRect(PdfMark mark) {
    // The viewer draws a note's icon from the corner of its box, larger.
    final Rect bounds = mark.type == MarkType.note
        ? mark.bounds.topLeft & PdfAnnotations.noteIconSize
        : mark.bounds;
    if (mark.pageIndex >= _pageTurns.length) return bounds;
    return rotatePageRect(
      bounds,
      _unrotatedPageSizes[mark.pageIndex],
      _pageTurns[mark.pageIndex],
    );
  }

  Future<void> _onEraserTap(TapUpDetails details) async {
    if (_loadingMarks || _marksPath != _currentFile.path) return;
    final PdfPageGeometry? geometry = _geometry;
    if (geometry == null) return;
    final PdfPagePoint hit = geometry.resolve(details.localPosition);
    PdfMark? best;
    double bestArea = double.infinity;
    for (final PdfMark mark in _marks) {
      if (mark.pageIndex != hit.pageIndex) continue;
      final Rect rect = _markDisplayRect(mark);
      if (!rect.inflate(6).contains(hit.pagePoint)) continue;
      // The smallest one under the finger: a note on top of a highlight is
      // the thing being pointed at.
      final double area = rect.width * rect.height;
      if (area < bestArea) {
        best = mark;
        bestArea = area;
      }
    }
    if (best == null) return;
    setState(() => _isLoading = true);
    final PdfEditResult result = await PdfAnnotations.remove(
      _currentFile,
      best,
    );
    if (!mounted) return;
    _handleResult(result, '${best.type.label} removed');
  }

  // --- Selected text ---------------------------------------------------------

  void _onTextSelectionChanged(PdfTextSelectionChangedDetails details) {
    final String? text = details.selectedText;
    final Rect? region = details.globalSelectedRegion;
    if (!mounted || (text == _selectedText && region == _selectionRegion)) {
      return;
    }
    void apply() {
      if (!mounted) return;
      setState(() {
        _selectedText = text;
        _selectionRegion = region;
      });
    }

    // A viewer being disposed reports its selection gone from inside the
    // frame, where nothing may be rebuilt.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  /// Drops the selection and returns what it held.
  String _takeSelection() {
    final String text = _selectedText ?? '';
    _pdfViewerController.clearSelection();
    setState(() {
      _selectedText = null;
      _selectionRegion = null;
    });
    return text;
  }

  Future<void> _copySelection() async {
    await Clipboard.setData(ClipboardData(text: _takeSelection()));
    _showMessage('Copied');
  }

  Future<void> _shareSelection() async {
    final String text = _takeSelection();
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (e) {
      _showMessage('Could not share: $e');
    }
  }

  void _findSelection() {
    final String query = _takeSelection()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (query.isEmpty) return;
    _searchController.text = query;
    _startSearch();
    _runSearch(query);
  }

  Future<void> _sendSelection({required bool translate}) async {
    final String text = _takeSelection();
    try {
      if (translate) {
        await DocumentService.translate(text);
      } else {
        await DocumentService.webSearch(text);
      }
    } on PlatformException catch (e) {
      _showMessage(
        e.message ??
            (translate
                ? 'No app here can translate text.'
                : 'No app here can search the web.'),
      );
    }
  }

  /// Marks up exactly the selected text, line by line.
  Future<void> _markSelection(MarkupKind kind) async {
    final List<viewer.PdfTextLine> lines =
        _pdfViewerKey.currentState?.getSelectedTextLines() ?? const [];
    if (lines.isEmpty) return;
    final Map<int, List<HighlightRect>> byPage = {};
    for (final viewer.PdfTextLine line in lines) {
      // Page numbers are 1-based here; bounds are in the page's own space,
      // which is the space markup is written in.
      byPage
          .putIfAbsent(line.pageNumber - 1, () => [])
          .add(
            HighlightRect(
              bounds: line.bounds,
              color: _markupColors[kind]!,
              kind: kind,
            ),
          );
    }
    _takeSelection();
    if (!await _flushViewer() || !mounted) return;
    setState(() => _isLoading = true);
    final PdfEditResult result = await _applyPerPage(
      byPage.keys,
      (file, pageIndex) => PdfService.addHighlightAnnotation(
        file,
        pageIndex,
        byPage[pageIndex]!,
      ),
    );
    if (!mounted) return;
    _handleResult(
      result,
      switch (kind) {
        MarkupKind.highlight => 'Highlighted',
        MarkupKind.underline => 'Underlined',
        MarkupKind.strikethrough => 'Struck through',
      },
      undoable: !_editMode,
    );
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
    final List<Offset> scenePoints = screenPoints
        .map(geometry.toScene)
        .toList(growable: false);

    setState(() {
      if (_isPen(_activeTool)) {
        // Resolve against the page under the first point so a stroke that
        // strays over a page boundary stays whole.
        final int pageIndex = geometry.resolve(screenPoints.first).pageIndex;
        final double scale = geometry.fitScaleFor(pageIndex);
        final double pageTop = geometry.sceneTopFor(pageIndex);
        final Size pageSize = geometry.pageSizes[pageIndex];

        final List<Offset> pagePoints = scenePoints
            .map((scene) {
              final Offset displayPoint = Offset(
                (scene.dx / scale).clamp(0.0, pageSize.width),
                ((scene.dy - pageTop) / scale).clamp(0.0, pageSize.height),
              );
              return _toPdfSpace(pageIndex, displayPoint);
            })
            .toList(growable: false);

        final bool shape = _activeTool == EditTool.shape;
        _pendingDrawStrokes.add(
          _PendingStroke(
            // A shape is its two ends; the wobble between them is not kept.
            scenePoints: shape
                ? [scenePoints.first, scenePoints.last]
                : scenePoints,
            pagePoints: shape
                ? [pagePoints.first, pagePoints.last]
                : pagePoints,
            pageIndex: pageIndex,
            color: _penColor,
            width: _penWidth,
            opacity: _penOpacity,
            shape: shape ? _shapeKind : null,
          ),
        );
      } else if (_isMarkup(_activeTool)) {
        final MarkupKind kind = _markupKindOf(_activeTool);
        final Rect screenBounds = _boundsOf(screenPoints);
        final PdfPageRect mapped = geometry.resolveRect(screenBounds);
        _pendingHighlights.add(
          _PendingHighlight(
            sceneBounds: Rect.fromPoints(
              geometry.toScene(screenBounds.topLeft),
              geometry.toScene(screenBounds.bottomRight),
            ),
            pageBounds: _rectToPdfSpace(mapped.pageIndex, mapped.bounds),
            pageIndex: mapped.pageIndex,
            color: _markupColors[kind]!,
            kind: kind,
          ),
        );
      }
      _currentDrawing = [];
    });
    _syncOverlayTicker();
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

  /// Set while the viewer's own second pop, after Back cleared a selection,
  /// is still on its way.
  bool _swallowPop = false;

  Future<void> _onBack() async {
    // The viewer parks an entry on this route while text is selected, and
    // takes it off again by popping the navigator. With canPop false that
    // pop lands here, where it is not the user asking to leave.
    if (ModalRoute.of(context)?.willHandlePopInternally ?? false) {
      // Still selected means Back was pressed, rather than the selection
      // being tapped away; the viewer then pops a second time on its own.
      _swallowPop = (_selectedText ?? '').isNotEmpty;
      Navigator.of(context).pop();
      if (_swallowPop) {
        Future<void>.delayed(
          const Duration(milliseconds: 400),
          () => _swallowPop = false,
        );
      }
      return;
    }
    if (_swallowPop) {
      _swallowPop = false;
      return;
    }
    if (_placement != null) {
      setState(() => _placement = null);
      return;
    }
    if (_editMode) {
      await _exitEditMode(keepChanges: false);
      return;
    }
    if (_isSearching) {
      _closeSearch();
      return;
    }
    if (await _confirmLeave() && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        appBar: _editMode ? _buildEditAppBar(theme) : _buildReadAppBar(),
        body: Stack(
          children: [
            Positioned.fill(child: _buildContent(theme)),
            // Kept last so the scrim actually covers the tool bar and blocks
            // input while an edit is being written.
            if (_isLoading)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black45,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        if (_busyLabel != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            '$_busyLabel…',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        bottomNavigationBar: _editMode
            ? _buildEditBar(theme)
            : _buildReadBar(theme),
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    if (!_settingsLoaded) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_reflow && !_editMode) {
      return ReflowView(
        file: _currentFile,
        theme: _settings.theme,
        initialPage: _currentPage,
      );
    }
    final bool isDrawingTool = _isPen(_activeTool) || _isMarkup(_activeTool);
    // Tints would also tint the live annotation colours, which draw on top
    // of the page unfiltered, so editing shows the page as it is.
    final PageTheme pageTheme = _editMode
        ? PageTheme.original
        : _settings.theme;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The viewer fills the Stack, so these constraints are exactly the
        // ones SfPdfViewer lays its pages out against.
        _viewportWidth = constraints.maxWidth;
        _viewportHeight = constraints.maxHeight;
        return Stack(
          key: _viewportKey,
          children: [
            ColorFiltered(
              colorFilter: pageTheme.filter,
              child: SfPdfViewerTheme(
                data: SfPdfViewerThemeData(
                  backgroundColor: pageTheme.viewerBackground,
                ),
                child: SfPdfViewer.file(
                  _currentFile,
                  key: _pdfViewerKey,
                  controller: _pdfViewerController,
                  initialScrollOffset: _targetScrollOffset ?? Offset.zero,
                  initialZoomLevel: _targetZoom ?? 1.0,
                  canShowScrollHead: false,
                  canShowScrollStatus: false,
                  pageSpacing: kPageSpacing,
                  scrollDirection:
                      _editMode ||
                          _settings.direction == ReadingDirection.vertical
                      ? PdfScrollDirection.vertical
                      : PdfScrollDirection.horizontal,
                  pageLayoutMode: !_editMode && _settings.pageByPage
                      ? PdfPageLayoutMode.single
                      : PdfPageLayoutMode.continuous,
                  onDocumentLoaded: _onDocumentLoaded,
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
                  onTap: _isTextTool || _activeTool == EditTool.note
                      ? _onViewerTap
                      : null,
                  // The built-in menu only copies; ours also marks up.
                  canShowTextSelectionMenu: false,
                  onTextSelectionChanged: _onTextSelectionChanged,
                  onFormFieldValueChanged: (_) => _markViewerDirty(),
                  onAnnotationEdited: (_) => _markViewerDirty(),
                  onAnnotationRemoved: (_) => _markViewerDirty(),
                ),
              ),
            ),
            if (isDrawingTool) _buildDrawingOverlay(),
            if (_activeTool == EditTool.editText) _buildEditTextOverlay(),
            if (_activeTool == EditTool.eraser) _buildEraserOverlay(),
            if ((_selectedText ?? '').trim().isNotEmpty && !isDrawingTool)
              _buildSelectionBar(theme),
            if (_placement != null)
              PlacementBox(
                rect: _placement!.rect,
                bytes: _placement!.bytes,
                onMove: _movePlacement,
                onResize: _resizePlacement,
              ),
            if (_isEnteringText && _textPosition != null) _buildTextEntry(),
            if (_pageSizes.isNotEmpty)
              Positioned(top: 12, left: 12, child: _buildPageIndicator()),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildToolSettingsBar(theme),
            ),
          ],
        );
      },
    );
  }

  void _onDocumentLoaded(PdfDocumentLoadedDetails details) {
    // The viewer lays out a page rotated 90 or 270 degrees with its width and
    // height swapped, so the geometry has to use the same orientation or
    // annotations resolve to the wrong page and position on rotated
    // documents.
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
        turn.swapsAxes ? Size(page.size.height, page.size.width) : page.size,
      );
    }
    if (!mounted) return;
    setState(() {
      _pageSizes = sizes;
      _unrotatedPageSizes = unrotated;
      _pageTurns = turns;
      _pageCount = count;
      _currentPage = _pdfViewerController.pageNumber;
    });
    final int? targetPage = _targetPage;
    if (targetPage != null) {
      _targetPage = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pdfViewerController.jumpToPage(targetPage);
      });
    }
    // An edit replaces the viewer, which takes the running search with it.
    // Re-run it so the bar that is still open keeps meaning something.
    if (_isSearching && _searchQuery.isNotEmpty && _searchResult == null) {
      _runSearch(_searchQuery);
    }
    if (_activeTool == EditTool.editText) _loadTextBoxes();
    if (_activeTool == EditTool.eraser) _loadMarks();
    if (!_formHintShown && PdfStamps.hasFormFields(details.document)) {
      _formHintShown = true;
      _showMessage('This PDF has a form. Tap a field to fill it in.');
    }
  }

  /// Said once per document, not after every edit reloads it.
  bool _formHintShown = false;

  void _onViewerTap(PdfGestureDetails details) {
    // pageNumber is 1-based, and is -1 when the tap landed outside every page.
    // Feeding it straight to the 0-based PdfDocument.pages[...] put text one
    // page late and failed outright on the last page.
    if (details.pageNumber < 1) return;
    final int pageIndex = details.pageNumber - 1;
    if (_activeTool == EditTool.note) {
      _addNoteAt(pageIndex, _toPdfSpace(pageIndex, details.pagePosition));
      return;
    }
    setState(() {
      // pagePosition is reported in displayed page space, so it needs the same
      // unrotation as gesture-drawn annotations.
      _textTarget = PdfPagePoint(
        pageIndex,
        _toPdfSpace(pageIndex, details.pagePosition),
      );
      _textPosition = details.position;
      _isEnteringText = true;
      _textOverlayController.text = _textPrefill ?? '';
    });
  }

  // --- App bars --------------------------------------------------------------

  PreferredSizeWidget _buildReadAppBar() {
    return AppBar(
      centerTitle: false,
      titleSpacing: 0,
      title: _isSearching ? _buildSearchField() : _buildTitle(),
      actions: _isSearching ? _buildSearchActions() : _buildReadActions(),
    );
  }

  PreferredSizeWidget _buildEditAppBar(ThemeData theme) {
    return AppBar(
      centerTitle: false,
      titleSpacing: 0,
      leading: IconButton(
        icon: const Icon(Icons.close_rounded),
        tooltip: 'Close without saving',
        onPressed: _isLoading ? null : () => _exitEditMode(keepChanges: false),
      ),
      title: Align(
        alignment: Alignment.centerLeft,
        child: IconButton(
          icon: const Icon(Icons.help_outline_rounded),
          tooltip: 'Help',
          onPressed: _showHelp,
        ),
      ),
      actions: [
        // Undo/redo must be blocked while a write is in flight: the loading
        // scrim does not cover the AppBar, and the completing edit would
        // append to history and silently undo the undo.
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
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 12),
          child: FilledButton(
            onPressed: _isLoading ? null : _finishEditing,
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }

  Widget _buildTitle() => Text(
    _doc.name,
    style: const TextStyle(fontSize: 18),
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

  List<Widget> _buildSearchActions() {
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

  List<Widget> _buildReadActions() {
    return [
      if (_hasUnsavedChanges)
        IconButton(
          icon: const Icon(Icons.save_rounded),
          onPressed: _isLoading ? null : _savePdf,
          tooltip: 'Save',
        ),
      IconButton(
        icon: const _WordIcon(),
        onPressed: _isLoading ? null : _convertToWord,
        tooltip: 'Convert to Word',
      ),
      IconButton(
        icon: const Icon(Icons.screen_rotation_rounded),
        onPressed: _toggleRotation,
        tooltip: 'Rotate screen',
      ),
      IconButton(
        icon: const Icon(Icons.manage_search_rounded),
        onPressed: _isLoading ? null : _startSearch,
        tooltip: 'Search text',
      ),
      IconButton(
        icon: const Icon(Icons.more_vert_rounded),
        onPressed: _isLoading ? null : _showFileOptions,
        tooltip: 'More',
      ),
    ];
  }

  // --- Overlays --------------------------------------------------------------

  Widget _buildDrawingOverlay() {
    // In pan mode the overlay still paints the pending preview but stops
    // taking input, so pinch and scroll land on the viewer underneath.
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: _panMode,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) =>
              setState(() => _currentDrawing = [details.localPosition]),
          onPanUpdate: (details) =>
              setState(() => _currentDrawing.add(details.localPosition)),
          onPanEnd: (_) => _onDrawEnd(),
          onPanCancel: () => setState(() => _currentDrawing = []),
          child: CustomPaint(
            size: Size.infinite,
            painter: _DrawingPainter(
              points: _currentDrawing,
              tool: _activeTool,
              drawColor: _penColor.withValues(alpha: _penOpacity),
              drawWidth: _penWidth,
              shapeKind: _shapeKind,
              markupColor: _markupColors[_markupKindOf(_activeTool)]!,
              strokes: _pendingDrawStrokes,
              highlights: _pendingHighlights,
              controller: _pdfViewerController,
              topInset: () => _geometry?.topInset ?? 0,
              repaint: _overlayTick,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEditTextOverlay() {
    // Translucent, and the painter declines hits, so taps come here while
    // scrolling and pinching still reach the viewer underneath.
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: _onEditTextTap,
        child: CustomPaint(
          size: Size.infinite,
          painter: _TextBoxPainter(
            boxes: _textBoxesPath == _currentFile.path
                ? [for (final _TextBox b in _textBoxes) (b.pageIndex, b.displayRect)]
                : const [],
            pageSizes: _pageSizes,
            viewportWidth: _viewportWidth,
            controller: _pdfViewerController,
            color: Theme.of(context).colorScheme.primary,
            repaint: _overlayTick,
          ),
        ),
      ),
    );
  }

  Widget _buildEraserOverlay() {
    // As the edit-text overlay: taps come here, drags reach the viewer.
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapUp: _onEraserTap,
        child: CustomPaint(
          size: Size.infinite,
          painter: _TextBoxPainter(
            boxes: _marksPath == _currentFile.path
                ? [
                    for (final PdfMark mark in _marks)
                      (mark.pageIndex, _markDisplayRect(mark)),
                  ]
                : const [],
            pageSizes: _pageSizes,
            viewportWidth: _viewportWidth,
            controller: _pdfViewerController,
            color: Theme.of(context).colorScheme.error,
            repaint: _overlayTick,
          ),
        ),
      ),
    );
  }

  /// What can be done with the selected text, floating by the selection.
  Widget _buildSelectionBar(ThemeData theme) {
    const double height = 48;
    double top = 12;
    final Rect? region = _selectionRegion;
    final RenderObject? box = _viewportKey.currentContext?.findRenderObject();
    if (region != null && box is RenderBox) {
      // Above the selection where there is room, below it otherwise.
      top = box.globalToLocal(region.topCenter).dy - height - 16;
      if (top < 8) top = box.globalToLocal(region.bottomCenter).dy + 32;
      top = top.clamp(8.0, math.max(8.0, _viewportHeight - height - 8));
    }
    Widget action(String label, VoidCallback onPressed) => TextButton(
      onPressed: _isLoading ? null : onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, height),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: Text(label),
    );
    return Positioned(
      top: top,
      left: 8,
      right: 8,
      child: Center(
        child: Material(
          elevation: 6,
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(height / 2),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                action('Copy', _copySelection),
                action('Highlight', () => _markSelection(MarkupKind.highlight)),
                action('Underline', () => _markSelection(MarkupKind.underline)),
                action(
                  'Strike',
                  () => _markSelection(MarkupKind.strikethrough),
                ),
                if (!_editMode) action('Find', _findSelection),
                action('Share', _shareSelection),
                if (DocumentService.supportsSaf) ...[
                  action('Translate', () => _sendSelection(translate: true)),
                  action('Web search', () => _sendSelection(translate: false)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextEntry() {
    // Clamped into the viewport: tapping near the right edge or the bottom of
    // the page used to put half the box, or its confirm button, off screen.
    const double boxWidth = 220;
    const double boxHeight = 64;
    final double left = (_textPosition!.dx - boxWidth / 2).clamp(
      8.0,
      (_viewportWidth - boxWidth - 8).clamp(8.0, double.infinity),
    );
    final double top = (_textPosition!.dy - boxHeight).clamp(
      8.0,
      (_viewportHeight - boxHeight - 8).clamp(8.0, double.infinity),
    );

    return Positioned(
      left: left,
      top: top,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: boxWidth,
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _isLoading ? null : _showThumbnails,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withAlpha(150),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$_currentPage/${_pageSizes.length}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
        ),
      ),
    );
  }

  // --- Bottom bars -----------------------------------------------------------

  Widget _buildReadBar(ThemeData theme) {
    return BottomAppBar(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      height: 72,
      color: theme.colorScheme.surface,
      elevation: 20,
      child: Row(
        children: [
          _buildToolBtn(
            Icons.edit_note_rounded,
            'Edit',
            () => _enterEditMode(EditTab.edit),
            theme,
          ),
          _buildToolBtn(
            Icons.border_color_outlined,
            'Annotate',
            () => _enterEditMode(EditTab.annotate),
            theme,
          ),
          _buildToolBtn(
            Icons.history_edu_rounded,
            'Sign',
            () => _enterEditMode(EditTab.sign),
            theme,
          ),
          _buildToolBtn(Icons.apps_rounded, 'Tools', _showTools, theme),
          _buildToolBtn(
            Icons.chrome_reader_mode_outlined,
            'View',
            _showViewSettings,
            theme,
            isActive: _reflow,
          ),
        ],
      ),
    );
  }

  Widget _buildEditBar(ThemeData theme) {
    final ColorScheme colors = theme.colorScheme;
    final List<Widget> tools = switch (_editTab) {
      EditTab.edit => [
        _buildEditTool(
          Icons.edit_note_rounded,
          'Edit text',
          () => _changeTool(EditTool.editText),
          active: _activeTool == EditTool.editText,
        ),
        _buildEditTool(
          Icons.title_rounded,
          'Add text',
          () => _changeTool(EditTool.text),
          active: _activeTool == EditTool.text,
        ),
        _buildEditTool(
          Icons.add_photo_alternate_outlined,
          'Add image',
          _pickImageToPlace,
          active: _placement != null && !_placement!.isSignature,
        ),
      ],
      EditTab.annotate => [
        _buildEditTool(
          Icons.highlight_rounded,
          'Highlight',
          () => _changeTool(EditTool.highlight),
          active: _activeTool == EditTool.highlight,
        ),
        _buildEditTool(
          Icons.format_underlined_rounded,
          'Underline',
          () => _changeTool(EditTool.underline),
          active: _activeTool == EditTool.underline,
        ),
        _buildEditTool(
          Icons.format_strikethrough_rounded,
          'Strike',
          () => _changeTool(EditTool.strikethrough),
          active: _activeTool == EditTool.strikethrough,
        ),
        _buildEditTool(
          Icons.draw_rounded,
          'Draw',
          () => _changeTool(EditTool.draw),
          active: _activeTool == EditTool.draw,
        ),
        _buildEditTool(
          Icons.brush_outlined,
          'Marker',
          () => _changeTool(EditTool.marker),
          active: _activeTool == EditTool.marker,
        ),
        _buildEditTool(
          Icons.category_outlined,
          'Shapes',
          () => _changeTool(EditTool.shape),
          active: _activeTool == EditTool.shape,
        ),
        _buildEditTool(
          Icons.sticky_note_2_outlined,
          'Note',
          () => _changeTool(EditTool.note),
          active: _activeTool == EditTool.note,
        ),
        _buildEditTool(
          Icons.auto_fix_normal_outlined,
          'Eraser',
          () => _changeTool(EditTool.eraser),
          active: _activeTool == EditTool.eraser,
        ),
      ],
      EditTab.sign => [
        _buildEditTool(
          Icons.history_edu_rounded,
          'Signature',
          _openSignatures,
          active: _placement != null && _placement!.isSignature,
        ),
        _buildEditTool(
          Icons.event_rounded,
          'Date',
          () => _changeTool(EditTool.date),
          active: _activeTool == EditTool.date,
        ),
      ],
    };

    return Material(
      color: colors.surface,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              // The annotate tab holds more tools than a phone is wide, so
              // the row scrolls; the others still spread across it.
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: tools,
                    ),
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: colors.outlineVariant),
            Row(
              children: [
                for (final EditTab tab in EditTab.values)
                  Expanded(
                    child: InkWell(
                      onTap: _isLoading ? null : () => _switchTab(tab),
                      child: Padding(
                        padding: const EdgeInsets.only(top: 12, bottom: 6),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              tab.label,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: tab == _editTab
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: tab == _editTab
                                    ? colors.onSurface
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 6),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              height: 3,
                              width: tab == _editTab ? 28 : 0,
                              decoration: BoxDecoration(
                                color: colors.primary,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEditTool(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool active = false,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: _isLoading ? null : onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          constraints: const BoxConstraints(minWidth: 72),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: active ? colors.secondaryContainer : null,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 26,
                color: active ? colors.onSecondaryContainer : colors.onSurface,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: active
                      ? colors.onSecondaryContainer
                      : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
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
    return Expanded(
      child: InkWell(
        onTap: _isLoading ? null : onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: isActive ? theme.colorScheme.primaryContainer : null,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: foreground),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolSettingsBar(ThemeData theme) {
    final Widget? content = _toolSettingsContent(theme);
    if (content == null) return const SizedBox.shrink();

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
      child: content,
    );
  }

  Widget? _toolSettingsContent(ThemeData theme) {
    if (_placement != null) {
      return Row(
        children: [
          TextButton(
            onPressed: _isLoading
                ? null
                : () => setState(() => _placement = null),
            child: const Text('Cancel'),
          ),
          Expanded(
            child: Text(
              'Drag to move, corner to resize',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          FilledButton(
            onPressed: _isLoading ? null : _commitPlacement,
            child: const Text('Place'),
          ),
        ],
      );
    }

    switch (_activeTool) {
      case EditTool.none:
        return null;
      case EditTool.editText:
        return Row(
          children: [
            if (_loadingText) ...[
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                _loadingText
                    ? 'Finding text…'
                    : 'Tap a dashed line to change it',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        );
      case EditTool.text:
      case EditTool.date:
        return Row(
          children: [
            const Text('Size:'),
            Expanded(
              child: Slider(
                value: _selectedTextSize,
                min: 8.0,
                max: 72.0,
                divisions: 32,
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
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Text('Width:'),
                Expanded(
                  child: Slider(
                    value: _selectedDrawWidth,
                    min: 1.0,
                    max: 20.0,
                    divisions: 19,
                    label: _selectedDrawWidth.round().toString(),
                    onChanged: (val) =>
                        setState(() => _selectedDrawWidth = val),
                  ),
                ),
                for (final color in const [
                  Colors.black,
                  Colors.blue,
                  Colors.red,
                ])
                  _buildColorPicker(
                    color,
                    (c) => setState(() => _selectedDrawColor = c),
                    _selectedDrawColor,
                  ),
              ],
            ),
            _buildPendingActions(
              theme,
              hasPending: _pendingDrawStrokes.isNotEmpty,
              onUndo: () => _discardLastPending(_pendingDrawStrokes),
              onDiscardAll: () => _discardAllPending(_pendingDrawStrokes),
              onApply: _commitPendingDrawStrokes,
            ),
          ],
        );
      case EditTool.marker:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final MapEntry<String, double> size
                      in _markerWidths.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(size.key),
                        selected: _markerWidth == size.value,
                        onSelected: (_) =>
                            setState(() => _markerWidth = size.value),
                      ),
                    ),
                  const SizedBox(width: 6),
                  for (final Color color in const [
                    Colors.yellow,
                    Colors.greenAccent,
                    Colors.lightBlueAccent,
                    Colors.pinkAccent,
                    Colors.orangeAccent,
                  ])
                    _buildColorPicker(
                      color,
                      (c) => setState(() => _markerColor = c),
                      _markerColor,
                    ),
                ],
              ),
            ),
            _buildPendingActions(
              theme,
              hasPending: _pendingDrawStrokes.isNotEmpty,
              onUndo: () => _discardLastPending(_pendingDrawStrokes),
              onDiscardAll: () => _discardAllPending(_pendingDrawStrokes),
              onApply: _commitPendingDrawStrokes,
            ),
          ],
        );
      case EditTool.shape:
        const Map<ShapeKind, (IconData, String)> kinds = {
          ShapeKind.rectangle: (Icons.crop_square_rounded, 'Rectangle'),
          ShapeKind.ellipse: (Icons.circle_outlined, 'Ellipse'),
          ShapeKind.line: (Icons.horizontal_rule_rounded, 'Line'),
          ShapeKind.arrow: (Icons.north_east_rounded, 'Arrow'),
        };
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final MapEntry<ShapeKind, (IconData, String)> kind
                      in kinds.entries)
                    IconButton(
                      icon: Icon(kind.value.$1),
                      tooltip: kind.value.$2,
                      isSelected: _shapeKind == kind.key,
                      style: IconButton.styleFrom(
                        backgroundColor: _shapeKind == kind.key
                            ? theme.colorScheme.secondaryContainer
                            : null,
                      ),
                      onPressed: () => setState(() => _shapeKind = kind.key),
                    ),
                  const SizedBox(width: 8),
                  for (final Color color in const [
                    Colors.red,
                    Colors.blue,
                    Colors.green,
                    Colors.black,
                  ])
                    _buildColorPicker(
                      color,
                      (c) => setState(() => _shapeColor = c),
                      _shapeColor,
                    ),
                ],
              ),
            ),
            Row(
              children: [
                const Text('Width:'),
                Expanded(
                  child: Slider(
                    value: _shapeWidth,
                    min: 1.0,
                    max: 12.0,
                    divisions: 11,
                    label: _shapeWidth.round().toString(),
                    onChanged: (val) => setState(() => _shapeWidth = val),
                  ),
                ),
              ],
            ),
            _buildPendingActions(
              theme,
              hasPending: _pendingDrawStrokes.isNotEmpty,
              onUndo: () => _discardLastPending(_pendingDrawStrokes),
              onDiscardAll: () => _discardAllPending(_pendingDrawStrokes),
              onApply: _commitPendingDrawStrokes,
            ),
          ],
        );
      case EditTool.note:
        return Text(
          'Tap where the note should go',
          style: theme.textTheme.bodyMedium,
        );
      case EditTool.eraser:
        final bool ready = !_loadingMarks && _marksPath == _currentFile.path;
        return Row(
          children: [
            if (!ready) ...[
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                !ready
                    ? 'Finding annotations…'
                    : _marks.isEmpty
                    ? 'Nothing to erase here. Pen strokes and shapes are '
                          'part of the page once applied; use Undo for those.'
                    : 'Tap a boxed highlight or note to remove it',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        );
      case EditTool.highlight:
      case EditTool.underline:
      case EditTool.strikethrough:
        final MarkupKind kind = _markupKindOf(_activeTool);
        final List<Color> palette = kind == MarkupKind.highlight
            ? const [
                Colors.yellow,
                Colors.greenAccent,
                Colors.lightBlueAccent,
                Colors.pinkAccent,
              ]
            : const [Colors.red, Colors.blue, Colors.green, Colors.black];
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final Color color in palette)
                  _buildColorPicker(
                    color,
                    (c) => setState(() => _markupColors[kind] = c),
                    _markupColors[kind]!,
                  ),
              ],
            ),
            _buildPendingActions(
              theme,
              hasPending: _pendingHighlights.isNotEmpty,
              onUndo: () => _discardLastPending(_pendingHighlights),
              onDiscardAll: () => _discardAllPending(_pendingHighlights),
              onApply: _commitPendingHighlights,
            ),
          ],
        );
    }
  }

  /// Pan toggle plus the three things a user needs to be able to do with work
  /// that has been drawn but not yet written: take back the last stroke, throw
  /// the whole batch away, or commit it.
  ///
  /// Without Undo and Discard the only exit from a bad stroke was to commit it
  /// and then undo the resulting document, which costs a full PDF rewrite.
  Widget _buildPendingActions(
    ThemeData theme, {
    required bool hasPending,
    required VoidCallback onUndo,
    required VoidCallback onDiscardAll,
    required VoidCallback onApply,
  }) {
    return Row(
      children: [
        IconButton(
          icon: Icon(_panMode ? Icons.pan_tool_rounded : Icons.edit_rounded),
          isSelected: _panMode,
          onPressed: _isLoading
              ? null
              : () {
                  setState(() => _panMode = !_panMode);
                  _syncOverlayTicker();
                },
          tooltip: _panMode ? 'Drawing paused — tap to draw' : 'Scroll & zoom',
        ),
        Expanded(
          child: Text(
            _panMode ? 'Scroll and zoom' : 'Draw on the page',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (hasPending) ...[
          IconButton(
            icon: const Icon(Icons.undo_rounded),
            onPressed: _isLoading ? null : onUndo,
            tooltip: 'Undo last',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _isLoading ? null : onDiscardAll,
            tooltip: 'Discard all',
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: FilledButton(
              onPressed: _isLoading ? null : onApply,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 36),
              ),
              child: const Text('Apply'),
            ),
          ),
        ],
      ],
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

/// The boxed "W" of a word processor, which Material's icon set lacks.
class _WordIcon extends StatelessWidget {
  const _WordIcon();

  @override
  Widget build(BuildContext context) {
    final Color color = IconTheme.of(context).color ?? Colors.black;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 2),
        borderRadius: BorderRadius.circular(4),
      ),
      // The button's tooltip names the action; the letter is decoration and
      // would otherwise be read out as "W".
      child: Text(
        'W',
        semanticsLabel: '',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w900,
          height: 1,
        ),
      ),
    );
  }
}

// --- Edit text sheet ------------------------------------------------------------

class _LineEdit {
  final String text;
  final double fontSize;
  final bool bold;
  final bool italic;
  final Color color;
  const _LineEdit(this.text, this.fontSize, this.bold, this.italic, this.color);
}

class _LineEditorSheet extends StatefulWidget {
  final PdfTextLine line;
  const _LineEditorSheet({required this.line});

  @override
  State<_LineEditorSheet> createState() => _LineEditorSheetState();
}

class _LineEditorSheetState extends State<_LineEditorSheet> {
  late final TextEditingController _text = TextEditingController(
    text: widget.line.text.trim(),
  );
  late double _size = widget.line.fontSize > 0
      ? widget.line.fontSize.clamp(4.0, 96.0)
      : 12;
  late bool _bold = widget.line.bold;
  late bool _italic = widget.line.italic;
  Color _color = Colors.black;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit(String text) =>
      Navigator.of(context).pop(_LineEdit(text, _size, _bold, _italic, _color));

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Edit text',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _text,
                autofocus: true,
                maxLines: null,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Size ${_size.round()}'),
                  Expanded(
                    child: Slider(
                      value: _size,
                      min: 4,
                      max: 96,
                      onChanged: (v) => setState(() => _size = v),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilterChip(
                    label: const Text('Bold'),
                    selected: _bold,
                    onSelected: (v) => setState(() => _bold = v),
                  ),
                  FilterChip(
                    label: const Text('Italic'),
                    selected: _italic,
                    onSelected: (v) => setState(() => _italic = v),
                  ),
                  for (final Color color in const [
                    Colors.black,
                    Color(0xFF444444),
                    Colors.red,
                    Colors.blue,
                  ])
                    GestureDetector(
                      onTap: () => setState(() => _color = color),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _color == color
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outlineVariant,
                            width: _color == color ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'The old line is covered in white, not removed: it stays in '
                'the file and can still be found by search or copy.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () => _submit(''),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Remove line'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => _submit(_text.text),
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Painters -------------------------------------------------------------------

class _DrawingPainter extends CustomPainter {
  final List<Offset> points;
  final EditTool tool;
  final Color drawColor;
  final double drawWidth;
  final ShapeKind shapeKind;
  final Color markupColor;
  final List<_PendingStroke> strokes;
  final List<_PendingHighlight> highlights;

  /// Reads the viewer's current transform at paint time.
  ///
  /// Pending work is held in scene space, so the projection has to be the live
  /// one rather than whatever it was when this painter was constructed —
  /// otherwise the preview slides off the page as soon as the user pans.
  final PdfViewerController controller;

  /// How far the viewer has pushed a short document down to centre it, in
  /// scene units; read at paint time for the same reason.
  final double Function() topInset;

  _DrawingPainter({
    required this.points,
    required this.tool,
    required this.drawColor,
    required this.drawWidth,
    required this.shapeKind,
    required this.markupColor,
    required this.strokes,
    required this.highlights,
    required this.controller,
    required this.topInset,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final double zoom = controller.zoomLevel;
    final Offset scroll = controller.scrollOffset - Offset(0, topInset());
    Offset toScreen(Offset scene) => (scene - scroll) * zoom;

    for (final h in highlights) {
      _drawMarkup(
        canvas,
        Rect.fromPoints(
          toScreen(h.sceneBounds.topLeft),
          toScreen(h.sceneBounds.bottomRight),
        ),
        h.color,
        h.kind,
        zoom,
      );
    }

    for (final stroke in strokes) {
      final List<Offset> screen = stroke.scenePoints
          .map(toScreen)
          .toList(growable: false);
      final Color color = stroke.color.withValues(alpha: stroke.opacity);
      // Zoom the preview's thickness too, or a stroke drawn zoomed in
      // visibly changes weight the moment it is committed.
      final double width = stroke.width * zoom;
      final ShapeKind? shape = stroke.shape;
      if (shape != null) {
        _drawShape(canvas, shape, screen.first, screen.last, color, width);
      } else {
        _drawPolyline(canvas, screen, color, width);
      }
    }

    if (points.isEmpty) return;

    if (tool == EditTool.draw || tool == EditTool.marker) {
      _drawPolyline(canvas, points, drawColor, drawWidth);
    } else if (tool == EditTool.shape) {
      _drawShape(
        canvas,
        shapeKind,
        points.first,
        points.last,
        drawColor,
        drawWidth,
      );
    } else if (_PdfEditorScreenState._isMarkup(tool)) {
      final Rect bounds = _PdfEditorScreenState._boundsOf(points);
      final MarkupKind kind = _PdfEditorScreenState._markupKindOf(tool);
      if (kind != MarkupKind.highlight) {
        // Show the whole area being marked, faintly, around the line.
        canvas.drawRect(bounds, Paint()..color = markupColor.withAlpha(40));
      }
      _drawMarkup(canvas, bounds, markupColor, kind, zoom);
    }
  }

  static void _drawMarkup(
    Canvas canvas,
    Rect rect,
    Color color,
    MarkupKind kind,
    double zoom,
  ) {
    switch (kind) {
      case MarkupKind.highlight:
        canvas.drawRect(
          rect,
          Paint()
            ..color = color.withAlpha(128)
            ..style = PaintingStyle.fill,
        );
      case MarkupKind.underline:
      case MarkupKind.strikethrough:
        final double y = kind == MarkupKind.underline
            ? rect.bottom
            : rect.center.dy;
        canvas.drawLine(
          Offset(rect.left, y),
          Offset(rect.right, y),
          Paint()
            ..color = color
            ..strokeWidth = (1.5 * zoom).clamp(1.0, 6.0),
        );
    }
  }

  static void _drawShape(
    Canvas canvas,
    ShapeKind kind,
    Offset from,
    Offset to,
    Color color,
    double width,
  ) {
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..color = color
      ..strokeWidth = width;
    switch (kind) {
      case ShapeKind.rectangle:
        canvas.drawRect(Rect.fromPoints(from, to), paint);
      case ShapeKind.ellipse:
        canvas.drawOval(Rect.fromPoints(from, to), paint);
      case ShapeKind.line:
        canvas.drawLine(from, to, paint);
      case ShapeKind.arrow:
        canvas.drawLine(from, to, paint);
        final double length = (to - from).distance;
        if (length < 1) return;
        final Offset along = (to - from) / length;
        final Offset across = Offset(-along.dy, along.dx);
        final double head = math.max(9, width * 4);
        final Offset base = to - along * head;
        canvas.drawPath(
          Path()
            ..moveTo(to.dx, to.dy)
            ..lineTo(
              (base + across * head * 0.45).dx,
              (base + across * head * 0.45).dy,
            )
            ..lineTo(
              (base - across * head * 0.45).dx,
              (base - across * head * 0.45).dy,
            )
            ..close(),
          Paint()..color = color,
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

/// Dashed boxes around every editable line or erasable annotation,
/// projected through the viewer's live transform so they follow the page
/// while it scrolls and zooms.
class _TextBoxPainter extends CustomPainter {
  /// Page index and rectangle in displayed page space.
  final List<(int, Rect)> boxes;
  final List<Size> pageSizes;
  final double viewportWidth;
  final PdfViewerController controller;
  final Color color;

  _TextBoxPainter({
    required this.boxes,
    required this.pageSizes,
    required this.viewportWidth,
    required this.controller,
    required this.color,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (pageSizes.isEmpty || viewportWidth <= 0) return;
    final double zoom = controller.zoomLevel;
    final Offset scroll = controller.scrollOffset;

    // Page tops once, rather than PdfPageGeometry.sceneTopFor per box, which
    // would walk every page before it for every line on a long document.
    final List<double> tops = List<double>.filled(pageSizes.length, 0);
    double top = 0;
    for (int i = 0; i < pageSizes.length; i++) {
      tops[i] = top;
      top += pageSizes[i].height * viewportWidth / pageSizes[i].width;
      top += kPageSpacing;
    }
    // A document shorter than the viewer is centred in it.
    final double inset = PdfPageGeometry.insetFor(
      top - kPageSpacing,
      size.height,
      zoom,
    );
    for (int i = 0; i < tops.length; i++) {
      tops[i] += inset;
    }

    final Rect screen = Offset.zero & size;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final (int pageIndex, Rect displayRect) in boxes) {
      if (pageIndex >= pageSizes.length) continue;
      final double scale = viewportWidth / pageSizes[pageIndex].width;
      final Rect r = displayRect.inflate(1.5);
      final Rect onScreen = Rect.fromLTRB(
        (r.left * scale - scroll.dx) * zoom,
        (tops[pageIndex] + r.top * scale - scroll.dy) * zoom,
        (r.right * scale - scroll.dx) * zoom,
        (tops[pageIndex] + r.bottom * scale - scroll.dy) * zoom,
      );
      if (!onScreen.overlaps(screen)) continue;
      _dashRect(canvas, onScreen, paint);
    }
  }

  static void _dashRect(Canvas canvas, Rect rect, Paint paint) {
    const double dash = 5;
    const double gap = 3;
    void line(Offset a, Offset b) {
      final double length = (b - a).distance;
      if (length == 0) return;
      final Offset step = (b - a) / length;
      for (double d = 0; d < length; d += dash + gap) {
        final double end = d + dash < length ? d + dash : length;
        canvas.drawLine(a + step * d, a + step * end, paint);
      }
    }

    line(rect.topLeft, rect.topRight);
    line(rect.topRight, rect.bottomRight);
    line(rect.bottomRight, rect.bottomLeft);
    line(rect.bottomLeft, rect.topLeft);
  }

  /// Taps belong to the overlay's gesture detector and drags to the viewer,
  /// so the painting itself claims nothing.
  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(covariant _TextBoxPainter oldDelegate) => true;
}
