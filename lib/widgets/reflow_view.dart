import 'dart:io';

import 'package:flutter/material.dart';

import '../services/pdf_tools.dart';
import '../services/reader_settings.dart';

/// The document's text alone, re-flowed to the screen width at a size the
/// reader picks. Layout, pictures and drawings are left out by design.
class ReflowView extends StatefulWidget {
  final File file;
  final PageTheme theme;

  /// 1-based page the view opens at.
  final int initialPage;

  const ReflowView({
    super.key,
    required this.file,
    required this.theme,
    this.initialPage = 1,
  });

  @override
  State<ReflowView> createState() => _ReflowViewState();
}

class _ReflowViewState extends State<ReflowView> {
  List<PdfTextPage>? _pages;
  String? _error;
  double _scale = 1.0;
  final Key _center = UniqueKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ReflowView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) _load();
  }

  Future<void> _load() async {
    setState(() {
      _pages = null;
      _error = null;
    });
    try {
      final List<PdfTextPage> pages = await PdfTools.extractText(widget.file);
      if (mounted) setState(() => _pages = pages);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read the text: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // "Original" is a white page, which is what the reflowed text sits on.
    final Color background = widget.theme.paperColor;
    final Color ink = widget.theme.inkColor;
    final List<PdfTextPage>? pages = _pages;

    Widget body;
    if (_error != null) {
      body = _message(_error!, ink);
    } else if (pages == null) {
      body = Center(child: CircularProgressIndicator(color: ink));
    } else if (pages.every((p) => p.lines.isEmpty)) {
      body = _message(
        'There is no text to reflow. This looks like a scanned document, '
        'which is pictures of pages.',
        ink,
      );
    } else {
      // Two slivers around a centre key, so the list can open at any page
      // without building every page before it.
      final int start = (widget.initialPage - 1).clamp(0, pages.length - 1);
      body = SelectionArea(
        child: CustomScrollView(
          center: _center,
          slivers: [
            SliverList.builder(
              itemCount: start,
              itemBuilder: (context, i) =>
                  _page(context, pages[start - 1 - i], ink),
            ),
            SliverList.builder(
              key: _center,
              itemCount: pages.length - start,
              itemBuilder: (context, i) =>
                  _page(context, pages[start + i], ink),
            ),
          ],
        ),
      );
    }

    return ColoredBox(
      color: background,
      child: Stack(
        children: [
          Positioned.fill(child: body),
          if (pages != null)
            Positioned(
              right: 16,
              bottom: 16,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(24),
                elevation: 3,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Smaller text',
                      icon: const Icon(Icons.text_decrease_rounded),
                      onPressed: _scale > 0.8
                          ? () => setState(() => _scale -= 0.1)
                          : null,
                    ),
                    IconButton(
                      tooltip: 'Larger text',
                      icon: const Icon(Icons.text_increase_rounded),
                      onPressed: _scale < 2.4
                          ? () => setState(() => _scale += 0.1)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _message(String text, Color ink) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: ink, fontSize: 16),
      ),
    ),
  );

  Widget _page(BuildContext context, PdfTextPage page, Color ink) {
    final List<PdfParagraph> paragraphs = PdfTools.paragraphsOf(page);
    final double base = 16 * _scale;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Divider(color: ink.withValues(alpha: 0.2))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'Page ${page.index + 1}',
                  style: TextStyle(
                    color: ink.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ),
              Expanded(child: Divider(color: ink.withValues(alpha: 0.2))),
            ],
          ),
          const SizedBox(height: 8),
          if (paragraphs.isEmpty)
            Text(
              '(No text on this page)',
              style: TextStyle(
                color: ink.withValues(alpha: 0.5),
                fontStyle: FontStyle.italic,
              ),
            ),
          for (final PdfParagraph paragraph in paragraphs)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                paragraph.text,
                style: TextStyle(
                  color: ink,
                  height: 1.5,
                  // Headings stay larger than body text, in proportion.
                  fontSize: base * (paragraph.first.fontSize / 11).clamp(0.9, 1.8),
                  fontWeight: paragraph.first.bold ? FontWeight.bold : null,
                  fontStyle: paragraph.first.italic ? FontStyle.italic : null,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
