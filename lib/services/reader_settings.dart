import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReadingDirection { vertical, horizontal }

/// Tints applied over the rendered page.
enum PageTheme {
  original('Original', Colors.white, Color(0xFF1B2A4A)),
  paper('Paper', Color(0xFFF6EBC9), Color(0xFF3B2F1E)),
  eyeComfort('Eye comfort', Color(0xFFD9F2D0), Color(0xFF1E3A1E)),
  night('Night', Colors.black, Colors.white);

  final String label;

  /// What a white page looks like in this theme, and the ink on it. Used for
  /// the swatches and for reflowed text, which is not a rendered page.
  final Color paperColor;
  final Color inkColor;

  const PageTheme(this.label, this.paperColor, this.inkColor);

  /// The filter that turns a rendered page into this theme.
  ///
  /// Paper and eye comfort multiply the page by a tint, so white takes the
  /// tint and black stays black. Night inverts, stopping short of pure black
  /// and white, which is harsh to read in the dark.
  ColorFilter get filter {
    switch (this) {
      case PageTheme.original:
        return const ColorFilter.matrix(<double>[
          1, 0, 0, 0, 0, //
          0, 1, 0, 0, 0, //
          0, 0, 1, 0, 0, //
          0, 0, 0, 1, 0, //
        ]);
      case PageTheme.paper:
      case PageTheme.eyeComfort:
        final Color c = paperColor;
        return ColorFilter.matrix(<double>[
          c.r, 0, 0, 0, 0, //
          0, c.g, 0, 0, 0, //
          0, 0, c.b, 0, 0, //
          0, 0, 0, 1, 0, //
        ]);
      case PageTheme.night:
        return const ColorFilter.matrix(<double>[
          -0.85, 0, 0, 0, 230, //
          0, -0.85, 0, 0, 230, //
          0, 0, -0.85, 0, 230, //
          0, 0, 0, 1, 0, //
        ]);
    }
  }
}

/// How documents are displayed, remembered across sessions.
@immutable
class ReaderSettings {
  final ReadingDirection direction;
  final PageTheme theme;
  final bool pageByPage;
  final bool keepScreenOn;

  const ReaderSettings({
    this.direction = ReadingDirection.vertical,
    this.theme = PageTheme.original,
    this.pageByPage = false,
    this.keepScreenOn = false,
  });

  /// Whether pages are laid out the way annotation placement assumes:
  /// continuous and vertical.
  bool get isContinuousVertical =>
      direction == ReadingDirection.vertical && !pageByPage;

  ReaderSettings copyWith({
    ReadingDirection? direction,
    PageTheme? theme,
    bool? pageByPage,
    bool? keepScreenOn,
  }) => ReaderSettings(
    direction: direction ?? this.direction,
    theme: theme ?? this.theme,
    pageByPage: pageByPage ?? this.pageByPage,
    keepScreenOn: keepScreenOn ?? this.keepScreenOn,
  );

  static const String _prefix = 'reader_';

  static Future<ReaderSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    T pick<T extends Enum>(List<T> values, String key, T fallback) {
      final String? name = prefs.getString('$_prefix$key');
      for (final T value in values) {
        if (value.name == name) return value;
      }
      return fallback;
    }

    return ReaderSettings(
      direction: pick(
        ReadingDirection.values,
        'direction',
        ReadingDirection.vertical,
      ),
      theme: pick(PageTheme.values, 'theme', PageTheme.original),
      pageByPage: prefs.getBool('${_prefix}page_by_page') ?? false,
      keepScreenOn: prefs.getBool('${_prefix}keep_screen_on') ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}direction', direction.name);
    await prefs.setString('${_prefix}theme', theme.name);
    await prefs.setBool('${_prefix}page_by_page', pageByPage);
    await prefs.setBool('${_prefix}keep_screen_on', keepScreenOn);
  }
}
