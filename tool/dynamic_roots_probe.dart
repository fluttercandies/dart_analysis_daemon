import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'worktree_memory_probe.dart' show Server;

Future<void> main(List<String> args) async {
  final base = Directory(args[1]).resolveSymbolicLinksSync();
  final roots = [
    for (var i = 0; i < 3; i++)
      Directory('$base/branch_$i').resolveSymbolicLinksSync(),
  ];
  String path(int i, String relative) =>
      Directory(roots[i]).uri.resolve(relative).toFilePath();
  if (args[0] == 'configure') {
    final plugin = Directory(
      args[2],
    ).resolveSymbolicLinksSync().replaceAll('\\', '/');
    for (var i = 0; i < 3; i++) {
      await File(
        path(i, 'lib/unit_4999.dart'),
      ).writeAsString('int branchProbe = 0;\n');
      await File(path(i, 'analysis_options.yaml')).writeAsString('''
analyzer:
  exclude:
    - lib/excluded.dart
plugins:
  minimal_plugin:
    path: $plugin
''');
      await File(path(i, 'lib/dependency.dart')).writeAsString(
        'class ForbiddenBase {}\nclass AllowedBase {}\ntypedef SelectedBase = ForbiddenBase;\n',
      );
      await File(path(i, 'lib/probe.dart')).writeAsString(
        "import 'dependency.dart';\nclass SemanticProbe$i extends SelectedBase {}\nclass SyntaxProbe$i {}\n",
      );
      await File(path(i, 'lib/excluded.dart')).writeAsString(
        'class SyntaxProbeExcluded$i {}\nint bad = missingExcluded;\n',
      );
    }
    stdout.writeln('Configured dedicated dynamic probe fixture');
    return;
  }
  var server = Server()..coverageFile = 'probe.dart';
  final clock = Stopwatch()..start();
  final phases = <Map>[];
  var allChecksPassed = true;
  var active = <int>[];
  Future<Map> get(int i, String relative) async {
    final result = await server.request('analysis.getErrors', {
      'file': path(i, relative),
    });
    return result['result'] as Map;
  }

  Future<void> overlay(int i, String relative, String content) async {
    await server.request('analysis.updateContent', {
      'files': {
        path(i, relative): {'type': 'add', 'content': content},
      },
    });
  }

  Future<void> waitFor(
    int i,
    String relative,
    bool Function(List) predicate, {
    int? afterVersion,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final timer = Stopwatch()..start();
    // Request once to schedule the target, then wait for pushed plugin results.
    // Polling getErrors continuously would itself keep toggling STATUS busy.
    await get(i, relative);
    bool matches() {
      final file = path(i, relative);
      final errors = server.diagnostics[file];
      final version = server.diagnosticVersions[file] ?? 0;
      return errors != null &&
          !server.busy &&
          (afterVersion == null || version > afterVersion) &&
          predicate(errors);
    }

    while (timer.elapsed < timeout) {
      if (matches()) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (matches()) return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError(
      'No fresh diagnostic: root=$i file=$relative cached=${server.diagnostics[path(i, relative)]} problems=${server.protocolProblems}',
    );
  }

  bool code(List errors, String name) =>
      errors.any((e) => '${e['code']}'.endsWith(name));
  Future<void> verify({Map<String, int>? since}) async {
    for (final i in active) {
      await waitFor(
        i,
        'lib/probe.dart',
        (errors) =>
            code(errors, 'dynamic_syntax_probe') &&
            code(errors, 'dynamic_semantic_probe'),
        afterVersion: since?[path(i, 'lib/probe.dart')],
      );
      final errors = server.diagnostics[path(i, 'lib/probe.dart')]!;
      if (errors.any(
        (e) =>
            '${e['message']}'.contains('Probe') &&
            !'${e['message']}'.contains('Probe$i'),
      )) {
        throw StateError('Cross-root plugin diagnosis: $errors');
      }
      await waitFor(
        i,
        'lib/unit_4999.dart',
        (errors) =>
            errors.length == 1 &&
            '${errors.single['message']}'.contains('missingBranch$i'),
      );
      if ((server.diagnostics[path(i, 'lib/excluded.dart')] ?? []).isNotEmpty) {
        throw StateError('Excluded file published diagnostics');
      }
    }
    if (server.protocolProblems.isNotEmpty) {
      throw StateError('${server.protocolProblems}');
    }
  }

  void record(String label, int startMs, Map extra) {
    final data = {
      'label': label,
      'startMs': startMs,
      'endMs': clock.elapsedMilliseconds,
      'durationMs': clock.elapsedMilliseconds - startMs,
      'roots': active,
      ...extra,
    };
    phases.add(data);
    stderr.writeln(jsonEncode(data));
  }

  try {
    final start = clock.elapsedMilliseconds;
    final singleConfiguration = args[0] == 'configuration-single';
    final pairConfiguration = args[0] == 'configuration-pair';
    final configurationOnly =
        args[0] == 'configurations' || singleConfiguration || pairConfiguration;
    active =
        singleConfiguration
            ? [1]
            : (pairConfiguration
                ? [0, 1]
                : (configurationOnly ? [0, 1, 2] : [0]));
    await server.start([for (final i in active) roots[i]]);
    // Pre-register all branch overlays, including not-yet-analyzed roots.
    for (var i = 0; i < 3; i++) {
      await overlay(
        i,
        'lib/unit_4999.dart',
        'int branchProbe = missingBranch$i;\n',
      );
    }
    await verify();
    record(active.join('+'), start, {'verified': true});
    for (final selected
        in configurationOnly
            ? <List<int>>[]
            : <List<int>>[
              [0, 1],
              [0, 1, 2],
              [0, 2],
              [0, 1, 2],
            ]) {
      final start = clock.elapsedMilliseconds;
      final previous = [...active];
      final previousVersions = Map<String, int>.of(server.diagnosticVersions);
      final responseWatch = Stopwatch()..start();
      await server.request('analysis.setAnalysisRoots', {
        'included': [for (final i in selected) roots[i]],
        'excluded': [],
      });
      final responseMs = responseWatch.elapsedMilliseconds;
      active = selected;
      await server.idle([for (final i in selected) roots[i]]);
      await verify(since: previousVersions);
      final hot = Stopwatch()..start();
      await get(0, 'lib/unit_4999.dart');
      record(selected.join('+'), start, {
        'verified': true,
        'previous': previous,
        'responseMs': responseMs,
        'oldRootQueryMs': hot.elapsedMilliseconds,
      });
      if (selected.length == 2 && !selected.contains(1)) {
        // A wrapper must deny routing removed roots: getErrors can analyze outside roots.
        final outside = await get(1, 'lib/unit_4999.dart');
        record('removed_B_direct_query', clock.elapsedMilliseconds, {
          'returnedErrors': (outside['errors'] as List).length,
          'wrapperMustReject': true,
        });
      }
    }
    for (final i in configurationOnly ? <int>[] : active) {
      final start = clock.elapsedMilliseconds;
      final beforeChange =
          server.diagnosticVersions[path(i, 'lib/probe.dart')] ?? 0;
      await overlay(
        i,
        'lib/dependency.dart',
        'class ForbiddenBase {}\nclass AllowedBase {}\ntypedef SelectedBase = AllowedBase;\n',
      );
      await waitFor(
        i,
        'lib/probe.dart',
        (errors) =>
            code(errors, 'dynamic_syntax_probe') &&
            !code(errors, 'dynamic_semantic_probe'),
        afterVersion: beforeChange,
      );
      for (final other in active.where((v) => v != i)) {
        await waitFor(
          other,
          'lib/probe.dart',
          (errors) =>
              code(errors, 'dynamic_syntax_probe') &&
              code(errors, 'dynamic_semantic_probe'),
        );
      }
      final beforeRestore =
          server.diagnosticVersions[path(i, 'lib/probe.dart')] ?? 0;
      await overlay(
        i,
        'lib/dependency.dart',
        'class ForbiddenBase {}\nclass AllowedBase {}\ntypedef SelectedBase = ForbiddenBase;\n',
      );
      await waitFor(
        i,
        'lib/probe.dart',
        (errors) => code(errors, 'dynamic_semantic_probe'),
        afterVersion: beforeRestore,
      );
      await verify();
      record('dependency_$i', start, {'propagationAndRestore': true});
    }
    if (args.contains('configurations') ||
        singleConfiguration ||
        pairConfiguration) {
      // Only mutate the dedicated fixture; restore disk state even on failure.
      final options = File(path(1, 'analysis_options.yaml'));
      final originalOptions = await options.readAsString();
      final start = clock.elapsedMilliseconds;
      var cleared = false;
      Map? directAfterDisable;
      Map? restartObservation;
      final directWhileEnabled = await get(1, 'lib/probe.dart');
      Map? reanalyzeObservation;
      try {
        final version =
            server.diagnosticVersions[path(1, 'lib/probe.dart')] ?? 0;
        await options.writeAsString(
          'analyzer:\n  exclude:\n    - lib/excluded.dart\n',
        );
        try {
          await waitFor(
            1,
            'lib/probe.dart',
            (errors) => errors.isEmpty,
            afterVersion: version,
            timeout: const Duration(seconds: 30),
          );
          cleared = true;
        } on StateError {
          // Preserve the failed clearing observation, then inspect direct queries.
          allChecksPassed = false;
          directAfterDisable = await get(1, 'lib/probe.dart');
        }
        for (final i in active.where((i) => i != 1)) {
          await waitFor(
            i,
            'lib/probe.dart',
            (errors) => code(errors, 'dynamic_semantic_probe'),
          );
        }
        if (!cleared && args.contains('reanalyze')) {
          final reanalyzeStart = clock.elapsedMilliseconds;
          final before =
              server.diagnosticVersions[path(1, 'lib/probe.dart')] ?? 0;
          await server.request('analysis.reanalyze', {});
          var reanalyzeCleared = false;
          try {
            await waitFor(
              1,
              'lib/probe.dart',
              (errors) => errors.isEmpty,
              afterVersion: before,
              timeout: const Duration(seconds: 20),
            );
            reanalyzeCleared = true;
          } on StateError {
            // Record unsupported clearing behavior, then use process replacement.
          }
          reanalyzeObservation = {
            'clearedPushDiagnostics': reanalyzeCleared,
            'durationMs': clock.elapsedMilliseconds - reanalyzeStart,
            'pushAfterReanalyze': server.diagnostics[path(1, 'lib/probe.dart')],
          };
        }
        if (!cleared) {
          final restartStart = clock.elapsedMilliseconds;
          final oldPid = server.process.pid;
          final stale = List.of(
            server.diagnostics[path(1, 'lib/probe.dart')] ?? [],
          );
          await server.close();
          server = Server()..coverageFile = 'probe.dart';
          await server.start([for (final i in active) roots[i]]);
          await waitFor(1, 'lib/probe.dart', (errors) => errors.isEmpty);
          restartObservation = {
            'oldPid': oldPid,
            'newPid': server.process.pid,
            'durationMs': clock.elapsedMilliseconds - restartStart,
            'stalePushBeforeRestart': stale,
            'pushAfterRestart': server.diagnostics[path(1, 'lib/probe.dart')],
            'directAfterRestart': await get(1, 'lib/probe.dart'),
          };
          for (final i in active) {
            await overlay(
              i,
              'lib/unit_4999.dart',
              'int branchProbe = missingBranch$i;\n',
            );
          }
        }
      } finally {
        await options.writeAsString(originalOptions);
      }
      await verify();
      record('plugin_configuration_B', start, {
        'disableClearedPushDiagnostics': cleared,
        'directAfterDisable': directAfterDisable,
        'directWhileEnabled': directWhileEnabled,
        'reanalyzeObservation': reanalyzeObservation,
        'restartObservation': restartObservation,
        'restored': true,
      });

      final config = File(path(1, '.dart_tool/package_config.json'));
      final originalConfig = await config.readAsString();
      final packageStart = clock.elapsedMilliseconds;
      final locations = <String>[];
      for (final name in ['ForbiddenBase', 'AllowedBase']) {
        final directory = Directory('$base/package_$name/lib');
        await directory.create(recursive: true);
        await File(
          '${directory.path}/base.dart',
        ).writeAsString('class $name {}\ntypedef SelectedBase = $name;\n');
        locations.add(directory.parent.uri.toString());
      }
      Future<void> setPackage(String location) async {
        final data = jsonDecode(originalConfig) as Map<String, dynamic>;
        (data['packages'] as List).add({
          'name': 'probe_dep',
          'rootUri': location,
          'packageUri': 'lib/',
          'languageVersion': '3.9',
        });
        await config.writeAsString(jsonEncode(data));
      }

      try {
        await setPackage(locations[0]);
        final before =
            server.diagnosticVersions[path(1, 'lib/probe.dart')] ?? 0;
        await overlay(
          1,
          'lib/dependency.dart',
          "import 'package:probe_dep/base.dart';\nexport 'package:probe_dep/base.dart';\n",
        );
        await waitFor(
          1,
          'lib/probe.dart',
          (errors) => code(errors, 'dynamic_semantic_probe'),
          afterVersion: before,
        );
        final changed =
            server.diagnosticVersions[path(1, 'lib/probe.dart')] ?? 0;
        await setPackage(locations[1]);
        await waitFor(
          1,
          'lib/probe.dart',
          (errors) =>
              code(errors, 'dynamic_syntax_probe') &&
              !code(errors, 'dynamic_semantic_probe') &&
              errors.every(
                (e) => '${e['code']}'.endsWith('dynamic_syntax_probe'),
              ),
          afterVersion: changed,
        );
        for (final i in active.where((i) => i != 1)) {
          await waitFor(
            i,
            'lib/probe.dart',
            (errors) => code(errors, 'dynamic_semantic_probe'),
          );
        }
      } finally {
        await config.writeAsString(originalConfig);
        await overlay(
          1,
          'lib/dependency.dart',
          'class ForbiddenBase {}\nclass AllowedBase {}\ntypedef SelectedBase = ForbiddenBase;\n',
        );
      }
      await verify();
      record('package_configuration_B', packageStart, {
        'remapAndRestore': true,
      });
    }
    stdout.writeln(
      jsonEncode({
        'ready': true,
        'mode': 'dynamic',
        'phases': phases,
        'analyzerPid': server.process.pid,
        'protocolProblems': server.protocolProblems,
        'allChecksPassed': allChecksPassed,
      }),
    );
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  } catch (error, stack) {
    stdout.writeln(
      jsonEncode({
        'ready': true,
        'mode': 'dynamic',
        'failed': '$error',
        'stack': '$stack',
        'phases': phases,
        'protocolProblems': server.protocolProblems,
      }),
    );
    rethrow;
  } finally {
    await server.close();
  }
}
