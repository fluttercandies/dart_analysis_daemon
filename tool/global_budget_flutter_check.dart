// Protected real Flutter comparison. Uses only the prepared temporary worktrees.
// Every product process belongs to an outer kill-on-close FFI Job.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/session_server.dart' show endpointFile;
import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--worker') {
    await _worker(args.skip(1).toList());
    return;
  }
  final output = await Directory.systemTemp.createTemp('dana-global-flutter-');
  final manifest =
      jsonDecode(
            await File(
              '../benchmarks/minimal-plugin/worktree-flutter-fixture1.json',
            ).readAsString(),
          )
          as Map;
  final sources = [
    for (final entry in manifest['roots'] as List)
      (entry as Map)['root'] as String,
  ];
  final roots = <String>[];
  final sampler = WindowsSystemMemorySampler();
  final results = <Object?>[];
  final report = <String, Object?>{
    'sdk': Platform.version,
    'fixtureManifest': manifest,
    'results': results,
    'reserveMiB': 4096,
    'startupRequiredMiB': 5120,
    'outerJobPeakLimitMiB': 4096,
    'diagnosticCompletionVerified': false,
    'comparisonScope':
        'isolated copies of prepared Flutter worktrees; owned whole product tree including root sessions and budget owner',
  };
  for (final root in sources) {
    if (!Directory(root).existsSync() ||
        !File('$root/lib/probe.dart').existsSync()) {
      throw StateError('Prepared Flutter worktree is missing: $root');
    }
    final head = await Process.run('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: root);
    if (head.exitCode != 0 || '${head.stdout}'.trim() != manifest['commit']) {
      throw StateError('Prepared worktree commit changed');
    }
    final copy = await Directory('${output.path}/root${roots.length}').create();
    roots.add(await copy.resolveSymbolicLinks());
    // Do not connect to or clean up any endpoint in the source worktree.
    for (final name in [
      'pubspec.yaml',
      'pubspec.lock',
      'analysis_options.yaml',
    ]) {
      await File('$root/$name').copy('${copy.path}/$name');
    }
    await for (final entity in Directory(
      '$root/lib',
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(Directory(root).path.length + 1);
      final target = File('${copy.path}/$relative');
      await target.parent.create(recursive: true);
      await entity.copy(target.path);
    }
    final original = File('$root/.dart_tool/package_config.json');
    final config = jsonDecode(await original.readAsString()) as Map;
    for (final package in config['packages'] as List) {
      final location = original.uri.resolve(
        (package as Map)['rootUri'] as String,
      );
      final self =
          Directory.fromUri(
            location,
          ).resolveSymbolicLinksSync().toLowerCase() ==
          Directory(root).resolveSymbolicLinksSync().toLowerCase();
      package['rootUri'] = (self ? copy.uri : location).toString();
    }
    final destination = File('${copy.path}/.dart_tool/package_config.json');
    await destination.parent.create();
    await destination.writeAsString(jsonEncode(config));
  }
  report['isolatedRoots'] = roots;
  final scenarios =
      (args.contains('--single-global') || args.contains('--global-cycles'))
          ? [('global', 3)]
          : [
            ('global', 3),
            ('independent', 1),
            ('global', 1),
            ('independent', 2),
            ('global', 2),
            ('independent', 3),
          ];
  for (final scenario in scenarios) {
    final initial = sampler.sample();
    if (initial == null ||
        !initial.freshAt(DateTime.now().toUtc()) ||
        initial.availablePhysicalBytes < 5120 * bytesPerMiB ||
        initial.availableCommitBytes < 5120 * bytesPerMiB) {
      results.add({
        'mode': scenario.$1,
        'roots': scenario.$2,
        'skipped': true,
        'reason': 'startup admission',
        'memory': initial?.toJson(),
      });
      break;
    }
    final caseDirectory =
        await Directory(
          '${output.path}/${scenario.$1}-${scenario.$2}',
        ).create();
    final snapshots = <Map<String, Object?>>[];
    final record = <String, Object?>{
      'mode': scenario.$1,
      'roots': scenario.$2,
      'snapshots': snapshots,
    };
    results.add(record);
    WindowsFfiAnalyzerProcess? owner;
    Timer? guard;
    Object? failure;
    final childLog = StringBuffer();
    final phaseClock = Stopwatch()..start();
    int? steadyStart;
    int? steadyEnd;
    try {
      owner = await WindowsFfiAnalyzerProcess.start(
        Platform.resolvedExecutable,
        [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          File.fromUri(Platform.script).path,
          '--worker',
          args.contains('--global-cycles') ? 'global-cycles' : scenario.$1,
          caseDirectory.path,
          ...roots.take(scenario.$2),
        ],
        workingDirectory: Directory.current.path,
      );
      final owned = owner;
      final stdoutDone = owned.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            childLog.writeln(line);
            final event = jsonDecode(line) as Map;
            if (event['event'] == 'steady') {
              steadyStart = phaseClock.elapsedMilliseconds;
            } else if (event['event'] == 'steadyEnd') {
              steadyEnd = phaseClock.elapsedMilliseconds;
            }
            stdout.writeln('${scenario.$1}/${scenario.$2}: $line');
          });
      final errors = owned.stderr.transform(utf8.decoder).join();
      void sample() {
        if (failure != null) return;
        final memory = sampler.sample();
        Map<String, Object?>? tree;
        try {
          tree = owned.sampleResources();
        } catch (error) {
          failure = error;
        }
        final value = {
          'elapsedMs': phaseClock.elapsedMilliseconds,
          'system': memory?.toJson(),
          'tree': tree,
        };
        snapshots.add(value);
        if (memory == null ||
            !memory.freshAt(DateTime.now().toUtc()) ||
            memory.availablePhysicalBytes < 4096 * bytesPerMiB ||
            memory.availableCommitBytes < 4096 * bytesPerMiB ||
            tree == null ||
            tree['peakPrivateMiB'] is! num ||
            (tree['peakPrivateMiB'] as num) > 4096) {
          failure ??= StateError('Runtime protection: ${jsonEncode(value)}');
          owned.terminate().ignore();
        }
      }

      guard = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => sample(),
      );
      final code = await owned.exitCode.timeout(const Duration(minutes: 10));
      guard.cancel();
      await owned.terminate();
      await stdoutDone;
      if (steadyStart != null && steadyEnd != null) {
        final values = <double>[];
        for (final sample in snapshots) {
          final at = sample['elapsedMs'] as int;
          final tree = sample['tree'];
          if (at >= steadyStart! &&
              at <= steadyEnd! &&
              tree is Map &&
              tree['complete'] == true &&
              tree['currentPrivateMiB'] is num) {
            values.add((tree['currentPrivateMiB'] as num).toDouble());
          }
        }
        values.sort();
        record['steadyWindow'] = {
          'durationMs': steadyEnd! - steadyStart!,
          'completeSamples': values.length,
          if (values.isNotEmpty) ...{
            'minPrivateMiB': values.first,
            'medianPrivateMiB': values[values.length ~/ 2],
            'maxPrivateMiB': values.last,
          },
        };
      }
      record['stderr'] = await errors;
      record['exitCode'] = code;
      record['jobEmpty'] = owned.confirmedEmpty;
      record['workerResult'] =
          await File('${caseDirectory.path}/worker-results.json').exists()
              ? jsonDecode(
                await File(
                  '${caseDirectory.path}/worker-results.json',
                ).readAsString(),
              )
              : null;
      record['ok'] = code == 0 && failure == null && owned.confirmedEmpty;
    } catch (error, stack) {
      failure ??= error;
      record['stack'] = '$stack';
    } finally {
      guard?.cancel();
      try {
        await owner?.terminate();
      } catch (error) {
        failure ??= error;
      }
      record['failure'] = failure == null ? null : '$failure';
      record['log'] = '$childLog';
      await File(
        '${output.path}/results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    }
    if (failure != null || record['ok'] != true) {
      exitCode = 1;
      break; // Never retry protection failures.
    }
  }
  stdout.writeln('results: ${output.path}/results.json');
}

