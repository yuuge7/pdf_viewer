import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/document_service.dart';
import '../services/pdf_tools.dart';
import 'formatting.dart';

/// Everything known about a document: where it lives, how big it is, its
/// pages, and the metadata stored inside the PDF.
class DocumentDetailsSheet extends StatefulWidget {
  final DocumentRef document;

  /// The copy being viewed, which is what page count and metadata are read
  /// from — it reflects unsaved edits, which is what the user is looking at.
  final File file;

  const DocumentDetailsSheet({
    super.key,
    required this.document,
    required this.file,
  });

  static Future<void> show(
    BuildContext context, {
    required DocumentRef document,
    required File file,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DocumentDetailsSheet(document: document, file: file),
    );
  }

  @override
  State<DocumentDetailsSheet> createState() => _DocumentDetailsSheetState();
}

class _DocumentDetailsSheetState extends State<DocumentDetailsSheet> {
  DocumentFacts? _facts;
  PdfFacts? _pdf;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Future<DocumentFacts> facts = DocumentService.facts(widget.document);
    PdfFacts? pdf;
    String? error;
    try {
      pdf = await PdfTools.readFacts(widget.file);
    } catch (e) {
      error = 'Could not read the document: $e';
    }
    final DocumentFacts resolved = await facts;
    if (!mounted) return;
    setState(() {
      _facts = resolved;
      _pdf = pdf;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DocumentFacts? facts = _facts;
    final PdfFacts? pdf = _pdf;

    final List<(String, String?)> rows = [
      ('Name', widget.document.name),
      ('Location', facts?.location),
      ('Size', facts?.size == null ? null : formatBytes(facts!.size!)),
      ('Modified', facts?.modified == null ? null : formatDateTime(facts!.modified!)),
      ('Pages', pdf?.pageCount.toString()),
      (
        'Page size',
        pdf == null || pdf.pageSizes.isEmpty
            ? null
            : _pageSizeSummary(pdf.pageSizes),
      ),
      (
        'Access',
        widget.document.savesInPlace
            ? 'Read and write'
            : widget.document.isUnsaved
            ? 'Not saved yet (use Save a copy to keep it)'
            : 'Read-only (edits save as a copy)',
      ),
      ('Title', pdf?.title),
      ('Author', pdf?.author),
      ('Subject', pdf?.subject),
      ('Keywords', pdf?.keywords),
      ('Created', pdf?.created == null ? null : formatDateTime(pdf!.created!)),
      ('Creator', pdf?.creator),
      ('Producer', pdf?.producer),
      ('PDF version', pdf == null || pdf.version.isEmpty ? null : pdf.version),
    ];

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Details',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (facts == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    for (final (String label, String? value) in rows)
                      if (value != null) _row(theme, label, value),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _pageSizeSummary(List<Size> sizes) {
    final String first = describePageSize(sizes.first);
    final bool uniform = sizes.every(
      (s) =>
          (s.width - sizes.first.width).abs() < 1 &&
          (s.height - sizes.first.height).abs() < 1,
    );
    return uniform ? first : '$first (first page; sizes vary)';
  }

  Widget _row(ThemeData theme, String label, String value) {
    return InkWell(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: value));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$label copied')),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 104,
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}
