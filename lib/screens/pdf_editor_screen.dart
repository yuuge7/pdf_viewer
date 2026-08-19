import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:share_plus/share_plus.dart';
import '../services/pdf_service.dart';

enum EditTool { none, text, highlight, draw }

class PdfEditorScreen extends StatefulWidget {
  final File file;

  const PdfEditorScreen({super.key, required this.file});

  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  late File _currentFile;
  PdfViewerController _pdfViewerController = PdfViewerController();
  GlobalKey<SfPdfViewerState> _pdfViewerKey = GlobalKey();
  bool _isLoading = false;

  final List<File> _history = [];
  int _historyIndex = 0;

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  PdfTextSearchResult? _searchResult;

  EditTool _activeTool = EditTool.none;
  List<Offset> _currentDrawing = [];
  Offset? _textPosition;
  Offset? _pdfPagePosition;
  int? _textTargetPage;
  bool _isEnteringText = false;
  final TextEditingController _textOverlayController = TextEditingController();

  Offset? _targetScrollOffset;
  double? _targetZoom;
  Size? _viewportSize;
  Size? _pdfPageSize;

  @override
  void initState() {
    super.initState();
    _currentFile = widget.file;
    _history.add(_currentFile);
  }

  Future<void> _commitTextAnnotation(String text) async {
    if (_pdfPagePosition == null || _textTargetPage == null || text.isEmpty) return;
    setState(() => _isLoading = true);
    
    File? newFile = await PdfService.addTextAnnotation(_currentFile, _textTargetPage!, text, _pdfPagePosition!);
    _handleNewFile(newFile, 'Text added successfully');
    
    setState(() {
      _textPosition = null;
      _pdfPagePosition = null;
      _textTargetPage = null;
      _isEnteringText = false;
      _textOverlayController.clear();
      _activeTool = EditTool.none;
    });
  }

  Future<void> _commitHighlightAnnotation(Rect bounds) async {
    setState(() => _isLoading = true);
    double zoom = _pdfViewerController.zoomLevel;
    double scrollX = _pdfViewerController.scrollOffset.dx;
    double scrollY = _pdfViewerController.scrollOffset.dy;
    
    // In continuous mode, scaling is based on fitting the width
    double fitScale = _viewportSize!.width / _pdfPageSize!.width;
    double actualScale = fitScale * zoom;

    double renderedWidth = _pdfPageSize!.width * actualScale;
    double offsetX = 0;
    if (renderedWidth < _viewportSize!.width) {
      offsetX = (_viewportSize!.width - renderedWidth) / 2;
    }
    
    double pageHeightPixels = _pdfPageSize!.height * actualScale;
    double pageSpacing = 4.0; 
    double totalPageHeightPixels = pageHeightPixels + pageSpacing;

    double globalTop = bounds.top + scrollY;
    int pageIndex = (globalTop / totalPageHeightPixels).floor();
    pageIndex = pageIndex.clamp(0, (_pdfViewerController.pageCount - 1).clamp(0, 9999));

    double relativeTop = globalTop - (pageIndex * totalPageHeightPixels);
    double relativeBottom = (bounds.bottom + scrollY) - (pageIndex * totalPageHeightPixels);
    
    Rect mappedBounds = Rect.fromLTRB(
      (bounds.left + scrollX - offsetX) / actualScale, 
      relativeTop / actualScale,
      (bounds.right + scrollX - offsetX) / actualScale, 
      relativeBottom / actualScale
    );

    File? newFile = await PdfService.addHighlightAnnotation(_currentFile, pageIndex, mappedBounds);
    _handleNewFile(newFile, 'Highlight added successfully');
    setState(() => _activeTool = EditTool.none);
  }

  Future<void> _commitDrawAnnotation(List<Offset> points) async {
    setState(() => _isLoading = true);
    double zoom = _pdfViewerController.zoomLevel;
    double scrollX = _pdfViewerController.scrollOffset.dx;
    double scrollY = _pdfViewerController.scrollOffset.dy;
    
    double fitScale = _viewportSize!.width / _pdfPageSize!.width;
    double actualScale = fitScale * zoom;

    double renderedWidth = _pdfPageSize!.width * actualScale;
    double offsetX = 0;
    if (renderedWidth < _viewportSize!.width) {
      offsetX = (_viewportSize!.width - renderedWidth) / 2;
    }
    
    double pageHeightPixels = _pdfPageSize!.height * actualScale;
    double pageSpacing = 4.0; 
    double totalPageHeightPixels = pageHeightPixels + pageSpacing;

    // Use the first point to determine the page
    double globalFirstY = points.first.dy + scrollY;
    int pageIndex = (globalFirstY / totalPageHeightPixels).floor();
    pageIndex = pageIndex.clamp(0, (_pdfViewerController.pageCount - 1).clamp(0, 9999));
    
    List<Offset> mappedPoints = points.map((p) {
      double globalY = p.dy + scrollY;
      double relativeY = globalY - (pageIndex * totalPageHeightPixels);
      return Offset(
        (p.dx + scrollX - offsetX) / actualScale, 
        relativeY / actualScale
      );
    }).toList();

    File? newFile = await PdfService.addDrawAnnotation(_currentFile, pageIndex, mappedPoints);
    _handleNewFile(newFile, 'Drawing added successfully');
    setState(() => _activeTool = EditTool.none);
  }

