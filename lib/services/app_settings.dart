import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide choices, remembered across sessions.
///
/// How a document is displayed is `ReaderSettings`; this is the app around
/// it.
class AppSettings {
  static const String _themeKey = 'app_theme_mode';

  /// Light, dark, or whatever the system is doing. `MaterialApp` listens.
  static final ValueNotifier<ThemeMode> themeMode = ValueNotifier<ThemeMode>(
    ThemeMode.system,
  );

  static Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? name = prefs.getString(_themeKey);
    for (final ThemeMode mode in ThemeMode.values) {
      if (mode.name == name) themeMode.value = mode;
    }
  }

  static Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
  }
}
