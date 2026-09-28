import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageDescriptor, ImmutableBuffer;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/document_service.dart';
import '../services/pdf_service.dart';
import '../services/pdf_tools.dart';
import '../services/scan_service.dart';
import '../widgets/export_sheet.dart';
import 'scan_screen.dart';

/// What the screen was opened to do. Everything is available either way;
/// the intent only decides what the screen leads with.
enum ManagePagesIntent { manage, delete, extract, insert }

/// One page on the board: where it comes from, plus the display size used to
/// shape its tile.
class _Slot {
  final int id;
  final PageSpec spec;
  final Size size;

  const _Slot(this.id, this.spec, this.size);

  _Slot withSpec(PageSpec spec) => _Slot(id, spec, size);

  /// Size as it will display, after the staged turns.
  Size get displaySize => spec.quarterTurns.isOdd ? size.flipped : size;
}

/// Rearranges a document's pages: reorder, rotate, delete, insert, extract
/// and re-lay onto a different paper size.
///
/// Nothing is written while the user works. Changes are staged on the board
/// and handed back as a list of [PageSpec]s on Done, so leaving without Done
/// costs nothing and every staged step is free to take back.
class ManagePagesScreen extends StatefulWidget {
  final File file;
  final String documentName;
  final ManagePagesIntent intent;

  const ManagePagesScreen({
    super.key,
    required this.file,
    required this.documentName,
    this.intent = ManagePagesIntent.manage,
  });

  static Future<List<PageSpec>?> open(
    BuildContext context, {
    required File file,
    required String documentName,
    ManagePagesIntent intent = ManagePagesIntent.manage,
  }) {
    return Navigator.of(context).push<List<PageSpec>>(
      MaterialPageRoute(
        builder: (_) => ManagePagesScreen(
          file: file,
          documentName: documentName,
          intent: intent,
        ),
      ),
    );
  }

  @override
  State<ManagePagesScreen> createState() => _ManagePagesScreenState();
}

class _ManagePagesScreenState extends State<ManagePagesScreen> {
  static const String _hintKey = 'manage_pages_hint_dismissed';

  List<_Slot> _slots = [];
  int _originalCount = 0;
  final Set<int> _selected = {};
  bool _loading = true;
  bool _busy = false;
  bool _showHint = false;
  int _nextId = 0;

  /// Rendered thumbnails by "path#page". A present-but-null entry means the
  /// page could not be rendered and is not retried.
  final Map<String, Uint8List?> _thumbs = {};
  final Set<String> _inFlight = {};

