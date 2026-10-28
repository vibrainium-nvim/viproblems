import 'package:nvim/nvim.dart';
import 'package:visettings/visettings.dart';

import '../diagnostics.dart';
import 'detail_popup.dart';
import 'tree.dart';

/// Main controller for the `viproblems` diagnostics view.
class ProblemsPanel {
  final Nvim nvim;
  final int panelHeight;
  final Map<String, String> extraKeymaps;
  final DiagnosticsProvider diagnosticsProvider;
  final Future<void> Function()? onDiagnosticsUpdated;

  final ProblemsTreeState treeState = ProblemsTreeState();
  late final DiagnosticDetailPopup _detailPopup = DiagnosticDetailPopup(nvim);

  static const Set<String> _nonEditorFiletypes = {
    'viworkspace',
    'viff',
    'viproblems',
    'viproblems-detail',
    'vibrainium-tabbar',
    'vibrainium-bottom-tabbar',
    'viworkspace-prompt',
    'viworkspace-confirm',
    'viworkspace-menu',
  };

  int? _nsId;
  int? _buf;
  int? _win;
  int? _lastActiveEditorWin;
  String? _lastActiveEditorBufPath;
  Set<int> _excludedWindows = const {};
  bool _highlightsInitialized = false;
  bool _autoRefreshRegistered = false;

  String? _rootPath;
  List<DiagnosticItem> _diagnostics = const [];
  RenderedProblemsTree? _rendered;

  ProblemsPanel({
    required this.nvim,
    this.panelHeight = 12,
    this.extraKeymaps = const {},
    this.diagnosticsProvider = const DiagnosticsProvider(),
    this.onDiagnosticsUpdated,
    bool bindRpc = true,
  }) {
    if (bindRpc) {
      nvim.rpc.onRequest = _handleRpc;
      nvim.rpc.onNotification = (method, params) async {
        await _handleRpc(method, params);
      };
    }
  }

  int? get bufferId => _buf;
  int? get windowId => _win;
  int? get lastActiveEditorWin => _lastActiveEditorWin;
  String? get lastActiveEditorBufPath => _lastActiveEditorBufPath;
  List<DiagnosticItem> get diagnostics => List.unmodifiable(_diagnostics);
  RenderedProblemsTree? get renderedTree => _rendered;
  DiagnosticDetailPopup get detailPopup => _detailPopup;

  int get errorCount => _rendered?.totalErrors ?? 0;
  int get warnCount => _rendered?.totalWarnings ?? 0;
  int get infoCount => _rendered?.totalInfos ?? 0;
  int get hintCount => _rendered?.totalHints ?? 0;

  void attachWindow(
    int? win, {
    Set<int> excludedWins = const {},
    int? lastActiveEditorWin,
  }) {
    _win = win;
    _excludedWindows = excludedWins;
    if (lastActiveEditorWin != null && lastActiveEditorWin > 0) {
      _lastActiveEditorWin = lastActiveEditorWin;
    }
  }

  Future<Object?> handleAction(String rawAction) async {
    final action = rawAction.startsWith('problems.')
        ? rawAction.substring('problems.'.length)
        : rawAction;

    switch (action) {
      case 'open':
        await open();
        return true;
      case 'close':
        await close();
        return true;
      case 'toggle':
        await toggle();
        return true;
      case 'refresh':
        await refresh();
        return true;
      case 'auto_refresh':
        if (await isOpen()) {
          await _rememberActiveEditorWin();
          await refresh();
        }
        return true;
      case 'reload':
        await reload();
        return true;
      case 'enter':
        await handleEnter();
        return true;
      case 'click':
        await handleClick(doubleClick: false);
        return true;
      case 'double_click':
        await handleClick(doubleClick: true);
        return true;
      case 'detail':
        await openDetailPopup();
        return true;
      case 'detail_jump':
        await _detailPopup.triggerJump();
        return true;
      case 'detail_code_action':
        await _detailPopup.triggerCodeAction();
        return true;
      case 'detail_copy':
        await _detailPopup.triggerCopy();
        return true;
      case 'detail_close':
        await _detailPopup.cancel();
        return true;
      case 'code_action':
        await handleCodeAction();
        return true;
      case 'copy':
        await handleCopy();
        return true;
      case 'filter_error':
        await handleToggleSeverity(DiagnosticSeverity.error);
        return true;
      case 'filter_warn':
        await handleToggleSeverity(DiagnosticSeverity.warn);
        return true;
      case 'filter_info':
        await handleToggleSeverity(DiagnosticSeverity.info);
        return true;
      case 'filter_hint':
        await handleToggleSeverity(DiagnosticSeverity.hint);
        return true;
      case 'filter_all':
        await handleEnableAllSeverities();
        return true;
      case 'toggle_scope':
        await handleToggleScope();
        return true;
      case 'collapse_all':
        await handleCollapseAll();
        return true;
      case 'expand_all':
        await handleExpandAll();
        return true;
      default:
        return null;
    }
  }

