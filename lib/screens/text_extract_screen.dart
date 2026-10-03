import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/ocr_service.dart';
import '../services/pdf_tools.dart';
import '../widgets/export_sheet.dart';

/// The text of a document, page by page, to copy, share or save.
///
/// Pages with no text are scans; where recognition is available they can be
/// read here without changing the document.
class TextExtractScreen extends StatefulWidget {
  final File file;
  final String documentName;

  const TextExtractScreen({
    super.key,
    required this.file,
    required this.documentName,
  });

  static Future<void> open(
    BuildContext context, {
    required File file,
    required String documentName,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            TextExtractScreen(file: file, documentName: documentName),
      ),
    );
  }

  @override
  State<TextExtractScreen> createState() => _TextExtractScreenState();
}

class _TextExtractScreenState extends State<TextExtractScreen> {
  /// One entry per page; empty where nothing was found.
  List<String> _pages = const [];
  List<Size> _pageSizes = const [];
  bool _loading = true;
  String? _error;

  /// Progress through the pages being recognised, or null when idle.
  (int, int)? _recognising;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final List<PdfTextPage> pages = await PdfTools.extractText(widget.file);
      if (!mounted) return;
      setState(() {
        _pages = [
          for (final PdfTextPage page in pages)
            PdfTools.paragraphsOf(page).map((p) => p.text).join('\n\n'),
        ];
        _pageSizes = [for (final PdfTextPage page in pages) page.displaySize];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not read the text: $e';
        _loading = false;
      });
    }
  }

  List<int> get _emptyPages => [
    for (int i = 0; i < _pages.length; i++)
      if (_pages[i].trim().isEmpty) i,
  ];

  bool get _hasText => _pages.any((p) => p.trim().isNotEmpty);

  /// Everything, with a rule between pages when there are several.
  String get _allText {
    if (_pages.length == 1) return _pages.single;
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < _pages.length; i++) {
      if (_pages[i].trim().isEmpty) continue;
      if (out.isNotEmpty) out.write('\n\n');
      out
        ..writeln('--- Page ${i + 1} ---')
        ..write(_pages[i]);
    }
    return out.toString();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _recognise() async {
    final List<int> empty = _emptyPages;
    if (empty.isEmpty) return;
    setState(() => _recognising = (0, empty.length));
    try {
      final found = await OcrService.recognisePages(
        widget.file,
        empty,
        _pageSizes,
        onProgress: (done, total) {
          if (mounted) setState(() => _recognising = (done, total));
        },
      );
      if (!mounted) return;
      setState(() {
        _pages = [
          for (int i = 0; i < _pages.length; i++)
            found[i]?.map((l) => l.text).join('\n') ?? _pages[i],
        ];
      });
      _message(
        found.isEmpty
            ? 'No text could be recognised.'
            : 'Recognised text on ${found.length} '
                  'page${found.length == 1 ? '' : 's'}.',
      );
    } on PlatformException catch (e) {
      _message(e.message ?? 'Text recognition failed.');
    } catch (e) {
      _message('Text recognition failed: $e');
    } finally {
      if (mounted) setState(() => _recognising = null);
    }
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _allText));
    _message('Copied');
  }

  Future<void> _share() async {
    try {
      await SharePlus.instance.share(ShareParams(text: _allText));
    } catch (e) {
      _message('Could not share: $e');
    }
  }

  Future<void> _save() async {
    final Directory outbox = await PdfTools.newOutbox();
    final String name = PdfTools.safeFileName(
      PdfTools.baseNameOf(widget.documentName),
    );
    final File out = File('${outbox.path}/$name.txt');
    await out.writeAsString(_allText, flush: true);
    if (!mounted) return;
    await ExportSheet.show(
      context,
      files: [out],
      mimeType: 'text/plain',
      title: 'Text file ready',
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool busy = _loading || _recognising != null;
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text('Extract text'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_rounded),
            tooltip: 'Copy all',
            onPressed: busy || !_hasText ? null : _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.ios_share_rounded),
            tooltip: 'Share',
            onPressed: busy || !_hasText ? null : _share,
          ),
          IconButton(
            icon: const Icon(Icons.save_alt_rounded),
            tooltip: 'Save as text file',
            onPressed: busy || !_hasText ? null : _save,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : _buildPages(theme),
    );
  }

  Widget _buildPages(ThemeData theme) {
    final List<int> empty = _emptyPages;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        if (empty.isNotEmpty) _buildScanNotice(theme, empty.length),
        for (int i = 0; i < _pages.length; i++)
          if (_pages[i].trim().isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 6),
              child: Text(
                'Page ${i + 1}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SelectableText(
              _pages[i],
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
            ),
          ],
      ],
    );
  }

  Widget _buildScanNotice(ThemeData theme, int count) {
    final (int, int)? progress = _recognising;
    final String pages = count == _pages.length
        ? (count == 1 ? 'This page has' : 'These pages have')
        : '$count page${count == 1 ? ' has' : 's have'}';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$pages no text to copy. A scanned page is a picture of text.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 12),
          if (progress != null) ...[
            LinearProgressIndicator(
              value: progress.$2 == 0 ? null : progress.$1 / progress.$2,
            ),
            const SizedBox(height: 8),
            Text(
              'Reading page ${(progress.$1 + 1).clamp(1, progress.$2)} '
              'of ${progress.$2}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ] else if (OcrService.isAvailable)
            FilledButton.icon(
              onPressed: _recognise,
              icon: const Icon(Icons.document_scanner_outlined),
              label: const Text('Recognise text'),
            )
          else
            Text(
              'Text recognition needs Android.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
        ],
      ),
    );
  }
}

/// Text read off a picture, to select, copy or share.
class RecognisedTextScreen extends StatelessWidget {
  final String text;
  final String sourceName;

  const RecognisedTextScreen({
    super.key,
    required this.text,
    required this.sourceName,
  });

  static Future<void> open(
    BuildContext context, {
    required String text,
    required String sourceName,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            RecognisedTextScreen(text: text, sourceName: sourceName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text('Recognised text'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_rounded),
            tooltip: 'Copy all',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Copied')));
            },
          ),
          IconButton(
            icon: const Icon(Icons.ios_share_rounded),
            tooltip: 'Share',
            onPressed: () => SharePlus.instance.share(ShareParams(text: text)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            sourceName,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
          ),
        ],
      ),
    );
  }
}
