import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../services/document_service.dart';
import '../services/pdf_tools.dart';
import '../services/recent_documents.dart';

/// File-level actions shared by the home screen and the editor.
///
/// Each one talks to the user itself (confirmations, errors) and reports
/// only the outcome the caller has to act on.
class DocumentActions {
  static const String feedbackUrl =
      'https://github.com/yuuge7/pdf_viewer/issues/new';

  static void showMessage(
    BuildContext context,
    String message, {
    SnackBarAction? action,
  }) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  /// Asks for a new name and renames the document itself. Returns the updated
  /// reference, or null if cancelled or refused.
  static Future<DocumentRef?> rename(
    BuildContext context,
    DocumentRef ref,
  ) async {
    final DocumentFacts facts = await DocumentService.facts(ref);
    if (!context.mounted) return null;
    if (!facts.canRename) {
      showMessage(
        context,
        'The app that holds this file does not allow renaming it. '
        'Use Save a copy to store it under a new name.',
      );
      return null;
    }

    final String extension = ref.name.toLowerCase().endsWith('.pdf')
        ? ref.name.substring(ref.name.length - 4)
        : '';
    final String? base = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(initial: PdfTools.baseNameOf(ref.name)),
    );
    if (base == null || !context.mounted) return null;
    final String newName = '$base${extension.isEmpty ? '.pdf' : extension}';
    if (newName == ref.name) return null;

    try {
      final DocumentRef renamed = await DocumentService.rename(ref, newName);
      await RecentDocuments.replace(ref, renamed);
      if (context.mounted) showMessage(context, 'Renamed to ${renamed.name}');
      return renamed;
    } on PlatformException catch (e) {
      if (context.mounted) {
        showMessage(context, e.message ?? 'Could not rename the file.');
      }
    } catch (e) {
      if (context.mounted) showMessage(context, 'Could not rename: $e');
    }
    return null;
  }

  /// Confirms, then deletes the document itself. Returns true once it is gone.
  static Future<bool> delete(BuildContext context, DocumentRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final ColorScheme colors = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          icon: Icon(Icons.delete_forever_rounded, color: colors.error),
          title: const Text('Delete this file?'),
          content: Text(
            '"${ref.name}" will be permanently deleted from your device. '
            'This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return false;

    final bool deleted = await DocumentService.delete(ref);
    if (!context.mounted) return deleted;
    if (!deleted) {
      showMessage(
        context,
        'The app that holds this file does not allow deleting it from here.',
      );
      return false;
    }
    await RecentDocuments.forget(ref);
    if (context.mounted) showMessage(context, 'Deleted ${ref.name}');
    return true;
  }

  /// Shares [file] under the document's real name.
  ///
  /// The file being viewed is a scratch copy called `edited_1738…pdf` or a
  /// cache copy called `open_…pdf`. Sharing it directly sends that name to the
  /// other app, so a copy is staged under the real one first.
  static Future<void> share(
    BuildContext context,
    File file,
    String name,
  ) async {
    try {
      final File staged = await stage(file, name);
      await SharePlus.instance.share(ShareParams(files: [XFile(staged.path)]));
    } catch (e) {
      if (context.mounted) showMessage(context, 'Could not share: $e');
    }
  }

  static Future<void> printFile(
    BuildContext context,
    File file,
    String name,
  ) async {
    if (!DocumentService.supportsSaf) {
      showMessage(context, 'Printing is not supported on this platform.');
      return;
    }
    try {
      // The print spooler reads the file after this call returns, while the
      // editor may already have moved on and deleted its scratch copy.
      final File staged = await stage(file, name);
      await DocumentService.printFile(staged, PdfTools.baseNameOf(name));
    } on PlatformException catch (e) {
      if (context.mounted) showMessage(context, e.message ?? 'Could not print.');
    }
  }

  /// Stars or unstars [ref]. Returns the new state, or null if it cannot be a
  /// favourite.
  static Future<bool?> toggleFavorite(
    BuildContext context,
    DocumentRef ref,
  ) async {
    // Same rule as Recent Files: a document handed over by another app comes
    // with a grant that is gone by the next launch, so a star on it could
    // only ever lead to "File no longer exists".
    if (ref.uri != null && !ref.canWrite) {
      showMessage(
        context,
        'Save a copy first to add this document to Favorites.',
      );
      return null;
    }
    final bool starred = await FavoriteDocuments.toggle(ref);
    if (context.mounted) {
      showMessage(
        context,
        starred ? 'Added to Favorites' : 'Removed from Favorites',
      );
    }
    return starred;
  }

  static Future<void> feedback(BuildContext context) async {
    try {
      await DocumentService.openUrl(feedbackUrl);
    } on PlatformException catch (e) {
      if (context.mounted) {
        showMessage(context, e.message ?? 'Could not open the browser.');
      }
    } on MissingPluginException {
      if (context.mounted) showMessage(context, 'Feedback: $feedbackUrl');
    }
  }

  /// Copies [file] into a fresh outbox under [name].
  static Future<File> stage(File file, String name) async {
    final Directory outbox = await PdfTools.newOutbox();
    final String safe = PdfTools.safeFileName(name);
    final String withExtension = safe.toLowerCase().endsWith('.pdf')
        ? safe
        : '$safe.pdf';
    return file.copy('${outbox.path}/$withExtension');
  }
}

class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  )..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _error = 'Enter a name.');
      return;
    }
    if (RegExp(r'[\\/:*?"<>|]').hasMatch(value)) {
      setState(() => _error = r'A name cannot contain \ / : * ? " < > |');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          suffixText: '.pdf',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Rename')),
      ],
    );
  }
}