  void _handleNewFile(File? newFile, String successMessage) {
    if (newFile != null) {
      _targetScrollOffset = _pdfViewerController.scrollOffset;
      _targetZoom = _pdfViewerController.zoomLevel;
      
      setState(() {
        if (_historyIndex < _history.length - 1) {
          _history.removeRange(_historyIndex + 1, _history.length);
        }
        _history.add(newFile);
        _historyIndex++;
        
        _currentFile = newFile;
        _pdfViewerKey = GlobalKey(); // Force SfPdfViewer to recreate
        _pdfViewerController = PdfViewerController(); // Refresh controller
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

  void _undo() {
    if (_historyIndex > 0) {
      _targetScrollOffset = _pdfViewerController.scrollOffset;
      _targetZoom = _pdfViewerController.zoomLevel;
      setState(() {
        _historyIndex--;
        _currentFile = _history[_historyIndex];
        _pdfViewerKey = GlobalKey();
        _pdfViewerController = PdfViewerController();
      });
    }
  }

  void _redo() {
    if (_historyIndex < _history.length - 1) {
      _targetScrollOffset = _pdfViewerController.scrollOffset;
      _targetZoom = _pdfViewerController.zoomLevel;
      setState(() {
        _historyIndex++;
        _currentFile = _history[_historyIndex];
        _pdfViewerKey = GlobalKey();
        _pdfViewerController = PdfViewerController();
      });
    }
  }

  Future<void> _savePdf() async {
    if (_currentFile.path != widget.file.path) {
      setState(() => _isLoading = true);
      try {
        await _currentFile.copy(widget.file.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved successfully!')));
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
        }
      } finally {
        setState(() => _isLoading = false);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No changes to save.')));
    }
  }

  void _sharePdf() {
    SharePlus.instance.share(ShareParams(
      files: [XFile(_currentFile.path)],
      text: 'Here is my document from ProPDF Studio',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      appBar: AppBar(
        title: _isSearching 
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search...',
                  border: InputBorder.none,
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (value) {
                  if (value.isNotEmpty) {
                    final result = _pdfViewerController.searchText(value);
                    setState(() {
                      _searchResult = result;
                    });
                  }
                },
              )
            : Text(
                widget.file.path.split(Platform.pathSeparator).last,
                style: const TextStyle(fontSize: 16),
              ),
        actions: [
          if (_isSearching)
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_up_rounded),
              onPressed: () {
                _searchResult?.previousInstance();
              },
            ),
          if (_isSearching)
            IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              onPressed: () {
                _searchResult?.nextInstance();
              },
            ),
          IconButton(
            icon: Icon(_isSearching ? Icons.close_rounded : Icons.search_rounded),
            onPressed: () {
              setState(() {
                if (_isSearching) {
                  _searchController.clear();
                  _searchResult?.clear();
                  _searchResult = null;
                }
                _isSearching = !_isSearching;
              });
            },
            tooltip: 'Search',
          ),
          if (!_isSearching)
            IconButton(
              icon: const Icon(Icons.undo_rounded),
              onPressed: _historyIndex > 0 ? _undo : null,
              tooltip: 'Undo',
            ),
          if (!_isSearching)
            IconButton(
              icon: const Icon(Icons.redo_rounded),
              onPressed: _historyIndex < _history.length - 1 ? _redo : null,
              tooltip: 'Redo',
            ),
          IconButton(
            icon: const Icon(Icons.save_rounded),
            onPressed: _savePdf,
            tooltip: 'Save',
          ),
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
      body: LayoutBuilder(
        builder: (context, constraints) {
          _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            children: [
              SfPdfViewer.file(
                  _currentFile,
                  key: _pdfViewerKey,
                  controller: _pdfViewerController,
                  initialScrollOffset: _targetScrollOffset ?? Offset.zero,
                  initialZoomLevel: _targetZoom ?? 1.0,
                  canShowScrollHead: _activeTool == EditTool.none,
                  canShowScrollStatus: false, 
                  pageSpacing: 4,
                  onDocumentLoaded: (PdfDocumentLoadedDetails details) {
                    if (details.document.pages.count > 0) {
                      _pdfPageSize = details.document.pages[0].size;
                    }
                    setState(() {});
                  },
                  onTap: (PdfGestureDetails details) {
                    if (_activeTool == EditTool.text) {
                      setState(() {
                        _pdfPagePosition = details.pagePosition;
                        _textPosition = details.position;
                        _textTargetPage = details.pageNumber;
                        _isEnteringText = true;
                        _textOverlayController.clear();
                      });
                    }
                  },
                ),
          
          if (_activeTool == EditTool.draw || _activeTool == EditTool.highlight)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) {
                  setState(() {
                    _currentDrawing = [details.localPosition];
                  });
                },
                onPanUpdate: (details) {
                  if (_activeTool == EditTool.draw || _activeTool == EditTool.highlight) {
                    setState(() {
                      _currentDrawing.add(details.localPosition);
                    });
                  }
                },
                onPanEnd: (details) {
                  if (_currentDrawing.length > 1) {
                    if (_activeTool == EditTool.draw) {
                      _commitDrawAnnotation(List.from(_currentDrawing));
                    } else if (_activeTool == EditTool.highlight) {
                      // Bounding box of drawing
                      double minX = _currentDrawing.map((e) => e.dx).reduce((a, b) => a < b ? a : b);
                      double maxX = _currentDrawing.map((e) => e.dx).reduce((a, b) => a > b ? a : b);
                      double minY = _currentDrawing.map((e) => e.dy).reduce((a, b) => a < b ? a : b);
                      double maxY = _currentDrawing.map((e) => e.dy).reduce((a, b) => a > b ? a : b);
                      _commitHighlightAnnotation(Rect.fromLTRB(minX, minY, maxX, maxY));
                    }
                  }
                  setState(() {
                    _currentDrawing.clear();
                  });
                },
                child: CustomPaint(
                  painter: _DrawingPainter(
                    points: _currentDrawing, 
                    tool: _activeTool
                  ),
                ),
              ),
            ),

          if (_isEnteringText && _textPosition != null)
            Positioned(
              left: _textPosition!.dx,
              top: _textPosition!.dy - 20,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: 200,
                  color: Colors.white.withAlpha(200),
                  child: TextField(
                    controller: _textOverlayController,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: 'Type text...',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.check, color: Colors.green),
                        onPressed: () {
                          _commitTextAnnotation(_textOverlayController.text);
                        },
                      ),
                    ),
                    onSubmitted: (val) {
                      _commitTextAnnotation(val);
                    },
                  ),
                ),
              ),
            ),
          // Custom page indicator
          if (_pdfViewerController.pageCount > 0)
            Positioned(
              bottom: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withAlpha(178), // 0.7 * 255 ≈ 178
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${_pdfViewerController.pageNumber}/${_pdfViewerController.pageCount}',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          if (_isLoading)
            Container(
              color: Colors.black45,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      );
    }),
      bottomNavigationBar: BottomAppBar(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        height: 80,
        color: theme.colorScheme.surface,
        elevation: 20,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildToolBtn(Icons.text_fields_rounded, 'Text', () {
              setState(() => _activeTool = _activeTool == EditTool.text ? EditTool.none : EditTool.text);
            }, theme, isActive: _activeTool == EditTool.text),
            _buildToolBtn(Icons.highlight_rounded, 'Highlight', () {
              setState(() => _activeTool = _activeTool == EditTool.highlight ? EditTool.none : EditTool.highlight);
            }, theme, isActive: _activeTool == EditTool.highlight),
            _buildToolBtn(Icons.draw_rounded, 'Draw', () {
              setState(() => _activeTool = _activeTool == EditTool.draw ? EditTool.none : EditTool.draw);
            }, theme, isActive: _activeTool == EditTool.draw),
            _buildToolBtn(Icons.search_rounded, 'Search', () {
               setState(() {
                 _isSearching = true;
               });
            }, theme),
          ],
        ),
      ),
    );
  }

  Widget _buildToolBtn(IconData icon, String label, VoidCallback onTap, ThemeData theme, {bool isActive = false}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: isActive ? theme.colorScheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isActive ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.primary),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.labelSmall?.copyWith(
              color: isActive ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.primary, 
              fontWeight: FontWeight.w600
            )),
          ],
        ),
      ),
    );
  }
}

class _DrawingPainter extends CustomPainter {
  final List<Offset> points;
  final EditTool tool;

  _DrawingPainter({required this.points, required this.tool});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    if (tool == EditTool.draw) {
      paint.color = Colors.blue;
      paint.strokeWidth = 3;
      
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(path, paint);
    } else if (tool == EditTool.highlight) {
      paint.color = Colors.yellow.withAlpha(128);
      paint.style = PaintingStyle.fill;

      double minX = points.map((e) => e.dx).reduce((a, b) => a < b ? a : b);
      double maxX = points.map((e) => e.dx).reduce((a, b) => a > b ? a : b);
      double minY = points.map((e) => e.dy).reduce((a, b) => a < b ? a : b);
      double maxY = points.map((e) => e.dy).reduce((a, b) => a > b ? a : b);
      
      canvas.drawRect(Rect.fromLTRB(minX, minY, maxX, maxY), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DrawingPainter oldDelegate) => true;
}
