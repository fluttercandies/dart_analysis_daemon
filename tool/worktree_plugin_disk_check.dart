// Real existing plugin, manager transport and bounded explicit disk inputs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_manager_probe_check.dart' show Client, check;

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp('dana-plugin-disk-');
  final project = await Directory('${fixture.path}/project').create();
  final lib = await Directory('${project.path}/lib').create();
  final target = File('${lib.path}/probe.dart');
  final dependency = File('${lib.path}/dependency.dart');
  const disk =
      "import 'dependency.dart';\nclass SyntaxProbeDisk {}\nclass SemanticProbeDisk extends SelectedBase {}\nint value = missingDisk;\n";
  const forbidden =
      'class ForbiddenBase {}\nclass AllowedBase {}\ntypedef SelectedBase = ForbiddenBase;\n';
  const allowed =
      'class ForbiddenBase {}\nclass AllowedBase {}\ntypedef SelectedBase = AllowedBase;\n';
  await target.writeAsString(disk);
  await dependency.writeAsString(forbidden);
  await File(
    '${project.path}/pubspec.yaml',
  ).writeAsString('name: plugin_disk_fixture\nenvironment:\n  sdk: ^3.9.0\n');
  await Directory('${project.path}/.dart_tool').create();
  await File('${project.path}/.dart_tool/package_config.json').writeAsString(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': 'plugin_disk_fixture',
          'rootUri': '../',
          'packageUri': 'lib/',
          'languageVersion': '3.9',
        },
      ],
    }),
  );
  final plugin = Directory.fromUri(
    Platform.script.resolve(
      '../../benchmarks/minimal-plugin/plugin-dynamic-probe',
    ),
  ).resolveSymbolicLinksSync().replaceAll('\\', '/');
  await File(
    '${project.path}/analysis_options.yaml',
  ).writeAsString('plugins:\n  minimal_plugin:\n    path: $plugin\n');
  final other = await Directory('${fixture.path}/other').create();
  final otherTarget = File('${other.path}/probe.dart');
  await otherTarget.writeAsString('int value = missingOther;\n');
  final manager = await Process.start(Platform.resolvedExecutable, [
    File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path,
    fixture.path,
    '--official-worker',
    '--system-memory',
  ]);
  final ready = Completer<Map>();
  manager.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (!ready.isCompleted) ready.complete(jsonDecode(line) as Map);
    },
  );
  final stderrLog = manager.stderr.transform(utf8.decoder).join();
  Client? admin;
  final results = <Map>[];
  final snapshots = <Map>[];
  Timer? sampler;
  var sampling = false;
  var skipped = false;
  var shutdownConfirmed = false;
  Object? failure;
  var bootstrapRejected = false;
  final bootstrapWatch = Stopwatch();
  int? baselineStarts;
  Future<void> observe(String name, List<String> codes) async {
    final watch = Stopwatch()..start();
    final result = await admin!.send(
      'observe-disk',
      fields: {
        'root': project.path,
        'file': target.absolute.path,
        'dependencies': [dependency.absolute.path],
        'expectedCodes': codes,
        'timeoutMs': 180000,
      },
      responseTimeout: const Duration(seconds: 190),
    );
    check(
      result['ok'] == true &&
          result['observationOnly'] == true &&
          result['builtinOnly'] == false &&
          result['diagnosticComplete'] == false &&
          (result['inputDigests'] as Map).length == 2 &&
          (result['pushSequence'] as int) > (result['sinceSequence'] as int),
      'Observation failed: $result',
    );
    final actual =
        (result['errors'] as List).map((e) => '${e['code']}').toList()..sort();
    final expected = List.of(codes)..sort();
    check(
      jsonEncode(actual) == jsonEncode(expected),
      'Unexpected pushed diagnostics',
    );
    check(
      !(result['directErrors'] as List).any(
        (e) => '${e['code']}'.startsWith('dynamic_'),
      ),
      'Built-in query unexpectedly treated as merged barrier',
    );
    results.add({
      'name': name,
      'passed': true,
      'elapsedMs': watch.elapsedMilliseconds,
      'response': result,
    });
    print('PASS $name');
  }

  const allCodes = [
    'undefined_identifier',
    'dynamic_syntax_probe',
    'dynamic_semantic_probe',
  ];
  try {
    check(
      (await ready.future.timeout(const Duration(seconds: 15)))['event'] ==
          'ready',
      'Manager not ready',
    );
    admin = await Client.connect(
      jsonDecode(await File('${fixture.path}/manager.json').readAsString())
          as Map,
    );
    final status = await admin.send('status');
    snapshots.add(status);
    if (status['memory']['allowed'] != true) {
      skipped = true;
      print('SKIP real memory admission');
      return;
    }
    sampler = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (sampling || snapshots.length >= 2048) return;
      sampling = true;
      try {
        snapshots.add(await admin!.send('status'));
      } catch (_) {
      } finally {
        sampling = false;
      }
    });
    try {
      bootstrapWatch.start();
      await observe(
        'plugin baseline merges built-in syntax and dependency semantic diagnostics',
        allCodes,
      );
    } catch (error) {
      if (!'$error'.contains(
        'Environment changed during official initialization',
      )) {
        rethrow;
      }
      bootstrapRejected = true;
      results.add({
        'name':
            'initialization-generated environment changes reject old generation',
        'passed': true,
        'error': '$error',
        'elapsedMs': bootstrapWatch.elapsedMilliseconds,
      });
      print(
        'PASS initialization-generated environment changes reject old generation',
      );
      // One fresh request after the rejected startup has confirmed Job zero.
      // Never retry a resource-guard failure or relax an identity check.
      await observe(
        'plugin baseline merges built-in syntax and dependency semantic diagnostics',
        allCodes,
      );
    }
    baselineStarts = (await admin.send('status'))['starts'] as int;
    await observe(
      'unchanged repeated request requires a fresh diagnostic push',
      allCodes,
    );
    await target.writeAsString(
      "import 'dependency.dart';\nclass Plain extends AllowedBase {}\nint value = 1;\n",
    );
    await observe('saved clean target clears all diagnostic classes', []);
    await target.writeAsString(disk);
    await observe(
      'saved target restoration republishes all diagnostic classes',
      allCodes,
    );
    await dependency.writeAsString(allowed);
    await observe(
      'saved declared dependency removes only semantic plugin diagnostic',
      ['undefined_identifier', 'dynamic_syntax_probe'],
    );
    await dependency.writeAsString(forbidden);
    await observe(
      'saved dependency restoration republishes semantic plugin diagnostic',
      allCodes,
    );
    final switched = await admin.send(
      'builtin-errors',
      fields: {
        'root': other.path,
        'file': otherTarget.absolute.path,
        'timeoutMs': 180000,
      },
      responseTimeout: const Duration(seconds: 190),
    );
    check(
      switched['ok'] == true &&
          switched['builtinOnly'] == true &&
          (switched['errors'] as List).any(
            (e) => '${e['message']}'.contains('missingOther'),
          ),
      'Cross-root built-in result wrong',
    );
    results.add({
      'name':
          'cross-root switch discards plugin tree before built-in-only tree',
      'passed': true,
      'response': switched,
    });
    print(
      'PASS cross-root switch discards plugin tree before built-in-only tree',
    );
    await observe(
      'returning root rebuilds plugin and observes fresh disk diagnostics',
      allCodes,
    );
    final finalStatus = await admin.send('status');
    snapshots.add(finalStatus);
    check(
      finalStatus['starts'] == baselineStarts + 2 &&
          finalStatus['trackedWorkers'] == 1 &&
          finalStatus['degraded'] == null,
      'Replacement lifecycle wrong',
    );
    sampler.cancel();
    await admin.send('shutdown');
    check(
      await manager.exitCode.timeout(const Duration(seconds: 25)) == 0,
      'Shutdown failed',
    );
    check(
      !File('${fixture.path}/manager.json').existsSync(),
      'Endpoint retained',
    );
    shutdownConfirmed = true;
  } catch (error) {
    failure = error;
    rethrow;
  } finally {
    sampler?.cancel();
    if (!shutdownConfirmed) {
      try {
        await admin?.send('shutdown');
        check(
          await manager.exitCode.timeout(const Duration(seconds: 25)) == 0,
          'Final cleanup failed',
        );
        shutdownConfirmed = true;
      } catch (error) {
        failure ??= error;
        manager.kill();
      }
    }
    admin?.close();
    final report = {
      'fixture': fixture.path,
      'plugin': plugin,
      'allPassed':
          !skipped &&
          failure == null &&
          results.length == (bootstrapRejected ? 9 : 8) &&
          shutdownConfirmed,
      'skipped': skipped,
      'failure': failure?.toString(),
      'shutdownConfirmed': shutdownConfirmed,
      'results': results,
      'snapshots': snapshots,
      'managerStderr': await stderrLog.timeout(const Duration(seconds: 5)),
    };
    await File(
      '${fixture.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    print(
      jsonEncode({
        'fixture': fixture.path,
        'allPassed': report['allPassed'],
        'failure': report['failure'],
      }),
    );
    if (failure != null) exitCode = 1;
  }
}
