import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/screens/manage_pages_screen.dart';
import 'package:pdf_viewer/services/document_service.dart';
import 'package:pdf_viewer/services/pdf_service.dart';
import 'package:pdf_viewer/services/reader_settings.dart';
import 'package:pdf_viewer/widgets/file_options_sheet.dart';
import 'package:pdf_viewer/widgets/formatting.dart';
import 'package:pdf_viewer/widgets/tool_option_sheets.dart';
import 'package:pdf_viewer/widgets/tools_sheet.dart';
import 'package:pdf_viewer/widgets/view_settings_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Pumps a button that opens [open] and records what it returns.
Future<List<T?>> pumpLauncher<T>(
  WidgetTester tester,
  Future<T?> Function(BuildContext context) open,
) async {
  final List<T?> results = [];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => results.add(await open(context)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('formatting', () {
    test('formats sizes and page sizes', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
      expect(describePageSize(PaperSize.a4.portrait), startsWith('A4'));
      expect(describePageSize(const Size(842, 595)), startsWith('A4'));
      expect(describePageSize(const Size(100, 100)), '35 × 35 mm');
      expect(formatDate(DateTime(2026, 9, 28)), '28 Sep 2026');
    });
  });

  group('ToolsSheet', () {
    testWidgets('returns the tapped tool, on either tab', (tester) async {
      final results = await pumpLauncher<ToolAction>(
        tester,
        (context) => ToolsSheet.show(context),
      );
      await tester.tap(find.text('Split PDF'));
      await tester.pumpAndSettle();
      expect(results.single, ToolAction.split);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annotate'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Signature'));
      await tester.pumpAndSettle();
      expect(results.last, ToolAction.signature);
    });
  });

  group('ViewSettingsSheet', () {
    testWidgets('reports every change as it happens', (tester) async {
      ReaderSettings? settings;
      bool? reflow;
      await pumpLauncher<void>(
        tester,
        (context) => ViewSettingsSheet.show(
          context,
          settings: const ReaderSettings(),
          reflow: false,
          onChanged: (s, r) {
            settings = s;
            reflow = r;
          },
        ),
      );

      await tester.tap(find.text('Horizontal'));
      await tester.pumpAndSettle();
      expect(settings!.direction, ReadingDirection.horizontal);

      await tester.tap(find.text('Night'));
      await tester.pumpAndSettle();
      expect(settings!.theme, PageTheme.night);

      await tester.tap(find.text('Reflow'));
      await tester.pumpAndSettle();
      expect(reflow, isTrue);

      await tester.tap(find.text('Keep screen on'));
      await tester.pumpAndSettle();
      expect(settings!.keepScreenOn, isTrue);
    });

    test('settings survive a round trip through preferences', () async {
      const ReaderSettings saved = ReaderSettings(
        direction: ReadingDirection.horizontal,
        theme: PageTheme.paper,
        pageByPage: true,
        keepScreenOn: true,
      );
      await saved.save();
      final ReaderSettings loaded = await ReaderSettings.load();
      expect(loaded.direction, saved.direction);
      expect(loaded.theme, saved.theme);
      expect(loaded.pageByPage, isTrue);
      expect(loaded.keepScreenOn, isTrue);
      expect(loaded.isContinuousVertical, isFalse);
    });
  });

  group('SplitSheet', () {
    testWidgets('each page by default', (tester) async {
      final results = await pumpLauncher<List<List<int>>>(
        tester,
        (context) => SplitSheet.show(context, 3),
      );
      await tester.tap(find.text('Split into 3 files'));
      await tester.pumpAndSettle();
      expect(results.single, [
        [0],
        [1],
        [2],
      ]);
    });

    testWidgets('custom ranges are validated before splitting', (
      tester,
    ) async {
      final results = await pumpLauncher<List<List<int>>>(
        tester,
        (context) => SplitSheet.show(context, 5),
      );
      await tester.tap(find.text('Ranges'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1-2, 9');
      await tester.pumpAndSettle();
      expect(find.textContaining('outside this document'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '1-2, 4-5');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Split into 2 files'));
      await tester.pumpAndSettle();
      expect(results.single, [
        [0, 1],
        [3, 4],
      ]);
    });
  });

  group('FileOptionsSheet', () {
    testWidgets('returns the chosen action and hides what it is told to', (
      tester,
    ) async {
      final results = await pumpLauncher<FileAction>(
        tester,
        (context) => FileOptionsSheet.show(
          context,
          document: const DocumentRef(path: 'x.pdf', name: 'Report.pdf'),
          renderPath: 'x.pdf',
          isFavorite: true,
          hidden: const {FileAction.toLongImage},
        ),
      );
      expect(find.text('Report.pdf'), findsOneWidget);
      expect(find.text('PDF to long image'), findsNothing);
      expect(find.byIcon(Icons.star_rounded), findsOneWidget);

      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(results.single, FileAction.rename);
    });
  });

  group('ManagePagesScreen', () {
    late Directory dir;
    late File file;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('manage');
      file = File('${dir.path}/doc.pdf')
        ..writeAsBytesSync(await buildDocument(3));
    });
    tearDown(() => dir.delete(recursive: true));

    Future<List<List<PageSpec>?>> openScreen(WidgetTester tester) async {
      final List<List<PageSpec>?> results = [];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async => results.add(
                  await ManagePagesScreen.open(
                    context,
                    file: file,
                    documentName: 'doc.pdf',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      // Reading the page sizes is real file IO and then an isolate, neither
      // of which the fake clock drives: alternate real waits with pumps until
      // the board appears.
      for (int i = 0; i < 100 && find.text('0 Selected').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('stages rotate and delete, and hands back the plan', (
      tester,
    ) async {
      final results = await openScreen(tester);
      expect(find.text('0 Selected'), findsOneWidget);

      // Done stays off until something changes.
      final Finder done = find.widgetWithText(FilledButton, 'Done');
      expect(tester.widget<FilledButton>(done).onPressed, isNull);

      await tester.tap(find.text('1'));
      await tester.pumpAndSettle();
      expect(find.text('1 Selected'), findsOneWidget);
      await tester.tap(find.text('Rotate'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('1')); // deselect page 1
      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('3'), findsNothing);

      await tester.tap(done);
      await tester.pumpAndSettle();

      final List<PageSpec> plan = results.single!;
      expect(plan, hasLength(2));
      expect((plan[0].source as OriginalPageSource).index, 0);
      expect(plan[0].quarterTurns, 1);
      expect((plan[1].source as OriginalPageSource).index, 1);
      expect(plan[1].quarterTurns, 0);
    });

    testWidgets('refuses to delete every page', (tester) async {
      await openScreen(tester);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(find.text('3 Selected'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('A document must keep at least one page.'), findsOneWidget);
    });
  });
}
