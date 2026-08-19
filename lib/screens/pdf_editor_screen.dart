import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:share_plus/share_plus.dart';
import '../services/pdf_service.dart';

class PdfEditorScreen extends StatefulWidget {
  final File file;

  const PdfEditorScreen({super.key, required this.file});

  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  late File _currentFile;
  final PdfViewerController _pdfViewerController = PdfViewerController();
  final GlobalKey<SfPdfViewerState> _pdfViewerKey = GlobalKey();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _currentFile = widget.file;
  }

  Future<void> _addTextAnnotation() async {
    setState(() => _isLoading = true);
    final String text = "SAMPLE TEXT";
    final Offset position = const Offset(100, 100);
    File? newFile = await PdfService.addTextAnnotation(_currentFile, text, position);
    _handleNewFile(newFile, 'Text added successfully');
  }

  Future<void> _addHighlight() async {
    setState(() => _isLoading = true);
    final Rect bounds = const Rect.fromLTWH(50, 200, 300, 50);
    File? newFile = await PdfService.addHighlightAnnotation(_currentFile, bounds);
    _handleNewFile(newFile, 'Highlight added successfully');
  }

  void _handleNewFile(File? newFile, String successMessage) {
    if (newFile != null) {
      setState(() {
        _currentFile = newFile;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successMessage)));
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to edit PDF')));
      }
    }
    setState(() => _isLoading = false);
  }

  void _sharePdf() {
    SharePlus.instance.share([XFile(_currentFile.path)], text: 'Here is my document from ProPDF Studio');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.file.path.split(Platform.pathSeparator).last,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_rounded),
            onPressed: _sharePdf,
            tooltip: 'Share',
          ),
          IconButton(
            icon: const Icon(Icons.bookmark_border_rounded),
            onPressed: () {
              _pdfViewerKey.currentState?.openBookmarkView();
            },
            tooltip: 'Bookmarks',
          ),
        ],
      ),
      body: Stack(
        children: [
          SfPdfViewer.file(
            _currentFile,
            key: _pdfViewerKey,
            controller: _pdfViewerController,
            canShowScrollHead: true,
            canShowScrollStatus: true,
            pageSpacing: 4,
          ),
          if (_isLoading)
            Container(
              color: Colors.black45,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
      bottomNavigationBar: BottomAppBar(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        height: 80,
        color: theme.colorScheme.surface,
        elevation: 20,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildToolBtn(Icons.text_fields_rounded, 'Text', _addTextAnnotation, theme),
            _buildToolBtn(Icons.highlight_rounded, 'Highlight', _addHighlight, theme),
            _buildToolBtn(Icons.draw_rounded, 'Draw', () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Draw tool coming soon!'))
              );
            }, theme),
            _buildToolBtn(Icons.search_rounded, 'Search', () {
               ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Search coming soon!'))
              );
            }, theme),
          ],
        ),
      ),
    );
  }

  Widget _buildToolBtn(IconData icon, String label, VoidCallback onTap, ThemeData theme) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: theme.colorScheme.primary),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