  Future<Object?> _handleRpc(String method, List<Object?> params) async {
    final action =
        (method == 'vibrainium_action' || method == 'viproblems_action') &&
                params.isNotEmpty
            ? params.first.toString()
            : method;
    return handleAction(action);
  }

  Future<bool> isOpen() async {
    final win = _win;
    if (win == null) return false;
    return nvim.winIsValid(win);
  }

  Future<void> toggle() async {
    if (await isOpen()) {
      await close();
    } else {
      await open();
    }
  }

  Future<void> open() async {
    await _rememberActiveEditorWin();
    await _ensureHighlights();
    if (!await isOpen()) {
      await _createPanelWin();
    }
    await _ensureAutoRefreshAugroup();
    await refresh();
  }

  Future<void> closeModals() async {
    await _detailPopup.close();
  }

  Future<void> close() async {
    await closeModals();
    final win = _win;
    _win = null;
    if (win != null && await nvim.winIsValid(win)) {
      await nvim.winClose(win, force: true);
    }
  }

  Future<void> reload() async {
    final ok = await HotReloader.reload();
    if (ok) {
      await onHotReloaded();
    } else {
      await nvim.notify(
        '[viproblems] Hot reload unavailable (running AOT or non-JIT)',
        level: 3,
      );
    }
  }

  Future<void> onHotReloaded() async {
    _highlightsInitialized = false;
    _autoRefreshRegistered = false;
    final buf = _buf;
    if (buf != null && await nvim.bufIsValid(buf)) {
      await _bindPanelKeys(buf);
    }
    if (await isOpen()) {
      await _ensureHighlights();
      await _ensureAutoRefreshAugroup();
      await refresh();
    }
  }

  Future<void> refresh({List<DiagnosticItem>? overrideDiagnostics}) async {
    await _rememberActiveEditorWin();
    final root = _rootPath ??=
        DiagnosticsProvider.normalizePath(await nvim.getCwd());
    final settings = await VibrainiumSettings.load(root);

    if (overrideDiagnostics != null) {
      _diagnostics = List.unmodifiable(overrideDiagnostics);
    } else {
      _diagnostics = await diagnosticsProvider.fetchAll(
        nvim: nvim,
        workspaceRoot: root,
        settings: settings,
      );
    }
    await render();
    if (onDiagnosticsUpdated != null) {
      await onDiagnosticsUpdated!();
    }
  }

  Future<ProblemsNode?> _nodeUnderCursor() async {
    final win = _win;
    final rendered = _rendered;
    if (win == null || rendered == null || !await nvim.winIsValid(win)) {
      return null;
    }
    final (row1, _) = await nvim.winGetCursor(win);
    final idx = row1 - 1;
    if (idx < 0 || idx >= rendered.nodes.length) return null;
    return rendered.nodes[idx];
  }

  Future<void> handleEnter() async {
    final node = await _nodeUnderCursor();
    if (node == null) return;

    switch (node) {
      case ProblemsToolbarNode(:final scopeColStart, :final scopeColEnd, :final filterPillCols):
        final win = _win;
        if (win != null && await nvim.winIsValid(win)) {
          final (_, col) = await nvim.winGetCursor(win);
          if (col >= scopeColStart && col <= scopeColEnd) {
            await handleToggleScope();
            return;
          }
          for (final entry in filterPillCols.entries) {
            final (start, end) = entry.value;
            if (col >= start && col <= end) {
              await handleToggleSeverity(entry.key);
              return;
            }
          }
        }
        await handleToggleScope();
      case ProblemsFileNode(:final filePath):
        treeState.toggleFile(filePath);
        await render();
      case ProblemsDiagnosticNode(:final diagnostic):
        await _jumpToDiagnostic(diagnostic);
      case ProblemsDividerNode() || ProblemsEmptyNode():
        break;
    }
  }

