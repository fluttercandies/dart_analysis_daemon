// Real product experiment; all descendants contained in a research native Job.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'worktree_native_worker_adapter.dart';
import 'worktree_resource_sampler.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty ||
      args.length > 2 ||
      (args.length == 2 && args[1] != '--flutter-example')) {
    throw ArgumentError('Supply warmed project and optional --flutter-example');
  }
  final flutterExample = args.contains('--flutter-example');
  final fixture = await Directory.systemTemp.createTemp('dana-product-idle-');
  late final Directory root;
  Map<String, Object?>? projectIdentity;
  if (flutterExample) {
    final manifestFile = File.fromUri(
      Platform.script.resolve(
        '../../benchmarks/minimal-plugin/worktree-flutter-fixture1.json',
      ),
    );
    final manifest = jsonDecode(await manifestFile.readAsString()) as Map;
    root = Directory(Directory(args.first).resolveSymbolicLinksSync());
    final matches = (manifest['roots'] as List).where(
      (entry) => entry['root'] == root.path,
    );
    if (matches.length != 1) {
      throw StateError(
        'Only a previously prepared temporary Flutter worktree is allowed',
      );
    }
    final head = await Process.run('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: root.path);
    final config =
        jsonDecode(
              await File(
                '${root.path}/.dart_tool/package_config.json',
              ).readAsString(),
            )
            as Map;
    final expectedSdk = Directory.fromUri(
      Uri.parse(config['flutterRoot'] as String),
    );
    final expectedDart =
        File(
          '${expectedSdk.path}/bin/cache/dart-sdk/bin/dart.exe',
        ).resolveSymbolicLinksSync();
    if (head.exitCode != 0 ||
        '${head.stdout}'.trim() != manifest['commit'] ||
        expectedDart.toLowerCase() !=
            File(
              Platform.resolvedExecutable,
            ).resolveSymbolicLinksSync().toLowerCase()) {
      throw StateError('Flutter project commit or selected SDK mismatch');
    }
    final fileCount = root.listSync(recursive: false).length;
    projectIdentity = {
      'commit': manifest['commit'],
      'root': root.path,
      'dartExecutable': expectedDart,
      'runtimeVersion': Platform.version,
      'libDartFiles':
          Directory('${root.path}/lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => file.path.endsWith('.dart'))
              .length,
      'rootEntries': fileCount,
    };
  } else {
    root = await Directory('${fixture.path}/project').create();
    for (final name in [
      'pubspec.yaml',
      'pubspec.lock',
      'analysis_options.yaml',
      '.dart_tool/package_config.json',
      '.dart_tool/package_graph.json',
      'lib/probe.dart',
      'lib/dependency.dart',
    ]) {
      final output = File('${root.path}/$name');
      await output.parent.create(recursive: true);
      await File('${args.first}/$name').copy(output.path);
    }
  }
  final resources = await ResearchResourceSampler.start();
  NativeModelWorker? worker;
  Timer? guard;
  Object? failure;
  var skipped = false;
  final snapshots = <Map>[];
  final cycles = <Map>[];
  Map sample(String phase) => {
    'phase': phase,
    'at': DateTime.now().toUtc().toIso8601String(),
    'memory': resources.status,
    'active': worker?.activeProcesses,
    'jobPids': worker?.jobPids,
    'privateMiB': worker?.currentPrivateCommitMiB,
    'workingSetMiB': worker?.currentWorkingSetMiB,
    'peakMiB': worker?.peakPrivateCommitMiB,
    'healthFresh': worker?.healthFresh,
  };
  Future<void> waitFor(bool Function() predicate, Duration timeout) async {
    final watch = Stopwatch()..start();
    while (!predicate()) {
      if (failure != null) throw StateError('$failure');
      if (watch.elapsed > timeout) throw TimeoutException('Job lifecycle');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  try {
    snapshots.add(sample('admission'));
    if (!resources.allowed) {
      skipped = true;
      return;
    }
    worker = await NativeModelWorker.start(
      fixture,
      officialRoot: root.path,
      workerScriptPath:
          File.fromUri(
            Platform.script.resolve('worktree_product_idle_worker.dart'),
          ).path,
      workerEnvironment: {
        'DANA_DART_EXECUTABLE': Platform.resolvedExecutable,
        'DANA_SESSION_IDLE_TIMEOUT_SECONDS': '2',
        'DANA_ANALYSIS_TIMEOUT_SECONDS': '150',
      },
    );
    await waitFor(() => worker!.healthFresh, const Duration(seconds: 3));
    final baselineProcesses = worker.activeProcesses!;
    final baselinePids = worker.jobPids.toSet();
    if (baselinePids.length != baselineProcesses) {
      throw StateError('Initial Job membership sample incomplete');
    }
    guard = Timer.periodic(const Duration(milliseconds: 250), (_) {
      snapshots.add(sample('monitor'));
      final age = resources.ageMs;
      if (resources.exited ||
          age == null ||
          age > 2000 ||
          (resources.physicalMiB ?? 0) < 4096 ||
          (resources.commitMiB ?? 0) < 4096 ||
          !worker!.healthFresh ||
          (worker.peakPrivateCommitMiB ?? 0) > 4096 ||
          worker.lastFailure != null) {
        failure ??= StateError(
          'Runtime protection: ${jsonEncode(sample('stop'))}',
        );
        unawaited(
          worker!.close().catchError((Object error) {
            failure ??= error;
          }),
        );
      }
    });
    for (var cycle = 0; cycle < 2; cycle++) {
      if (!resources.allowed) {
        throw StateError('Fresh analyzer admission denied');
      }
      final baseline = sample('baseline-$cycle');
      final result = await worker.officialRequest(
        'initialize',
        budget: const Duration(seconds: 160),
      );
      snapshots.add({...sample('check-completed-$cycle'), 'response': result});
      if (result['ok'] != true ||
          result['idleTimeoutSeconds'] != 2 ||
          (result['errors'] as num?) == null ||
          (result['errors'] as num) < 1) {
        throw StateError('Product check failed: $result');
      }
      if (cycles.isNotEmpty &&
          cycles.last['start']['sessionPid'] == result['sessionPid']) {
        throw StateError('Session PID was reused');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      final resident = sample('resident-$cycle');
      if ((worker.activeProcesses ?? 0) <= baselineProcesses) {
        throw StateError('Analyzer not observed');
      }
      final released = await worker.officialRequest(
        'release',
        budget: const Duration(seconds: 25),
      );
      if (released['ok'] != true) throw StateError('Release failed: $released');
      snapshots.add({
        ...sample('endpoint-removed-$cycle'),
        'release': released,
      });
      await waitFor(
        () =>
            worker!.activeProcesses == baselineProcesses &&
            worker.jobPids.length == baselinePids.length &&
            baselinePids.containsAll(worker.jobPids),
        const Duration(seconds: 10),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final reclaimed = sample('reclaimed-$cycle');
      cycles.add({
        'cycle': cycle,
        'start': result,
        'release': released,
        'baseline': baseline,
        'resident': resident,
        'reclaimed': reclaimed,
      });
      print('PASS product idle cycle $cycle ${jsonEncode(cycles.last)}');
    }
  } catch (error) {
    failure ??= error;
    print('FAIL $error');
    if (worker != null && !worker.confirmedEmpty && worker.jobPids.isNotEmpty) {
      // Read-only diagnostics restricted to PIDs observed in this test's Job.
      final ids = worker.jobPids.join(',');
      final detail = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Get-CimInstance Win32_Process | Where-Object { @($ids) -contains \$_.ProcessId } | Select-Object ProcessId,ParentProcessId,Name,CommandLine | ConvertTo-Json -Compress',
      ]).timeout(const Duration(seconds: 10));
      snapshots.add({
        'phase': 'failure-processes',
        'stdout': '${detail.stdout}',
        'stderr': '${detail.stderr}',
      });
    }
  } finally {
    guard?.cancel();
    if (worker != null) {
      try {
        await worker.close();
      } catch (error) {
        failure ??= error;
      }
    }
    await resources.close();
    final report = {
      'fixture': fixture.path,
      'scope': flutterExample ? 'real-flutter-example' : 'microfixture',
      'project': projectIdentity,
      'skipped': skipped,
      'allPassed':
          !skipped &&
          failure == null &&
          cycles.length == 2 &&
          worker?.confirmedEmpty == true,
      'failure': failure?.toString(),
      'jobEmpty': worker?.confirmedEmpty,
      'cycles': cycles,
      'snapshots': snapshots,
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
