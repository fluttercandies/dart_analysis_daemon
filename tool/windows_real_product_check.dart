// Real managed public entry, source-edit/cache/crash lifecycle. Run via guard.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/cli.dart';
import 'package:dart_analysis_daemon/src/global_budget_service.dart';
import 'package:dart_analysis_daemon/src/session_client.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first != '--probe') {
    await cliMain(args);
    return;
  }
  final fixture = Directory(args[1]);
  final plugin = await Directory(
    '${fixture.path}/p/lib',
  ).create(recursive: true);
  final original = Directory(
    '../benchmarks/minimal-plugin/plugin-dynamic-probe',
  );
  await File(
    '${original.path}/pubspec.yaml',
  ).copy('${plugin.parent.path}/pubspec.yaml');
  final baseline = await File('${original.path}/lib/main.dart').readAsString();
  final source = await File(
    '${plugin.path}/main.dart',
  ).writeAsString('$baseline\ninvalid syntax here;');
  final roots = <String>[];
  final files = <String>[];
  for (final name in ['A', 'B', 'C']) {
    final root = await Directory(
      '${fixture.path}/$name/lib',
    ).create(recursive: true);
    roots.add(await root.parent.resolveSymbolicLinks());
    final file = await File(
      '${root.path}/probe.dart',
    ).writeAsString('class SyntaxProbeWindows {}\n');
    files.add(await file.resolveSymbolicLinks());
    await File('${root.parent.path}/pubspec.yaml').writeAsString(
      'name: probe_${name.toLowerCase()}\nenvironment:\n  sdk: ^3.9.0\n',
    );
    await Directory('${root.parent.path}/.dart_tool').create();
    await File(
      '${root.parent.path}/.dart_tool/package_config.json',
    ).writeAsString(
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'probe_${name.toLowerCase()}',
            'rootUri': '../',
            'packageUri': 'lib/',
            'languageVersion': '3.9',
          },
        ],
      }),
    );
    if (name == 'A') {
      await File('${root.parent.path}/analysis_options.yaml').writeAsString(
        'plugins:\n  minimal_plugin:\n    path: ${plugin.parent.path.replaceAll('\\', '/')}\n',
      );
    }
  }
  final results = <Map<String, Object?>>[];
  final clients = <SessionClient>[];
  Future<Map<String, Object?>> budget(String op) =>
      globalBudgetRequest({'op': op}, autoStart: false);
  Future<Map<String, Object?>> check(int i, String phase) async {
    final watch = Stopwatch()..start();
    final response = await clients[i].checkFiles([files[i]]);
    results.add({
      'phase': phase,
      'elapsedMs': watch.elapsedMilliseconds,
      'response': response,
    });
    if (response['ok'] != true || response['diagnosticComplete'] != false) {
      throw StateError('Unexpected product response: $response');
    }
    return response;
  }

  try {
    clients.add(await SessionClient.connect(roots.first));
    Map<String, Object?>? failed;
    for (var i = 0; i < 6; i++) {
      final response = await clients.first.checkFiles([files.first]);
      results.add({'phase': 'broken-plugin', 'response': response});
      if (response['ok'] == false) {
        failed = response;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (failed == null || !'${failed['error']}'.contains('pluginError')) {
      throw StateError(
        'Real plugin compilation failure was not surfaced: $failed',
      );
    }
    await source.writeAsString(baseline);
    final repaired = await check(0, 'repaired-plugin');
    final hot = await check(0, 'hot-plugin');
    if (hot['workerGeneration'] != repaired['workerGeneration']) {
      throw StateError('Hot worker was not reused');
    }
    final beforeEdit = await source.lastModified();
    await source.writeAsString(
      baseline.replaceAll(
        "startsWith('SyntaxProbe')",
        "startsWith('UpdatedProbe')",
      ),
    );
    await source.setLastModified(beforeEdit);
    final edited = await check(0, 'preserved-time-edit');
    if (edited['workerGeneration'] == repaired['workerGeneration']) {
      throw StateError('Edited plugin reused old worker');
    }
    for (var i = 1; i < roots.length; i++) {
      clients.add(await SessionClient.connect(roots[i]));
      await check(i, 'dynamic-root-$i');
    }
    final switched = await check(0, 'switch-back');
    for (var round = 0; round < 5; round++) {
      final repeated = await check(0, 'stability-$round');
      final status = await budget('status');
      if (repeated['workerGeneration'] != switched['workerGeneration'] ||
          status['workerCount'] != 1 ||
          status['degraded'] != null ||
          status['queuedRequests'] != 0) {
        throw StateError('Repeated checks retained invalid worker state');
      }
      results.add({'phase': 'stability-status-$round', 'response': status});
    }
    final old = await budget('status');
    final state = Directory(Platform.environment['DANA_GLOBAL_STATE_DIR']!);
    final journal =
        jsonDecode(await File('${state.path}/worker-job.json').readAsString())
            as Map;
    final oldCache = Directory('${state.path}/${journal['cacheName']}');
    if (!Process.killPid(old['pid'] as int)) {
      throw StateError('Exact owner crash failed');
    }
    final recovered = await check(0, 'owner-crash-recovery');
    if (recovered['workerGeneration'] != 1 || await oldCache.exists()) {
      throw StateError('Crash cleanup/recovery failed');
    }
    results.add({'phase': 'final-status', 'response': await budget('status')});
  } catch (error, stack) {
    results.add({'error': '$error', 'stack': '$stack'});
    exitCode = 1;
  } finally {
    for (final client in clients) {
      try {
        await client.shutdown();
      } catch (error) {
        results.add({'cleanupError': '$error'});
        exitCode = 1;
      }
      await client.close();
    }
    try {
      results.add({'phase': 'owner-stop', 'response': await budget('stop')});
    } catch (error) {
      results.add({'cleanupError': '$error'});
      exitCode = 1;
    }
    await File('${fixture.path}/worker-results.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'checks': results,
        'pluginStartLog':
            await File('${fixture.path}/plugin-start.jsonl').exists()
                ? await File(
                  '${fixture.path}/plugin-start.jsonl',
                ).readAsString()
                : null,
      }),
    );
  }
}