  Future<void> handleClick({required bool doubleClick}) async {
    await _rememberActiveEditorWin();
    await _detailPopup.close();
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) return;

    final node = await _nodeUnderCursor();
    if (node is ProblemsToolbarNode && !doubleClick) {
      final (_, col) = await nvim.winGetCursor(win);
      if (col >= node.scopeColStart && col <= node.scopeColEnd) {
        await handleToggleScope();
        return;
      }
      for (final entry in node.filterPillCols.entries) {
        final (start, end) = entry.value;
        if (col >= start && col <= end) {
          await handleToggleSeverity(entry.key);
          return;
        }
      }
    }

    if (doubleClick) {
      await handleEnter();
    }
  }

  Future<void> openDetailPopup() async {
    final node = await _nodeUnderCursor();
    final diag = switch (node) {
      ProblemsDiagnosticNode(:final diagnostic) => diagnostic,
      ProblemsFileNode(:final diagnostics) =>
        diagnostics.isNotEmpty ? diagnostics.first : null,
      _ => null,
    };
    if (diag == null) return;

    await _detailPopup.open(
      diagnostic: diag,
      onJump: (item) async {
        await _jumpToDiagnostic(item);
      },
      onCodeAction: (item) async {
        await _triggerCodeActionForDiagnostic(item);
      },
      onCopy: (item) async {
        await _copyDiagnosticMessage(item);
        await _focusPanel();
      },
      onClose: _focusPanel,
    );
  }

  Future<void> handleCodeAction() async {
    final node = await _nodeUnderCursor();
    final diag = switch (node) {
      ProblemsDiagnosticNode(:final diagnostic) => diagnostic,
      ProblemsFileNode(:final diagnostics) =>
        diagnostics.isNotEmpty ? diagnostics.first : null,
      _ => null,
    };
    if (diag == null) return;
    await _triggerCodeActionForDiagnostic(diag);
  }

  Future<void> handleCopy() async {
    final node = await _nodeUnderCursor();
    switch (node) {
      case ProblemsDiagnosticNode(:final diagnostic):
        await _copyDiagnosticMessage(diagnostic);
      case ProblemsFileNode(:final relativePath):
        await nvim.copyToClipboard(relativePath);
        await nvim.notify('Copied path: $relativePath');
      default:
        break;
    }
  }

  Future<void> _copyDiagnosticMessage(DiagnosticItem item) async {
    await nvim.copyToClipboard(item.message);
    await nvim.notify('Copied diagnostic: ${item.firstLineMessage}');
  }

  Future<void> handleToggleSeverity(DiagnosticSeverity severity) async {
    treeState.toggleSeverity(severity);
    await render();
  }

  Future<void> handleEnableAllSeverities() async {
    treeState.enableAllSeverities();
    await render();
  }

  Future<void> handleToggleScope() async {
    treeState.toggleScope();
    await render();
    if (onDiagnosticsUpdated != null) {
      await onDiagnosticsUpdated!();
    }
  }

  Future<void> handleCollapseAll() async {
    treeState.collapseAll(_diagnostics.map((d) => d.filePath));
    await render();
  }

  Future<void> handleExpandAll() async {
    treeState.expandAll();
    await render();
  }

  Future<void> _focusPanel() async {
    final win = _win;
    if (win != null && await nvim.winIsValid(win)) {
      await nvim.setCurrentWin(win);
    }
  }

  Future<bool> _isEligibleEditorWin(int? w) async {
    if (w == null || w <= 0) return false;
    if (w == _win || _excludedWindows.contains(w)) return false;
    if (!await nvim.winIsValid(w)) return false;

    final config = await nvim.winGetConfig(w);
    final relative = config['relative']?.toString() ?? '';
    if (relative.isNotEmpty) return false;

    final buf = await nvim.winGetBuf(w);
    if (buf > 0) {
      final filetype =
          (await nvim.bufGetOption(buf, 'filetype'))?.toString() ?? '';
      if (_nonEditorFiletypes.contains(filetype)) return false;
      final buftype =
          (await nvim.bufGetOption(buf, 'buftype'))?.toString() ?? '';
      if (buftype.isNotEmpty) return false;
    }
    return true;
  }

  Future<void> _rememberActiveEditorWin() async {
    int? candidateWin;
    final current = await nvim.getCurrentWin();
    if (await _isEligibleEditorWin(current)) {
      candidateWin = current;
    } else {
      final alt = await nvim.getAlternateWin();
      if (await _isEligibleEditorWin(alt)) {
        candidateWin = alt;
      }
    }

    if (candidateWin != null) {
      _lastActiveEditorWin = candidateWin;
    }

    final editorWin = _lastActiveEditorWin;
    if (editorWin != null && await nvim.winIsValid(editorWin)) {
      final buf = await nvim.winGetBuf(editorWin);
      if (buf > 0 && await nvim.bufIsValid(buf)) {
        final name = await nvim.bufGetName(buf);
        if (name.isNotEmpty) {
          _lastActiveEditorBufPath = DiagnosticsProvider.normalizePath(name);
        }
      }
    }
  }

  Future<void> _jumpToDiagnostic(DiagnosticItem item) async {
    await _rememberActiveEditorWin();

    int? targetWin;
    final candidates = <int?>[
      await nvim.getAlternateWin(),
      _lastActiveEditorWin,
      await nvim.getCurrentWin(),
    ];
    for (final candidate in candidates) {
      if (await _isEligibleEditorWin(candidate)) {
        targetWin = candidate;
        break;
      }
    }

    if (targetWin == null) {
      final wins = await nvim.listWins();
      for (final w in wins) {
        if (await _isEligibleEditorWin(w)) {
          targetWin = w;
          break;
        }
      }
    }

    if (targetWin != null) {
      _lastActiveEditorWin = targetWin;
      await nvim.setCurrentWin(targetWin);
    } else {
      await nvim.command('topleft split');
      final newWin = await nvim.getCurrentWin();
      if (newWin > 0) {
        _lastActiveEditorWin = newWin;
        await nvim.winSetOption(newWin, 'winfixwidth', false);
        await nvim.winSetOption(newWin, 'winfixheight', false);
        await nvim.winSetOption(newWin, 'number', true);
        await nvim.winSetOption(newWin, 'signcolumn', 'auto');
      }
    }

    final escaped = item.filePath.replaceAll(' ', r'\ ');
    await nvim.command('edit $escaped');
    final activeWin = await nvim.getCurrentWin();
    try {
      await nvim.winSetCursor(
        activeWin,
        item.lnum.clamp(1, 10000000),
        item.col.clamp(0, 10000000),
      );
      await nvim.command('normal! zz');
    } catch (_) {}
  }

  Future<void> _triggerCodeActionForDiagnostic(DiagnosticItem item) async {
    await _jumpToDiagnostic(item);
    try {
      await nvim.execLua('vim.lsp.buf.code_action()');
    } catch (_) {}
  }

  Future<void> render() async {
    final buf = _buf;
    final nsId = _nsId;
    if (buf == null || nsId == null || !await nvim.bufIsValid(buf)) return;

    int width = 80;
    try {
      width = await nvim.getEditorWidth();
    } catch (_) {}

    final rendered = treeState.build(
      diagnostics: _diagnostics,
      currentBufferPath: _lastActiveEditorBufPath,
      width: width,
    );
    _rendered = rendered;

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: rendered.lines);
    await nvim.bufSetOption(buf, 'modifiable', false);

    await nvim.bufClearNamespace(buf, nsId);
    for (final hl in rendered.highlights) {
      await nvim.bufSetExtmark(buf, nsId, hl.line, hl.colStart, {
        'end_col': hl.colEnd,
        'hl_group': hl.group,
      });
    }
  }

  Future<void> ensureAutoRefresh() async {
    await _ensureAutoRefreshAugroup();
  }

  Future<void> _ensureAutoRefreshAugroup() async {
    if (_autoRefreshRegistered) return;
    _autoRefreshRegistered = true;
    try {
      await nvim.execLua(r'''
local group = vim.api.nvim_create_augroup('VibrainiumProblemsAutoRefresh', { clear = true })
vim.api.nvim_create_autocmd({ 'DiagnosticChanged', 'BufEnter' }, {
  group = group,
  callback = function()
    pcall(function()
      require('vibrainium').action('problems.auto_refresh')
    end)
  end,
})
''');
    } catch (_) {}
  }

  Future<void> _ensureHighlights() async {
    _nsId ??= await nvim.createNamespace('viproblems_panel');
    if (_highlightsInitialized) return;
    _highlightsInitialized = true;

    const groups = <String, Map<String, Object?>>{
      'ViproblemsHeader': {'bold': true, 'link': 'Title'},
      'ViproblemsDivider': {'link': 'WinSeparator'},
      'ViproblemsFileHeader': {'bold': true, 'link': 'Directory'},
      'ViproblemsError': {'bold': true, 'link': 'DiagnosticError'},
      'ViproblemsWarn': {'bold': true, 'link': 'DiagnosticWarn'},
      'ViproblemsInfo': {'bold': true, 'link': 'DiagnosticInfo'},
      'ViproblemsHint': {'bold': true, 'link': 'DiagnosticHint'},
      'ViproblemsLocation': {'link': 'LineNr'},
      'ViproblemsSource': {'italic': true, 'link': 'Special'},
      'ViproblemsMuted': {'link': 'Comment'},
    };

    for (final entry in groups.entries) {
      await nvim.setHl(0, entry.key, entry.value);
    }
  }

  Future<int> ensureBuffer() async {
    await _ensureHighlights();
    var buf = _buf;
    if (buf == null || !await nvim.bufIsValid(buf)) {
      buf = await nvim.createBuf(listed: false, scratch: true);
      _buf = buf;
      await nvim.bufSetOption(buf, 'buftype', 'nofile');
      await nvim.bufSetOption(buf, 'bufhidden', 'hide');
      await nvim.bufSetOption(buf, 'swapfile', false);
      await nvim.bufSetOption(buf, 'filetype', 'viproblems');
      await _bindPanelKeys(buf);
    }
    return buf;
  }

  Future<void> _createPanelWin() async {
    final buf = await ensureBuffer();
    final win = await nvim.openWin(buf, true, {
      'split': 'below',
      'height': panelHeight,
      'style': 'minimal',
    });
    _win = win;

    await nvim.winSetOption(win, 'number', false);
    await nvim.winSetOption(win, 'relativenumber', false);
    await nvim.winSetOption(win, 'signcolumn', 'no');
    await nvim.winSetOption(win, 'foldcolumn', '0');
    await nvim.winSetOption(win, 'statuscolumn', '');
    await nvim.winSetOption(win, 'wrap', false);
    await nvim.winSetOption(win, 'cursorline', true);
    await nvim.winSetOption(win, 'winfixheight', true);
  }

  Future<void> _bindPanelKeys(int buf) async {
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<LeftMouse>',
      "<LeftMouse><Cmd>lua require('vibrainium').action('problems.click')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<2-LeftMouse>',
      "<LeftMouse><Cmd>lua require('vibrainium').action('problems.double_click')<CR>",
    );

    final mappings = <String, String>{
      '<CR>': 'problems.enter',
      'o': 'problems.enter',
      'K': 'problems.detail',
      'd': 'problems.detail',
      '<Space>': 'problems.detail',
      'a': 'problems.code_action',
      'y': 'problems.copy',
      'e': 'problems.filter_error',
      'w': 'problems.filter_warn',
      'i': 'problems.filter_info',
      'h': 'problems.filter_hint',
      '0': 'problems.filter_all',
      's': 'problems.toggle_scope',
      'zM': 'problems.collapse_all',
      'zR': 'problems.expand_all',
      'R': 'problems.refresh',
      'H': 'problems.reload',
      'q': 'problems.close',
      ...extraKeymaps,
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
}
