import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/document_service.dart';
import '../services/pdf_tools.dart';
import '../services/recent_documents.dart';
import '../services/sheet/formula.dart';
import '../services/sheet/sheet_styles.dart';
import '../services/sheet/workbook.dart';
import '../services/sheet/xlsx_file.dart';
import '../widgets/document_actions.dart';
import '../widgets/sheet_grid.dart';

/// One step that can be taken back: a sheet as it was, and where the
/// selection was.
class _Step {
  final int sheet;
  final SheetSnapshot snapshot;
  final CellRange selection;
  final int row;
  final int col;
  const _Step(this.sheet, this.snapshot, this.selection, this.row, this.col);
}

enum _Menu { saveCopy, share }

enum _Structure {
  rowAbove('Insert row above', Icons.keyboard_arrow_up_rounded),
  rowBelow('Insert row below', Icons.keyboard_arrow_down_rounded),
  colLeft('Insert column left', Icons.keyboard_arrow_left_rounded),
  colRight('Insert column right', Icons.keyboard_arrow_right_rounded),
  deleteRows('Delete row', Icons.table_rows_outlined),
  deleteCols('Delete column', Icons.view_column_outlined);

  final String label;
  final IconData icon;
  const _Structure(this.label, this.icon);
}

/// A spreadsheet to read and edit: cells, formulas, formats, rows and
/// columns, saved back as `.xlsx`.
class SpreadsheetScreen extends StatefulWidget {
  final Workbook book;

  /// The file the workbook came from, or null for a new one. With a write
  /// grant and [savesInPlace], Save goes back to it.
  final DocumentRef? document;
  final String name;

  /// False for a workbook that was not an `.xlsx` to begin with (a CSV, a
  /// new one): saving it means choosing where the workbook goes.
  final bool savesInPlace;

  const SpreadsheetScreen({
    super.key,
    required this.book,
    required this.name,
    this.document,
    this.savesInPlace = false,
  });

  static Future<void> open(
    BuildContext context, {
    required Workbook book,
    required String name,
    DocumentRef? document,
    bool savesInPlace = false,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SpreadsheetScreen(
          book: book,
          name: name,
          document: document,
          savesInPlace: savesInPlace,
        ),
      ),
    );
  }

  @override
  State<SpreadsheetScreen> createState() => _SpreadsheetScreenState();
}

class _SpreadsheetScreenState extends State<SpreadsheetScreen> {
  static const int _maxSteps = 60;

  static const List<Color> _palette = [
    Color(0xFF000000), Color(0xFF424242), Color(0xFF9E9E9E), Color(0xFFFFFFFF), //
    Color(0xFFD32F2F), Color(0xFFF57C00), Color(0xFFFBC02D), Color(0xFF388E3C),
    Color(0xFF00796B), Color(0xFF1976D2), Color(0xFF303F9F), Color(0xFF7B1FA2),
    Color(0xFFFFCDD2), Color(0xFFFFE0B2), Color(0xFFFFF9C4), Color(0xFFC8E6C9),
    Color(0xFFB2DFDB), Color(0xFFBBDEFB), Color(0xFFC5CAE9), Color(0xFFE1BEE7),
  ];

  static const Map<String, String> _formats = {
    'General': 'General',
    'Number  1234.50': '0.00',
    'Thousands  1,234.50': '#,##0.00',
    'Whole  1235': '0',
    'Percent  12%': '0%',
    'Percent  12.50%': '0.00%',
    'Date  31/12/2026': 'dd/mm/yyyy',
    'Date  31 Dec 2026': 'd mmm yyyy',
    'Time  14:30': 'hh:mm',
    'Text': '@',
  };

  final GlobalKey<SheetGridState> _grid = GlobalKey();
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  late DocumentRef? _doc = widget.document;
  late String _name = widget.name;
  late bool _savesInPlace =
      widget.savesInPlace && (widget.document?.canWrite ?? false);

  int _sheet = 0;
  CellRange _selection = const CellRange(0, 0, 0, 0);
  int _row = 0;
  int _col = 0;
  int _revision = 0;
  bool _dirty = false;
  bool _busy = false;
  String _lastFind = '';

