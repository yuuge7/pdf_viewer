import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/main.dart';
import 'package:pdf_viewer/screens/home_screen.dart';
import 'package:pdf_viewer/services/document_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String p(List<String> parts) => parts.join(Platform.pathSeparator);

DocumentRef refFor(String name, {String? uri, bool canWrite = true}) =>
    DocumentRef(
      path: p(['docs', name]),
      name: name,
      uri: uri,
      canWrite: canWrite,
    );

Future<void> pumpHome(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
  // Let the SharedPreferences read settle.
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('app', () {
    testWidgets('boots into the home screen', (tester) async {
      await tester.pumpWidget(const PdfViewerApp());
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Open a Document'), findsOneWidget);
    });

    testWidgets('has no dead placeholder actions', (tester) async {
      await pumpHome(tester);

      expect(find.text('View All'), findsNothing);
      expect(find.byIcon(Icons.settings_outlined), findsNothing);
    });
  });

  group('recent files', () {
    testWidgets('shows the empty state when there are none', (tester) async {
      await pumpHome(tester);

      expect(find.text('No recent files yet'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    });

    testWidgets('lists stored documents newest first', (tester) async {
      SharedPreferences.setMockInitialValues({
        'recent_files': [
          refFor('newest.pdf').encode(),
          refFor('older.pdf').encode(),
        ],
      });
      await pumpHome(tester);

      expect(find.text('No recent files yet'), findsNothing);
      expect(find.text('newest.pdf'), findsOneWidget);
      expect(find.text('older.pdf'), findsOneWidget);

      final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect(tiles, hasLength(2));
      expect(((tiles.first.title!) as Text).data, 'newest.pdf');
    });

    testWidgets('reads legacy bare-path entries after an upgrade',
        (tester) async {
      // Older builds stored plain absolute paths. Upgrading must not wipe the
      // list.
      SharedPreferences.setMockInitialValues({
        'recent_files': [p(['docs', 'legacy.pdf'])],
      });
      await pumpHome(tester);

      expect(find.text('legacy.pdf'), findsOneWidget);
    });

    testWidgets('removing an entry persists the removal', (tester) async {
      SharedPreferences.setMockInitialValues({
        'recent_files': [
          refFor('a.pdf').encode(),
          refFor('b.pdf').encode(),
        ],
      });
      await pumpHome(tester);

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pumpAndSettle();

      expect(find.text('a.pdf'), findsNothing);
      expect(find.text('b.pdf'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      final remaining = (prefs.getStringList('recent_files') ?? [])
          .map(DocumentRef.decode)
          .whereType<DocumentRef>()
          .toList();
      expect(remaining, hasLength(1));
      expect(remaining.single.name, 'b.pdf');
    });

    testWidgets('opening a missing file reports it and drops the entry',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'recent_files': [
          const DocumentRef(
            path: '/definitely/not/here.pdf',
            name: 'definitely-not-here.pdf',
          ).encode(),
        ],
      });
      await pumpHome(tester);

      await tester.tap(find.text('definitely-not-here.pdf'));
      await tester.pumpAndSettle();

      expect(find.text('File no longer exists'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('recent_files'), isEmpty);
    });

    testWidgets('says whether a document saves in place', (tester) async {
      SharedPreferences.setMockInitialValues({
        'recent_files': [
          refFor('writable.pdf', uri: 'content://x/1').encode(),
          refFor('locked.pdf', uri: 'content://x/2', canWrite: false).encode(),
        ],
      });
      await pumpHome(tester);

      expect(find.text('Saves to the original file'), findsOneWidget);
      expect(find.text('Read-only copy'), findsOneWidget);
    });

    testWidgets('shows the display name rather than an opaque URI',
        (tester) async {
      const uri = 'content://com.android.providers.media/document/9999';
      SharedPreferences.setMockInitialValues({
        'recent_files': [refFor('report.pdf', uri: uri).encode()],
      });
      await pumpHome(tester);

      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.textContaining(uri), findsNothing);
    });
  });
}
