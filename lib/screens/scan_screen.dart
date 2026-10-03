import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/ocr_service.dart';
import '../services/document_service.dart';
import '../services/recent_documents.dart';
import '../services/scan_service.dart';
import 'scan_crop_screen.dart';

/// Where the pages captured in a session end up.
enum ScanDestination {
  /// Build a new PDF and save it through the system document picker.
  newDocument,

  /// Hand the rendered page images back, for appending to a document that is
  /// already open in the editor.
  appendToDocument,
}

/// Capture, clean up and order pages before they become a PDF.
///
/// The captured photos are never modified. Crop, rotation and filter are held
/// per page as intent and re-applied on every render, so every adjustment
/// stays reversible until the document is built.
class ScanScreen extends StatefulWidget {
  final ScanSource initialSource;
  final ScanDestination destination;

  /// Pictures the session starts with instead of asking [initialSource] for
  /// some: the ones another app handed over through "Open with".
  final List<String> initialImages;

  const ScanScreen({
    super.key,
    required this.initialSource,
    required this.destination,
    this.initialImages = const [],
  });

  /// Runs a session and returns the saved document, or null if the user
  /// backed out or saved nothing.
  static Future<DocumentRef?> createDocument(
    BuildContext context, {
    required ScanSource source,
    List<String> initialImages = const [],
  }) async {
    final Object? result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute(
        builder: (_) => ScanScreen(
          initialSource: source,
          destination: ScanDestination.newDocument,
          initialImages: initialImages,
        ),
      ),
    );
    return result is DocumentRef ? result : null;
  }

  /// Runs a session and returns the rendered pages, ready to append to an
  /// open document.
  static Future<List<Uint8List>?> capturePages(
    BuildContext context, {
    required ScanSource source,
  }) async {
    final Object? result = await Navigator.of(context).push<Object?>(
      MaterialPageRoute(
        builder: (_) => ScanScreen(
          initialSource: source,
          destination: ScanDestination.appendToDocument,
        ),
      ),
    );
    return result is List<Uint8List> ? result : null;
  }

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  /// Capping the capture keeps decoding fast and the PDF small. 2600px across
  /// an A4 sheet is about 220 dpi, well past what a phone camera resolves
  /// through a document anyway.
  static const double _maxCaptureEdge = 2600;

  final ImagePicker _picker = ImagePicker();
  final PageController _pageController = PageController();
  final List<ScanPage> _pages = [];

  /// Rendered previews, keyed by [ScanPage.renderKey], so changing a filter
  /// invalidates exactly the page that changed.
  final Map<String, Uint8List> _previews = {};
  final Set<String> _rendering = {};

  int _index = 0;
  bool _isBusy = false;
  bool _isPicking = false;
  String? _status;
  ScanPageSize _pageSize = ScanPageSize.fitImage;

  /// Whether the saved PDF gets a text layer, read off the pages on the
  /// device, so that it can be searched and copied from.
  bool _searchable = OcrService.isAvailable;

  @override
  void initState() {
    super.initState();
    ScanService.sweepStaleCaptures();
    // Straight into the camera or the gallery: the session has no content of
    // its own yet, so an empty screen would just be a detour.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.initialImages.isNotEmpty) {
        _adopt(widget.initialImages, popIfStillEmpty: true);
      } else {
        _addPages(widget.initialSource, popIfStillEmpty: true);
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  ScanPage? get _current =>
      _pages.isEmpty ? null : _pages[_index.clamp(0, _pages.length - 1)];

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Capture ---------------------------------------------------------------

  Future<void> _addPages(
    ScanSource source, {
    bool popIfStillEmpty = false,
  }) async {
    if (_isPicking) return;
    setState(() => _isPicking = true);
    List<XFile> picked = const [];
    try {
      if (source == ScanSource.camera) {
        final XFile? shot = await _picker.pickImage(
          source: ImageSource.camera,
          maxWidth: _maxCaptureEdge,
          maxHeight: _maxCaptureEdge,
          imageQuality: 92,
        );
        if (shot != null) picked = [shot];
      } else {
        picked = await _picker.pickMultiImage(
          maxWidth: _maxCaptureEdge,
          maxHeight: _maxCaptureEdge,
          imageQuality: 92,
        );
      }
    } catch (e) {
      _showMessage('Could not open the camera: $e');
    }

    if (!mounted) return;
    setState(() => _isPicking = false);

    if (picked.isEmpty) {
      if (popIfStillEmpty && _pages.isEmpty && mounted) {
        Navigator.of(context).pop();
      }
      return;
    }

    await _adopt([for (final XFile file in picked) file.path]);
  }

  /// Takes the pictures at [paths] into the session as new pages.
  Future<void> _adopt(
    List<String> paths, {
    bool popIfStillEmpty = false,
  }) async {
    final List<ScanPage> added = [];
    for (final String path in paths) {
      try {
        // image_picker leaves the shot in a shared cache Android may clear
        // while this screen is still open; keep our own copy.
        final File retained = await ScanService.retainCapture(path);
        added.add(ScanPage(sourcePath: retained.path));
      } catch (e) {
        debugPrint('Could not keep capture $path: $e');
      }
    }
    if (!mounted) return;
    if (added.isEmpty) {
      if (popIfStillEmpty && _pages.isEmpty) Navigator.of(context).pop();
      return;
    }

    setState(() {
      _pages.addAll(added);
      _index = _pages.length - added.length;
    });
    _jumpTo(_index);

    // Trim the desk out of each shot in the background. Nothing waits on it;
    // an undetected page simply stays uncropped.
    for (final ScanPage page in added) {
      unawaited(_autoCrop(page));
    }
  }

  Future<void> _autoCrop(ScanPage page) async {
    final ScanQuad? detected = await ScanService.detectDocument(
      page.sourcePath,
    );
    if (!mounted || detected == null) return;
    final int index = _pages.indexWhere((p) => p.sourcePath == page.sourcePath);
    // The page may have been deleted, or cropped by hand, while this ran.
    if (index < 0 || !_pages[index].quad.isFull) return;
    setState(() => _pages[index] = _pages[index].copyWith(quad: detected));
  }

  void _jumpTo(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _pageController.jumpToPage(index);
    });
  }

  // --- Per-page edits --------------------------------------------------------

  void _updateCurrent(ScanPage Function(ScanPage page) change) {
    final ScanPage? page = _current;
    if (page == null) return;
    setState(() => _pages[_index] = change(page));
  }

  Future<void> _cropCurrent() async {
    final ScanPage? page = _current;
    if (page == null) return;
    final ScanQuad? quad = await ScanCropScreen.show(
      context,
      imagePath: page.sourcePath,
      initialQuad: page.quad,
    );
    if (quad == null || !mounted) return;
    _updateCurrent((p) => p.copyWith(quad: quad));
  }

  void _rotateCurrent() =>
      _updateCurrent((p) => p.copyWith(quarterTurns: p.quarterTurns + 1));

  void _setFilter(ScanFilter filter, {required bool applyToAll}) {
    setState(() {
      if (applyToAll) {
        for (int i = 0; i < _pages.length; i++) {
          _pages[i] = _pages[i].copyWith(filter: filter);
        }
      } else if (_current != null) {
        _pages[_index] = _pages[_index].copyWith(filter: filter);
      }
    });
  }

  Future<void> _deleteCurrent() async {
    final ScanPage? page = _current;
    if (page == null) return;
    setState(() {
      _pages.removeAt(_index);
      if (_index >= _pages.length) _index = (_pages.length - 1).clamp(0, 9999);
    });
    // The capture is this session's own copy, so nothing else refers to it.
    try {
      await File(page.sourcePath).delete();
    } catch (_) {
      // Best effort.
    }
    if (_pages.isNotEmpty) _jumpTo(_index);
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final ScanPage page = _pages.removeAt(oldIndex);
      _pages.insert(newIndex, page);
      _index = newIndex;
    });
    _jumpTo(_index);
  }

  // --- Preview ---------------------------------------------------------------

  Uint8List? _previewFor(ScanPage page) {
    final String key = page.renderKey;
    final Uint8List? cached = _previews[key];
    if (cached != null) return cached;
    if (!_rendering.contains(key)) {
      _rendering.add(key);
      unawaited(_renderPreview(page, key));
    }
    return null;
  }

  Future<void> _renderPreview(ScanPage page, String key) async {
    final Uint8List? bytes = await ScanService.render(
      page,
      maxEdge: ScanService.previewEdge,
    );
    _rendering.remove(key);
    if (!mounted || bytes == null) return;
    setState(() {
      // Only the previews still reachable from a page are worth keeping; a
      // long session of filter changes would otherwise hold every render.
      final Set<String> live = _pages.map((p) => p.renderKey).toSet();
      _previews.removeWhere((k, _) => !live.contains(k));
      _previews[key] = bytes;
    });
  }

  // --- Finishing -------------------------------------------------------------

  /// Renders every page at full resolution, reporting progress.
  Future<List<Uint8List>?> _renderAll() async {
    final List<Uint8List> rendered = [];
    for (int i = 0; i < _pages.length; i++) {
      if (mounted) {
        setState(
          () => _status = 'Processing page ${i + 1} of ${_pages.length}',
        );
      }
      final Uint8List? bytes = await ScanService.render(_pages[i]);
      if (bytes == null) {
        _showMessage('Page ${i + 1} could not be processed.');
        return null;
      }
      rendered.add(bytes);
    }
    return rendered;
  }

  Future<void> _finish() async {
    if (_pages.isEmpty) return;
    if (widget.destination == ScanDestination.appendToDocument) {
      await _finishAsPages();
    } else {
      await _finishAsDocument();
    }
  }

  Future<void> _finishAsPages() async {
    setState(() => _isBusy = true);
    try {
      final List<Uint8List>? rendered = await _renderAll();
      if (!mounted || rendered == null) return;
      await _discardCaptures();
      if (!mounted) return;
      Navigator.of(context).pop(rendered);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  /// Deletes the session's photos.
  ///
  /// They are this session's own copies, taken so the picker's cache could not
  /// be cleared under it, so nothing else refers to them once the pages have
  /// been rendered or thrown away.
  Future<void> _discardCaptures() async {
    for (final ScanPage page in _pages) {
      try {
        await File(page.sourcePath).delete();
      } catch (_) {
        // Best effort; the daily sweep catches whatever is left.
      }
    }
  }

  Future<void> _finishAsDocument() async {
    final String? name = await _askForName();
    if (name == null || !mounted) return;

    setState(() => _isBusy = true);
    File? built;
    // Set once the built file has been handed to the caller, which makes the
    // caller responsible for it. Deleting it unconditionally would pull the
    // document out from under the editor on a platform with no document
    // picker, where the built file is what gets opened.
    bool handedOff = false;
    try {
      final List<Uint8List>? rendered = await _renderAll();
      if (!mounted || rendered == null) return;

      setState(() => _status = 'Building the PDF');
      built = await ScanService.buildPdf(rendered, _pageSize);
      if (!mounted) return;
      if (built == null) {
        _showMessage('Could not build the PDF.');
        return;
      }

      if (_searchable && OcrService.isAvailable) {
        setState(() => _status = 'Recognising text');
        try {
          final OcrOutcome outcome = await OcrService.makeSearchable(built);
          final Uint8List? searchable = outcome.bytes;
          if (searchable != null) {
            await built.writeAsBytes(searchable, flush: true);
          }
        } catch (_) {
          // A scan nobody can search is still the scan that was asked for.
        }
        if (!mounted) return;
      }

      if (!DocumentService.supportsSaf) {
        // No document picker to save through, so hand back the file as it
        // stands rather than pretending it was filed somewhere.
        handedOff = true;
        await _discardCaptures();
        if (!mounted) return;
        Navigator.of(context).pop(DocumentRef(path: built.path, name: name));
        return;
      }

      setState(() => _status = 'Saving');
      final DocumentRef? saved = await DocumentService.saveCopy(name, built);
      if (!mounted) return;
      if (saved == null) return; // Cancelled at the system picker.

      await RecentDocuments.add(saved);
      await _discardCaptures();
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) _showMessage('Could not save the scan: $e');
    } finally {
      // The saved copy lives at the URI the user chose; this scratch file is
      // only the staging area.
      if (built != null && !handedOff) {
        try {
          await built.delete();
        } catch (_) {
          // Best effort.
        }
      }
      if (mounted) {
        setState(() {
          _isBusy = false;
          _status = null;
        });
      }
    }
  }

  Future<String?> _askForName() async {
    final TextEditingController controller = TextEditingController(
      text: 'Scan ${_timestamp()}.pdf',
    );
    ScanPageSize size = _pageSize;
    bool searchable = _searchable;

    final String? name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Save scan'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'File name',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 16),
              const Text('Page size'),
              const SizedBox(height: 8),
              SegmentedButton<ScanPageSize>(
                segments: [
                  for (final ScanPageSize option in ScanPageSize.values)
                    ButtonSegment(value: option, label: Text(option.label)),
                ],
                selected: {size},
                showSelectedIcon: false,
                onSelectionChanged: (selection) =>
                    setDialogState(() => size = selection.first),
              ),
              if (OcrService.isAvailable)
                SwitchListTile(
                  contentPadding: const EdgeInsets.only(top: 8),
                  value: searchable,
                  onChanged: (on) => setDialogState(() => searchable = on),
                  title: const Text('Searchable text'),
                  subtitle: const Text('Read the pages so they can be searched'),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    if (name == null) return null;
    if (mounted) {
      setState(() {
        _pageSize = size;
        _searchable = searchable;
      });
    }
    if (name.isEmpty) return 'Scan ${_timestamp()}.pdf';
    return name.toLowerCase().endsWith('.pdf') ? name : '$name.pdf';
  }

  static String _timestamp() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}${two(now.minute)}';
  }

  Future<void> _confirmDiscard() async {
    if (_pages.isEmpty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard scan?'),
        content: Text(
          '${_pages.length} page${_pages.length == 1 ? '' : 's'} '
          'will be thrown away.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep scanning'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    for (final ScanPage page in _pages) {
      try {
        await File(page.sourcePath).delete();
      } catch (_) {
        // Best effort.
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool hasPages = _pages.isNotEmpty;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _isBusy ? null : _confirmDiscard,
            tooltip: 'Discard',
          ),
          title: Text(
            hasPages ? 'Page ${_index + 1} of ${_pages.length}' : 'New scan',
          ),
          actions: [
            TextButton.icon(
              onPressed: (_isBusy || !hasPages) ? null : _finish,
              icon: const Icon(Icons.check_rounded),
              label: Text(
                widget.destination == ScanDestination.appendToDocument
                    ? 'Add'
                    : 'Save',
              ),
            ),
          ],
        ),
        body: Stack(
          children: [
            Column(
              children: [
                Expanded(child: hasPages ? _buildPager() : _buildEmpty(theme)),
                if (hasPages) ...[_buildFilters(theme), _buildStrip(theme)],
              ],
            ),
            if (_isBusy || _isPicking)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        if (_status != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _status!,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        bottomNavigationBar: hasPages ? _buildActions(theme) : null,
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.document_scanner_outlined,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text('No pages yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => _addPages(ScanSource.camera),
                  icon: const Icon(Icons.photo_camera_rounded),
                  label: const Text('Camera'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => _addPages(ScanSource.gallery),
                  icon: const Icon(Icons.photo_library_rounded),
                  label: const Text('Gallery'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPager() {
    return PageView.builder(
      controller: _pageController,
      itemCount: _pages.length,
      onPageChanged: (index) => setState(() => _index = index),
      itemBuilder: (context, index) {
        final Uint8List? preview = _previewFor(_pages[index]);
        return Padding(
          padding: const EdgeInsets.all(16),
          child: preview == null
              ? const Center(child: CircularProgressIndicator())
              : InteractiveViewer(
                  maxScale: 4,
                  child: Center(
                    child: Image.memory(
                      preview,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
        );
      },
    );
  }

  Widget _buildFilters(ThemeData theme) {
    final ScanPage? page = _current;
    if (page == null) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final ScanFilter filter in ScanFilter.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text(filter.label),
                selected: page.filter == filter,
                onSelected: (_) => _setFilter(filter, applyToAll: false),
              ),
            ),
          if (_pages.length > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ActionChip(
                avatar: const Icon(Icons.done_all_rounded, size: 18),
                label: const Text('Apply to all'),
                onPressed: () => _setFilter(page.filter, applyToAll: true),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStrip(ThemeData theme) {
    return SizedBox(
      height: 92,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _pages.length,
        onReorderItem: _reorder,
        itemBuilder: (context, index) {
          final ScanPage page = _pages[index];
          final Uint8List? preview = _previews[page.renderKey];
          final bool isCurrent = index == _index;
          return Padding(
            key: ValueKey(page.sourcePath),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ReorderableDragStartListener(
              index: index,
              child: GestureDetector(
                onTap: () {
                  setState(() => _index = index);
                  _pageController.animateToPage(
                    index,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                  );
                },
                child: Container(
                  width: 58,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isCurrent
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                      width: isCurrent ? 2.5 : 1,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: preview == null
                      ? Center(
                          child: Text(
                            '${index + 1}',
                            style: theme.textTheme.labelLarge,
                          ),
                        )
                      : Image.memory(
                          preview,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildActions(ThemeData theme) {
    return BottomAppBar(
      height: 76,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _action(theme, Icons.crop_rounded, 'Crop', _cropCurrent),
          _action(theme, Icons.rotate_right_rounded, 'Rotate', _rotateCurrent),
          _action(
            theme,
            Icons.delete_outline_rounded,
            'Delete',
            _deleteCurrent,
          ),
          _action(
            theme,
            Icons.photo_camera_rounded,
            'Camera',
            () => _addPages(ScanSource.camera),
          ),
          _action(
            theme,
            Icons.photo_library_rounded,
            'Gallery',
            () => _addPages(ScanSource.gallery),
          ),
        ],
      ),
    );
  }

  Widget _action(
    ThemeData theme,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: _isBusy ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
