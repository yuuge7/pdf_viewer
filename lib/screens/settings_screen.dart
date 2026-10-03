import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/pdf_tools.dart';
import '../widgets/document_actions.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    Widget heading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(centerTitle: false, title: const Text('Settings')),
      body: ListView(
        children: [
          heading('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: AppSettings.themeMode,
              builder: (context, mode, _) => SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text('Auto'),
                    icon: Icon(Icons.brightness_auto_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text('Light'),
                    icon: Icon(Icons.light_mode_outlined),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text('Dark'),
                    icon: Icon(Icons.dark_mode_outlined),
                  ),
                ],
                selected: {mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => AppSettings.setThemeMode(s.single),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Text(
              'Page colours while reading are under View, inside a document.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          heading('Storage'),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Clear temporary files'),
            subtitle: const Text(
              'Conversions and exports waiting to be saved. They are cleared '
              'after a day anyway.',
            ),
            onTap: () async {
              final int removed = await PdfTools.clearOutboxes();
              if (!context.mounted) return;
              DocumentActions.showMessage(
                context,
                removed == 0
                    ? 'Nothing to clear.'
                    : 'Cleared $removed temporary '
                          'folder${removed == 1 ? '' : 's'}.',
              );
            },
          ),
          heading('Privacy'),
          const ListTile(
            contentPadding: EdgeInsets.symmetric(horizontal: 20),
            leading: Icon(Icons.wifi_off_rounded),
            title: Text('Everything happens on this device'),
            subtitle: Text(
              'No account, no ads, no analytics. Documents are never '
              'uploaded: text recognition, conversion and editing all run '
              'here. Translate and Web search hand the selected text to '
              'another app, and only when you tap them.',
            ),
          ),
          heading('About'),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Icons.feedback_outlined),
            title: const Text('Send feedback'),
            onTap: () => DocumentActions.feedback(context),
          ),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Icons.description_outlined),
            title: const Text('Licences'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'ProPDF Studio',
            ),
          ),
        ],
      ),
    );
  }
}
