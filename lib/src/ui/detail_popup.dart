import 'dart:convert';

import 'package:nvim/nvim.dart';

import '../diagnostics.dart';

/// Floating rounded window showing the full multiline message, metadata,
/// and action shortcuts for a [DiagnosticItem].
class DiagnosticDetailPopup {
  final Nvim nvim;
  int? _buf;
  int? _win;
  int? _nsId;
  DiagnosticItem? _diagnostic;
  Future<void> Function(DiagnosticItem item)? _onJump;
  Future<void> Function(DiagnosticItem item)? _onCodeAction;
  Future<void> Function(DiagnosticItem item)? _onCopy;
  Future<void> Function()? _onClose;

  DiagnosticDetailPopup(this.nvim);

  bool get isOpen => _win != null;
  int? get windowId => _win;
  int? get bufferId => _buf;
  DiagnosticItem? get diagnostic => _diagnostic;

  Future<void> open({
    required DiagnosticItem diagnostic,
    required Future<void> Function(DiagnosticItem item) onJump,
    required Future<void> Function(DiagnosticItem item) onCodeAction,
    required Future<void> Function(DiagnosticItem item) onCopy,
    Future<void> Function()? onClose,
  }) async {
    await close();
    _diagnostic = diagnostic;
    _onJump = onJump;
    _onCodeAction = onCodeAction;
    _onCopy = onCopy;
    _onClose = onClose;

    _nsId ??= await nvim.createNamespace('viproblems_detail');

    final buf = await nvim.createBuf(listed: false, scratch: true);
    _buf = buf;

    final sev = diagnostic.severity;
    final srcTag = diagnostic.sourceTag;
    final headerText = srcTag.isNotEmpty
        ? ' ${sev.icon} ${sev.label} • $srcTag '
        : ' ${sev.icon} ${sev.label} ';
    final locationText =
        ' 󰈙 ${diagnostic.relativePath}:${diagnostic.lnum}:${diagnostic.col + 1} ';

    final rawMsgLines = diagnostic.message.split('\n');
    final msgLines = <String>[
      for (final line in rawMsgLines) '   ${line.trimRight()}',
    ];

    const footerHints =
        ' [<CR>] Jump   [a] Code Action   [y] Copy   [q/<Esc>] Close ';

    var maxChars = 54;
    for (final s in [headerText, locationText, ...msgLines, footerHints]) {
      final len = s.runes.length + 2;
      if (len > maxChars) maxChars = len;
    }

    final editorWidth = await nvim.getEditorWidth();
    final editorHeight = await nvim.getEditorHeight();
    final innerWidth = maxChars.clamp(48, (editorWidth - 8).clamp(48, 100));
    final divider = '─' * innerWidth;

    final lines = <String>[
      headerText,
      locationText,
      divider,
      ...msgLines,
      divider,
      footerHints,
    ];

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: lines);
    await nvim.bufSetOption(buf, 'modifiable', false);
    await nvim.bufSetOption(buf, 'buftype', 'nofile');
    await nvim.bufSetOption(buf, 'bufhidden', 'wipe');
    await nvim.bufSetOption(buf, 'filetype', 'viproblems-detail');

    final nsId = _nsId!;
    await nvim.bufClearNamespace(buf, nsId);
    await nvim.bufSetExtmark(buf, nsId, 0, 0, {
      'end_col': _byteLen(headerText),
      'hl_group': sev.highlightGroup,
    });
    await nvim.bufSetExtmark(buf, nsId, 1, 0, {
      'end_col': _byteLen(locationText),
      'hl_group': 'ViproblemsLocation',
    });
    await nvim.bufSetExtmark(buf, nsId, 2, 0, {
      'end_col': _byteLen(divider),
      'hl_group': 'ViproblemsDivider',
    });
    final bottomDivLine = lines.length - 2;
    await nvim.bufSetExtmark(buf, nsId, bottomDivLine, 0, {
      'end_col': _byteLen(divider),
      'hl_group': 'ViproblemsDivider',
    });
    await nvim.bufSetExtmark(buf, nsId, lines.length - 1, 0, {
      'end_col': _byteLen(footerHints),
      'hl_group': 'ViproblemsMuted',
    });

    final innerHeight =
        lines.length.clamp(6, (editorHeight - 6).clamp(6, 24));
    final row = ((editorHeight - innerHeight) ~/ 2).clamp(1, editorHeight - 2);
    final col = ((editorWidth - innerWidth) ~/ 2).clamp(1, editorWidth - 2);

    final win = await nvim.openWin(buf, true, {
      'relative': 'editor',
      'row': row,
      'col': col,
      'width': innerWidth,
      'height': innerHeight,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' Diagnostic Detail ',
      'title_pos': 'center',
    });
    _win = win;

    await nvim.winSetOption(win, 'wrap', true);
    await nvim.winSetOption(win, 'cursorline', false);

    const mappings = <String, String>{
      '<CR>': 'problems.detail_jump',
      'o': 'problems.detail_jump',
      'a': 'problems.detail_code_action',
      'y': 'problems.detail_copy',
      'q': 'problems.detail_close',
      '<Esc>': 'problems.detail_close',
      'K': 'problems.detail_close',
      'd': 'problems.detail_close',
    };

    for (final entry in mappings.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<Cmd>lua require('vibrainium').action('${entry.value}')<CR>",
      );
    }
  }

  Future<void> triggerJump() async {
    final item = _diagnostic;
    final cb = _onJump;
    await close();
    if (item != null && cb != null) {
      await cb(item);
    }
  }

  Future<void> triggerCodeAction() async {
    final item = _diagnostic;
    final cb = _onCodeAction;
    await close();
    if (item != null && cb != null) {
      await cb(item);
    }
  }

  Future<void> triggerCopy() async {
    final item = _diagnostic;
    final cb = _onCopy;
    await close();
    if (item != null && cb != null) {
      await cb(item);
    }
  }

  Future<void> cancel() async {
    final cb = _onClose;
    await close();
    if (cb != null) {
      await cb();
    }
  }

  Future<void> close() async {
    final win = _win;
    _win = null;
    _buf = null;
    _diagnostic = null;
    _onJump = null;
    _onCodeAction = null;
    _onCopy = null;
    _onClose = null;
    if (win != null) {
      try {
        if (await nvim.winIsValid(win)) {
          await nvim.winClose(win, force: true);
        }
      } catch (_) {}
    }
  }

  static int _byteLen(String s) => utf8.encode(s).length;
}
