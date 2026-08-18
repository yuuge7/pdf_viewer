import 'dart:io';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:path_provider/path_provider.dart';

class PdfService {
  /// Adds a simple text annotation to the first page of the PDF
  static Future<File?> addTextAnnotation(File file, String text, Offset position) async {
    try {
      // Read the existing PDF document
      final List<int> bytes = await file.readAsBytes();
      final PdfDocument document = PdfDocument(inputBytes: bytes);

      if (document.pages.count == 0) return null;

      // Get the first page (or you can pass the page index dynamically)
      final PdfPage page = document.pages[0];

      // Add a simple text string as a graphical element
      page.graphics.drawString(
        text,
        PdfStandardFont(PdfFontFamily.helvetica, 24),
        bounds: Rect.fromLTWH(position.dx, position.dy, 200, 50),
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

  /// Adds a highlight annotation to a specific bounds on the first page
  static Future<File?> addHighlightAnnotation(File file, Rect bounds) async {
    try {
      final List<int> bytes = await file.readAsBytes();
      final PdfDocument document = PdfDocument(inputBytes: bytes);

      if (document.pages.count == 0) return null;
      
      final PdfPage page = document.pages[0];
      
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
}
