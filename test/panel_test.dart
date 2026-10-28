import 'dart:async';
import 'dart:typed_data';

import 'package:nvim/nvim.dart';
import 'package:test/test.dart';
import 'package:viproblems/viproblems.dart';

class _FakeNvimServer {
  final StreamController<List<int>> _toClient = StreamController<List<int>>();
  final StreamController<List<int>> _fromClient = StreamController<List<int>>();
  late final RpcSession serverSession;
  late final RpcSession clientSession;

  String cwd = '/workspace';
  int _nextBuf = 10;
  int _nextWin = 100;
  final Map<int, List<String>> bufLines = {1: ['line1']};
  final Map<int, Map<String, Object?>> bufOptions = {1: {'filetype': 'dart', 'buftype': ''}};
  final Map<int, Map<String, String>> bufKeymaps = {};
  final Map<int, List<Map<String, Object?>>> bufExtmarks = {};
  final Set<int> validWins = {1};
  final Map<int, int> winBufs = {1: 1};
  final Map<int, Map<String, Object?>> winConfigs = {};
  final Map<int, Map<String, Object?>> winOptions = {};
  final Map<int, (int, int)> cursors = {1: (1, 0)};
  final List<String> notifications = [];
  final List<String> commands = [];
  final List<String> luaScripts = [];
  final Map<String, String> registers = {};
  List<Map<String, Object?>> rawDiagnostics = [];
  int currentWin = 1;

  _FakeNvimServer() {
    serverSession = RpcSession(
      input: _fromClient.stream,
      output: (Uint8List b) => _toClient.add(b),
    );
    clientSession = RpcSession(
      input: _toClient.stream,
      output: (Uint8List b) => _fromClient.add(b),
    );
    serverSession.onRequest = _handleRequest;
  }

  Future<Object?> _handleRequest(String method, List<Object?> params) async {
    switch (method) {
      case 'nvim_create_namespace':
        return 1;
      case 'nvim_set_hl':
        return null;
      case 'nvim_create_buf':
        final id = _nextBuf++;
        bufLines[id] = [];
        bufOptions[id] = {};
        bufKeymaps[id] = {};
        bufExtmarks[id] = [];
        return MsgpackExt(0, MsgpackCodec.encode(id));
      case 'nvim_buf_is_valid':
        return bufLines.containsKey(params[0] as int);
      case 'nvim_buf_set_lines':
        final buf = params[0] as int;
        final lines = (params[4] as List).map((e) => e.toString()).toList();
        bufLines[buf] = lines;
        return null;
      case 'nvim_buf_get_lines':
        final buf = params[0] as int;
        return bufLines[buf] ?? const <String>[];
      case 'nvim_set_option_value':
        final name = params[0].toString();
        final value = params[1];
        final opts = (params[2] as Map).cast<String, Object?>();
        if (opts.containsKey('win')) {
          final win = opts['win'] as int;
          winOptions.putIfAbsent(win, () => {})[name] = value;
        } else if (opts.containsKey('buf')) {
          final buf = opts['buf'] as int;
          bufOptions.putIfAbsent(buf, () => {})[name] = value;
        }
        return null;
      case 'nvim_get_option_value':
        final name = params[0].toString();
        final opts = (params[1] as Map).cast<String, Object?>();
        if (name == 'columns') return 120;
        if (name == 'lines') return 40;
        if (opts.containsKey('buf')) {
          final buf = opts['buf'] as int;
          return bufOptions[buf]?[name];
        }
        return null;
      case 'nvim_buf_set_keymap':
        final buf = params[0] as int;
        final lhs = params[2].toString();
        final rhs = params[3].toString();
        bufKeymaps.putIfAbsent(buf, () => {})[lhs] = rhs;
        return null;
      case 'nvim_buf_clear_namespace':
        final buf = params[0] as int;
        bufExtmarks[buf] = [];
        return null;
      case 'nvim_buf_set_extmark':
        final buf = params[0] as int;
        final line = params[2] as int;
        final col = params[3] as int;
        final opts = (params[4] as Map).cast<String, Object?>();
        bufExtmarks.putIfAbsent(buf, () => []).add({
          'line': line,
          'col': col,
          ...opts,
        });
        return 1;
      case 'nvim_open_win':
        final buf = params[0] as int;
        final enter = params[1] as bool;
        final config = (params[2] as Map).cast<String, Object?>();
        final win = _nextWin++;
        validWins.add(win);
        winBufs[win] = buf;
        winConfigs[win] = config;
        cursors[win] = (1, 0);
        if (enter) {
          currentWin = win;
        }
        return MsgpackExt(1, MsgpackCodec.encode(win));
      case 'nvim_win_is_valid':
        return validWins.contains(params[0] as int);
      case 'nvim_win_close':
        validWins.remove(params[0] as int);
        winBufs.remove(params[0] as int);
        return null;
      case 'nvim_win_get_config':
        return winConfigs[params[0] as int] ?? const <String, Object?>{};
      case 'nvim_win_get_buf':
        return winBufs[params[0] as int] ?? 0;
      case 'nvim_win_get_cursor':
        final win = params[0] as int;
        final c = cursors[win] ?? (1, 0);
        return [c.$1, c.$2];
      case 'nvim_win_set_cursor':
        final win = params[0] as int;
        final pos = params[1] as List;
        cursors[win] = (pos[0] as int, pos[1] as int);
        return null;
      case 'nvim_set_current_win':
        currentWin = params[0] as int;
        return null;
      case 'nvim_get_current_win':
        return currentWin;
      case 'nvim_list_wins':
        return validWins.toList();
      case 'nvim_buf_get_name':
        return '$cwd/lib/main.dart';
      case 'nvim_exec_lua':
        final code = params[0].toString();
        luaScripts.add(code);
        if (code.contains('vim.diagnostic.get')) {
          return rawDiagnostics;
        }
        return null;
      case 'nvim_call_function':
        final fn = params[0].toString();
        if (fn == 'getcwd') return cwd;
        if (fn == 'setreg') {
          final args = params[1] as List;
          registers[args[0].toString()] = args[1].toString();
        }
        return null;
      case 'nvim_notify':
        notifications.add(params[0].toString());
        return null;
      case 'nvim_command':
        commands.add(params[0].toString());
        return null;
      default:
        return null;
    }
  }

