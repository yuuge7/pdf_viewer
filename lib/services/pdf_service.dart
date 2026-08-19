import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path_provider/path_provider.dart';

class PdfService {
  /// Adds a simple text annotation to a specific page of the PDF
  static Future<File?> addTextAnnotation(File file, int pageIndex, String text, Offset position) async {
    try {
      // Read the existing PDF document
      final List<int> bytes = await file.readAsBytes();
      final PdfDocument document = PdfDocument(inputBytes: bytes);

      if (document.pages.count <= pageIndex) return null;

      // Get the page
      final PdfPage page = document.pages[pageIndex];

      // Add a simple text string as a graphical element
      page.graphics.drawString(
        text,
        PdfStandardFont(PdfFontFamily.helvetica, 24),
        bounds: Rect.fromLTWH(position.dx, position.dy, 500, 50),
        brush: PdfBrushes.red,
      );

      // Save the document
      final List<int> savedBytes = await document.save();
      document.dispose();

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
      final PdfDocument document = PdfDocument(inputBytes: bytes);

      if (document.pages.count <= pageIndex) return null;
      
      final PdfPage page = document.pages[pageIndex];
      
      // Create a highlight annotation
      final PdfTextMarkupAnnotation highlightAnnotation = PdfTextMarkupAnnotation(
        bounds,
        'Highlight',
        PdfColor(255, 255, 0),
      );
      highlightAnnotation.textMarkupAnnotationType = PdfTextMarkupAnnotationType.highlight;
      
      page.annotations.add(highlightAnnotation);

      // Save
      final List<int> savedBytes = await document.save();
      document.dispose();

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
      final PdfDocument document = PdfDocument(inputBytes: bytes);

      if (document.pages.count <= pageIndex) return null;
      
      final PdfPage page = document.pages[pageIndex];
      
      // Draw a simple path/scribble using PdfGraphics
      if (points.length > 1) {
        final PdfPen pen = PdfPen(PdfColor(0, 0, 255), width: 3);
        final PdfPath path = PdfPath();
        for (int i = 0; i < points.length - 1; i++) {
          path.addLine(points[i], points[i + 1]);
        }
        page.graphics.drawPath(path, pen: pen);
      }

      // Save
      final List<int> savedBytes = await document.save();
      document.dispose();

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
