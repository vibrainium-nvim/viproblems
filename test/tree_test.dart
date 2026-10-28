import 'package:test/test.dart';
import 'package:viproblems/viproblems.dart';

void main() {
  group('ProblemsTreeState', () {
    final sampleDiagnostics = <DiagnosticItem>[
      const DiagnosticItem(
        filePath: '/workspace/lib/b.dart',
        relativePath: 'lib/b.dart',
        lnum: 20,
        col: 4,
        severity: DiagnosticSeverity.warn,
        message: 'Unused local variable "x"',
        source: 'dart',
        code: 'unused_local_variable',
      ),
      const DiagnosticItem(
        filePath: '/workspace/lib/a.dart',
        relativePath: 'lib/a.dart',
        lnum: 12,
        col: 2,
        severity: DiagnosticSeverity.error,
        message: "Undefined name 'foo'\nTry correcting the name to one that is defined.",
        source: 'dart',
        code: 'undefined_identifier',
      ),
      const DiagnosticItem(
        filePath: '/workspace/lib/a.dart',
        relativePath: 'lib/a.dart',
        lnum: 5,
        col: 0,
        severity: DiagnosticSeverity.hint,
        message: 'Prefer const with constant constructors',
        source: 'dart',
        code: 'prefer_const_constructors',
      ),
    ];

    test('groups by file, sorts files by highest severity, and sorts diagnostics by line/col', () {
      final state = ProblemsTreeState();
      final rendered = state.build(diagnostics: sampleDiagnostics, width: 80);

      expect(rendered.totalErrors, 1);
      expect(rendered.totalWarnings, 1);
      expect(rendered.totalInfos, 0);
      expect(rendered.totalHints, 1);

      // Node 0: Toolbar, Node 1: Divider
      expect(rendered.nodes[0], isA<ProblemsToolbarNode>());
      expect(rendered.nodes[1], isA<ProblemsDividerNode>());

      // Node 2: lib/a.dart comes first because it has an Error (severity 1 < warn 2)
      final fileA = rendered.nodes[2] as ProblemsFileNode;
      expect(fileA.relativePath, 'lib/a.dart');
      expect(fileA.errorCount, 1);
      expect(fileA.hintCount, 1);
      expect(fileA.expanded, isTrue);

      // Diagnostics in lib/a.dart are sorted by lnum (line 5 before line 12)
      final diagA1 = rendered.nodes[3] as ProblemsDiagnosticNode;
      expect(diagA1.diagnostic.lnum, 5);
      expect(diagA1.diagnostic.severity, DiagnosticSeverity.hint);

      final diagA2 = rendered.nodes[4] as ProblemsDiagnosticNode;
      expect(diagA2.diagnostic.lnum, 12);
      expect(diagA2.diagnostic.severity, DiagnosticSeverity.error);
      expect(rendered.lines[4], contains("Undefined name 'foo'"));
      expect(rendered.lines[4], contains('[+1 lines]'));
      expect(rendered.lines[4], contains('dart (undefined_identifier)'));

      // Node 5: lib/b.dart
      final fileB = rendered.nodes[5] as ProblemsFileNode;
      expect(fileB.relativePath, 'lib/b.dart');
      expect(fileB.warnCount, 1);

      final diagB1 = rendered.nodes[6] as ProblemsDiagnosticNode;
      expect(diagB1.diagnostic.lnum, 20);
    });

    test('collapsing and expanding file nodes hides and restores diagnostic rows', () {
      final state = ProblemsTreeState();
      state.toggleFile('/workspace/lib/a.dart');
      expect(state.isFileExpanded('/workspace/lib/a.dart'), isFalse);

      final rendered = state.build(diagnostics: sampleDiagnostics);
      final fileNodes = rendered.nodes.whereType<ProblemsFileNode>().toList();
      expect(fileNodes.length, 2);
      expect(fileNodes.first.relativePath, 'lib/a.dart');
      expect(fileNodes.first.expanded, isFalse);

      // Only lib/b.dart's diagnostic row should be visible
      final diagNodes =
          rendered.nodes.whereType<ProblemsDiagnosticNode>().toList();
      expect(diagNodes.length, 1);
      expect(diagNodes.single.diagnostic.relativePath, 'lib/b.dart');

      state.collapseAll(sampleDiagnostics.map((d) => d.filePath));
      final allCollapsed = state.build(diagnostics: sampleDiagnostics);
      expect(
        allCollapsed.nodes.whereType<ProblemsDiagnosticNode>(),
        isEmpty,
      );

      state.expandAll();
      final allExpanded = state.build(diagnostics: sampleDiagnostics);
      expect(
        allExpanded.nodes.whereType<ProblemsDiagnosticNode>().length,
        3,
      );
    });

    test('filters diagnostics by severity and shows filter hint when all filtered out', () {
      final state = ProblemsTreeState();
      state.toggleSeverity(DiagnosticSeverity.warn);
      state.toggleSeverity(DiagnosticSeverity.hint);

      final rendered = state.build(diagnostics: sampleDiagnostics);
      final diagNodes =
          rendered.nodes.whereType<ProblemsDiagnosticNode>().toList();
      expect(diagNodes.length, 1);
      expect(diagNodes.single.diagnostic.severity, DiagnosticSeverity.error);

      // Disable error too -> no matching diagnostics
      state.toggleSeverity(DiagnosticSeverity.error);
      final emptyFiltered = state.build(diagnostics: sampleDiagnostics);
      expect(emptyFiltered.nodes.last, isA<ProblemsEmptyNode>());
      expect(
        emptyFiltered.lines.last,
        contains('No problems matching active severity filters'),
      );

      // Reset all filters
      state.enableAllSeverities();
      final restored = state.build(diagnostics: sampleDiagnostics);
      expect(
        restored.nodes.whereType<ProblemsDiagnosticNode>().length,
        3,
      );
    });

    test('filters by Current Buffer scope', () {
      final state = ProblemsTreeState();
      state.toggleScope();
      expect(state.scope, ProblemsScope.currentBuffer);

      final rendered = state.build(
        diagnostics: sampleDiagnostics,
        currentBufferPath: '/workspace/lib/b.dart',
      );
      expect(rendered.totalErrors, 0);
      expect(rendered.totalWarnings, 1);
      final fileNodes = rendered.nodes.whereType<ProblemsFileNode>().toList();
      expect(fileNodes.length, 1);
      expect(fileNodes.single.relativePath, 'lib/b.dart');
    });
  });
}