  final ScrollController _scroll = ScrollController();
  Timer? _autoScroll;
  final GlobalKey _gridKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _autoScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final PdfFacts facts = await PdfTools.readFacts(widget.file);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _originalCount = facts.pageCount;
        _slots = [
          for (int i = 0; i < facts.pageCount; i++)
            _Slot(_nextId++, PageSpec(OriginalPageSource(i)), facts.pageSizes[i]),
        ];
        _showHint = !(prefs.getBool(_hintKey) ?? false);
        _loading = false;
      });
      if (widget.intent == ManagePagesIntent.insert) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _insert());
      }
    } catch (e) {
      if (!mounted) return;
      _say('Could not read the pages: $e');
      Navigator.of(context).pop();
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Whether the board still matches the document exactly.
  bool get _isUnchanged {
    if (_slots.length != _originalCount) return false;
    for (int i = 0; i < _slots.length; i++) {
      final PageSpec spec = _slots[i].spec;
      final PageSource source = spec.source;
      if (source is! OriginalPageSource ||
          source.index != i ||
          spec.quarterTurns % 4 != 0 ||
          spec.setup != null) {
        return false;
      }
    }
    return true;
  }

  List<_Slot> get _selectedSlots =>
      _slots.where((s) => _selected.contains(s.id)).toList(growable: false);

  bool _requireSelection() {
    if (_selected.isNotEmpty) return true;
    _say('Select pages first.');
    return false;
  }

  Future<bool> _confirmDiscard() async {
    if (_isUnchanged) return true;
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard page changes?'),
        content: const Text('Nothing has been applied to the document yet.'),
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
    return discard == true;
  }

  void _done() {
    Navigator.of(context).pop([for (final _Slot slot in _slots) slot.spec]);
  }

  // --- Staged operations -----------------------------------------------------

  void _rotateSelected() {
    if (!_requireSelection()) return;
    setState(() {
      _slots = [
        for (final _Slot slot in _slots)
          _selected.contains(slot.id)
              ? slot.withSpec(
                  slot.spec.copyWith(quarterTurns: slot.spec.quarterTurns + 1),
                )
              : slot,
      ];
    });
  }

  void _deleteSelected({bool thenApply = false}) {
    if (!_requireSelection()) return;
    if (_selected.length >= _slots.length) {
      _say('A document must keep at least one page.');
      return;
    }
    final int removed = _selected.length;
    setState(() {
      _slots = _slots.where((s) => !_selected.contains(s.id)).toList();
      _selected.clear();
    });
    if (thenApply) {
      _done();
      return;
    }
    _say(
      '${removed == 1 ? '1 page' : '$removed pages'} removed. '
      'Tap Done to apply.',
    );
  }

  Future<void> _extractSelected() async {
    if (!_requireSelection()) return;
    final List<_Slot> chosen = _selectedSlots;
    final List<int> numbers = [
      for (final _Slot slot in chosen) _slots.indexOf(slot) + 1,
    ];
    setState(() => _busy = true);
    try {
      final File out = await PdfTools.extract(
        widget.file,
        [for (final _Slot slot in chosen) slot.spec],
        '${PdfTools.baseNameOf(widget.documentName)} '
        '(${_describeNumbers(numbers)})',
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await ExportSheet.show(
        context,
        files: [out],
        mimeType: 'application/pdf',
        title: 'Extracted ${chosen.length == 1 ? '1 page' : '${chosen.length} pages'}',
      );
    } catch (e) {
      _say('Could not extract: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "p1-3, 5" for page numbers already in order.
  static String _describeNumbers(List<int> numbers) {
    final List<String> parts = [];
    int start = numbers.first;
    int previous = start;
    for (final int n in numbers.skip(1).followedBy([-1])) {
      if (n == previous + 1) {
        previous = n;
        continue;
      }
      parts.add(start == previous ? '$start' : '$start-$previous');
      start = n;
      previous = n;
    }
    return 'p${parts.join(',')}';
  }

  Future<void> _insert() async {
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                _selected.isEmpty
                    ? 'Insert at the end'
                    : 'Insert after the selected pages',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final (String value, IconData icon, String label) in const [
              ('blank', Icons.note_add_outlined, 'Blank page'),
              ('photos', Icons.photo_library_outlined, 'Photos from gallery'),
              ('camera', Icons.document_scanner_outlined, 'Scan with camera'),
              ('pdf', Icons.picture_as_pdf_outlined, 'Pages from another PDF'),
            ])
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: Icon(icon),
                title: Text(label),
                onTap: () => Navigator.of(sheetContext).pop(value),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    // After the last selected page, or at the end.
    int at = _slots.length;
    if (_selected.isNotEmpty) {
      at = _slots.lastIndexWhere((s) => _selected.contains(s.id)) + 1;
    }
    final Size neighbour = at > 0
        ? _slots[at - 1].displaySize
        : (_slots.isNotEmpty ? _slots.first.displaySize : PaperSize.a4.portrait);

    List<_Slot> added = [];
    try {
      switch (choice) {
        case 'blank':
          added = [
            _Slot(_nextId++, PageSpec(BlankPageSource(neighbour)), neighbour),
          ];
        case 'photos':
          final List<XFile> picked = await ImagePicker().pickMultiImage();
          if (picked.isNotEmpty) setState(() => _busy = true);
          try {
            added = await _imageSlots([
              for (final XFile file in picked)
                await PdfService.normalizePhoto(await file.readAsBytes()),
            ]);
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        case 'camera':
          if (!mounted) return;
          final List<Uint8List>? pages = await ScanScreen.capturePages(
            context,
            source: ScanSource.camera,
          );
          added = await _imageSlots(pages ?? const []);
        case 'pdf':
          added = await _foreignSlots();
      }
    } catch (e) {
      _say('Could not add pages: $e');
      return;
    }
    if (added.isEmpty || !mounted) return;
    setState(() {
      _slots.insertAll(at, added);
      _selected
        ..clear()
        ..addAll(added.map((s) => s.id));
    });
    _say(
      '${added.length == 1 ? '1 page' : '${added.length} pages'} added. '
      'Tap Done to apply.',
    );
  }

  Future<List<_Slot>> _imageSlots(List<Uint8List> images) async {
    final List<_Slot> slots = [];
    for (final Uint8List bytes in images) {
      final ImmutableBuffer buffer = await ImmutableBuffer.fromUint8List(bytes);
      final ImageDescriptor descriptor = await ImageDescriptor.encoded(buffer);
      final Size size = Size(
        descriptor.width.toDouble(),
        descriptor.height.toDouble(),
      );
      descriptor.dispose();
      buffer.dispose();
      slots.add(_Slot(_nextId++, PageSpec(ImagePageSource(bytes)), size));
    }
    return slots;
  }

  Future<List<_Slot>> _foreignSlots() async {
    final List<PickedDocument> picked = await DocumentService.pickMany();
    final List<_Slot> slots = [];
    for (final PickedDocument document in picked) {
      final PdfFacts facts = await PdfTools.readFacts(File(document.path));
      for (int i = 0; i < facts.pageCount; i++) {
        slots.add(
          _Slot(
            _nextId++,
            PageSpec(ForeignPageSource(document.path, i)),
            facts.pageSizes[i],
          ),
        );
      }
    }
    return slots;
  }

  Future<void> _setup() async {
    final _SetupChoice? choice = await showModalBottomSheet<_SetupChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SetupSheet(selectedCount: _selected.length),
    );
    if (choice == null || !mounted) return;
    setState(() {
      _slots = [
        for (final _Slot slot in _slots)
          if (choice.allPages || _selected.contains(slot.id))
            slot.withSpec(
              choice.setup == null
                  ? slot.spec.copyWith(clearSetup: true)
                  : slot.spec.copyWith(setup: choice.setup),
            )
          else
            slot,
      ];
    });
  }

  void _move(int draggedId, int targetIndex) {
    final int from = _slots.indexWhere((s) => s.id == draggedId);
    if (from < 0 || from == targetIndex) return;
    setState(() {
      final _Slot slot = _slots.removeAt(from);
      _slots.insert(targetIndex.clamp(0, _slots.length), slot);
    });
  }

  /// Scrolls while a dragged page is held near the top or bottom edge, so a
  /// page can be carried past the part of the grid on screen.
  void _onDragUpdate(Offset globalPosition) {
    final RenderBox? box =
        _gridKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final double y = box.globalToLocal(globalPosition).dy;
    const double edge = 72;
    double speed = 0;
    if (y < edge) speed = -(edge - y) / 3;
    if (y > box.size.height - edge) speed = (y - (box.size.height - edge)) / 3;
    _autoScroll?.cancel();
    if (speed == 0) return;
    _autoScroll = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!_scroll.hasClients) return;
      final double target = (_scroll.offset + speed).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      _scroll.jumpTo(target);
    });
  }

  void _stopAutoScroll() {
    _autoScroll?.cancel();
    _autoScroll = null;
  }

  // --- Thumbnails ------------------------------------------------------------

  (String, int)? _renderTarget(PageSource source) => switch (source) {
    OriginalPageSource(:final int index) => (widget.file.path, index),
    ForeignPageSource(:final String path, :final int index) => (path, index),
    _ => null,
  };

  Future<void> _loadThumb(String path, int index) async {
    final String key = '$path#$index';
    if (_thumbs.containsKey(key) || _inFlight.contains(key)) return;
    _inFlight.add(key);
    final Uint8List? bytes = await DocumentService.renderPage(
      path,
      index,
      width: 360,
    );
    _inFlight.remove(key);
    if (mounted) setState(() => _thumbs[key] = bytes);
  }

  Widget _pageImage(PageSpec spec, {bool large = false}) {
    final PageSource source = spec.source;
    if (source is ImagePageSource) {
      return Image.memory(source.bytes, fit: BoxFit.contain);
    }
    if (source is BlankPageSource) return const ColoredBox(color: Colors.white);
    final (String path, int index) = _renderTarget(source)!;
    if (large) {
      return FutureBuilder<Uint8List?>(
        future: DocumentService.renderPage(path, index, width: 1400),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final Uint8List? data = snapshot.data;
          return data == null
              ? const Center(child: Icon(Icons.description_outlined, size: 48))
              : Image.memory(data, fit: BoxFit.contain);
        },
      );
    }
    final String key = '$path#$index';
    if (!_thumbs.containsKey(key)) _loadThumb(path, index);
    final Uint8List? bytes = _thumbs[key];
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
    }
    return Center(
      child: _thumbs.containsKey(key)
          ? const Icon(Icons.description_outlined, color: Colors.black26)
          : const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
    );
  }

  Future<void> _preview(_Slot slot) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: RotatedBox(
                    quarterTurns: slot.spec.quarterTurns % 4,
                    child: AspectRatio(
                      aspectRatio: slot.size.width / slot.size.height,
                      child: ColoredBox(
                        color: Colors.white,
                        child: _pageImage(slot.spec, large: true),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                tooltip: 'Close',
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool focused =
        widget.intent == ManagePagesIntent.delete ||
        widget.intent == ManagePagesIntent.extract;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: false,
          title: Text(switch (widget.intent) {
            ManagePagesIntent.delete => 'Delete pages',
            ManagePagesIntent.extract => 'Extract pages',
            _ => 'Manage pages',
          }),
          actions: [
            if (widget.intent != ManagePagesIntent.extract)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton(
                  onPressed: _loading || _busy || _isUnchanged ? null : _done,
                  child: const Text('Done'),
                ),
              ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Stack(
                children: [
                  Column(
                    children: [
                      if (_showHint && !focused) _buildHint(theme),
                      if (focused) _buildIntentBanner(theme),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
                        child: Row(
                          children: [
                            Text(
                              '${_selected.length} Selected',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Text('All', style: theme.textTheme.titleMedium),
                            Checkbox(
                              value: _selected.isEmpty
                                  ? false
                                  : _selected.length == _slots.length
                                  ? true
                                  : null,
                              tristate: true,
                              onChanged: (_) => setState(() {
                                if (_selected.length == _slots.length) {
                                  _selected.clear();
                                } else {
                                  _selected.addAll(_slots.map((s) => s.id));
                                }
                              }),
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: _buildGrid(theme)),
                    ],
                  ),
                  if (_busy)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black45,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                ],
              ),
        bottomNavigationBar: _loading
            ? null
            : focused
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    style: widget.intent == ManagePagesIntent.delete
                        ? FilledButton.styleFrom(
                            backgroundColor: colors.error,
                            foregroundColor: colors.onError,
                          )
                        : null,
                    onPressed: _selected.isEmpty || _busy
                        ? null
                        : widget.intent == ManagePagesIntent.delete
                        ? () => _deleteSelected(thenApply: true)
                        : _extractSelected,
                    icon: Icon(
                      widget.intent == ManagePagesIntent.delete
                          ? Icons.delete_outline_rounded
                          : Icons.file_upload_outlined,
                    ),
                    label: Text(
                      '${widget.intent == ManagePagesIntent.delete ? 'Delete' : 'Extract'} '
                      '${_selected.length == 1 ? '1 page' : '${_selected.length} pages'}',
                    ),
                  ),
                ),
              )
            : _buildActions(theme),
      ),
    );
  }

  Widget _buildHint(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Long press to sort manually',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.cancel_rounded),
            onPressed: () async {
              setState(() => _showHint = false);
              final SharedPreferences prefs =
                  await SharedPreferences.getInstance();
              await prefs.setBool(_hintKey, true);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildIntentBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Text(
        widget.intent == ManagePagesIntent.delete
            ? 'Select the pages to delete.'
            : 'Select the pages to copy into a new PDF.',
        style: theme.textTheme.bodyLarge,
      ),
    );
  }

  Widget _buildGrid(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final int columns = constraints.maxWidth > 900
            ? 5
            : constraints.maxWidth > 600
            ? 3
            : 2;
        const double spacing = 16;
        const double aspect = 0.72;
        final double tileWidth =
            (constraints.maxWidth - 32 - spacing * (columns - 1)) / columns;
        return GridView.builder(
          key: _gridKey,
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: spacing,
            mainAxisSpacing: spacing,
            childAspectRatio: aspect,
          ),
          itemCount: _slots.length,
          itemBuilder: (context, index) {
            final _Slot slot = _slots[index];
            final Widget tile = _buildTile(theme, slot, index);
            return DragTarget<int>(
              onWillAcceptWithDetails: (details) {
                if (details.data != slot.id) _move(details.data, index);
                return true;
              },
              builder: (context, _, _) => LongPressDraggable<int>(
                data: slot.id,
                onDragUpdate: (details) =>
                    _onDragUpdate(details.globalPosition),
                onDragEnd: (_) => _stopAutoScroll(),
                onDraggableCanceled: (_, _) => _stopAutoScroll(),
                feedback: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: tileWidth,
                    height: tileWidth / aspect,
                    child: tile,
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.25, child: tile),
                child: tile,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTile(ThemeData theme, _Slot slot, int index) {
    final ColorScheme colors = theme.colorScheme;
    final bool selected = _selected.contains(slot.id);
    final PageSetup? setup = slot.spec.setup;
    return GestureDetector(
      onTap: () => setState(() {
        if (!_selected.remove(slot.id)) _selected.add(slot.id);
      }),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? colors.primary : Colors.transparent,
            width: 3,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Center(
                  child: RotatedBox(
                    quarterTurns: slot.spec.quarterTurns % 4,
                    child: AspectRatio(
                      aspectRatio: slot.size.width / slot.size.height,
                      child: ColoredBox(
                        color: Colors.white,
                        child: _pageImage(slot.spec),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: selected ? colors.primary : Colors.black26,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white70, width: 1.5),
                ),
                child: selected
                    ? Icon(Icons.check_rounded, size: 18, color: colors.onPrimary)
                    : null,
              ),
            ),
            if (setup != null)
              Positioned(
                top: 8,
                left: 8,
                child: _badge(colors, setup.paper.label, colors.tertiary),
              ),
            Positioned(
              left: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: selected ? colors.primary : Colors.grey.shade600,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(10),
                  ),
                ),
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: selected ? colors.onPrimary : Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            Positioned(
              right: 4,
              bottom: 4,
              child: IconButton(
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(backgroundColor: Colors.black26),
                icon: const Icon(
                  Icons.open_in_full_rounded,
                  size: 18,
                  color: Colors.white,
                ),
                tooltip: 'Preview',
                onPressed: () => _preview(slot),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(ColorScheme colors, String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: colors.onTertiary,
        fontSize: 11,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _buildActions(ThemeData theme) {
    Widget action(IconData icon, String label, VoidCallback onTap) {
      return Expanded(
        child: InkWell(
          onTap: _busy ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon),
                const SizedBox(height: 4),
                Text(label, style: theme.textTheme.labelLarge),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            action(Icons.note_add_outlined, 'Insert', _insert),
            action(Icons.rotate_right_rounded, 'Rotate', _rotateSelected),
            action(Icons.file_upload_outlined, 'Extract', _extractSelected),
            action(Icons.delete_outline_rounded, 'Delete', _deleteSelected),
            action(Icons.settings_outlined, 'Setup', _setup),
          ],
        ),
      ),
    );
  }
}

// --- Page setup ---------------------------------------------------------------

class _SetupChoice {
  /// Null restores the pages' own size.
  final PageSetup? setup;
  final bool allPages;
  const _SetupChoice(this.setup, this.allPages);
}

class _SetupSheet extends StatefulWidget {
  final int selectedCount;
  const _SetupSheet({required this.selectedCount});

  @override
  State<_SetupSheet> createState() => _SetupSheetState();
}

class _SetupSheetState extends State<_SetupSheet> {
  PaperSize? _paper = PaperSize.a4;
  SetupOrientation _orientation = SetupOrientation.auto;
  double _margin = 0;
  late bool _all = widget.selectedCount == 0;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Page setup',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Fits each page onto the chosen paper. Page content is kept, '
              'scaled to fit and centred.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            label('Paper size'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Original'),
                  selected: _paper == null,
                  onSelected: (_) => setState(() => _paper = null),
                ),
                for (final PaperSize paper in PaperSize.values)
                  ChoiceChip(
                    label: Text(paper.label),
                    selected: _paper == paper,
                    onSelected: (_) => setState(() => _paper = paper),
                  ),
              ],
            ),
            if (_paper != null) ...[
              label('Orientation'),
              SegmentedButton<SetupOrientation>(
                segments: const [
                  ButtonSegment(value: SetupOrientation.auto, label: Text('Auto')),
                  ButtonSegment(
                    value: SetupOrientation.portrait,
                    label: Text('Portrait'),
                  ),
                  ButtonSegment(
                    value: SetupOrientation.landscape,
                    label: Text('Landscape'),
                  ),
                ],
                selected: {_orientation},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _orientation = s.single),
              ),
              label('Margins'),
              SegmentedButton<double>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('None')),
                  ButtonSegment(value: 18, label: Text('Small')),
                  ButtonSegment(value: 36, label: Text('Normal')),
                ],
                selected: {_margin},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _margin = s.single),
              ),
            ],
            label('Apply to'),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  enabled: widget.selectedCount > 0,
                  label: Text('Selected (${widget.selectedCount})'),
                ),
                const ButtonSegment(value: true, label: Text('All pages')),
              ],
              selected: {_all},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _all = s.single),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                _SetupChoice(
                  _paper == null
                      ? null
                      : PageSetup(
                          paper: _paper!,
                          orientation: _orientation,
                          margin: _margin,
                        ),
                  _all,
                ),
              ),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }
}
