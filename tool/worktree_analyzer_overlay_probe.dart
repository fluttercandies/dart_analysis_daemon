// Independent official analyzer experiment; launched only inside a native Job.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_analyzer_client.dart';
export 'worktree_analyzer_client.dart' show ProbeDiagnosticCache;

Future<void> main(List<String> args) async {
  final fixture = Directory(args[0]);
  final createdRoot = await Directory(
    '${fixture.path}/project/lib',
  ).create(recursive: true);
  final root = Directory(createdRoot.resolveSymbolicLinksSync());
  final project = root.parent;
  final file = File.fromUri(root.uri.resolve('probe.dart'));
  final dependency = File.fromUri(root.uri.resolve('dependency.dart'));
  const disk =
      "import 'dependency.dart';\nclass SyntaxProbeDisk {}\nclass SemanticProbeDisk extends SelectedBase {}\nint value = missingDisk;\n";
  await file.writeAsString(disk);
  await dependency.writeAsString(
    'class ForbiddenBase {}\nclass AllowedBase {}\ntypedef SelectedBase = ForbiddenBase;\n',
  );
  await File('${project.path}/pubspec.yaml').writeAsString(
    'name: overlay_research_fixture\nenvironment:\n  sdk: ^3.9.0\n',
  );
  await Directory('${project.path}/.dart_tool').create();
  await File('${project.path}/.dart_tool/package_config.json').writeAsString(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': 'overlay_research_fixture',
          'rootUri': '../',
          'packageUri': 'lib/',
          'languageVersion': '3.9',
        },
      ],
    }),
  );
  final plugin =
      args.length > 1
          ? Directory(args[1]).resolveSymbolicLinksSync().replaceAll('\\', '/')
          : null;
  if (plugin != null) {
    await File(
      '${project.path}/analysis_options.yaml',
    ).writeAsString('plugins:\n  minimal_plugin:\n    path: $plugin\n');
  }
  final results = <Map>[];
  var generation = 0;
  final lifecycles = <Map<String, Object?>>[];
  ResearchAnalyzerClient? server;
  Future<void> start() async {
    generation++;
    server = ResearchAnalyzerClient(
      project.path,
      File('${fixture.path}/protocol-$generation.jsonl'),
    );
    await server!.start();
    lifecycles.add({
      'generation': generation,
      'rootSetupMs': server!.clock.elapsedMilliseconds,
      'requests': server!.requestTimings,
    });
  }

  bool has(List errors, String code) =>
      errors.any((e) => '${e['code']}'.endsWith(code));
  Future<void> verify(
    String name,
    int since,
    bool Function(List) predicate,
  ) async {
    final current = server!;
    final watch = Stopwatch()..start();
    final direct = await current.request('analysis.getErrors', {
      'file': file.path,
    });
    final directErrors = direct['result']['errors'] as List;
    // getErrors is recorded for comparison. A fresh push + idle is the candidate
    // barrier, because plugins may finish after the direct built-in response.
    while (true) {
      if (!current.busy &&
          current.diagnostics.matches(file.path, since, predicate)) {
        final observed = current.errorSequence[file.path];
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!current.busy &&
            current.diagnostics.matches(file.path, since, predicate) &&
            current.problems.isEmpty) {
          results.add({
            'name': name,
            'generation': generation,
            'passed': true,
            'elapsedMs': watch.elapsedMilliseconds,
            'since': since,
            'pushSequence': observed,
            'directErrors': directErrors,
            'pushedErrors': current.errors[file.path],
          });
          await File('${fixture.path}/progress.json').writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'complete': false,
              'plugin': plugin,
              'results': results,
              'lifecycles': lifecycles,
            }),
          );
          stderr.writeln('PASS $name');
          return;
        }
      }
      if (watch.elapsed > const Duration(seconds: 60)) {
        throw StateError(
          'No fresh expected diagnostics: $name ${current.errors} ${current.problems}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<int> content(Map<String, Object> files) async {
    final before = server!.eventSequence;
    await server!.request('analysis.updateContent', {'files': files});
    return before;
  }

  bool diskState(List e) =>
      e.any((e) => '${e['message']}'.contains('missingDisk')) &&
      (plugin == null ||
          (has(e, 'dynamic_syntax_probe') && has(e, 'dynamic_semantic_probe')));
  bool cleanState(List e) => e.isEmpty;
  const clean =
      "import 'dependency.dart';\nclass Plain extends AllowedBase {}\nint value = 1;\n";
  final overlay = {
    file.path: {'type': 'add', 'content': clean},
  };
  try {
    await start();
    await verify('disk baseline', 0, diskState);
    await verify(
      'overlay replaces built-in and plugin diagnostics',
      await content(overlay),
      cleanState,
    );
    final before = server!.eventSequence;
    await content({
      file.path: {'type': 'add', 'content': 'int value = missingTransient;\n'},
    });
    await content(overlay);
    await verify(
      'rapid successive versions settle to latest overlay',
      before,
      cleanState,
    );
    await verify(
      'remove restores disk diagnostics',
      await content({
        file.path: {'type': 'remove'},
      }),
      diskState,
    );
    await verify(
      'dependency overlay updates semantic plugin diagnostic',
      await content({
        dependency.path: {
          'type': 'add',
          'content':
              'class AllowedBase {}\ntypedef SelectedBase = AllowedBase;\n',
        },
      }),
      (e) =>
          e.any((e) => '${e['message']}'.contains('missingDisk')) &&
          (plugin == null ||
              (has(e, 'dynamic_syntax_probe') &&
                  !has(e, 'dynamic_semantic_probe'))),
    );
    await verify(
      'dependency remove restores semantic plugin diagnostic',
      await content({
        dependency.path: {'type': 'remove'},
      }),
      diskState,
    );
    await verify(
      'overlay before worker replacement',
      await content(overlay),
      cleanState,
    );
    await server!.close();
    server = null;
    // Controller rechecks admission before allowing another native subtree start.
    stdout.writeln(jsonEncode({'event': 'restart-admission'}));
    final permission =
        await stdin
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
    if (permission != 'resume') {
      throw StateError('Replacement admission denied');
    }
    await start();
    await verify(
      'new worker starts with disk state before replay',
      0,
      diskState,
    );
    await verify(
      'full snapshot replay restores unsaved state',
      await content(overlay),
      cleanState,
    );
    if (await file.readAsString() != disk) {
      throw StateError('Overlay wrote to disk');
    }
  } finally {
    await server?.close();
  }
  final report = {
    'allPassed': true,
    'plugin': plugin,
    'results': results,
    'lifecycles': lifecycles,
    'fixture': fixture.path,
    'barrier':
        'fresh expected push after send, idle and 250ms stability; experimental, not a universal protocol guarantee',
  };
  await File(
    '${fixture.path}/results.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(jsonEncode({'event': 'complete', 'checks': results.length}));
}
