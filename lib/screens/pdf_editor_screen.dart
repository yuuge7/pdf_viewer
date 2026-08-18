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
  bool _isEditing = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _currentFile = widget.file;
  }

  Future<void> _addTextAnnotation() async {
    setState(() {
      _isLoading = true;
    });

    final String text = "SAMPLE TEXT";
    // Place it somewhere visible, maybe centered on the first page
    final Offset position = const Offset(100, 100);

    File? newFile = await PdfService.addTextAnnotation(_currentFile, text, position);
    
    if (newFile != null) {
      setState(() {
        _currentFile = newFile;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Text added to PDF')),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to edit PDF')),
        );
      }
    }

    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _addHighlight() async {
    setState(() {
      _isLoading = true;
    });

    // We'll highlight a predefined bounds area for demonstration
    final Rect bounds = const Rect.fromLTWH(50, 200, 300, 50);

    File? newFile = await PdfService.addHighlightAnnotation(_currentFile, bounds);
    
    if (newFile != null) {
      setState(() {
        _currentFile = newFile;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Highlight added to PDF')),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to edit PDF')),
        );
      }
    }

    setState(() {
      _isLoading = false;
    });
  }

  void _sharePdf() {
    Share.shareXFiles([XFile(_currentFile.path)], text: 'Here is my edited PDF');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PDF Editor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _sharePdf,
            tooltip: 'Share PDF',
          ),
          IconButton(
            icon: Icon(_isEditing ? Icons.check : Icons.edit),
            onPressed: () {
              setState(() {
                _isEditing = !_isEditing;
              });
            },
            tooltip: 'Toggle Edit Mode',
          )
        ],
      ),
      body: Stack(
        children: [
          SfPdfViewer.file(
            _currentFile,
            key: _pdfViewerKey,
            controller: _pdfViewerController,
            canShowScrollHead: false,
            canShowScrollStatus: false,
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
      floatingActionButton: _isEditing
          ? Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'textBtn',
                  onPressed: _addTextAnnotation,
                  icon: const Icon(Icons.text_fields),
                  label: const Text('Add Text'),
                ),
                const SizedBox(height: 10),
                FloatingActionButton.extended(
                  heroTag: 'highlightBtn',
                  onPressed: _addHighlight,
                  icon: const Icon(Icons.highlight),
                  label: const Text('Highlight'),
                ),
              ],
            )
          : null,
    );
  }
}
