import 'package:flutter/material.dart';

import '../services/reader_settings.dart';

/// Reading direction, page tint and display toggles. Every change applies
/// immediately through [onChanged], so the document behind the sheet
/// updates while it is open.
class ViewSettingsSheet extends StatefulWidget {
  final ReaderSettings settings;
  final bool reflow;
  final void Function(ReaderSettings settings, bool reflow) onChanged;

  const ViewSettingsSheet({
    super.key,
    required this.settings,
    required this.reflow,
    required this.onChanged,
  });

  static Future<void> show(
    BuildContext context, {
    required ReaderSettings settings,
    required bool reflow,
    required void Function(ReaderSettings settings, bool reflow) onChanged,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ViewSettingsSheet(
        settings: settings,
        reflow: reflow,
        onChanged: onChanged,
      ),
    );
  }

  @override
  State<ViewSettingsSheet> createState() => _ViewSettingsSheetState();
}

class _ViewSettingsSheetState extends State<ViewSettingsSheet> {
  late ReaderSettings _settings = widget.settings;
  late bool _reflow = widget.reflow;

  void _update({ReaderSettings? settings, bool? reflow}) {
    setState(() {
      _settings = settings ?? _settings;
      _reflow = reflow ?? _reflow;
    });
    widget.onChanged(_settings, _reflow);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final TextStyle? heading = theme.textTheme.titleMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Reading direction', style: heading),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _choice(
                  icon: Icons.view_week_outlined,
                  label: 'Horizontal',
                  selected:
                      _settings.direction == ReadingDirection.horizontal,
                  onTap: () => _update(
                    settings: _settings.copyWith(
                      direction: ReadingDirection.horizontal,
                    ),
                    reflow: false,
                  ),
                ),
                _choice(
                  icon: Icons.view_agenda_outlined,
                  label: 'Vertical',
                  selected: _settings.direction == ReadingDirection.vertical,
                  onTap: () => _update(
                    settings: _settings.copyWith(
                      direction: ReadingDirection.vertical,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Background', style: heading),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final PageTheme theme in PageTheme.values)
                  _swatch(theme),
              ],
            ),
            const SizedBox(height: 16),
            _toggle(
              icon: Icons.subject_rounded,
              label: 'Reflow',
              subtitle: 'Text only, sized to fit the screen',
              value: _reflow,
              onChanged: (value) => _update(reflow: value),
            ),
            _toggle(
              icon: Icons.note_outlined,
              label: 'Page by page',
              value: _settings.pageByPage,
              onChanged: (value) => _update(
                settings: _settings.copyWith(pageByPage: value),
                reflow: value ? false : null,
              ),
            ),
            _toggle(
              icon: Icons.stay_current_portrait_rounded,
              label: 'Keep screen on',
              value: _settings.keepScreenOn,
              onChanged: (value) =>
                  _update(settings: _settings.copyWith(keepScreenOn: value)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _choice({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? colors.primary : colors.surfaceContainerHighest,
              ),
              child: Icon(
                icon,
                color: selected ? colors.onPrimary : colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: selected ? colors.primary : colors.onSurface,
                fontWeight: selected ? FontWeight.w600 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _swatch(PageTheme pageTheme) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool selected = _settings.theme == pageTheme;
    return Semantics(
      selected: selected,
      button: true,
      label: pageTheme.label,
      child: InkWell(
        onTap: () => _update(settings: _settings.copyWith(theme: pageTheme)),
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 76,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: pageTheme.paperColor,
                    border: Border.all(
                      color: selected ? colors.primary : colors.outlineVariant,
                      width: selected ? 3 : 1,
                    ),
                  ),
                  child: Text(
                    'Aa',
                    style: TextStyle(
                      color: pageTheme.inkColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  pageTheme.label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: selected ? colors.primary : colors.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toggle({
    required IconData icon,
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon),
      title: Text(label),
      subtitle: subtitle == null ? null : Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }
}
