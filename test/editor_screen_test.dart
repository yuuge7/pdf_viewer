import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/screens/pdf_editor_screen.dart';
import 'package:pdf_viewer/services/document_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

Future<Uint8List> buildDocument(int pageCount) async {
  final PdfDocument document = PdfDocument();
  for (int i = 0; i < pageCount; i++) {
    document.pages.add().graphics.drawString(
      'PAGE${i + 1}',
      PdfStandardFont(PdfFontFamily.helvetica, 20),
    );
  }
  final bytes = Uint8List.fromList(await document.save());
  document.dispose();
  return bytes;
}

/// Pumps with real waits in between, for work the fake clock does not drive.
Future<void> settleReal(WidgetTester tester, {int rounds = 20}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory dir;
  late DocumentRef ref;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // The viewer's native renderer is absent on the test host. Rendering
    // simply fails quietly, but closing a document on relayout throws unless
    // the channel answers.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('syncfusion_flutter_pdfviewer'),
          (call) async => null,
        );
    dir = await Directory.systemTemp.createTemp('editor');
    final File file = File('${dir.path}/doc.pdf')
      ..writeAsBytesSync(await buildDocument(2));
    ref = DocumentRef(path: file.path, name: 'doc.pdf');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // The viewer may still hold the file open on Windows.
    }
  });

  testWidgets('read mode offers the reader actions', (tester) async {
    await tester.pumpWidget(MaterialApp(home: PdfEditorScreen(document: ref)));
    await settleReal(tester);

    expect(find.text('doc.pdf'), findsOneWidget);
    expect(find.byTooltip('Convert to Word'), findsOneWidget);
    expect(find.byTooltip('Rotate screen'), findsOneWidget);
    expect(find.byTooltip('Search text'), findsOneWidget);
    expect(find.byTooltip('More'), findsOneWidget);
    for (final String label in ['Edit', 'Annotate', 'Sign', 'Tools', 'View']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('edit mode swaps in its own bars, and X leaves it', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: PdfEditorScreen(document: ref)));
    await settleReal(tester);

    await tester.tap(find.text('Annotate'));
    await settleReal(tester, rounds: 5);

    expect(find.text('Done'), findsOneWidget);
    expect(find.byTooltip('Close without saving'), findsOneWidget);
    expect(find.text('Highlight'), findsOneWidget);
    expect(find.text('Underline'), findsOneWidget);

    await tester.tap(find.text('Sign'));
    await settleReal(tester, rounds: 5);
    expect(find.text('Signature'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);

    await tester.tap(find.byTooltip('Close without saving'));
    await settleReal(tester, rounds: 5);
    expect(find.text('Done'), findsNothing);
    expect(find.byTooltip('Convert to Word'), findsOneWidget);
  });

  testWidgets('view settings relayout, tint and reflow the document', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: PdfEditorScreen(document: ref)));
    await settleReal(tester);

    await tester.tap(find.text('View'));
    await settleReal(tester, rounds: 5);
    await tester.tap(find.text('Horizontal'));
    await settleReal(tester, rounds: 5);
    await tester.tap(find.text('Night'));
    await settleReal(tester, rounds: 5);
    await tester.tap(find.text('Reflow'));
    await settleReal(tester);

    // Close the sheet; the reflowed text is behind it.
    await tester.tapAt(const Offset(20, 20));
    await settleReal(tester);
    expect(find.textContaining('PAGE1'), findsOneWidget);
    expect(find.text('Page 1'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('reader_direction'), 'horizontal');
    expect(prefs.getString('reader_theme'), 'night');
  });

  testWidgets('the tools and file sheets open from read mode', (tester) async {
    await tester.pumpWidget(MaterialApp(home: PdfEditorScreen(document: ref)));
    await settleReal(tester);

    await tester.tap(find.text('Tools'));
    await settleReal(tester, rounds: 5);
    expect(find.text('Manage pages'), findsOneWidget);
    expect(find.text('Merge PDF'), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await settleReal(tester, rounds: 5);

    await tester.tap(find.byTooltip('More'));
    await settleReal(tester, rounds: 5);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Compress PDF'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('an unsaved import offers nothing that needs a real file', (
    tester,
  ) async {
    // What a Word or text file becomes when it is opened from another app:
    // a PDF in temporary storage with no document behind it.
    final DocumentRef unsaved = DocumentRef.unsaved(
      path: ref.path,
      name: 'doc.pdf',
    );
    await tester.pumpWidget(
      MaterialApp(home: PdfEditorScreen(document: unsaved)),
    );
    await settleReal(tester);

    await tester.tap(find.byTooltip('More'));
    await settleReal(tester, rounds: 5);
    expect(find.text('Compress PDF'), findsOneWidget);
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });
}