  Future<void> dispose() async {
    await clientSession.close();
    await serverSession.close();
    await _toClient.close();
    await _fromClient.close();
  }
}

void main() {
  group('ProblemsPanel', () {
    test('opens panel, renders diagnostics, jumps to editor on <CR>, opens detail popup, and triggers code actions', () async {
      final server = _FakeNvimServer();
      server.rawDiagnostics = [
        {
          'file': '/workspace/lib/main.dart',
          'bufnr': 1,
          'lnum': 14,
          'col': 6,
          'end_lnum': 14,
          'end_col': 12,
          'severity': 1,
          'message': 'Undefined name "bar"\nCheck imports.',
          'source': 'dart',
          'code': 'undefined_identifier',
        },
      ];

      final panel = ProblemsPanel(nvim: Nvim(server.clientSession));
      await panel.open();

      expect(await panel.isOpen(), isTrue);
      expect(panel.errorCount, 1);

      final panelWin = panel.windowId!;
      final panelBuf = panel.bufferId!;
      final lines = server.bufLines[panelBuf]!;
      // Line 0: toolbar, Line 1: divider, Line 2: file node, Line 3: diagnostic node
      expect(lines.length, 4);
      expect(lines[2], contains('lib/main.dart'));
      expect(lines[3], contains('[14:7] Undefined name "bar" [+1 lines]  dart (undefined_identifier)'));

      // 1. Press <CR> on diagnostic row (row 4, 1-based) -> jumps to editor window 1 at (14, 6)
      server.cursors[panelWin] = (4, 0);
      await panel.handleAction('problems.enter');
      expect(server.currentWin, 1);
      expect(server.commands, contains('edit /workspace/lib/main.dart'));
      expect(server.cursors[1], (14, 6));

      // 2. Open detail popup on diagnostic row
      server.currentWin = panelWin;
      server.cursors[panelWin] = (4, 0);
      await panel.handleAction('problems.detail');
      expect(panel.detailPopup.isOpen, isTrue);
      final popupBuf = panel.detailPopup.bufferId!;
      expect(
        server.bufLines[popupBuf]!.join('\n'),
        contains('Check imports.'),
      );

      // Trigger copy from detail popup
      await panel.handleAction('problems.detail_copy');
      expect(panel.detailPopup.isOpen, isFalse);
      expect(server.registers['"'], 'Undefined name "bar"\nCheck imports.');

      // 3. Trigger code action on diagnostic row
      server.luaScripts.clear();
      server.cursors[panelWin] = (4, 0);
      await panel.handleAction('problems.code_action');
      expect(
        server.luaScripts.any((s) => s.contains('vim.lsp.buf.code_action()')),
        isTrue,
      );

      // 4. Click toolbar scope pill to toggle scope
      final toolbar = panel.renderedTree!.nodes.first as ProblemsToolbarNode;
      server.cursors[panelWin] = (1, toolbar.scopeColStart + 1);
      await panel.handleAction('problems.click');
      expect(panel.treeState.scope, ProblemsScope.currentBuffer);

      // 5. Click toolbar Error filter pill to toggle Error filter
      final updatedToolbar = panel.renderedTree!.nodes.first as ProblemsToolbarNode;
      final errPill = updatedToolbar.filterPillCols[DiagnosticSeverity.error]!;
      server.cursors[panelWin] = (1, errPill.$1 + 1);
      await panel.handleAction('problems.click');
      expect(panel.treeState.isSeverityEnabled(DiagnosticSeverity.error), isFalse);

      await server.dispose();
    });
  });
}
