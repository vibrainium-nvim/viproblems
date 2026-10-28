import 'dart:convert';

import '../diagnostics.dart';

/// Scope filter for the `viproblems` panel.
enum ProblemsScope {
  workspace('Workspace'),
  currentBuffer('Current Buffer');

  final String label;
  const ProblemsScope(this.label);
}

/// Sealed node hierarchy for rows in the rendered `viproblems` buffer.
sealed class ProblemsNode {
  const ProblemsNode();
}

/// Top interactive toolbar row showing severity totals, active scope, and filter pills.
class ProblemsToolbarNode extends ProblemsNode {
  final int errorCount;
  final int warnCount;
  final int infoCount;
  final int hintCount;
  final ProblemsScope scope;
  final Set<DiagnosticSeverity> enabledSeverities;
  final int scopeColStart;
  final int scopeColEnd;
  final Map<DiagnosticSeverity, (int, int)> filterPillCols;

  const ProblemsToolbarNode({
    required this.errorCount,
    required this.warnCount,
    required this.infoCount,
    required this.hintCount,
    required this.scope,
    required this.enabledSeverities,
    required this.scopeColStart,
    required this.scopeColEnd,
    required this.filterPillCols,
  });
}

/// Horizontal divider line separating the toolbar from the diagnostic tree.
class ProblemsDividerNode extends ProblemsNode {
  const ProblemsDividerNode();
}

/// Collapsible file header grouping diagnostics for a single file.
class ProblemsFileNode extends ProblemsNode {
  final String filePath;
  final String relativePath;
  final bool expanded;
  final int errorCount;
  final int warnCount;
  final int infoCount;
  final int hintCount;
  final List<DiagnosticItem> diagnostics;

  const ProblemsFileNode({
    required this.filePath,
    required this.relativePath,
    required this.expanded,
    required this.errorCount,
    required this.warnCount,
    required this.infoCount,
    required this.hintCount,
    required this.diagnostics,
  });
}

/// A single diagnostic row inside an expanded [ProblemsFileNode].
class ProblemsDiagnosticNode extends ProblemsNode {
  final DiagnosticItem diagnostic;

  const ProblemsDiagnosticNode(this.diagnostic);
}

/// Empty state row displayed when no diagnostics match the active filters.
class ProblemsEmptyNode extends ProblemsNode {
  final String text;
  const ProblemsEmptyNode(this.text);
}

/// Byte-indexed highlight span on a single buffer line.
class ProblemsHighlightSpan {
  final int line;
  final int colStart;
  final int colEnd;
  final String group;

  const ProblemsHighlightSpan({
    required this.line,
    required this.colStart,
    required this.colEnd,
    required this.group,
  });
}

/// Output of [ProblemsTreeState.build].
class RenderedProblemsTree {
  final List<String> lines;
  final List<ProblemsNode> nodes;
  final List<ProblemsHighlightSpan> highlights;
  final int totalErrors;
  final int totalWarnings;
  final int totalInfos;
  final int totalHints;

  const RenderedProblemsTree({
    required this.lines,
    required this.nodes,
    required this.highlights,
    required this.totalErrors,
    required this.totalWarnings,
    required this.totalInfos,
    required this.totalHints,
  });
}

/// Stateful tree builder and filter manager for the `viproblems` panel.
class ProblemsTreeState {
  final Set<String> collapsedFiles = {};
  final Set<DiagnosticSeverity> enabledSeverities = {
    DiagnosticSeverity.error,
    DiagnosticSeverity.warn,
    DiagnosticSeverity.info,
    DiagnosticSeverity.hint,
  };
  ProblemsScope scope = ProblemsScope.workspace;

  static const Map<String, String> _fileIcons = {
    'dart': '',
    'lua': '',
    'md': '',
    'json': '',
    'yaml': '',
    'yml': '',
    'toml': '',
    'sh': '',
    'zsh': '',
    'bash': '',
    'py': '',
    'rs': '',
    'go': '',
    'js': '',
    'ts': '',
    'html': '',
    'css': '',
    'c': '',
    'cpp': '',
    'h': '',
  };

  bool isFileExpanded(String filePath) =>
      !collapsedFiles.contains(DiagnosticsProvider.normalizePath(filePath));

  void toggleFile(String filePath) {
    final norm = DiagnosticsProvider.normalizePath(filePath);
    if (!collapsedFiles.remove(norm)) {
      collapsedFiles.add(norm);
    }
  }

  void collapseAll(Iterable<String> filePaths) {
    for (final p in filePaths) {
      collapsedFiles.add(DiagnosticsProvider.normalizePath(p));
    }
  }

  void expandAll() {
    collapsedFiles.clear();
  }

