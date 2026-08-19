import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

void main() {
  var x = SfPdfViewer.network('https://example.com/test.pdf',
    onTap: (PdfDocumentCastDetails details) {
      
    },
  );
}
