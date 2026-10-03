part of 'tool_option_sheets.dart';

// --- Shared pieces for the stamping sheets ------------------------------------

enum _Scope { all, current, custom }

/// Which pages a stamp goes on: all, the one on screen, or typed ranges.
///
/// Reports null for "every page", a list of 0-based pages otherwise, and
/// `valid` false while the typed ranges do not parse.
class _PageScope extends StatefulWidget {
  final int pageCount;
  final int currentPage;
  final void Function(List<int>? pages, bool valid) onChanged;

  const _PageScope({
    required this.pageCount,
    required this.currentPage,
    required this.onChanged,
  });

  @override
  State<_PageScope> createState() => _PageScopeState();
}

class _PageScopeState extends State<_PageScope> {
  _Scope _scope = _Scope.all;
  final TextEditingController _ranges = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ranges.dispose();
    super.dispose();
  }

  void _report() {
    String? error;
    List<int>? pages;
    bool valid = true;
    switch (_scope) {
      case _Scope.all:
        pages = null;
      case _Scope.current:
        pages = [widget.currentPage - 1];
      case _Scope.custom:
        try {
          // Ranges may overlap or repeat; a stamp goes on a page once.
          pages =
              PdfTools.parseRanges(
                _ranges.text,
                widget.pageCount,
              ).expand((g) => g).toSet().toList()
                ..sort();
        } on FormatException catch (e) {
          valid = false;
          error = _ranges.text.trim().isEmpty ? null : e.message;
        }
    }
    setState(() => _error = error);
    widget.onChanged(pages, valid);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pageCount < 2) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label(context, 'Pages'),
        SegmentedButton<_Scope>(
          segments: [
            const ButtonSegment(value: _Scope.all, label: Text('All')),
            ButtonSegment(
              value: _Scope.current,
              label: Text('Page ${widget.currentPage}'),
            ),
            const ButtonSegment(value: _Scope.custom, label: Text('Custom')),
          ],
          selected: {_scope},
          showSelectedIcon: false,
          onSelectionChanged: (s) {
            _scope = s.single;
            _report();
          },
        ),
        if (_scope == _Scope.custom) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _ranges,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Page ranges',
              hintText: 'e.g. 1-3, 7',
              errorText: _error,
            ),
            onChanged: (_) => _report(),
          ),
        ],
      ],
    );
  }
}

class _ColorDots extends StatelessWidget {
  final List<Color> colors;
  final Color selected;
  final ValueChanged<Color> onSelected;

