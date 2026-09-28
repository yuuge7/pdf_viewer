import 'package:flutter/material.dart';

import '../services/pdf_tools.dart';

/// Shared frame for the option sheets: title, body, one primary action.
class _OptionSheet extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final String actionLabel;
  final VoidCallback? onAction;

  const _OptionSheet({
    required this.title,
    this.subtitle,
    required this.children,
    required this.actionLabel,
    required this.onAction,
  });

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
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              ...children,
              const SizedBox(height: 20),
              FilledButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _label(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.only(bottom: 8, top: 4),
  child: Text(
    text,
    style: Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  ),
);

Future<T?> _showSheet<T>(BuildContext context, Widget sheet) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => sheet,
  );
}

// --- Split --------------------------------------------------------------------

enum _SplitMode { eachPage, everyN, ranges }

/// Asks how to split a document of [pageCount] pages; returns the 0-based
/// page groups, one per output file.
class SplitSheet extends StatefulWidget {
  final int pageCount;
  const SplitSheet({super.key, required this.pageCount});

  static Future<List<List<int>>?> show(BuildContext context, int pageCount) =>
      _showSheet(context, SplitSheet(pageCount: pageCount));

  @override
  State<SplitSheet> createState() => _SplitSheetState();
}

class _SplitSheetState extends State<SplitSheet> {
  _SplitMode _mode = _SplitMode.eachPage;
  int _every = 2;
  final TextEditingController _ranges = TextEditingController();

  @override
  void dispose() {
    _ranges.dispose();
    super.dispose();
  }

