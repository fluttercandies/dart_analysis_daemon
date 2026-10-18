import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:yaml/yaml.dart';

// Isolate Pub installation and fixture entry points from the user's cache.
Future<void> main() async {
  final package = Directory.current;
  final fixture = await Directory.systemTemp.createTemp('dana-job-install-');
  final cache = Directory('${fixture.path}/cache');
  final copy = Directory('${fixture.path}/package');
  await copy.create();
  for (final name in ['lib', 'bin']) {
    final source = Directory('${package.path}/$name');
    await for (final entity in source.list(recursive: true)) {
      final relative = entity.path.substring(source.path.length);
      final destination = '${copy.path}/$name$relative';
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      }
      if (entity is File) {
        await File(destination).parent.create(recursive: true);
        await entity.copy(destination);
      }
    }
  }
  final spec = await File('${package.path}/pubspec.yaml').readAsString();
  // The copied fixture needs runtime dependencies only, never the test SDK.
  await File('${copy.path}/pubspec.yaml').writeAsString(
    spec.replaceFirst(RegExp(r'dev_dependencies:[\s\S]*?(?=executables:)'), ''),
  );
  await File(
    '${package.path}/test/fixtures/ffi_transport_probe.dart',
  ).copy('${copy.path}/bin/ffi_transport_probe.dart');
  await File(
    '${package.path}/test/fixtures/global_budget_driver.dart',
  ).copy('${copy.path}/bin/global_budget_driver.dart');
  final config =
      jsonDecode(
            await File(
              '${package.path}/.dart_tool/package_config.json',
            ).readAsString(),
          )
          as Map;
  final packageRecords = {
    for (final record in (config['packages'] as List).cast<Map>())
      record['name'] as String: record,
  };
  final runtimeSpec = loadYaml(spec) as Map;
  final pending =
      (runtimeSpec['dependencies'] as Map).keys.cast<String>().toList();
  final copied = <String>{};
  final configUri = File('${package.path}/.dart_tool/package_config.json').uri;
  while (pending.isNotEmpty) {
    final name = pending.removeLast();
    if (!copied.add(name)) continue;
    final source = Directory.fromUri(
      configUri.resolve(packageRecords[name]!['rootUri'] as String),
    );
    final target = Directory(
      '${cache.path}/hosted/pub.dev/${source.uri.pathSegments.where((s) => s.isNotEmpty).last}',
    );
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: true)) {
      final destination =
          '${target.path}${entity.path.substring(source.path.length)}';
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      }
      if (entity is File) await entity.copy(destination);
    }
    final dependencySpec =
        loadYaml(await File('${source.path}/pubspec.yaml').readAsString())
            as Map;
    for (final entry
        in (dependencySpec['dependencies'] as Map? ?? {}).entries) {
      if (entry.value is Map && (entry.value as Map).containsKey('sdk')) {
        continue;
      }
      pending.add(entry.key as String);
    }
  }
  final records = <Map<String, Object?>>[];
  Future<void> run(
    String label,
    List<String> arguments, {
    int expected = 0,
    String? containsOutput,
    String? executable,
    bool runInShell = false,
    Map<String, String> environment = const {},
  }) async {
    final clock = Stopwatch()..start();
    final process = await Process.start(
      executable ?? Platform.resolvedExecutable,
      arguments,
      runInShell: runInShell,
      workingDirectory: fixture.path,
      environment: {
        'PUB_CACHE': cache.path,
        'PATH':
            '${File(Platform.resolvedExecutable).parent.path};${Platform.environment['PATH'] ?? ''}',
        ...environment,
      },
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    int code;
    try {
      code = await process.exitCode.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      // Only the process tree created by this check is in scope.
      await Process.run('taskkill', [
        '/PID',
        '${process.pid}',
        '/T',
        '/F',
      ]).timeout(const Duration(seconds: 5));
      await process.exitCode.timeout(const Duration(seconds: 5));
      records.add({
        'label': label,
        'timedOut': true,
        'milliseconds': clock.elapsedMilliseconds,
        'stdout': await output,
        'stderr': await errors,
      });
      await File(
        '${fixture.path}/results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(records));
      stderr.writeln(
        'Timed out: $label; results: ${fixture.path}/results.json',
      );
      rethrow;
    }
    final result = ProcessResult(process.pid, code, await output, await errors);
    records.add({
      'label': label,
      'exitCode': result.exitCode,
      'milliseconds': clock.elapsedMilliseconds,
      'stdout': result.stdout,
      'stderr': result.stderr,
    });
    await File(
      '${fixture.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(records));
    stdout.writeln('$label: ${result.exitCode}');
    if (result.exitCode != expected) {
      throw StateError('$label failed: ${result.stdout}\n${result.stderr}');
    }
    if (containsOutput != null &&
        !result.stdout.toString().contains(containsOutput)) {
      throw StateError('$label missing $containsOutput: ${result.stdout}');
    }
  }

  stdout.writeln('fixture: ${fixture.path}');
  for (final cycle in [1, 2]) {
    if (cycle == 2) {
      final manifest = File('${copy.path}/pubspec.yaml');
      await manifest.writeAsString(
        (await manifest.readAsString()).replaceFirst(
          'version: 0.1.0',
          'version: 0.1.1',
        ),
      );
    }
    await run('activate-$cycle', [
      'pub',
      'global',
      'activate',
      '--source',
      'path',
      copy.path,
    ]);
    await run('help-$cycle', [
      'pub',
      'global',
      'run',
      'dart_analysis_daemon',
      '--help',
    ]);
    await run(
      'launcher-$cycle',
      ['--help'],
      executable: '${cache.path}/bin/dana.bat',
      runInShell: true,
      containsOutput: '--version',
    );
    await run(
      'ffi-probe-$cycle',
      ['pub', 'global', 'run', 'dart_analysis_daemon:ffi_transport_probe'],
      environment: {'DANA_PROCESS_BACKEND': 'windows-ffi-job'},
      containsOutput: '"ok":true',
    );
    final root =
        await Directory('${fixture.path}/managed-root-$cycle').create();
    final target = await File(
      '${root.path}/file.dart',
    ).writeAsString('int value = 1;');
    final managedEnvironment = {
      'DANA_GLOBAL_BUDGET': '1',
      'DANA_GLOBAL_STATE_DIR': '${fixture.path}/managed-state-$cycle',
      'DANA_GLOBAL_COOLDOWN_MS': '0',
      'DANA_ANALYSIS_TIMEOUT_SECONDS': '5',
    };
    final command = [
      'pub',
      'global',
      'run',
      'dart_analysis_daemon:global_budget_driver',
    ];
    try {
      await run(
        'global-api-$cycle',
        [...command, '--api-check', root.path, target.path],
        environment: managedEnvironment,
        containsOutput: '"globalBudget":true',
      );
      await run(
        'global-root-stop-$cycle',
        [...command, 'stop', '--root', root.path],
        environment: managedEnvironment,
        containsOutput: '"shutdownComplete":true',
      );
    } finally {
      await run(
        'global-owner-stop-$cycle',
        [...command, 'budget', 'stop'],
        environment: managedEnvironment,
        containsOutput: '"shutdownComplete":true',
      );
    }
  }
  stdout.writeln('isolated-install-ok');
}
