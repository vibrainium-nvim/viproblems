import 'package:nvim/nvim.dart';
import 'package:visettings/visettings.dart';

/// Neovim diagnostic severity (`vim.diagnostic.severity`).
enum DiagnosticSeverity {
  error(1, 'Error', 'E', '󰅚', 'ViproblemsError'),
  warn(2, 'Warning', 'W', '󰀪', 'ViproblemsWarn'),
  info(3, 'Info', 'I', '󰋽', 'ViproblemsInfo'),
  hint(4, 'Hint', 'H', '󰌶', 'ViproblemsHint');

  final int level;
  final String label;
  final String shortCode;
  final String icon;
  final String highlightGroup;

  const DiagnosticSeverity(
    this.level,
    this.label,
    this.shortCode,
    this.icon,
    this.highlightGroup,
  );

  static DiagnosticSeverity fromLevel(int? rawLevel) {
    return switch (rawLevel) {
      1 => DiagnosticSeverity.error,
      2 => DiagnosticSeverity.warn,
      3 => DiagnosticSeverity.info,
      4 => DiagnosticSeverity.hint,
      _ => DiagnosticSeverity.error,
    };
  }
}

/// A single diagnostic item retrieved from Neovim's `vim.diagnostic.get()`.
class DiagnosticItem {
  final String filePath;
  final String relativePath;
  final int bufnr;
  final int lnum; // 1-based line number
  final int col; // 0-based column number
  final int endLnum; // 1-based end line number
  final int endCol; // 0-based end column number
  final DiagnosticSeverity severity;
  final String message;
  final String? source;
  final String? code;

  const DiagnosticItem({
    required this.filePath,
    required this.relativePath,
    this.bufnr = 0,
    required this.lnum,
    required this.col,
    int? endLnum,
    int? endCol,
    required this.severity,
    required this.message,
    this.source,
    this.code,
  })  : endLnum = endLnum ?? lnum,
        endCol = endCol ?? col;

  /// First line of [message], trimmed for compact single-line display.
  String get firstLineMessage {
    final lines = message.split('\n');
    return lines.first.trim();
  }

  /// Number of additional lines beyond the first line (`0` if single-line).
  int get extraLineCount {
    final lines = message.split('\n');
    return lines.length > 1 ? lines.length - 1 : 0;
  }

  /// Formatted source and code suffix, e.g. `dart (undefined_identifier)` or `dart`.
  String get sourceTag {
    final s = source?.trim() ?? '';
    final c = code?.trim() ?? '';
    if (s.isNotEmpty && c.isNotEmpty) return '$s ($c)';
    if (s.isNotEmpty) return s;
    if (c.isNotEmpty) return '($c)';
    return '';
  }
}

/// Fetches diagnostics from Neovim via `vim.diagnostic.get()`.
class DiagnosticsProvider {
  static const String _luaFetchDiagnostics = r'''
local raw = vim.diagnostic.get(nil)
local out = {}
local buf_names = {}

for _, d in ipairs(raw) do
  local bufnr = d.bufnr or 0
  local fname = buf_names[bufnr]
  if fname == nil then
    if bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
      fname = vim.api.nvim_buf_get_name(bufnr) or ''
    else
      fname = ''
    end
    buf_names[bufnr] = fname
  end

  if fname ~= '' then
    local code_str = ''
    if d.code ~= nil then
      code_str = tostring(d.code)
    elseif d.user_data and type(d.user_data) == 'table' and d.user_data.lsp and d.user_data.lsp.code ~= nil then
      code_str = tostring(d.user_data.lsp.code)
    end
    table.insert(out, {
      file = fname,
      bufnr = bufnr,
      lnum = (d.lnum or 0) + 1,
      col = d.col or 0,
      end_lnum = (d.end_lnum or d.lnum or 0) + 1,
      end_col = d.end_col or d.col or 0,
      severity = d.severity or 1,
      message = d.message or '',
      source = d.source or '',
      code = code_str,
    })
  end
end

return out
''';

  const DiagnosticsProvider();

  /// Normalizes [path] to forward slashes without trailing slash.
  static String normalizePath(String path) {
    var norm = path.replaceAll(r'\', '/');
    while (norm.endsWith('/') && norm.length > 1) {
      norm = norm.substring(0, norm.length - 1);
    }
    return norm;
  }

  /// Computes a path relative to [workspaceRoot] when inside [workspaceRoot].
  static String toRelativePath(String workspaceRoot, String fullPath) {
    final normRoot = normalizePath(workspaceRoot);
    final normFull = normalizePath(fullPath);
    if (normFull == normRoot) return '';
    if (normFull.startsWith('$normRoot/')) {
      return normFull.substring(normRoot.length + 1);
    }
    return normFull;
  }

  /// Extracts the file basename from [path].
  static String basename(String path) {
    final norm = normalizePath(path);
    final idx = norm.lastIndexOf('/');
    return idx == -1 ? norm : norm.substring(idx + 1);
  }

  /// Queries Neovim for all active diagnostics across loaded buffers.
  Future<List<DiagnosticItem>> fetchAll({
    required Nvim nvim,
    required String workspaceRoot,
    VibrainiumSettings settings = const VibrainiumSettings(),
  }) async {
    Object? raw;
    try {
      raw = await nvim.execLua(_luaFetchDiagnostics);
    } catch (_) {
      return const [];
    }

    if (raw is! List) return const [];

    final normRoot = normalizePath(workspaceRoot);
    final results = <DiagnosticItem>[];

    for (final entry in raw) {
      if (entry is! Map) continue;
      final rawFile = entry['file']?.toString() ?? '';
      if (rawFile.isEmpty) continue;

      final filePath = normalizePath(rawFile);
      final relPath = toRelativePath(normRoot, filePath);
      final name = basename(filePath);

      if (relPath != filePath &&
          settings.isWorkspaceExcluded(
            relPath,
            name: name,
            isDirectory: false,
          )) {
        continue;
      }

      final bufnr = (entry['bufnr'] as num?)?.toInt() ?? 0;
      final lnum = ((entry['lnum'] as num?)?.toInt() ?? 1).clamp(1, 10000000);
      final col = ((entry['col'] as num?)?.toInt() ?? 0).clamp(0, 10000000);
      final endLnum =
          ((entry['end_lnum'] as num?)?.toInt() ?? lnum).clamp(1, 10000000);
      final endCol =
          ((entry['end_col'] as num?)?.toInt() ?? col).clamp(0, 10000000);
      final severityLevel = (entry['severity'] as num?)?.toInt() ?? 1;
      final message = entry['message']?.toString() ?? '';
      if (message.trim().isEmpty) continue;

      final sourceRaw = entry['source']?.toString().trim() ?? '';
      final codeRaw = entry['code']?.toString().trim() ?? '';

      results.add(
        DiagnosticItem(
          filePath: filePath,
          relativePath: relPath.isEmpty ? name : relPath,
          bufnr: bufnr,
          lnum: lnum,
          col: col,
          endLnum: endLnum,
          endCol: endCol,
          severity: DiagnosticSeverity.fromLevel(severityLevel),
          message: message,
          source: sourceRaw.isEmpty ? null : sourceRaw,
          code: codeRaw.isEmpty ? null : codeRaw,
        ),
      );
    }

    return results;
  }
}
