import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_environment_identity.dart';
import 'worktree_manager_probe_check.dart' show Client, check, poll;
import 'worktree_test_runtime.dart';

Future<void> main() async {
  final alternateDart = requireTestRuntime('DANA_TEST_ALTERNATE_DART');
  final secondDart = requireTestRuntime('DANA_TEST_SECOND_DART');
  final alternateVersion = await testRuntimeVersion(alternateDart);
  final secondVersion = await testRuntimeVersion(secondDart);
  final fixture = await Directory.systemTemp.createTemp('dana-environment-');
  final root = await Directory('${fixture.path}/root').create();
  final plugin = await Directory(
    '${fixture.path}/plugin/lib',
  ).create(recursive: true);
  final preset = await Directory(
    '${fixture.path}/preset/lib',
  ).create(recursive: true);
  final configuration = await Directory('${root.path}/.dart_tool').create();
  final options = File('${root.path}/analysis_options.yaml');
  final include = File('${preset.path}/rules.yaml');
  final pluginSource = File('${plugin.path}/main.dart');
  final runtime = Platform.resolvedExecutable;
  final collector = ResearchEnvironmentCollector();
  final results = <Map>[];
  Future<void> run(String name, Future<void> Function() body) async {
    final clock = Stopwatch()..start();
    await body().timeout(const Duration(seconds: 30));
    results.add({
      'name': name,
      'passed': true,
      'durationMs': clock.elapsedMilliseconds,
    });
    print('PASS $name');
  }

  final packageConfig = File('${configuration.path}/package_config.json');
  await packageConfig.writeAsString(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': 'preset',
          'rootUri': Directory(preset.parent.path).uri.toString(),
          'packageUri': 'lib/',
        },
      ],
    }),
  );
  await File(
    '${plugin.parent.path}/pubspec.yaml',
  ).writeAsString('name: probe_plugin\n');
  await pluginSource.writeAsString('void main() {}\n');
  await include.writeAsString(
    'analyzer:\n  errors:\n    unused_import: warning\n',
  );
  final baseOptions =
      'include: package:preset/rules.yaml\nplugins:\n  probe_plugin:\n    path: ../plugin\n';
  await options.writeAsString(baseOptions);
  Future<ResearchEnvironment> capture([String? executable]) =>
      collector.capture(root.path, executable ?? runtime);
  await run(
    'selected runtime version comes from executable and stable files preserve identity',
    () async {
      final first = await capture();
      final second = await capture();
      check(
        first.key == second.key &&
            first.version.startsWith('Dart SDK version:'),
        'Unstable identity or missing selected version',
      );
      check(
        first.files.keys.any((p) => p.endsWith('rules.yaml')) &&
            first.files.keys.any((p) => p.endsWith('main.dart')),
        'Transitive sources missing',
      );
    },
  );
  await run(
    'included package options and same-length plugin edits invalidate content identity',
    () async {
      final first = await capture();
      await include.writeAsString(
        'analyzer:\n  errors:\n    unused_import: ignore\n',
      );
      final second = await capture();
      check(first.key != second.key, 'Included options edit ignored');
      await pluginSource.writeAsString('void main() { }\n');
      final third = await capture();
      check(third.key != second.key, 'Plugin source edit ignored');
      final timestamp = pluginSource.statSync().modified;
      await pluginSource.writeAsString('void main() {;}\n');
      pluginSource.setLastModifiedSync(timestamp);
      check(
        (await capture()).key != third.key,
        'Same-size restored-time source edit ignored',
      );
    },
  );
  await run(
    'Windows absolute include and plugin paths resolve as filesystem paths',
    () async {
      try {
        await options.writeAsString(
          'include: ${include.absolute.path.replaceAll('\\', '/')}\nplugins:\n  probe_plugin:\n    path: ${plugin.parent.absolute.path.replaceAll('\\', '/')}\n',
        );
        final snapshot = await capture();
        check(
          snapshot.files.containsKey(include.resolveSymbolicLinksSync()) &&
              snapshot.files.containsKey(
                pluginSource.resolveSymbolicLinksSync(),
              ),
          'Absolute inputs absent',
        );
        final previous = snapshot.key;
        await pluginSource.writeAsString('void main() {;;}\n');
        check(
          (await capture()).key != previous,
          'Absolute plugin edit ignored',
        );
      } finally {
        await options.writeAsString(baseOptions);
      }
    },
  );
  await run(
    'package remapping lockfile and plugin package config alter identity',
    () async {
      var previous = await capture();
      for (final path in [
        '${root.path}/pubspec.lock',
        '${plugin.parent.path}/pubspec.lock',
        '${plugin.parent.path}/.dart_tool/package_config.json',
      ]) {
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsString('{}\n');
        final next = await capture();
        check(
          next.key != previous.key,
          'Configuration input not tracked: $path',
        );
        previous = next;
      }
      final bytes = await packageConfig.readAsString();
      final remapped = await Directory(
        '${fixture.path}/alternate-preset/lib',
      ).create(recursive: true);
      await File(
        '${remapped.path}/rules.yaml',
      ).writeAsString(await include.readAsString());
      final config = jsonDecode(bytes) as Map;
      (config['packages'] as List).single['rootUri'] =
          remapped.parent.uri.toString();
      await packageConfig.writeAsString(jsonEncode(config));
      check(
        (await capture()).key != previous.key,
        'Package remapping to another directory ignored',
      );
      await packageConfig.writeAsString(bytes);
    },
  );
  await run(
    'cycles missing includes unsupported plugins malformed YAML and oversized inputs fail closed',
    () async {
      for (final invalid in [
        'include: analysis_options.yaml\n',
        'include: missing.yaml\n',
        'plugins:\n  hosted_plugin: ^1.0.0\n',
        'include: [\n',
      ]) {
        await options.writeAsString(invalid);
        var rejected = false;
        try {
          await capture();
        } catch (_) {
          rejected = true;
        }
        check(rejected, 'Unsupported identity accepted: $invalid');
      }
      await options.writeAsString(List.filled(4 * 1024 * 1024 + 1, 'x').join());
      var rejected = false;
      try {
        await capture();
      } catch (_) {
        rejected = true;
      }
      check(rejected, 'Oversized options accepted');
      await options.writeAsString(baseOptions);
    },
  );
  await run(
    'different selected SDK records its own version without starting analyzer',
    () async {
      final selected = await capture(alternateDart);
      final host = await capture();
      check(
        selected.version.contains(alternateVersion) &&
            host.version.contains(await testRuntimeVersion(runtime)) &&
            selected.key != host.key,
        'Selected version confused with host',
      );
    },
  );
  final process = await Process.start(runtime, [
    File.fromUri(Platform.script.resolve('worktree_manager_probe.dart')).path,
    fixture.path,
    '--environment-identity',
  ]);
  final ready = Completer<void>();
  process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (!ready.isCompleted && jsonDecode(line)['event'] == 'ready') {
        ready.complete();
      }
    },
  );
  process.stderr.transform(utf8.decoder).listen(stderr.write);
  final clients = <Client>[];
  try {
    await ready.future.timeout(const Duration(seconds: 10));
    final metadata =
        jsonDecode(await File('${fixture.path}/manager.json').readAsString())
            as Map;
    final client = await Client.connect(metadata);
    clients.add(client);
    final admin = await Client.connect(metadata);
    clients.add(admin);
    Future<Map> work({int duration = 10, String? executable}) => client.send(
      'check',
      fields: {
        'root': root.path,
        'workMs': duration,
        'timeoutMs': 20000,
        if (executable != null) 'dartExecutable': executable,
      },
    );
    await run('unchanged environment reuses one native worker', () async {
      final first = await work();
      final second = await work();
      check(
        first['ok'] == true &&
            second['ok'] == true &&
            first['workerGeneration'] == second['workerGeneration'] &&
            (await admin.send('status'))['starts'] == 1,
        'Environment reuse failed',
      );
    });
    await run(
      'configuration edit during active lease fails stale result and replaces worker sequentially',
      () async {
        final pending = work(duration: 800);
        await poll(() async => (await admin.send('status'))['leases'] == 1);
        await include.writeAsString(
          'analyzer:\n  errors:\n    unused_import: error\n',
        );
        final replacement = work();
        check(
          (await pending)['ok'] == false,
          'Old configuration returned success',
        );
        final result = await replacement;
        check(
          result['ok'] == true && (await admin.send('status'))['starts'] == 2,
          'Configuration replacement failed',
        );
      },
    );
    await run(
      'result-time validation detects plugin edits without a second request',
      () async {
        final pending = work(duration: 500);
        await poll(() async => (await admin.send('status'))['leases'] == 1);
        await pluginSource.writeAsString('void main() { print(1); }\n');
        check(
          (await pending)['ok'] == false,
          'Changed plugin result published',
        );
        check(
          (await work())['ok'] == true &&
              (await admin.send('status'))['starts'] == 3,
          'Plugin rebuild failed',
        );
      },
    );
    await run(
      'malformed configuration rejects request invalidates active result and recovers after repair',
      () async {
        final pending = work(duration: 700);
        await poll(() async => (await admin.send('status'))['leases'] == 1);
        await options.writeAsString('include: [\n');
        check((await work())['ok'] == false, 'Malformed options reused worker');
        check(
          (await pending)['ok'] == false,
          'Malformed options permitted old active result',
        );
        await options.writeAsString(baseOptions);
        check(
          (await work())['ok'] == true &&
              (await admin.send('status'))['starts'] == 4,
          'Repair failed to rebuild',
        );
      },
    );
    await run(
      'different selected executable launches compatible lightweight worker and separates generation',
      () async {
        final result = await work(executable: secondDart);
        check(
          result['ok'] == true &&
              '${result['runtimeVersion']}'.contains(secondVersion) &&
              '${result['workerRuntimeVersion']}'.contains(secondVersion) &&
              (await admin.send('status'))['starts'] == 5,
          'Runtime switch reused host worker',
        );
      },
    );
    await admin.send('shutdown');
    check(
      await process.exitCode.timeout(const Duration(seconds: 25)) == 0,
      'Environment manager cleanup failed',
    );
    final report = {
      'results': results,
      'fixture': fixture.path,
      'allPassed': true,
    };
    await File(
      '${fixture.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    print(jsonEncode(report));
  } finally {
    for (final client in clients) {
      client.close();
    }
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      process.kill();
    }
  }
}
