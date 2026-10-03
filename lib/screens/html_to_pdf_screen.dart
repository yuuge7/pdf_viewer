import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/document_import.dart';
import '../services/document_service.dart';
import '../services/flow_document.dart';
import '../services/pdf_tools.dart';

/// What [HtmlToPdfScreen] made.
class HtmlPdf {
  /// The new document, saved nowhere yet.
  final DocumentRef document;

  /// Whether the web view laid the page out, as opposed to the built-in
  /// reader, which keeps the content and little of the styling.
  final bool faithful;

  const HtmlPdf(this.document, {required this.faithful});
}

/// Turns HTML — typed, pasted or read from a file — into a PDF.
///
/// Pops with an [HtmlPdf], whose document the caller opens in the editor.
class HtmlToPdfScreen extends StatefulWidget {
  /// HTML to start with, and the name of the file it came from.
  final String initialHtml;
  final String? sourceName;

  const HtmlToPdfScreen({super.key, this.initialHtml = '', this.sourceName});

  static Future<HtmlPdf?> open(
    BuildContext context, {
    String initialHtml = '',
    String? sourceName,
  }) {
    return Navigator.of(context).push<HtmlPdf>(
      MaterialPageRoute(
        builder: (_) =>
            HtmlToPdfScreen(initialHtml: initialHtml, sourceName: sourceName),
      ),
    );
  }

  /// A page past this is a data dump the web view would choke on.
  static const int maxBytes = 8 * 1024 * 1024;

  @override
  State<HtmlToPdfScreen> createState() => _HtmlToPdfScreenState();
}

class _HtmlToPdfScreenState extends State<HtmlToPdfScreen> {
  static const String _sample =
      '<h1>Meeting notes</h1>\n'
      '<p>Write <b>HTML</b> here, or open a saved web page.</p>\n'
      '<ul>\n  <li>Headings, lists and tables</li>\n'
      '  <li>Inline styles and <code>&lt;style&gt;</code> blocks</li>\n</ul>\n';

  late final TextEditingController _html = TextEditingController(
    text: widget.initialHtml,
  );
  late String? _sourceName = widget.sourceName;
  bool _letter = false;
  bool _landscape = false;
  bool _margins = true;
  bool _busy = false;

  @override
  void dispose() {
    _html.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openFile() async {
    final IncomingDocument? picked;
    try {
      picked = await DocumentService.pickAny(
        types: const ['text/html', 'application/xhtml+xml', 'text/plain'],
      );
    } on PlatformException catch (e) {
      _message(e.message ?? 'Could not open the picker.');
      return;
    }
    if (picked == null) return;
    // Read once; nothing here writes back to it.
    DocumentService.release(picked.ref);
    try {
      final File file = picked.ref.file;
      if (await file.length() > HtmlToPdfScreen.maxBytes) {
        _message('That page is too large to convert.');
        return;
      }
      final String html = FlowDocument.decodeText(await file.readAsBytes());
      if (!mounted) return;
      setState(() {
        _html.text = html;
        _sourceName = picked!.ref.name;
      });
    } catch (e) {
      _message('Could not read ${picked.ref.name}: $e');
    }
  }

  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = data?.text ?? '';
    if (text.isEmpty) {
      _message('The clipboard has no text.');
      return;
    }
    setState(() => _html.text = text);
  }

  /// Set once the web view has failed to print a page, so that the next
  /// conversion in this session does not wait on it again.
  static bool _webEngineStuck = false;

  Future<void> _convert() async {
    final String typed = _html.text;
    if (typed.trim().isEmpty) return;
    // Text with no markup at all still deserves its line breaks.
    final String html = typed.contains('<')
        ? typed
        : '<pre style="white-space:pre-wrap">'
              '${typed.replaceAll('&', '&amp;')}</pre>';
    setState(() => _busy = true);
    try {
      final Directory outbox = await PdfTools.newOutbox();
      final String base = PdfTools.safeFileName(
        PdfTools.baseNameOf(_sourceName ?? 'Page'),
      );
      final File out = File('${outbox.path}/$base.pdf');

      // The system web view lays a page out as a browser would, when it
      // works. It has been seen to accept a page and never hand anything
      // back, so it gets a time limit and a stand-in.
      bool faithful = false;
      if (DocumentService.supportsSaf && !_webEngineStuck) {
        final File engineOut = File('${outbox.path}/web_engine.pdf');
        try {
          await DocumentService.htmlToPdf(
            html,
            outPath: engineOut.path,
            landscape: _landscape,
            letter: _letter,
            margins: _margins,
          ).timeout(const Duration(seconds: 12));
          if (engineOut.existsSync() && engineOut.lengthSync() > 0) {
            await engineOut.rename(out.path);
            faithful = true;
          }
        } on TimeoutException {
          _webEngineStuck = true;
        } on PlatformException {
          // Fall through to the built-in layout.
        } on MissingPluginException {
          // Likewise.
        }
      }
      if (!faithful) {
        final Size paper = _letter
            ? const Size(612, 792)
            : const Size(FlowDocument.a4Width, FlowDocument.a4Height);
        await out.writeAsBytes(
          await DocumentImport.renderHtml(
            html,
            await DocumentImport.loadFonts(),
            pageWidth: _landscape ? paper.height : paper.width,
            pageHeight: _landscape ? paper.width : paper.height,
            margin: _margins ? 50 : 18,
            title: base,
          ),
          flush: true,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(
        HtmlPdf(
          DocumentRef.unsaved(path: out.path, name: '$base.pdf'),
          faithful: faithful,
        ),
      );
    } on FormatException catch (e) {
      _message(e.message);
    } catch (e) {
      _message('Could not convert the page: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool empty = _html.text.trim().isEmpty;
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text('HTML to PDF'),
        actions: [
          IconButton(
            icon: const Icon(Icons.content_paste_rounded),
            tooltip: 'Paste',
            onPressed: _busy ? null : _paste,
          ),
          IconButton(
            icon: const Icon(Icons.folder_open_rounded),
            tooltip: 'Open an HTML file',
            onPressed: _busy ? null : _openFile,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  controller: _html,
                  enabled: !_busy,
                  expands: true,
                  maxLines: null,
                  textAlignVertical: TextAlignVertical.top,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                    labelText: _sourceName ?? 'HTML',
                    hintText: _sample,
                    hintMaxLines: 12,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('A4')),
                        ButtonSegment(value: true, label: Text('Letter')),
                      ],
                      selected: {_letter},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) =>
                          setState(() => _letter = s.single),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                          value: false,
                          icon: Icon(Icons.crop_portrait_rounded),
                          tooltip: 'Portrait',
                        ),
                        ButtonSegment(
                          value: true,
                          icon: Icon(Icons.crop_landscape_rounded),
                          tooltip: 'Landscape',
                        ),
                      ],
                      selected: {_landscape},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) =>
                          setState(() => _landscape = s.single),
                    ),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              value: _margins,
              onChanged: _busy ? null : (v) => setState(() => _margins = v),
              title: const Text('Page margins'),
              dense: true,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                'Converted on this device. Nothing is downloaded, so pictures '
                'show only if the page embeds them.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy || empty ? null : _convert,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: Text(_busy ? 'Converting' : 'Convert to PDF'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
