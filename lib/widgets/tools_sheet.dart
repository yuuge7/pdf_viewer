import 'dart:math' as math;

import 'package:flutter/material.dart';

enum ToolAction {
  managePages,
  deletePages,
  extractPages,
  insertPages,
  toWord,
  toImage,
  compress,
  split,
  merge,
  watermark,
  pageNumbers,
  flatten,
  protect,
  extractText,
  ocr,
  editText,
  addText,
  addImage,
  highlight,
  underline,
  strikethrough,
  draw,
  marker,
  shapes,
  note,
  eraser,
  signature,
}

class _Tool {
  final ToolAction action;
  final IconData icon;
  final String label;
  final Color color;
  const _Tool(this.action, this.icon, this.label, this.color);
}

/// Every tool in one place, as two tabs: document tools and annotation tools.
class ToolsSheet extends StatelessWidget {
  final int initialTab;

  /// Whether the open document asks for a password, which turns Protect
  /// into the way to take it off again.
  final bool isProtected;

  const ToolsSheet({super.key, this.initialTab = 0, this.isProtected = false});

  static Future<ToolAction?> show(
    BuildContext context, {
    int initialTab = 0,
    bool isProtected = false,
  }) {
    return showModalBottomSheet<ToolAction>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          ToolsSheet(initialTab: initialTab, isProtected: isProtected),
    );
  }

  static const double _rowHeight = 108;

  static const List<_Tool> _documentTools = [
    _Tool(ToolAction.managePages, Icons.dashboard_customize_outlined, 'Manage pages', Color(0xFF7C6CF2)),
    _Tool(ToolAction.deletePages, Icons.delete_outline_rounded, 'Delete pages', Color(0xFFE5484D)),
    _Tool(ToolAction.extractPages, Icons.file_upload_outlined, 'Extract pages', Color(0xFF30A46C)),
    _Tool(ToolAction.insertPages, Icons.note_add_outlined, 'Insert pages', Color(0xFF3E8BFF)),
    _Tool(ToolAction.toWord, Icons.description_outlined, 'PDF to Word', Color(0xFFE5484D)),
    _Tool(ToolAction.toImage, Icons.image_outlined, 'PDF to image', Color(0xFFF76B15)),
    _Tool(ToolAction.compress, Icons.compress_rounded, 'Compress', Color(0xFFFFB224)),
    _Tool(ToolAction.split, Icons.call_split_rounded, 'Split PDF', Color(0xFF30A46C)),
    _Tool(ToolAction.merge, Icons.library_add_outlined, 'Merge PDF', Color(0xFFF76B15)),
    _Tool(ToolAction.watermark, Icons.branding_watermark_outlined, 'Watermark', Color(0xFF3E8BFF)),
    _Tool(ToolAction.pageNumbers, Icons.format_list_numbered_rounded, 'Page numbers', Color(0xFF7C6CF2)),
    _Tool(ToolAction.extractText, Icons.text_snippet_outlined, 'Extract text', Color(0xFF30A46C)),
    _Tool(ToolAction.ocr, Icons.document_scanner_outlined, 'Recognise text', Color(0xFFF76B15)),
    _Tool(ToolAction.flatten, Icons.layers_clear_outlined, 'Flatten', Color(0xFFFFB224)),
    _Tool(ToolAction.protect, Icons.lock_outline_rounded, 'Protect', Color(0xFFE5484D)),
  ];

  static const List<_Tool> _annotateTools = [
    _Tool(ToolAction.editText, Icons.edit_note_rounded, 'Edit text', Color(0xFF3E8BFF)),
    _Tool(ToolAction.addText, Icons.title_rounded, 'Add text', Color(0xFF7C6CF2)),
    _Tool(ToolAction.addImage, Icons.add_photo_alternate_outlined, 'Add image', Color(0xFFF76B15)),
    _Tool(ToolAction.highlight, Icons.highlight_rounded, 'Highlight', Color(0xFFFFB224)),
    _Tool(ToolAction.underline, Icons.format_underlined_rounded, 'Underline', Color(0xFF30A46C)),
    _Tool(ToolAction.strikethrough, Icons.format_strikethrough_rounded, 'Strikethrough', Color(0xFFE5484D)),
    _Tool(ToolAction.draw, Icons.draw_rounded, 'Draw', Color(0xFF3E8BFF)),
    _Tool(ToolAction.marker, Icons.brush_outlined, 'Marker', Color(0xFFFFB224)),
    _Tool(ToolAction.shapes, Icons.category_outlined, 'Shapes', Color(0xFF30A46C)),
    _Tool(ToolAction.note, Icons.sticky_note_2_outlined, 'Note', Color(0xFFF76B15)),
    _Tool(ToolAction.eraser, Icons.auto_fix_normal_outlined, 'Eraser', Color(0xFFE5484D)),
    _Tool(ToolAction.signature, Icons.history_edu_rounded, 'Signature', Color(0xFF7C6CF2)),
  ];

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      dividerColor: Colors.transparent,
                      labelStyle: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      tabs: const [
                        Tab(text: 'Tools'),
                        Tab(text: 'Annotate'),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            SizedBox(
              // Four rows where the screen has room for them; the grids
              // scroll for the rest.
              height: math.min(
                _rowHeight * 4 + 8 * 3 + 24,
                MediaQuery.of(context).size.height * 0.62,
              ),
              child: TabBarView(
                children: [
                  _grid(context, _documentTools),
                  _grid(context, _annotateTools),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, List<_Tool> tools) {
    final ThemeData theme = Theme.of(context);
    bool unlock(_Tool tool) =>
        isProtected && tool.action == ToolAction.protect;
    // A fixed row height rather than an aspect ratio, so whole rows fit the
    // sheet on any width instead of the last one sliding out of view.
    return GridView(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        mainAxisSpacing: 8,
        mainAxisExtent: _rowHeight,
      ),
      children: [
        for (final _Tool tool in tools)
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => Navigator.of(context).pop(tool.action),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tool.color.withValues(alpha: 0.16),
                  ),
                  child: Icon(
                    unlock(tool) ? Icons.lock_open_rounded : tool.icon,
                    color: tool.color,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  unlock(tool) ? 'Remove password' : tool.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