  /// The groups for the current choice, or the reason there are none.
  (List<List<int>>?, String?) _plan() {
    switch (_mode) {
      case _SplitMode.eachPage:
        return (PdfTools.chunk(widget.pageCount, 1), null);
      case _SplitMode.everyN:
        return (PdfTools.chunk(widget.pageCount, _every), null);
      case _SplitMode.ranges:
        if (_ranges.text.trim().isEmpty) return (null, null);
        try {
          return (PdfTools.parseRanges(_ranges.text, widget.pageCount), null);
        } on FormatException catch (e) {
          return (null, e.message);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final (List<List<int>>? groups, String? error) = _plan();
    final bool pointless =
        groups != null &&
        groups.length == 1 &&
        groups.single.length == widget.pageCount;
    return _OptionSheet(
      title: 'Split PDF',
      subtitle: '${widget.pageCount} pages',
      actionLabel: groups == null
          ? 'Split'
          : 'Split into ${groups.length} file${groups.length == 1 ? '' : 's'}',
      onAction: groups == null || pointless
          ? null
          : () => Navigator.of(context).pop(groups),
      children: [
        SegmentedButton<_SplitMode>(
          segments: const [
            ButtonSegment(value: _SplitMode.eachPage, label: Text('Each page')),
            ButtonSegment(value: _SplitMode.everyN, label: Text('Every N')),
            ButtonSegment(value: _SplitMode.ranges, label: Text('Ranges')),
          ],
          selected: {_mode},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _mode = s.single),
        ),
        const SizedBox(height: 16),
        if (_mode == _SplitMode.everyN)
          Row(
            children: [
              const Expanded(child: Text('Pages per file')),
              IconButton.outlined(
                icon: const Icon(Icons.remove_rounded),
                onPressed: _every > 1 ? () => setState(() => _every--) : null,
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '$_every',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton.outlined(
                icon: const Icon(Icons.add_rounded),
                onPressed: _every < widget.pageCount - 1
                    ? () => setState(() => _every++)
                    : null,
              ),
            ],
          ),
        if (_mode == _SplitMode.ranges)
          TextField(
            controller: _ranges,
            autofocus: true,
            keyboardType: TextInputType.text,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Page ranges',
              hintText: 'e.g. 1-3, 4-6, 9',
              helperText: 'One file per range',
              errorText: error,
            ),
            onChanged: (_) => setState(() {}),
          ),
        if (_mode == _SplitMode.eachPage)
          Text('Every page becomes its own PDF.',
              style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }
}

// --- Compress -----------------------------------------------------------------

class CompressSheet extends StatefulWidget {
  /// Whether pages can be rasterised here; without it only lossless works.
  final bool canRasterize;

  const CompressSheet({super.key, required this.canRasterize});

  static Future<CompressLevel?> show(
    BuildContext context, {
    required bool canRasterize,
  }) => _showSheet(context, CompressSheet(canRasterize: canRasterize));

  @override
  State<CompressSheet> createState() => _CompressSheetState();
}

class _CompressSheetState extends State<CompressSheet> {
  late CompressLevel _level = widget.canRasterize
      ? CompressLevel.medium
      : CompressLevel.low;

  static const Map<CompressLevel, (String, String)> _labels = {
    CompressLevel.low: (
      'Low',
      'Lossless. Same quality, text stays selectable. Saves least.',
    ),
    CompressLevel.medium: (
      'Medium',
      'Pages become 150 dpi images. Good for reading and sharing.',
    ),
    CompressLevel.high: (
      'High',
      'Pages become 100 dpi images. Smallest file, visibly softer.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return _OptionSheet(
      title: 'Compress PDF',
      actionLabel: 'Compress',
      onAction: () => Navigator.of(context).pop(_level),
      children: [
        for (final CompressLevel level in CompressLevel.values)
          if (level == CompressLevel.low || widget.canRasterize)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SelectableCard(
                selected: _level == level,
                title: _labels[level]!.$1,
                subtitle: _labels[level]!.$2,
                onTap: () => setState(() => _level = level),
              ),
            ),
        if (_level != CompressLevel.low)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Text in the compressed copy can no longer be selected, '
                    'searched or converted to Word. Your original is kept '
                    'until you choose to replace it.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SelectableCard extends StatelessWidget {
  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SelectableCard({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected ? colors.primaryContainer : null,
            border: Border.all(
              color: selected ? colors.primary : colors.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Images -------------------------------------------------------------------

class ImageExportOptions {
  /// 0-based pages to render; every page for a long image.
  final List<int> pages;
  final bool png;
  final int width;

  const ImageExportOptions({
    required this.pages,
    required this.png,
    required this.width,
  });
}

enum _PageChoice { all, current, custom }

/// Options for turning pages into pictures. With [long], every page is
/// stitched into one image, so only the width is asked for.
class ImageExportSheet extends StatefulWidget {
  final int pageCount;

  /// 1-based.
  final int currentPage;
  final bool long;

  const ImageExportSheet({
    super.key,
    required this.pageCount,
    required this.currentPage,
    this.long = false,
  });

  static Future<ImageExportOptions?> show(
    BuildContext context, {
    required int pageCount,
    required int currentPage,
    bool long = false,
  }) => _showSheet(
    context,
    ImageExportSheet(
      pageCount: pageCount,
      currentPage: currentPage,
      long: long,
    ),
  );

  @override
  State<ImageExportSheet> createState() => _ImageExportSheetState();
}

class _ImageExportSheetState extends State<ImageExportSheet> {
  _PageChoice _pages = _PageChoice.all;
  bool _png = false;
  int _width = 1600;
  final TextEditingController _custom = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.long) _width = 1080;
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  (List<int>?, String?) _selectedPages() {
    switch (_pages) {
      case _PageChoice.all:
        return ([for (int i = 0; i < widget.pageCount; i++) i], null);
      case _PageChoice.current:
        return ([widget.currentPage - 1], null);
      case _PageChoice.custom:
        if (_custom.text.trim().isEmpty) return (null, null);
        try {
          final Set<int> pages = {
            for (final List<int> group in PdfTools.parseRanges(
              _custom.text,
              widget.pageCount,
            ))
              ...group,
          };
          return (pages.toList()..sort(), null);
        } on FormatException catch (e) {
          return (null, e.message);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final (List<int>? pages, String? error) = widget.long
        ? (<int>[for (int i = 0; i < widget.pageCount; i++) i], null)
        : _selectedPages();
    final Map<int, String> widths = widget.long
        ? const {1080: 'Standard', 1600: 'High', 2400: 'Max'}
        : const {1080: 'Standard', 1600: 'High', 2400: 'Ultra'};

    return _OptionSheet(
      title: widget.long ? 'PDF to long image' : 'PDF to image',
      subtitle: widget.long
          ? 'All ${widget.pageCount} pages, top to bottom, in one JPG. '
                'Very long documents are narrowed to fit.'
          : null,
      actionLabel: pages == null
          ? 'Convert'
          : widget.long
          ? 'Create image'
          : 'Convert ${pages.length} page${pages.length == 1 ? '' : 's'}',
      onAction: pages == null
          ? null
          : () => Navigator.of(context).pop(
              ImageExportOptions(pages: pages, png: _png, width: _width),
            ),
      children: [
        if (!widget.long) ...[
          _label(context, 'Pages'),
          SegmentedButton<_PageChoice>(
            segments: [
              const ButtonSegment(value: _PageChoice.all, label: Text('All')),
              ButtonSegment(
                value: _PageChoice.current,
                label: Text('Page ${widget.currentPage}'),
              ),
              const ButtonSegment(
                value: _PageChoice.custom,
                label: Text('Custom'),
              ),
            ],
            selected: {_pages},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _pages = s.single),
          ),
          if (_pages == _PageChoice.custom) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _custom,
              autofocus: true,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: 'e.g. 1-3, 5',
                errorText: error,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
          const SizedBox(height: 16),
          _label(context, 'Format'),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('JPG')),
              ButtonSegment(value: true, label: Text('PNG')),
            ],
            selected: {_png},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _png = s.single),
          ),
          const SizedBox(height: 16),
        ],
        _label(context, 'Resolution'),
        SegmentedButton<int>(
          segments: [
            for (final MapEntry<int, String> entry in widths.entries)
              ButtonSegment(
                value: entry.key,
                label: Text(entry.value),
                tooltip: '${entry.key} px wide',
              ),
          ],
          selected: {_width},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _width = s.single),
        ),
      ],
    );
  }
}