  bool isSeverityEnabled(DiagnosticSeverity severity) =>
      enabledSeverities.contains(severity);

  void toggleSeverity(DiagnosticSeverity severity) {
    if (!enabledSeverities.remove(severity)) {
      enabledSeverities.add(severity);
    }
  }

  void enableAllSeverities() {
    enabledSeverities.addAll(DiagnosticSeverity.values);
  }

  void toggleScope() {
    scope = scope == ProblemsScope.workspace
        ? ProblemsScope.currentBuffer
        : ProblemsScope.workspace;
  }

  static String iconForFile(String path) {
    final name = DiagnosticsProvider.basename(path);
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx > 0 && dotIdx < name.length - 1) {
      final ext = name.substring(dotIdx + 1).toLowerCase();
      final match = _fileIcons[ext];
      if (match != null) return match;
    }
    return '󰈙';
  }

  /// Builds the flattened [RenderedProblemsTree] from [diagnostics].
  RenderedProblemsTree build({
    required List<DiagnosticItem> diagnostics,
    String? currentBufferPath,
    int width = 80,
  }) {
    final lines = <String>[];
    final nodes = <ProblemsNode>[];
    final highlights = <ProblemsHighlightSpan>[];

    void addLine(
      String text,
      ProblemsNode node, [
      List<(int, int, String)> lineHighlights = const [],
    ]) {
      final lineIdx = lines.length;
      lines.add(text);
      nodes.add(node);
      for (final (start, end, group) in lineHighlights) {
        highlights.add(
          ProblemsHighlightSpan(
            line: lineIdx,
            colStart: start,
            colEnd: end,
            group: group,
          ),
        );
      }
    }

    // 1. Filter by scope first so summary counts reflect active scope
    final normCurrentBuf = currentBufferPath == null || currentBufferPath.isEmpty
        ? null
        : DiagnosticsProvider.normalizePath(currentBufferPath);

    final scopedDiagnostics = scope == ProblemsScope.currentBuffer
        ? (normCurrentBuf == null
            ? const <DiagnosticItem>[]
            : diagnostics
                .where(
                  (d) =>
                      DiagnosticsProvider.normalizePath(d.filePath) ==
                      normCurrentBuf,
                )
                .toList())
        : diagnostics;

    var totalErrors = 0;
    var totalWarnings = 0;
    var totalInfos = 0;
    var totalHints = 0;
    for (final d in scopedDiagnostics) {
      switch (d.severity) {
        case DiagnosticSeverity.error:
          totalErrors++;
        case DiagnosticSeverity.warn:
          totalWarnings++;
        case DiagnosticSeverity.info:
          totalInfos++;
        case DiagnosticSeverity.hint:
          totalHints++;
      }
    }

    // 2. Build top toolbar line
    final errPart = ' 󰅚 $totalErrors ';
    final warnPart = ' 󰀪 $totalWarnings ';
    final infoPart = ' 󰋽 $totalInfos ';
    final hintPart = ' 󰌶 $totalHints ';
    const sep1 = ' │ ';
    final scopeLabel = 'Scope: [${scope.label} ▾]';
    const sep2 = ' │ Filter: ';

    final prefixBeforeFilters =
        '$errPart$warnPart$infoPart$hintPart$sep1$scopeLabel$sep2';

    final toolbarHighlights = <(int, int, String)>[];
    var cursorBytes = 0;

    final errBytes = _byteLen(errPart);
    toolbarHighlights.add((
      cursorBytes,
      cursorBytes + errBytes,
      totalErrors > 0 ? 'ViproblemsError' : 'ViproblemsMuted',
    ));
    cursorBytes += errBytes;

    final warnBytes = _byteLen(warnPart);
    toolbarHighlights.add((
      cursorBytes,
      cursorBytes + warnBytes,
      totalWarnings > 0 ? 'ViproblemsWarn' : 'ViproblemsMuted',
    ));
    cursorBytes += warnBytes;

    final infoBytes = _byteLen(infoPart);
    toolbarHighlights.add((
      cursorBytes,
      cursorBytes + infoBytes,
      totalInfos > 0 ? 'ViproblemsInfo' : 'ViproblemsMuted',
    ));
    cursorBytes += infoBytes;

    final hintBytes = _byteLen(hintPart);
    toolbarHighlights.add((
      cursorBytes,
      cursorBytes + hintBytes,
      totalHints > 0 ? 'ViproblemsHint' : 'ViproblemsMuted',
    ));
    cursorBytes += hintBytes;

    final sep1Bytes = _byteLen(sep1);
    toolbarHighlights.add((
      cursorBytes,
      cursorBytes + sep1Bytes,
      'ViproblemsDivider',
    ));
    cursorBytes += sep1Bytes;

    final scopeStartByte = cursorBytes;
    final scopeBytes = _byteLen(scopeLabel);
    final scopeEndByte = scopeStartByte + scopeBytes;
    toolbarHighlights.add((
      scopeStartByte,
      scopeEndByte,
      'ViproblemsHeader',
    ));
    cursorBytes = scopeEndByte;

    final sep2Bytes = _byteLen(sep2);
    toolbarHighlights.add((
      cursorBytes,
      cursorBytes + sep2Bytes,
      'ViproblemsMuted',
    ));
    cursorBytes += sep2Bytes;

    final filterPillsBuf = StringBuffer();
    final filterPillCols = <DiagnosticSeverity, (int, int)>{};

    for (var i = 0; i < DiagnosticSeverity.values.length; i++) {
      final sev = DiagnosticSeverity.values[i];
      final active = enabledSeverities.contains(sev);
      final check = active ? '✓' : '·';
      final pill = '[${sev.shortCode}$check]';
      final pillBytes = _byteLen(pill);
      final startCol = cursorBytes;
      final endCol = startCol + pillBytes;
      filterPillCols[sev] = (startCol, endCol);
      toolbarHighlights.add((
        startCol,
        endCol,
        active ? sev.highlightGroup : 'ViproblemsMuted',
      ));
      filterPillsBuf.write(pill);
      cursorBytes = endCol;
      if (i < DiagnosticSeverity.values.length - 1) {
        filterPillsBuf.write(' ');
        cursorBytes += 1;
      }
    }

    final toolbarLine = '$prefixBeforeFilters$filterPillsBuf';
    addLine(
      toolbarLine,
      ProblemsToolbarNode(
        errorCount: totalErrors,
        warnCount: totalWarnings,
        infoCount: totalInfos,
        hintCount: totalHints,
        scope: scope,
        enabledSeverities: Set.unmodifiable(enabledSeverities),
        scopeColStart: scopeStartByte,
        scopeColEnd: scopeEndByte,
        filterPillCols: filterPillCols,
      ),
      toolbarHighlights,
    );

    final dividerWidth = width > 12 ? width : 80;
    final divider = '─' * dividerWidth;
    addLine(
      divider,
      const ProblemsDividerNode(),
      [(0, _byteLen(divider), 'ViproblemsDivider')],
    );

    // 3. Filter by enabled severities
    final filtered = scopedDiagnostics
        .where((d) => enabledSeverities.contains(d.severity))
        .toList();

    if (filtered.isEmpty) {
      final emptyMsg = scopedDiagnostics.isEmpty
          ? '  ✓ No problems found'
          : '  (No problems matching active severity filters — press 0 to reset)';
      addLine(
        emptyMsg,
        ProblemsEmptyNode(emptyMsg),
        [(0, _byteLen(emptyMsg), 'ViproblemsMuted')],
      );
      return RenderedProblemsTree(
        lines: lines,
        nodes: nodes,
        highlights: highlights,
        totalErrors: totalErrors,
        totalWarnings: totalWarnings,
        totalInfos: totalInfos,
        totalHints: totalHints,
      );
    }

    // 4. Group diagnostics by normalized filePath
    final byFile = <String, List<DiagnosticItem>>{};
    for (final item in filtered) {
      final norm = DiagnosticsProvider.normalizePath(item.filePath);
      byFile.putIfAbsent(norm, () => []).add(item);
    }

    final fileGroups = <_FileGroup>[];
    for (final entry in byFile.entries) {
      final items = entry.value
        ..sort((a, b) {
          final lineCmp = a.lnum.compareTo(b.lnum);
          if (lineCmp != 0) return lineCmp;
          final colCmp = a.col.compareTo(b.col);
          if (colCmp != 0) return colCmp;
          return a.severity.level.compareTo(b.severity.level);
        });

      var errs = 0;
      var warns = 0;
      var infos = 0;
      var hints = 0;
      var minSeverityLevel = 99;
      for (final d in items) {
        if (d.severity.level < minSeverityLevel) {
          minSeverityLevel = d.severity.level;
        }
        switch (d.severity) {
          case DiagnosticSeverity.error:
            errs++;
          case DiagnosticSeverity.warn:
            warns++;
          case DiagnosticSeverity.info:
            infos++;
          case DiagnosticSeverity.hint:
            hints++;
        }
      }

      fileGroups.add(
        _FileGroup(
          filePath: entry.key,
          relativePath: items.first.relativePath,
          items: items,
          errors: errs,
          warnings: warns,
          infos: infos,
          hints: hints,
          minSeverityLevel: minSeverityLevel,
        ),
      );
    }

    // Sort files by highest severity first (error > warn > info > hint),
    // then by error count descending, then alphabetically by relativePath.
    fileGroups.sort((a, b) {
      final sevCmp = a.minSeverityLevel.compareTo(b.minSeverityLevel);
      if (sevCmp != 0) return sevCmp;
      final errCmp = b.errors.compareTo(a.errors);
      if (errCmp != 0) return errCmp;
      final warnCmp = b.warnings.compareTo(a.warnings);
      if (warnCmp != 0) return warnCmp;
      return a.relativePath.compareTo(b.relativePath);
    });

    // 5. Render each file group and its diagnostics
    for (final group in fileGroups) {
      final expanded = isFileExpanded(group.filePath);
      final chevron = expanded ? '▾' : '▸';
      final icon = iconForFile(group.relativePath);
      final headerMain = ' $chevron $icon ${group.relativePath}';
      final headerMainBytes = _byteLen(headerMain);

      final fileSpans = <(int, int, String)>[
        (0, headerMainBytes, 'ViproblemsFileHeader'),
      ];

      final badgesBuf = StringBuffer();
      var badgeOffset = headerMainBytes;

      void appendBadge(int count, DiagnosticSeverity sev) {
        if (count <= 0) return;
        final text = '  ${sev.icon} $count';
        final bLen = _byteLen(text);
        fileSpans.add((badgeOffset, badgeOffset + bLen, sev.highlightGroup));
        badgesBuf.write(text);
        badgeOffset += bLen;
      }

      appendBadge(group.errors, DiagnosticSeverity.error);
      appendBadge(group.warnings, DiagnosticSeverity.warn);
      appendBadge(group.infos, DiagnosticSeverity.info);
      appendBadge(group.hints, DiagnosticSeverity.hint);

      final fileLine = '$headerMain$badgesBuf';
      addLine(
        fileLine,
        ProblemsFileNode(
          filePath: group.filePath,
          relativePath: group.relativePath,
          expanded: expanded,
          errorCount: group.errors,
          warnCount: group.warnings,
          infoCount: group.infos,
          hintCount: group.hints,
          diagnostics: List.unmodifiable(group.items),
        ),
        fileSpans,
      );

      if (!expanded) continue;

      for (final diag in group.items) {
        const indent = '    ';
        final iconStr = '${diag.severity.icon} ';
        final posStr = '[${diag.lnum}:${diag.col + 1}] ';
        final msgStr = diag.firstLineMessage;
        final extraLines = diag.extraLineCount;
        final extraStr = extraLines > 0 ? ' [+$extraLines lines]' : '';
        final srcTag = diag.sourceTag;
        final srcStr = srcTag.isNotEmpty ? '  $srcTag' : '';

        final fullLine = '$indent$iconStr$posStr$msgStr$extraStr$srcStr';

        final indentBytes = _byteLen(indent);
        final iconBytes = _byteLen(iconStr);
        final posBytes = _byteLen(posStr);
        final msgBytes = _byteLen(msgStr);
        final extraBytes = _byteLen(extraStr);
        final srcBytes = _byteLen(srcStr);

        final diagSpans = <(int, int, String)>[
          (
            indentBytes,
            indentBytes + iconBytes,
            diag.severity.highlightGroup,
          ),
          (
            indentBytes + iconBytes,
            indentBytes + iconBytes + posBytes,
            'ViproblemsLocation',
          ),
        ];

        final afterMsg = indentBytes + iconBytes + posBytes + msgBytes;
        if (extraBytes > 0) {
          diagSpans.add((
            afterMsg,
            afterMsg + extraBytes,
            'ViproblemsSource',
          ));
        }
        if (srcBytes > 0) {
          diagSpans.add((
            afterMsg + extraBytes,
            afterMsg + extraBytes + srcBytes,
            'ViproblemsMuted',
          ));
        }

        addLine(fullLine, ProblemsDiagnosticNode(diag), diagSpans);
      }
    }

    return RenderedProblemsTree(
      lines: lines,
      nodes: nodes,
      highlights: highlights,
      totalErrors: totalErrors,
      totalWarnings: totalWarnings,
      totalInfos: totalInfos,
      totalHints: totalHints,
    );
  }

  static int _byteLen(String s) => utf8.encode(s).length;
}

class _FileGroup {
  final String filePath;
  final String relativePath;
  final List<DiagnosticItem> items;
  final int errors;
  final int warnings;
  final int infos;
  final int hints;
  final int minSeverityLevel;

  const _FileGroup({
    required this.filePath,
    required this.relativePath,
    required this.items,
    required this.errors,
    required this.warnings,
    required this.infos,
    required this.hints,
    required this.minSeverityLevel,
  });
}
