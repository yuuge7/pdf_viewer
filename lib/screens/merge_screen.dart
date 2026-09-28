import 'dart:io';

import 'package:flutter/material.dart';

import '../services/document_service.dart';
import '../services/pdf_tools.dart';

/// A document lined up for merging.
class MergeItem {
  final String path;
  final String name;
  const MergeItem({required this.path, required this.name});
}

/// Collects documents, lets the user order them, and joins them into one.
/// Returns the merged file (in a temporary outbox), or null.
class MergeScreen extends StatefulWidget {
  final List<MergeItem> initial;

  const MergeScreen({super.key, this.initial = const []});

  static Future<File?> open(
    BuildContext context, {
    List<MergeItem> initial = const [],
  }) {
    return Navigator.of(context).push<File>(
      MaterialPageRoute(builder: (_) => MergeScreen(initial: initial)),
    );
  }

  @override
  State<MergeScreen> createState() => _MergeScreenState();
}

class _Entry {
  final int id;
  final MergeItem item;
  int? pages;
  _Entry(this.id, this.item);
}

class _MergeScreenState extends State<MergeScreen> {
  final List<_Entry> _entries = [];
  int _nextId = 0;
  bool _busy = false;
  late final TextEditingController _name = TextEditingController();

  @override
  void initState() {
    super.initState();
    _add(widget.initial);
    if (widget.initial.isNotEmpty) {
      _name.text = '${PdfTools.baseNameOf(widget.initial.first.name)} merged';
    } else {
      _name.text = 'Merged';
    }
    if (widget.initial.length < 2) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _add(List<MergeItem> items) {
    for (final MergeItem item in items) {
      final _Entry entry = _Entry(_nextId++, item);
      _entries.add(entry);
      PdfTools.readFacts(File(item.path))
          .then((facts) {
            if (mounted) setState(() => entry.pages = facts.pageCount);
          })
          .catchError((Object _) {
            if (mounted) setState(() => entry.pages = -1);
          });
    }
  }

  Future<void> _pick() async {
    try {
      final List<PickedDocument> picked = await DocumentService.pickMany();
      if (!mounted || picked.isEmpty) return;
      setState(() {
        _add([
          for (final PickedDocument doc in picked)
            MergeItem(path: doc.path, name: doc.name),
        ]);
      });
    } catch (e) {
      _say('Could not pick files: $e');
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _merge() async {
    if (_entries.any((e) => e.pages == -1)) {
      _say('Remove the files that could not be read first.');
      return;
    }
    setState(() => _busy = true);
    try {
      final String name = _name.text.trim().isEmpty ? 'Merged' : _name.text.trim();
      final File merged = await PdfTools.merge(
        [for (final _Entry entry in _entries) File(entry.item.path)],
        name,
      );
      if (mounted) Navigator.of(context).pop(merged);
    } catch (e) {
      _say('Could not merge: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int totalPages = _entries.fold(
      0,
      (sum, e) => sum + ((e.pages ?? 0) > 0 ? e.pages! : 0),
    );
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: const Text('Merge PDF'),
        actions: [
          IconButton(
            tooltip: 'Add files',
            icon: const Icon(Icons.add_rounded),
            onPressed: _busy ? null : _pick,
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Name of the merged file',
                    suffixText: '.pdf',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              if (_entries.isEmpty)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.library_add_outlined,
                          size: 56,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 12),
                        const Text('Add two or more PDFs to merge.'),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: _pick,
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Add files'),
                        ),
                      ],
                    ),
                  ),
                )
              else ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Drag to change the order',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (totalPages > 0)
                        Text(
                          '$totalPages pages in total',
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: _entries.length,
                    onReorderItem: (from, to) => setState(
                      () => _entries.insert(to, _entries.removeAt(from)),
                    ),
                    itemBuilder: (context, index) {
                      final _Entry entry = _entries[index];
                      final int? pages = entry.pages;
                      return ListTile(
                        key: ValueKey(entry.id),
                        leading: CircleAvatar(child: Text('${index + 1}')),
                        title: Text(
                          entry.item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          pages == null
                              ? 'Reading…'
                              : pages < 0
                              ? 'Could not be read (damaged or password protected)'
                              : '$pages page${pages == 1 ? '' : 's'}',
                          style: pages != null && pages < 0
                              ? TextStyle(color: theme.colorScheme.error)
                              : null,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Remove',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () =>
                                  setState(() => _entries.removeAt(index)),
                            ),
                            ReorderableDragStartListener(
                              index: index,
                              child: const Padding(
                                padding: EdgeInsets.all(8),
                                child: Icon(Icons.drag_handle_rounded),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black45,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _entries.length < 2 || _busy ? null : _merge,
            icon: const Icon(Icons.merge_rounded),
            label: Text(
              _entries.length < 2
                  ? 'Add at least two files'
                  : 'Merge ${_entries.length} files',
            ),
          ),
        ),
      ),
    );
  }
}