Future<void> _worker(List<String> args) async {
  final cycles = args[0] == 'global-cycles';
  final mode = cycles ? 'global' : args[0];
  final output = Directory(args[1]);
  final roots = args.skip(2).toList();
  final cli = '${Directory.current.path}/bin/dart_analysis_daemon.dart';
  final environment = {
    'DANA_GLOBAL_BUDGET': mode == 'global' ? '1' : '0',
    'DANA_GLOBAL_STATE_DIR': '${output.path}/budget-state',
    'DANA_GLOBAL_RESERVE_MIB': '4096',
    'DANA_GLOBAL_STARTUP_MIB': '1024',
    'DANA_GLOBAL_QUEUE_TIMEOUT_SECONDS': '180',
    'DANA_GLOBAL_IDLE_SECONDS': '300',
    'DANA_GLOBAL_COOLDOWN_MS': '100',
    'DANA_DART_EXECUTABLE': Platform.resolvedExecutable,
    'DANA_PROCESS_BACKEND': 'windows-ffi-job',
    'DANA_ANALYSIS_TIMEOUT_SECONDS': '150',
    'DASH__SUPPRESS_ANALYTICS': 'true',
  };
  final processes = <Process>[];
  final errors = <Future<String>>[];
  final checks = <Map<String, Object?>>[];
  final startup = <Map<String, Object?>>[];
  final result = <String, Object?>{
    'mode': mode,
    'roots': roots,
    'checks': checks,
    'startup': startup,
  };
  Future<Map<String, Object?>> command(List<String> args) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      cli,
      ...args,
    ], environment: environment);
    final outputText = process.stdout.transform(utf8.decoder).join();
    final errorText = process.stderr.transform(utf8.decoder).join();
    final code = await process.exitCode.timeout(const Duration(seconds: 180));
    final text = await outputText;
    final decoded = text.trim().isEmpty ? null : jsonDecode(text);
    // CLI exit 1 also represents valid diagnostics with errors, not a transport failure.
    if ((code != 0 &&
        !(code == 1 && decoded is Map && decoded['ok'] == true))) {
      throw StateError(
        'Product command failed ($code): $args\n${await errorText}\n$text',
      );
    }
    return Map<String, Object?>.from(decoded as Map);
  }

  try {
    for (var i = 0; i < roots.length; i++) {
      final root = roots[i];
      final startupClock = Stopwatch()..start();
      final serving = await Process.start(Platform.resolvedExecutable, [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        cli,
        'serve',
        '--root',
        root,
      ], environment: environment);
      processes.add(serving);
      serving.stdout.drain<void>().ignore();
      errors.add(serving.stderr.transform(utf8.decoder).join());
      final startupDeadline = DateTime.now().add(const Duration(seconds: 175));
      while (!await endpointFile(root).exists()) {
        if (DateTime.now().isAfter(startupDeadline)) {
          throw TimeoutException('Product root startup: $root');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final lifecycle = <String, Object?>{
        'rootIndex': i,
        'serveLaunchToEndpointMs': startupClock.elapsedMilliseconds,
      };
      startup.add(lifecycle);
      for (var query = 0; query < 2; query++) {
        final clock = Stopwatch()..start();
        final response = await command([
          'check',
          '--root',
          root,
          '--reuse-ide',
          'never',
          '--files',
          File('$root/lib/probe.dart').resolveSymbolicLinksSync(),
        ]);
        checks.add({
          'rootIndex': i,
          'query': query,
          'elapsedMs': clock.elapsedMilliseconds,
          'response': response,
        });
        if (query == 0) {
          lifecycle['serveLaunchToFirstCheckMs'] =
              startupClock.elapsedMilliseconds;
        }
        stdout.writeln(
          jsonEncode({
            'event': 'check',
            'rootIndex': i,
            'query': query,
            'elapsedMs': clock.elapsedMilliseconds,
          }),
        );
        await stdout.flush();
      }
    }
    if (cycles) {
      for (var cycle = 0; cycle < 3; cycle++) {
        final order =
            cycle.isEven
                ? roots.asMap().keys.toList().reversed
                : roots.asMap().keys;
        for (final i in order) {
          final clock = Stopwatch()..start();
          final response = await command([
            'check',
            '--root',
            roots[i],
            '--reuse-ide',
            'never',
            '--files',
            File('${roots[i]}/lib/probe.dart').resolveSymbolicLinksSync(),
          ]);
          checks.add({
            'rootIndex': i,
            'cycle': cycle,
            'elapsedMs': clock.elapsedMilliseconds,
            'response': response,
          });
          stdout.writeln(
            jsonEncode({
              'event': 'cycle-check',
              'cycle': cycle,
              'rootIndex': i,
              'elapsedMs': clock.elapsedMilliseconds,
            }),
          );
          await stdout.flush();
        }
      }
    }
    stdout.writeln(jsonEncode({'event': 'steady', 'roots': roots.length}));
    await stdout.flush();
    await Future<void>.delayed(const Duration(seconds: 2));
    stdout.writeln(jsonEncode({'event': 'steadyEnd', 'roots': roots.length}));
    await stdout.flush();
    if (mode == 'global') {
      result['globalStatus'] = await command(['budget', 'status']);
    }
    result['ok'] = true;
  } catch (error, stack) {
    result['error'] = '$error';
    result['stack'] = '$stack';
    exitCode = 1;
  } finally {
    try {
      for (final root in roots) {
        if (await endpointFile(root).exists()) {
          await command(['stop', '--root', root]);
        }
      }
      if (mode == 'global' &&
          await File('${output.path}/budget-state/endpoint.json').exists()) {
        result['stop'] = await command(['budget', 'stop']);
      }
      for (final process in processes) {
        await process.exitCode.timeout(const Duration(seconds: 10));
      }
      result['serverLogs'] = [for (final log in errors) await log];
    } catch (error) {
      result['cleanupError'] = '$error';
      exitCode = 1;
    }
    await File(
      '${output.path}/worker-results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
  }
}