  final List<_Step> _undo = [];
  final List<_Step> _redo = [];

  Workbook get _book => widget.book;
  Sheet get _current => _book.sheets[_sheet];

  @override
  void initState() {
    super.initState();
    _input.text = _book.inputOf(0, 0, 0);
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // --- Selection and typing ---------------------------------------------------

  bool get _hasPendingInput => _input.text != _book.inputOf(_sheet, _row, _col);

  void _showSelected() {
    _input.text = _book.inputOf(_sheet, _row, _col);
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  void _select(CellRange range, int row, int col) {
    // Moving away from a cell keeps what was typed into it.
    if (_hasPendingInput) _commit(advance: false);
    setState(() {
      _selection = range;
      _row = row;
      _col = col;
    });
    _showSelected();
  }

  void _remember() {
    _undo.add(_Step(_sheet, _current.snapshot(), _selection, _row, _col));
    if (_undo.length > _maxSteps) _undo.removeAt(0);
    _redo.clear();
  }

  void _changed() {
    _book.edited = true;
    _book.invalidate();
    setState(() {
      _dirty = true;
      _revision++;
    });
  }

  void _commit({bool advance = true}) {
    if (_hasPendingInput) {
      _remember();
      _book.setInput(_sheet, _row, _col, _input.text);
      _changed();
    }
    if (advance) {
      final CellRange? merge = _current.mergeAt(_row, _col);
      final int next = (merge?.bottom ?? _row) + 1;
      setState(() {
        _row = next;
        _selection = CellRange(next, _col, next, _col);
      });
      _grid.currentState?.ensureVisible(next, _col);
    }
    _showSelected();
  }

  void _cancelInput() {
    _showSelected();
    _inputFocus.unfocus();
  }

  void _restore(List<_Step> from, List<_Step> to) {
    if (from.isEmpty) return;
    final _Step step = from.removeLast();
    final Sheet sheet = _book.sheets[step.sheet];
    to.add(_Step(step.sheet, sheet.snapshot(), _selection, _row, _col));
    sheet.restore(step.snapshot);
    _book.invalidate();
    setState(() {
      _sheet = step.sheet;
      _selection = step.selection;
      _row = step.row;
      _col = step.col;
      _dirty = true;
      _revision++;
    });
    _showSelected();
  }

  // --- Formats and structure --------------------------------------------------

  CellStyle get _style =>
      _book.styles.at(_current.cell(_row, _col)?.style ?? 0);

  void _format(StyleChange change) {
    if (_hasPendingInput) _commit(advance: false);
    _remember();
    _book.applyStyle(_sheet, _selection, change);
    _changed();
    _showSelected();
  }

  Future<void> _pickColor({required bool fill}) async {
    final ThemeData theme = Theme.of(context);
    final int? picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fill ? 'Fill colour' : 'Text colour',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final Color color in _palette)
                    Semantics(
                      button: true,
                      label: 'Colour',
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () =>
                            Navigator.of(sheetContext).pop(color.toARGB32()),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(sheetContext).pop(0),
                icon: const Icon(Icons.format_color_reset_outlined),
                label: Text(fill ? 'No fill' : 'Automatic'),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _format(fill ? StyleChange(fill: picked) : StyleChange(color: picked));
  }

  void _restructure(_Structure action) {
    if (_hasPendingInput) _commit(advance: false);
    final int rows = _selection.bottom - _selection.top + 1;
    final int cols = _selection.right - _selection.left + 1;
    if (action == _Structure.deleteRows && rows >= _current.usedRows && _selection.top == 0) {
      // Nothing would be left to anchor the sheet on.
      if (_current.usedRows > 0) {
        _message('That would delete every row.');
        return;
      }
    }
    _remember();
    switch (action) {
      case _Structure.rowAbove:
        _book.shift(_sheet, _selection.top, 1, columns: false);
      case _Structure.rowBelow:
        _book.shift(_sheet, _selection.bottom + 1, 1, columns: false);
      case _Structure.colLeft:
        _book.shift(_sheet, _selection.left, 1, columns: true);
      case _Structure.colRight:
        _book.shift(_sheet, _selection.right + 1, 1, columns: true);
      case _Structure.deleteRows:
        _book.shift(_sheet, _selection.top, -rows, columns: false);
      case _Structure.deleteCols:
        _book.shift(_sheet, _selection.left, -cols, columns: true);
    }
    _changed();
    // The selection stays where it was on screen; what is under it moved.
    setState(() {
      _selection = CellRange(_row, _col, _row, _col);
    });
    _showSelected();
  }

  Future<void> _pickFromList(ListValidation validation) async {
    final List<String> options = _book.optionsFor(_sheet, validation);
    if (options.isEmpty) {
      _message('This list has no choices.');
      return;
    }
    final String current = _book.display(_sheet, _row, _col);
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final String option in options)
              ListTile(
                title: Text(option),
                trailing: option == current
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(option),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    _input.text = picked;
    _commit(advance: false);
  }

  // --- Find -------------------------------------------------------------------

  Future<void> _find() async {
    final TextEditingController controller = TextEditingController(
      text: _lastFind,
    );
    final String? query = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Find in sheet'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Text or number',
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Find next'),
          ),
        ],
      ),
    );
    if (query == null || query.trim().isEmpty || !mounted) return;
    _lastFind = query;
    _findNext(query);
  }

  /// Selects the next cell after the current one whose text holds [query],
  /// reading across then down, and wrapping round.
  void _findNext(String query) {
    final String wanted = query.trim().toLowerCase();
    final List<int> rows = _current.rows.keys.toList()..sort();
    (int, int)? first;
    (int, int)? next;
    for (final int row in rows) {
      final List<int> cols = _current.rows[row]!.keys.toList()..sort();
      for (final int col in cols) {
        if (!_book.display(_sheet, row, col).toLowerCase().contains(wanted)) {
          continue;
        }
        first ??= (row, col);
        final bool after = row > _row || (row == _row && col > _col);
        if (after && next == null) next = (row, col);
      }
      if (next != null) break;
    }
    final (int, int)? hit = next ?? first;
    if (hit == null) {
      _message('"$query" is not on this sheet.');
      return;
    }
    _select(CellRange(hit.$1, hit.$2, hit.$1, hit.$2), hit.$1, hit.$2);
    _grid.currentState?.ensureVisible(hit.$1, hit.$2);
    _message(
      'Found in ${cellName(hit.$1, hit.$2)}',
    );
  }

  // --- Saving -----------------------------------------------------------------

  static Future<Uint8List> _encode(Workbook book) async {
    try {
      // Off the UI thread where the workbook can be handed across.
      return await Isolate.run(() => XlsxFile.write(book));
    } on ArgumentError {
      return XlsxFile.write(book);
    }
  }

  String get _xlsxName {
    final String base = PdfTools.safeFileName(PdfTools.baseNameOf(_name));
    return '$base.xlsx';
  }

  Future<File> _writeTemp() async {
    final Uint8List bytes = await _encode(_book);
    final Directory outbox = await PdfTools.newOutbox();
    final File out = File('${outbox.path}/$_xlsxName');
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  /// Saves to the file it came from, or asks where to. Returns whether
  /// the workbook is now saved.
  Future<bool> _save({bool copy = false}) async {
    if (_hasPendingInput) _commit(advance: false);
    setState(() => _busy = true);
    try {
      final File temp = await _writeTemp();
      final DocumentRef? doc = _doc;
      if (!copy && doc != null && _savesInPlace) {
        await DocumentService.write(doc, temp);
        if (!mounted) return true;
        setState(() => _dirty = false);
        _message('Saved to ${doc.name}');
        return true;
      }
      if (!DocumentService.supportsSaf) {
        _message('Saving is not supported on this platform.');
        return false;
      }
      final DocumentRef? saved = await DocumentService.saveCopy(
        _xlsxName,
        temp,
        mimeType: XlsxFile.mimeType,
      );
      if (saved == null || !mounted) return false;
      await RecentDocuments.add(saved);
      if (!mounted) return true;
      if (copy && _savesInPlace) {
        _message('Saved a copy as ${saved.name}');
        return true;
      }
      // The first real home this workbook has: later saves go to it.
      setState(() {
        _doc = saved;
        _name = saved.name;
        _savesInPlace = saved.canWrite;
        _dirty = false;
      });
      _message('Saved as ${saved.name}');
      return true;
    } on PlatformException catch (e) {
      _message(e.message ?? 'Could not save.');
      return false;
    } catch (e) {
      _message('Could not save: $e');
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    if (_hasPendingInput) _commit(advance: false);
    setState(() => _busy = true);
    try {
      final File temp = await _writeTemp();
      if (!mounted) return;
      await DocumentActions.share(context, temp, _xlsxName);
    } catch (e) {
      _message('Could not share: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onBack() async {
    if (_hasPendingInput) _commit(advance: false);
    if (!_dirty) {
      Navigator.of(context).pop();
      return;
    }
    final String? choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave without saving?'),
        content: Text('Your changes to $_name have not been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('keep'),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('discard'),
            child: const Text('Discard'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'discard' || (choice == 'save' && await _save())) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  // --- Build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        appBar: AppBar(
          centerTitle: false,
          titleSpacing: 0,
          title: Text(
            _name,
            style: const TextStyle(fontSize: 18),
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.undo_rounded),
              tooltip: 'Undo',
              onPressed: _busy || _undo.isEmpty
                  ? null
                  : () => _restore(_undo, _redo),
            ),
            IconButton(
              icon: const Icon(Icons.redo_rounded),
              tooltip: 'Redo',
              onPressed: _busy || _redo.isEmpty
                  ? null
                  : () => _restore(_redo, _undo),
            ),
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: 'Find',
              onPressed: _busy ? null : _find,
            ),
            IconButton(
              icon: const Icon(Icons.save_rounded),
              tooltip: 'Save',
              onPressed: _busy || (!_dirty && _savesInPlace) ? null : _save,
            ),
            PopupMenuButton<_Menu>(
              tooltip: 'More',
              enabled: !_busy,
              onSelected: (choice) => switch (choice) {
                _Menu.saveCopy => _save(copy: true),
                _Menu.share => _share(),
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: _Menu.saveCopy, child: Text('Save a copy')),
                PopupMenuItem(value: _Menu.share, child: Text('Share')),
              ],
            ),
          ],
        ),
        body: Stack(
          children: [
            Column(
              children: [
                _buildFormulaBar(theme),
                const Divider(height: 1),
                Expanded(
                  child: SheetGrid(
                    key: _grid,
                    book: _book,
                    sheetIndex: _sheet,
                    selection: _selection,
                    anchorRow: _row,
                    anchorCol: _col,
                    revision: _revision,
                    onSelect: _select,
                    onEdit: () => _inputFocus.requestFocus(),
                  ),
                ),
                if (_book.sheets.length > 1) _buildTabs(theme),
                const Divider(height: 1),
                _buildFormatBar(theme),
              ],
            ),
            if (_busy)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black38,
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormulaBar(ThemeData theme) {
    final ListValidation? validation = _current.validationAt(_row, _col);
    final bool pending = _hasPendingInput;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 52),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _selection.isSingle ? cellName(_row, _col) : _selection.name,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _inputFocus,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: 'Value or =formula',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _commit(),
            ),
          ),
          if (pending) ...[
            IconButton(
              icon: const Icon(Icons.close_rounded),
              tooltip: 'Cancel',
              onPressed: _cancelInput,
            ),
            IconButton(
              icon: const Icon(Icons.check_rounded),
              tooltip: 'Enter',
              color: theme.colorScheme.primary,
              onPressed: () => _commit(advance: false),
            ),
          ] else if (validation != null)
            IconButton(
              icon: const Icon(Icons.arrow_drop_down_circle_outlined),
              tooltip: 'Choose from list',
              onPressed: () => _pickFromList(validation),
            ),
        ],
      ),
    );
  }

  Widget _buildTabs(ThemeData theme) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: _book.sheets.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) => ChoiceChip(
          label: Text(_book.sheets[index].name),
          selected: index == _sheet,
          showCheckmark: false,
          onSelected: (_) {
            if (index == _sheet) return;
            if (_hasPendingInput) _commit(advance: false);
            setState(() {
              _sheet = index;
              _selection = const CellRange(0, 0, 0, 0);
              _row = 0;
              _col = 0;
            });
            _showSelected();
          },
        ),
      ),
    );
  }

  Widget _buildFormatBar(ThemeData theme) {
    final CellStyle style = _style;
    Widget toggle(IconData icon, String tip, bool on, VoidCallback onPressed) =>
        IconButton(
          icon: Icon(icon),
          tooltip: tip,
          isSelected: on,
          style: IconButton.styleFrom(
            backgroundColor: on ? theme.colorScheme.secondaryContainer : null,
          ),
          onPressed: _busy ? null : onPressed,
        );
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              toggle(
                Icons.format_bold_rounded,
                'Bold',
                style.bold,
                () => _format(StyleChange(bold: !style.bold)),
              ),
              toggle(
                Icons.format_italic_rounded,
                'Italic',
                style.italic,
                () => _format(StyleChange(italic: !style.italic)),
              ),
              toggle(
                Icons.format_underlined_rounded,
                'Underline',
                style.underline,
                () => _format(StyleChange(underline: !style.underline)),
              ),
              IconButton(
                icon: Icon(
                  Icons.format_color_text_rounded,
                  color: style.color == null ? null : Color(style.color!),
                ),
                tooltip: 'Text colour',
                onPressed: _busy ? null : () => _pickColor(fill: false),
              ),
              IconButton(
                icon: Icon(
                  Icons.format_color_fill_rounded,
                  color: style.fill == null ? null : Color(style.fill!),
                ),
                tooltip: 'Fill colour',
                onPressed: _busy ? null : () => _pickColor(fill: true),
              ),
              const SizedBox(height: 28, child: VerticalDivider(width: 12)),
              toggle(
                Icons.format_align_left_rounded,
                'Align left',
                style.hAlign == HAlign.left,
                () => _format(
                  StyleChange(
                    hAlign: style.hAlign == HAlign.left
                        ? HAlign.general
                        : HAlign.left,
                  ),
                ),
              ),
              toggle(
                Icons.format_align_center_rounded,
                'Align centre',
                style.hAlign == HAlign.center,
                () => _format(
                  StyleChange(
                    hAlign: style.hAlign == HAlign.center
                        ? HAlign.general
                        : HAlign.center,
                  ),
                ),
              ),
              toggle(
                Icons.format_align_right_rounded,
                'Align right',
                style.hAlign == HAlign.right,
                () => _format(
                  StyleChange(
                    hAlign: style.hAlign == HAlign.right
                        ? HAlign.general
                        : HAlign.right,
                  ),
                ),
              ),
              const SizedBox(height: 28, child: VerticalDivider(width: 12)),
              PopupMenuButton<String>(
                tooltip: 'Number format',
                enabled: !_busy,
                icon: const Icon(Icons.pin_outlined),
                onSelected: (code) => _format(StyleChange(numFmt: code)),
                itemBuilder: (_) => [
                  for (final MapEntry<String, String> f in _formats.entries)
                    PopupMenuItem(value: f.value, child: Text(f.key)),
                ],
              ),
              PopupMenuButton<_Structure>(
                tooltip: 'Rows and columns',
                enabled: !_busy,
                icon: const Icon(Icons.table_chart_outlined),
                onSelected: _restructure,
                itemBuilder: (_) => [
                  for (final _Structure action in _Structure.values)
                    PopupMenuItem(
                      value: action,
                      child: Row(
                        children: [
                          Icon(action.icon, size: 20),
                          const SizedBox(width: 12),
                          Text(action.label),
                        ],
                      ),
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
