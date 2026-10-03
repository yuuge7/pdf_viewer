import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before the first frame, so a dark-mode user is not flashed a light one.
  await AppSettings.load();
  runApp(const PdfViewerApp());
}

class PdfViewerApp extends StatelessWidget {
  const PdfViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppSettings.themeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'ProPDF Studio',
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: mode,
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }

  static ThemeData _theme(Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF1E3A8A), // Premium Deep Blue
        brightness: brightness,
      ),
      appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0),
    );
  }
}
