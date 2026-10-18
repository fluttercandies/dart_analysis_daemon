// Research residency comparison, with explicit microfixture/Flutter scope.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_environment_identity.dart';
import 'worktree_native_worker_adapter.dart';
import 'worktree_resource_sampler.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty ||
      args
          .skip(1)
          .any(
            (a) =>
                a != '--reuse-roots' &&
                a != '--reverse-order' &&
                a != '--flutter-example',
          )) {
    throw ArgumentError(
      'Supply a previously warmed plugin disk fixture project',
    );
  }
  if (args.contains('--flutter-example') && !args.contains('--reuse-roots')) {
    throw ArgumentError('Flutter mode requires prepared detached worktrees');
  }
  final source = Directory(args.first).resolveSymbolicLinksSync();
  final fixture = await Directory.systemTemp.createTemp('dana-residency-');
  final roots = <String>[];
  const files = [
    'pubspec.yaml',
    'pubspec.lock',
    'analysis_options.yaml',
    '.dart_tool/package_config.json',
    '.dart_tool/package_graph.json',
    'lib/probe.dart',
    'lib/dependency.dart',
  ];
  for (var i = 0; i < 3; i++) {
    if (args.contains('--reuse-roots')) {
      final suffix = args.contains('--flutter-example') ? '/example' : '';
      final root =
          Directory('$source/root$i$suffix').resolveSymbolicLinksSync();
      for (final name in files) {
        if (!File('$root/$name').existsSync()) {
          throw StateError('Incomplete warmed fixture');
        }
      }
      roots.add(root);
      continue;
    }
    final root = Directory('${fixture.path}/root$i');
    for (final name in files) {
      final input = File('$source/$name');
      if (input.lengthSync() > 512 * 1024) {
        throw StateError('Template too large');
      }
      final output = File('${root.path}/$name');
      await output.parent.create(recursive: true);
      await input.copy(output.path);
    }
    roots.add(root.resolveSymbolicLinksSync());
  }
  final sampler = await ResearchResourceSampler.start();
  final collector = ResearchEnvironmentCollector();
  final trials = <Map>[];
  final allWorkers = <NativeModelWorker>[];
  Object? failure;
  Object? transportFailure;
  Object? guardFailure;
  String? phase;
  final clock = Stopwatch()..start();
  final samples = <Map>[];
  void check(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  List<NativeModelWorker> live() =>
      allWorkers.where((w) => !w.confirmedEmpty).toList();
  Map sample() {
    final workers = live();
    final known = workers.every(
      (w) =>
          w.healthFresh &&
          w.currentPrivateCommitMiB != null &&
          w.currentWorkingSetMiB != null,
    );
    return {
      'ms': clock.elapsedMilliseconds,
      'phase': phase,
      ...sampler.status,
      'liveTrees': workers.length,
      'currentKnown': known,
      'currentPrivateCommitMiB':
          known
              ? workers.fold<double>(
                0,
                (s, w) => s + w.currentPrivateCommitMiB!,
              )
              : null,
      'currentWorkingSetMiB':
          known
              ? workers.fold<double>(0, (s, w) => s + w.currentWorkingSetMiB!)
              : null,
      'sumHistoricalPeaksMiB': workers.fold<double>(
        0,
        (s, w) => s + (w.peakPrivateCommitMiB ?? 0),
      ),
    };
  }

  final ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
    if (samples.length < 12000) samples.add(sample());
    final workers = live();
    final unsafe =
        sampler.exited ||
        (sampler.ageMs ?? 99999) > 2000 ||
        (sampler.physicalMiB ?? 0) < 4096 ||
        (sampler.commitMiB ?? 0) < 4096 ||
        workers.fold<double>(0, (s, w) => s + (w.peakPrivateCommitMiB ?? 0)) >
            4096 ||
        workers.any(
          (w) =>
              w.lastFailure != null ||
              (w.healthClock.elapsedMilliseconds > 2000 && !w.healthFresh),
        );
    if (unsafe && guardFailure == null) {
      guardFailure = StateError('Runtime guard; no resource retry');
      for (final worker in workers) {
        unawaited(worker.close().catchError((Object _) {}));
      }
    }
  });
  Future<void> closeAll() async {
    for (final worker in live()) {
      await worker.close();
      check(worker.confirmedEmpty, 'Job zero not confirmed');
    }
  }

  Future<void> observe(NativeModelWorker worker, String root) async {
    check(guardFailure == null, 'Resource guard already failed');
    final result = await worker.officialRequest(
      'observe-disk',
      fields: {
        'file': '$root/lib/probe.dart',
        'dependencies': ['$root/lib/dependency.dart'],
        'expectedCodes': [
          'undefined_identifier',
          'dynamic_syntax_probe',
          'dynamic_semantic_probe',
        ],
      },
    );
    check(
      result['ok'] == true &&
          result['observationOnly'] == true &&
          result['diagnosticComplete'] == false,
      'Diagnostic observation failed: $result',
    );
  }

  try {
    for (var count = 1; count <= 3; count++) {
      for (final policy
          in args.contains('--reverse-order')
              ? ['single-resident', 'independent']
              : ['independent', 'single-resident']) {
        phase = '$count/$policy';
        final trial = <String, Object?>{
          'count': count,
          'policy': policy,
          'completed': false,
          'operations': <Map>[],
          'stableSamples': <Map>[],
        };
        trials.add(trial);
        final resident = <String, NativeModelWorker>{};
        final environments = <String, String>{};
        final operations = trial['operations'] as List<Map>;
        Future<NativeModelWorker> getWorker(String root) async {
          if (resident.containsKey(root)) return resident[root]!;
          if (policy == 'single-resident') {
            await closeAll();
            resident.clear();
          }
          check(
            guardFailure == null && sampler.allowed,
            'Fresh startup admission denied',
          );
          final before = await collector.capture(
            root,
            Platform.resolvedExecutable,
          );
          check(
            sampler.allowed,
            'Fresh admission changed during environment capture',
          );
          final watch = Stopwatch()..start();
          final worker = await NativeModelWorker.start(
            fixture,
            officialRoot: root,
          );
          allWorkers.add(worker);
          check(
            guardFailure == null && sampler.allowed,
            'Initialization admission denied',
          );
          final initialized = await worker.officialRequest('initialize');
          check(
            initialized['ok'] == true,
            'Initialization failed: $initialized',
          );
          final after = await collector.capture(
            root,
            Platform.resolvedExecutable,
          );
          check(
            before.key == after.key,
            'Environment changed during initialization',
          );
          if (environments.containsKey(root)) {
            check(
              environments[root] == after.key,
              'Environment changed between visits',
            );
          }
          environments[root] = after.key;
          resident[root] = worker;
          operations.add({
            'op': 'start',
            'root': root,
            'elapsedMs': watch.elapsedMilliseconds,
          });
          return worker;
        }

        // Same root order and oracle for both policies. Second pass measures
        // reuse versus rebuild; admission remains serial even in the baseline.
        for (var pass = 0; pass < 2; pass++) {
          for (final root in roots.take(count)) {
            final watch = Stopwatch()..start();
            final worker = await getWorker(root);
            final queryWatch = Stopwatch()..start();
            await observe(worker, root);
            operations.add({
              'op': 'observe',
              'pass': pass,
              'root': root,
              'elapsedMs': watch.elapsedMilliseconds,
              'queryMs': queryWatch.elapsedMilliseconds,
            });
          }
        }
        // Fixed observation interval after all roots have returned expected
        // diagnostics. Sequential member samples are not an atomic Job total.
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          check(guardFailure == null, 'Runtime guard during stable interval');
          (trial['stableSamples'] as List<Map>).add(sample());
        }
        for (final root in roots.take(count)) {
          check(
            (await collector.capture(root, Platform.resolvedExecutable)).key ==
                environments[root],
            'Environment changed during trial',
          );
        }
        trial['environments'] = environments;
        trial['completed'] = true;
        print('PASS $phase');
        await closeAll();
      }
    }
  } catch (error) {
    transportFailure = error;
    failure = guardFailure ?? error;
    print('STOP $phase: $failure');
  } finally {
    ticker.cancel();
    try {
      await closeAll();
    } catch (error) {
      failure ??= error;
    }
    await sampler.close();
    final report = {
      'fixture': fixture.path,
      'template': source,
      'rootsReused': args.contains('--reuse-roots'),
      'reverseOrder': args.contains('--reverse-order'),
      'scope':
          args.contains('--flutter-example')
              ? 'Flutter aopd example detached Git worktrees plus existing probe plugin; oracle target only'
              : 'three copies of a tiny plugin fixture; not real Flutter worktrees',
      'runtime': Platform.version,
      'failure': failure?.toString(),
      'transportFailure': transportFailure?.toString(),
      'guardFailure': guardFailure?.toString(),
      'trials': trials,
      'samples': samples,
      'allJobsEmpty': allWorkers.every((w) => w.confirmedEmpty),
      'allCompleted': failure == null && trials.length == 6,
      'memoryScope':
          'owned Job member private commit and summed working sets; excludes driver/owners; working sets can double-count shared pages',
    };
    await File(
      '${fixture.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    print(
      jsonEncode({
        'fixture': fixture.path,
        'allCompleted': report['allCompleted'],
        'failure': report['failure'],
        'allJobsEmpty': report['allJobsEmpty'],
      }),
    );
    if (failure != null) exitCode = 1;
  }
}
