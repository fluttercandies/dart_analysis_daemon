// Isolated real SDK cache experiment. Never edits the original plugin/cache.
// The controller owns the whole experiment tree through a kill-on-close Job.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_analysis_daemon/src/environment_identity.dart';
import 'package:dart_analysis_daemon/src/managed_plugin_cache.dart';
import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';

import 'worktree_analyzer_client.dart';

Future<void> main(List<String> args) async {
  if (args.length == 2 && args.first == '--worker') {
    await _worker(Directory(args.last));
    return;
  }
  if (args.isNotEmpty || !Platform.isWindows) {
    throw ArgumentError('Run without arguments on Windows');
  }
  final output = await Directory.systemTemp.createTemp('dana-plugin-cache-');
  final sampler = WindowsSystemMemorySampler();
  final initial = sampler.sample();
  final report = <String, Object?>{
    'sdk': Platform.version,
    'sdkRevision':
        await File(
          '${File(Platform.resolvedExecutable).parent.parent.path}/revision',
        ).readAsString(),
    'fixture': output.path,
    'initialMemory': initial?.toJson(),
    'reserveMiB': 4096,
    'startupRequiredMiB': 5120,
    'outerJobPeakLimitMiB': 4096,
    'diagnosticComplete': false,
  };
  WindowsFfiAnalyzerProcess? owner;
  Timer? guard;
  Object? failure;
  final samples = <Map<String, Object?>>[];
  try {
    if (initial == null ||
        !initial.freshAt(DateTime.now().toUtc()) ||
        initial.availablePhysicalBytes < 5120 * bytesPerMiB ||
        initial.availableCommitBytes < 5120 * bytesPerMiB) {
      report['skipped'] = 'startup admission';
      return;
    }
    owner = await WindowsFfiAnalyzerProcess.start(Platform.resolvedExecutable, [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      File.fromUri(Platform.script).path,
      '--worker',
      output.path,
    ], workingDirectory: Directory.current.path);
    final owned = owner;
    final lines = owned.stdout.transform(utf8.decoder).join();
    final errors = owned.stderr.transform(utf8.decoder).join();
    void sample() {
      if (failure != null) return;
      try {
        final memory = sampler.sample();
        final tree = owned.sampleResources();
        samples.add({'system': memory?.toJson(), 'tree': tree});
        if (memory == null ||
            !memory.freshAt(DateTime.now().toUtc()) ||
            memory.availablePhysicalBytes < 4096 * bytesPerMiB ||
            memory.availableCommitBytes < 4096 * bytesPerMiB ||
            tree['peakPrivateMiB'] is! num ||
            (tree['peakPrivateMiB'] as num) > 4096) {
          throw StateError('Runtime memory protection');
        }
      } catch (error) {
        failure = error;
        owned.terminate().ignore();
      }
    }

    guard = Timer.periodic(const Duration(milliseconds: 250), (_) => sample());
    sample();
    report['exitCode'] = await owned.exitCode.timeout(
      const Duration(minutes: 5),
    );
    guard.cancel();
    await owned.terminate();
    report['stdout'] = await lines;
    report['stderr'] = await errors;
    final result = File('${output.path}/worker-results.json');
    if (await result.exists()) {
      report['workerResult'] = jsonDecode(await result.readAsString());
    }
    if (report['exitCode'] != 0) throw StateError('Cache worker failed');
  } catch (error, stack) {
    failure ??= error;
    report['stack'] = '$stack';
  } finally {
    guard?.cancel();
    try {
      await owner?.terminate();
    } catch (error) {
      failure ??= error;
    }
    report['jobEmpty'] = owner?.confirmedEmpty;
    report['failure'] = failure == null ? null : '$failure';
    report['samples'] = samples;
    await File(
      '${output.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('results: ${output.path}/results.json');
    if (failure != null) exitCode = 1;
  }
}

Future<void> _worker(Directory fixture) async {
  final project = Directory(
    await (await Directory('${fixture.path}/project').create())
        .resolveSymbolicLinks(),
  );
  final plugin = Directory(
    await (await Directory('${fixture.path}/plugin').create())
        .resolveSymbolicLinks(),
  );
  final original = Directory(
    '../benchmarks/minimal-plugin/plugin-dynamic-probe',
  );
  await File(
    '${original.path}/pubspec.yaml',
  ).copy('${plugin.path}/pubspec.yaml');
  await Directory('${plugin.path}/lib').create();
  final source = File('${plugin.path}/lib/main.dart');
  final baseline = await File('${original.path}/lib/main.dart').readAsString();
  await source.writeAsString(baseline);
  final baselineTime = await source.lastModified();
  await Directory('${project.path}/lib').create();
  final target = await File('${project.path}/lib/probe.dart').writeAsString(
    'class SyntaxProbeBaseline {}\nclass UpdatedProbe {}\nclass RestoredProbe {}\n',
  );
  final targetPath = await target.resolveSymbolicLinks();
  await File(
    '${project.path}/pubspec.yaml',
  ).writeAsString('name: cache_probe\nenvironment:\n  sdk: ^3.9.0\n');
  await Directory('${project.path}/.dart_tool').create();
  await File('${project.path}/.dart_tool/package_config.json').writeAsString(
    jsonEncode({
      'configVersion': 2,
      'packages': [
        {
          'name': 'cache_probe',
          'rootUri': '../',
          'packageUri': 'lib/',
          'languageVersion': '3.9',
        },
      ],
    }),
  );
  await File('${project.path}/analysis_options.yaml').writeAsString(
    'plugins:\n  minimal_plugin:\n    path: ${plugin.path.replaceAll('\\', '/')}\n',
  );
  var state = await Directory('${fixture.path}/sdk-state').create();
  final records = <Map<String, Object?>>[];
  Future<void> observe(String phase, String expected) async {
    final identity = await EnvironmentIdentity().capture(project.path);
    final client = ResearchAnalyzerClient(
      project.path,
      File('${fixture.path}/$phase.protocol.jsonl'),
      maxLogBytes: 4 * 1024 * 1024,
      maxRequestTimings: 64,
      launch:
          () => Process.start(
            Platform.resolvedExecutable,
            [
              'language-server',
              '--protocol=analyzer',
              '--client-id=cache-research',
            ],
            workingDirectory: project.path,
            environment: {
              'ANALYZER_STATE_LOCATION_OVERRIDE': state.path,
              // SDK-supported per-process suppression; never change user settings.
              'DASH__SUPPRESS_ANALYTICS': 'true',
            },
          ),
    );
    final clock = Stopwatch()..start();
    try {
      await client.start();
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      List<dynamic>? observed;
      while (true) {
        if (client.failure != null) throw StateError('${client.failure}');
        final diagnostics = client.errors[targetPath];
        final syntax =
            diagnostics
                ?.where((e) => e is Map && e['code'] == 'dynamic_syntax_probe')
                .toList();
        if (syntax != null &&
            syntax.length == 1 &&
            (syntax.single['message'] as String).contains(expected)) {
          observed = syntax;
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('$phase expected $expected; got $diagnostics');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final hosts =
          await Directory(
            '${state.path}/.plugin_manager',
          ).list().where((e) => e is Directory).toList();
      if (hosts.length != 1) throw StateError('Expected one isolated host');
      final host = hosts.single.path;
      final config = File('$host/.dart_tool/package_config.json');
      final packages =
          (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
      final resolved =
          packages.where((p) => p['name'] == 'minimal_plugin').single;
      final actualRoot = Directory.fromUri(
        config.uri.resolve(resolved['rootUri'] as String),
      );
      if ((await actualRoot.resolveSymbolicLinks()).toLowerCase() !=
          (await plugin.resolveSymbolicLinks()).toLowerCase()) {
        throw StateError('Actual host did not resolve the isolated plugin');
      }
      final snapshot = File('$host/bin/plugin.aot');
      final artifacts = <String, Object?>{};
      for (final name in [
        'pubspec.yaml',
        'pubspec.lock',
        '.dart_tool/package_config.json',
        'bin/plugin.dart',
        'bin/depfile.txt',
      ]) {
        final file = File('$host/$name');
        final bytes = await file.readAsBytes();
        if (bytes.length > 4 * 1024 * 1024) {
          throw StateError('Host observation artifact exceeds 4MiB');
        }
        artifacts[name] = {
          'sha256': sha256.convert(bytes).toString(),
          'bytes': bytes.length,
        };
      }
      records.add({
        'phase': phase,
        'environmentIdentity': identity,
        'sourceSha256': sha256.convert(await source.readAsBytes()).toString(),
        'sourceModified': (await source.lastModified()).toIso8601String(),
        'host': host,
        'resolvedPluginRoot': actualRoot.path,
        'hostArtifacts': artifacts,
        'resolvedPackages': [
          for (final package in packages)
            {
              'name': package['name'],
              'rootUri':
                  config.uri.resolve(package['rootUri'] as String).toString(),
              'packageUri': package['packageUri'],
              'languageVersion': package['languageVersion'],
            },
        ],
        'snapshotSha256':
            sha256.convert(await snapshot.readAsBytes()).toString(),
        'snapshotModified': (await snapshot.lastModified()).toIso8601String(),
        'elapsedMs': clock.elapsedMilliseconds,
        'observed': observed,
        'observationOnly': true,
      });
    } finally {
      try {
        try {
          await client.close();
        } catch (error) {
          // The real server can exit 0 before its shutdown response is read.
          // Preserve this observation; tree cleanup is owned by the controller.
          final code = await client.process!.exitCode.timeout(
            const Duration(seconds: 5),
          );
          if (code != 0 || client.problems.isNotEmpty) rethrow;
          records.add({
            'phase': '$phase-shutdown',
            'exitCode': code,
            'closeError': '$error',
          });
        }
      } finally {
        await File('${fixture.path}/worker-results.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({'records': records}),
        );
      }
    }
  }

  await observe('baseline', 'SyntaxProbeBaseline');
  await source.writeAsString(
    baseline.replaceAll(
      "startsWith('SyntaxProbe')",
      "startsWith('UpdatedProbe')",
    ),
  );
  await observe('ordinary-edit', 'UpdatedProbe');
  await source.writeAsString(
    baseline.replaceAll(
      "startsWith('SyntaxProbe')",
      "startsWith('RestoredProbe')",
    ),
  );
  await source.setLastModified(baselineTime);
  // Matching SDK source predicts that an older timestamp reuses the last AOT.
  // This is a deliberately scoped stale-cache observation, never a product pass.
  await observe('preserved-timestamp-edit', 'UpdatedProbe');
  final observations =
      records.where((r) => r.containsKey('snapshotSha256')).toList();
  if (observations.map((r) => r['environmentIdentity']).toSet().length != 3 ||
      observations[0]['snapshotSha256'] == observations[1]['snapshotSha256'] ||
      observations[1]['snapshotSha256'] != observations[2]['snapshotSha256']) {
    throw StateError('Unexpected identity/cache behavior');
  }
  // A fresh analyzer-owned state bypasses the old AOT without touching any
  // shared SDK/plugin cache or changing the source timestamp again.
  final cache = ManagedPluginCache(fixture, 'sdk-cache-${'c' * 16}');
  final observedIdentity = await EnvironmentIdentity().capture(project.path);
  state = await cache.prepare(project.path, observedIdentity);
  if ((await cache.prepare(project.path, observedIdentity)).path !=
      state.path) {
    throw StateError('Unchanged cache identity was not reused');
  }
  await observe('isolated-state-recovery', 'RestoredProbe');
  final recovered = records.lastWhere((r) => r.containsKey('snapshotSha256'));
  if (observations[2]['environmentIdentity'] !=
          recovered['environmentIdentity'] ||
      observations[2]['snapshotSha256'] == recovered['snapshotSha256']) {
    throw StateError('Fresh state did not bypass the stale snapshot');
  }
}