  const _ColorDots({
    required this.colors,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        for (final Color color in colors)
          Semantics(
            button: true,
            selected: color == selected,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onSelected(color),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color == selected
                        ? scheme.primary
                        : scheme.outlineVariant,
                    width: color == selected ? 3 : 1,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// --- Watermark ----------------------------------------------------------------

enum _WatermarkLayout { diagonal, straight, tiled }

class WatermarkSheet extends StatefulWidget {
  final int pageCount;
  final int currentPage;

  const WatermarkSheet({
    super.key,
    required this.pageCount,
    required this.currentPage,
  });

  static Future<WatermarkOptions?> show(
    BuildContext context, {
    required int pageCount,
    required int currentPage,
  }) => _showSheet(
    context,
    WatermarkSheet(pageCount: pageCount, currentPage: currentPage),
  );

  @override
  State<WatermarkSheet> createState() => _WatermarkSheetState();
}

class _WatermarkSheetState extends State<WatermarkSheet> {
  static const List<Color> _colors = [
    Color(0xFF808080),
    Color(0xFFD32F2F),
    Color(0xFF1565C0),
    Color(0xFF2E7D32),
    Color(0xFF000000),
  ];

  final TextEditingController _text = TextEditingController(
    text: 'CONFIDENTIAL',
  );
  _WatermarkLayout _layout = _WatermarkLayout.diagonal;
  double _opacity = 0.3;
  Color _color = _colors.first;
  List<int>? _pages;
  bool _pagesValid = true;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  WatermarkOptions get _options => WatermarkOptions(
    text: _text.text,
    color: _color,
    opacity: _opacity,
    angle: _layout == _WatermarkLayout.straight ? 0 : 45,
    tiled: _layout == _WatermarkLayout.tiled,
    pages: _pages,
  );

  @override
  Widget build(BuildContext context) {
    final bool ready = _text.text.trim().isNotEmpty && _pagesValid;
    return _OptionSheet(
      title: 'Watermark',
      subtitle: 'Written over the page. Undo takes it off again.',
      actionLabel: 'Add watermark',
      onAction: ready ? () => Navigator.of(context).pop(_options) : null,
      children: [
        Center(child: _WatermarkPreview(options: _options)),
        const SizedBox(height: 16),
        TextField(
          controller: _text,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Text',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        SegmentedButton<_WatermarkLayout>(
          segments: const [
            ButtonSegment(
              value: _WatermarkLayout.diagonal,
              label: Text('Diagonal'),
            ),
            ButtonSegment(
              value: _WatermarkLayout.straight,
              label: Text('Straight'),
            ),
            ButtonSegment(value: _WatermarkLayout.tiled, label: Text('Tiled')),
          ],
          selected: {_layout},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _layout = s.single),
        ),
        const SizedBox(height: 12),
        _label(context, 'Opacity ${(_opacity * 100).round()}%'),
        Slider(
          value: _opacity,
          min: 0.05,
          max: 1,
          onChanged: (v) => setState(() => _opacity = v),
        ),
        _label(context, 'Colour'),
        _ColorDots(
          colors: _colors,
          selected: _color,
          onSelected: (c) => setState(() => _color = c),
        ),
        const SizedBox(height: 12),
        _PageScope(
          pageCount: widget.pageCount,
          currentPage: widget.currentPage,
          onChanged: (pages, valid) => setState(() {
            _pages = pages;
            _pagesValid = valid;
          }),
        ),
      ],
    );
  }
}

/// A page in miniature with the watermark on it, close enough to the real
/// thing to choose by.
class _WatermarkPreview extends StatelessWidget {
  final WatermarkOptions options;
  const _WatermarkPreview({required this.options});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 120,
      height: 168,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: CustomPaint(painter: _WatermarkPainter(options)),
    );
  }
}

class _WatermarkPainter extends CustomPainter {
  final WatermarkOptions options;
  _WatermarkPainter(this.options);

  @override
  void paint(Canvas canvas, Size size) {
    // Stand-in lines of text, so the mark has something to sit on.
    final Paint rule = Paint()..color = const Color(0xFFDDDDDD);
    for (double y = 14; y < size.height - 10; y += 12) {
      canvas.drawRect(Rect.fromLTWH(12, y, size.width - 24, 3), rule);
    }
    final String text = options.text.trim();
    if (text.isEmpty) return;

    TextPainter layout(double fontSize) => TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: options.color.withValues(alpha: options.opacity),
        ),
      ),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();

    final double radians = -options.angle * math.pi / 180;
    void drawAt(TextPainter painter, Offset centre) {
      canvas.save();
      canvas.translate(centre.dx, centre.dy);
      canvas.rotate(radians);
      painter.paint(canvas, Offset(-painter.width / 2, -painter.height / 2));
      canvas.restore();
    }

    if (!options.tiled) {
      // The same fit the real thing uses: as wide as its direction allows.
      final double run = math.min(
        size.width / math.max(0.2, math.cos(radians).abs()),
        size.height / math.max(0.2, math.sin(radians).abs()),
      );
      final TextPainter probe = layout(10);
      final double fontSize = (10 * run * 0.72 / math.max(1, probe.width))
          .clamp(3.0, 40.0);
      drawAt(layout(fontSize), size.center(Offset.zero));
      return;
    }
    final TextPainter painter = layout(7);
    final double stepX = painter.width + 14;
    final double stepY = math.max(painter.height * 4, 34);
    int row = 0;
    for (double y = stepY / 2; y < size.height + stepY; y += stepY) {
      final double shift = row.isOdd ? stepX / 2 : 0;
      for (double x = -stepX / 2 + shift; x < size.width + stepX; x += stepX) {
        drawAt(painter, Offset(x, y));
      }
      row++;
    }
  }

  @override
  bool shouldRepaint(covariant _WatermarkPainter old) => true;
}

// --- Page numbers -------------------------------------------------------------

