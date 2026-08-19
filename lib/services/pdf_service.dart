import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path_provider/path_provider.dart';

class DrawStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  DrawStroke({required this.points, required this.color, required this.width});
}

class HighlightRect {
  final Rect bounds;
  final Color color;
  HighlightRect({required this.bounds, required this.color});
}

class PdfService {
  /// Adds a simple text annotation to a specific page of the PDF
  static Future<File?> addTextAnnotation(File file, int pageIndex, String text, Offset position, Color color, double fontSize) async {
    try {
      final List<int> bytes = await file.readAsBytes();
      
      final int r = color.red;
      final int g = color.green;
      final int b = color.blue;

      final List<int>? savedBytes = await Isolate.run(() async {
        try {
          final PdfDocument document = PdfDocument(inputBytes: bytes);
          if (document.pages.count <= pageIndex) return null;
          final PdfPage page = document.pages[pageIndex];
          page.graphics.drawString(
            text,
            PdfStandardFont(PdfFontFamily.helvetica, fontSize),
            bounds: Rect.fromLTWH(position.dx, position.dy - (fontSize / 2), 500, fontSize * 2),
            brush: PdfSolidBrush(PdfColor(r, g, b)),
          );
          final List<int> result = await document.save();
          document.dispose();
          return result;
        } catch (e) {
          return null;
        }
      });

      if (savedBytes == null) return null;

      // Write to a new file
      final Directory directory = await getApplicationDocumentsDirectory();
      final String newPath = '${directory.path}/edited_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final File newFile = File(newPath);
      await newFile.writeAsBytes(savedBytes, flush: true);

      return newFile;
    } catch (e) {
      debugPrint("Error editing PDF: $e");
      return null;
    }
  }

  /// Adds multiple highlight annotations to a specific page
  static Future<File?> addHighlightAnnotation(File file, int pageIndex, List<HighlightRect> highlights) async {
    try {
      final List<int> bytes = await file.readAsBytes();
      
      final List<int>? savedBytes = await Isolate.run(() async {
        try {
          final PdfDocument document = PdfDocument(inputBytes: bytes);
          if (document.pages.count <= pageIndex) return null;
          final PdfPage page = document.pages[pageIndex];
          
          for (final h in highlights) {
            final PdfTextMarkupAnnotation highlightAnnotation = PdfTextMarkupAnnotation(
              h.bounds,
              'Highlight',
              PdfColor(h.color.red, h.color.green, h.color.blue),
            );
            highlightAnnotation.textMarkupAnnotationType = PdfTextMarkupAnnotationType.highlight;
            page.annotations.add(highlightAnnotation);
          }

          final List<int> result = await document.save();
          document.dispose();
          return result;
        } catch (e) {
          return null;
        }
      });

      if (savedBytes == null) return null;

      final Directory directory = await getApplicationDocumentsDirectory();
      final String newPath = '${directory.path}/edited_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final File newFile = File(newPath);
      await newFile.writeAsBytes(savedBytes, flush: true);

      return newFile;
    } catch (e) {
      debugPrint("Error highlighting PDF: $e");
      return null;
    }
  }

  /// Adds multiple draw annotations (paths/lines) to a specific page
  static Future<File?> addDrawAnnotation(File file, int pageIndex, List<DrawStroke> strokes) async {
    try {
      final List<int> bytes = await file.readAsBytes();
      
      final List<int>? savedBytes = await Isolate.run(() async {
        try {
          final PdfDocument document = PdfDocument(inputBytes: bytes);
          if (document.pages.count <= pageIndex) return null;
          final PdfPage page = document.pages[pageIndex];
          
          for (final stroke in strokes) {
            if (stroke.points.length > 1) {
              final PdfPen pen = PdfPen(PdfColor(stroke.color.red, stroke.color.green, stroke.color.blue), width: stroke.width);
              final PdfPath path = PdfPath();
              for (int i = 0; i < stroke.points.length - 1; i++) {
                path.addLine(stroke.points[i], stroke.points[i + 1]);
              }
              page.graphics.drawPath(path, pen: pen);
            }
          }

          final List<int> result = await document.save();
          document.dispose();
          return result;
        } catch (e) {
          return null;
        }
      });

      if (savedBytes == null) return null;

      final Directory directory = await getApplicationDocumentsDirectory();
      final String newPath = '${directory.path}/edited_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final File newFile = File(newPath);
      await newFile.writeAsBytes(savedBytes, flush: true);

      return newFile;
    } catch (e) {
      debugPrint("Error drawing on PDF: $e");
      return null;
    }
  }
}
