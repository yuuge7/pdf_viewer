import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path_provider/path_provider.dart';

class PdfService {
  /// Adds a simple text annotation to a specific page of the PDF
  static Future<File?> addTextAnnotation(File file, int pageIndex, String text, Offset position) async {
    try {
      final List<int> bytes = await file.readAsBytes();
      
      final List<int>? savedBytes = await Isolate.run(() async {
        try {
          final PdfDocument document = PdfDocument(inputBytes: bytes);
          if (document.pages.count <= pageIndex) return null;
          final PdfPage page = document.pages[pageIndex];
          page.graphics.drawString(
            text,
            PdfStandardFont(PdfFontFamily.helvetica, 24),
            bounds: Rect.fromLTWH(position.dx, position.dy - 12, 500, 50),
            brush: PdfBrushes.red,
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

  /// Adds a highlight annotation to a specific bounds on a specific page
  static Future<File?> addHighlightAnnotation(File file, int pageIndex, Rect bounds) async {
    try {
      final List<int> bytes = await file.readAsBytes();
      
      final List<int>? savedBytes = await Isolate.run(() async {
        try {
          final PdfDocument document = PdfDocument(inputBytes: bytes);
          if (document.pages.count <= pageIndex) return null;
          final PdfPage page = document.pages[pageIndex];
          
          final PdfTextMarkupAnnotation highlightAnnotation = PdfTextMarkupAnnotation(
            bounds,
            'Highlight',
            PdfColor(255, 255, 0),
          );
          highlightAnnotation.textMarkupAnnotationType = PdfTextMarkupAnnotationType.highlight;
          page.annotations.add(highlightAnnotation);

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

  /// Adds a draw annotation (path/lines) to a specific page
  static Future<File?> addDrawAnnotation(File file, int pageIndex, List<Offset> points) async {
    try {
      final List<int> bytes = await file.readAsBytes();
      
      final List<int>? savedBytes = await Isolate.run(() async {
        try {
          final PdfDocument document = PdfDocument(inputBytes: bytes);
          if (document.pages.count <= pageIndex) return null;
          final PdfPage page = document.pages[pageIndex];
          
          if (points.length > 1) {
            final PdfPen pen = PdfPen(PdfColor(0, 0, 255), width: 3);
            final PdfPath path = PdfPath();
            for (int i = 0; i < points.length - 1; i++) {
              path.addLine(points[i], points[i + 1]);
            }
            page.graphics.drawPath(path, pen: pen);
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
