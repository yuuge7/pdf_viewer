import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_viewer/main.dart';
import 'package:pdf_viewer/screens/home_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

String p(List<String> parts) => parts.join(Platform.pathSeparator);

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

      // These used to render but do nothing when tapped.
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

    testWidgets('lists stored files newest first', (tester) async {
      SharedPreferences.setMockInitialValues({
        'recent_files': [
          p(['docs', 'newest.pdf']),
          p(['docs', 'older.pdf']),
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

    testWidgets('removing an entry persists the removal', (tester) async {
      SharedPreferences.setMockInitialValues({
        'recent_files': [
          p(['docs', 'a.pdf']),
          p(['docs', 'b.pdf']),
        ],
      });
      await pumpHome(tester);

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pumpAndSettle();

      expect(find.text('a.pdf'), findsNothing);
      expect(find.text('b.pdf'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('recent_files'), [p(['docs', 'b.pdf'])]);
    });

    testWidgets('opening a missing file reports it and drops the entry',
        (tester) async {
      final missing = p([Directory.systemTemp.path, 'definitely-not-here.pdf']);
      SharedPreferences.setMockInitialValues({
        'recent_files': [missing],
      });
      await pumpHome(tester);

      await tester.tap(find.text('definitely-not-here.pdf'));
      await tester.pumpAndSettle();

      expect(find.text('File no longer exists'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('recent_files'), isEmpty);
    });

    testWidgets('shows the file name, not the whole path, as the title',
        (tester) async {
      final path = p(['a', 'deep', 'nested', 'report.pdf']);
      SharedPreferences.setMockInitialValues({
        'recent_files': [path],
      });
      await pumpHome(tester);

      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text(path), findsOneWidget);
    });
  });
}