class PageNumbersSheet extends StatefulWidget {
  final int pageCount;
  final int currentPage;

  const PageNumbersSheet({
    super.key,
    required this.pageCount,
    required this.currentPage,
  });

  static Future<PageNumberOptions?> show(
    BuildContext context, {
    required int pageCount,
    required int currentPage,
  }) => _showSheet(
    context,
    PageNumbersSheet(pageCount: pageCount, currentPage: currentPage),
  );

  @override
  State<PageNumbersSheet> createState() => _PageNumbersSheetState();
}

class _PageNumbersSheetState extends State<PageNumbersSheet> {
  PageNumberStyle _style = PageNumberStyle.number;
  StampPosition _position = StampPosition.bottomCenter;
  double _size = 11;
  int _startAt = 1;
  List<int>? _pages;
  bool _pagesValid = true;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return _OptionSheet(
      title: 'Page numbers',
      actionLabel: 'Add page numbers',
      onAction: _pagesValid
          ? () => Navigator.of(context).pop(
              PageNumberOptions(
                style: _style,
                position: _position,
                fontSize: _size,
                startAt: _startAt,
                pages: _pages,
              ),
            )
          : null,
      children: [
        _label(context, 'Format'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final PageNumberStyle style in PageNumberStyle.values)
              ChoiceChip(
                label: Text(style.sample),
                selected: _style == style,
                onSelected: (_) => setState(() => _style = style),
              ),
          ],
        ),
        const SizedBox(height: 12),
        _label(context, 'Position'),
        Center(
          child: _PositionPicker(
            selected: _position,
            onSelected: (p) => setState(() => _position = p),
          ),
        ),
        const SizedBox(height: 12),
        _label(context, 'Size ${_size.round()} pt'),
        Slider(
          value: _size,
          min: 7,
          max: 24,
          divisions: 17,
          onChanged: (v) => setState(() => _size = v),
        ),
        Row(
          children: [
            const Expanded(child: Text('Start numbering at')),
            IconButton.outlined(
              icon: const Icon(Icons.remove_rounded),
              tooltip: 'Lower',
              onPressed: _startAt > 1 ? () => setState(() => _startAt--) : null,
            ),
            SizedBox(
              width: 48,
              child: Text(
                '$_startAt',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton.outlined(
              icon: const Icon(Icons.add_rounded),
              tooltip: 'Higher',
              onPressed: () => setState(() => _startAt++),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _PageScope(
          pageCount: widget.pageCount,
          currentPage: widget.currentPage,
          onChanged: (pages, valid) => setState(() {
            _pages = pages;
            _pagesValid = valid;
          }),
        ),
      ],
    );
  }
}

/// A page with six spots on it, one per place a number can go.
class _PositionPicker extends StatelessWidget {
  final StampPosition selected;
  final ValueChanged<StampPosition> onSelected;

  const _PositionPicker({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    Widget row(List<StampPosition> positions) => Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final StampPosition position in positions)
          Tooltip(
            message: position.label,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onSelected(position),
              child: Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                child: Container(
                  width: 30,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: position == selected
                        ? colors.primary
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '1',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: position == selected
                          ? colors.onPrimary
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return Container(
      width: 180,
      height: 210,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          row(StampPosition.values.sublist(0, 3)),
          row(StampPosition.values.sublist(3)),
        ],
      ),
    );
  }
}

// --- Passwords ----------------------------------------------------------------

/// Asks for a new password, twice. Returns it, or null if dismissed.
class ProtectSheet extends StatefulWidget {
  const ProtectSheet({super.key});

  static Future<String?> show(BuildContext context) =>
      _showSheet(context, const ProtectSheet());

  @override
  State<ProtectSheet> createState() => _ProtectSheetState();
}

class _ProtectSheetState extends State<ProtectSheet> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _again = TextEditingController();
  bool _hidden = true;

  @override
  void dispose() {
    _password.dispose();
    _again.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool mismatch =
        _again.text.isNotEmpty && _again.text != _password.text;
    final bool ready =
        _password.text.isNotEmpty && _again.text == _password.text;
    return _OptionSheet(
      title: 'Protect with a password',
      subtitle:
          'The document is encrypted (AES-256) when you save it. There is no '
          'way to open it without the password, so keep it somewhere safe.',
      actionLabel: 'Protect',
      onAction: ready ? () => Navigator.of(context).pop(_password.text) : null,
      children: [
        TextField(
          controller: _password,
          obscureText: _hidden,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: 'Password',
            suffixIcon: IconButton(
              icon: Icon(
                _hidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              tooltip: _hidden ? 'Show' : 'Hide',
              onPressed: () => setState(() => _hidden = !_hidden),
            ),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _again,
          obscureText: _hidden,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            labelText: 'Repeat password',
            errorText: mismatch ? 'The passwords do not match.' : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}

/// Asks for the password of [name]. Returns it, or null if cancelled.
Future<String?> askPassword(
  BuildContext context,
  String name, {
  bool wrong = false,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PasswordDialog(name: name, wrong: wrong),
  );
}

class _PasswordDialog extends StatefulWidget {
  final String name;
  final bool wrong;
  const _PasswordDialog({required this.name, required this.wrong});

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController _password = TextEditingController();
  bool _hidden = true;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_password.text.isNotEmpty) Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Password needed'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('${widget.name} is protected.'),
          const SizedBox(height: 16),
          TextField(
            controller: _password,
            obscureText: _hidden,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Password',
              errorText: widget.wrong ? 'That password is not right.' : null,
              suffixIcon: IconButton(
                icon: Icon(
                  _hidden
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                tooltip: _hidden ? 'Show' : 'Hide',
                onPressed: () => setState(() => _hidden = !_hidden),
              ),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Open')),
      ],
    );
  }
}

// --- Notes --------------------------------------------------------------------

/// Asks for the words of a note. Returns them, or null if cancelled.
Future<String?> askNoteText(BuildContext context, {String initial = ''}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NoteDialog(initial: initial),
  );
}

class _NoteDialog extends StatefulWidget {
  final String initial;
  const _NoteDialog({required this.initial});

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Note'),
      content: TextField(
        controller: _text,
        autofocus: true,
        minLines: 3,
        maxLines: 6,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: 'Write a note',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_text.text),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

// --- New document -------------------------------------------------------------

@immutable
class NewPdfOptions {
  final Size pageSize;
  final int pageCount;
  const NewPdfOptions(this.pageSize, this.pageCount);
}

class NewPdfSheet extends StatefulWidget {
  const NewPdfSheet({super.key});

  static Future<NewPdfOptions?> show(BuildContext context) =>
      _showSheet(context, const NewPdfSheet());

  @override
  State<NewPdfSheet> createState() => _NewPdfSheetState();
}

class _NewPdfSheetState extends State<NewPdfSheet> {
  PaperSize _paper = PaperSize.a4;
  bool _landscape = false;
  int _pages = 1;

  @override
  Widget build(BuildContext context) {
    return _OptionSheet(
      title: 'New PDF',
      subtitle: 'Blank pages to write, draw and paste onto.',
      actionLabel: 'Create',
      onAction: () => Navigator.of(context).pop(
        NewPdfOptions(
          _landscape ? _paper.portrait.flipped : _paper.portrait,
          _pages,
        ),
      ),
      children: [
        _label(context, 'Paper'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final PaperSize paper in PaperSize.values)
              ChoiceChip(
                label: Text(paper.label),
                selected: _paper == paper,
                onSelected: (_) => setState(() => _paper = paper),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: false,
              label: Text('Portrait'),
              icon: Icon(Icons.crop_portrait_rounded),
            ),
            ButtonSegment(
              value: true,
              label: Text('Landscape'),
              icon: Icon(Icons.crop_landscape_rounded),
            ),
          ],
          selected: {_landscape},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _landscape = s.single),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(child: Text('Pages')),
            IconButton.outlined(
              icon: const Icon(Icons.remove_rounded),
              tooltip: 'Fewer',
              onPressed: _pages > 1 ? () => setState(() => _pages--) : null,
            ),
            SizedBox(
              width: 48,
              child: Text(
                '$_pages',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            IconButton.outlined(
              icon: const Icon(Icons.add_rounded),
              tooltip: 'More',
              onPressed: _pages < 200 ? () => setState(() => _pages++) : null,
            ),
          ],
        ),
      ],
    );
  }
}
