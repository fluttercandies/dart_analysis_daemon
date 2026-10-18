import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_native_worker_adapter.dart';
import 'worktree_resource_sampler.dart';
import 'worktree_scheduler_model.dart';
import 'worktree_overlay_transport.dart' show sendOverlayFrame;

Future<void> main() async {
  final fixture = await Directory.systemTemp.createTemp(
    'dana-official-worker-',
  );
  final roots = <String>[];
  for (var i = 0; i < 2; i++) {
    final directory = await Directory('${fixture.path}/root$i').create();
    roots.add(directory.resolveSymbolicLinksSync());
    await File(
      '${directory.path}/probe.dart',
    ).writeAsString('int value = missingBranch$i;\n');
    await File(
      '${directory.path}/pubspec.yaml',
    ).writeAsString('name: worker_probe_$i\nenvironment:\n  sdk: ^3.9.0\n');
  }
  final sampler = await ResearchResourceSampler.start();
  final admission = sampler.status;
  final workers = <NativeModelWorker>[];
  final results = <Map>[];
  final samples = <Map>[];
  final timings = <Map>[];
  Object? failure;
  Timer? ticker;
  var starts = 0;
  var skipped = false;
  var schedulerStarted = false;
  final clock = Stopwatch()..start();
  late WorktreeSchedulerModel scheduler;
  void check(bool condition, String message) {
    if (!condition) throw StateError(message);
  }

  Future<void> run(String name, Future<void> Function() action) async {
    final watch = Stopwatch()..start();
    await action().timeout(const Duration(seconds: 180));
    results.add({
      'name': name,
      'passed': true,
      'elapsedMs': watch.elapsedMilliseconds,
    });
    print('PASS $name');
  }

  try {
    if (!sampler.allowed) {
      skipped = true;
      print('SKIP startup admission ${jsonEncode(admission)}');
      return;
    }
    scheduler = WorktreeSchedulerModel(
      nowMs: () => clock.elapsedMilliseconds,
      canStart: () => failure == null && sampler.allowed,
      closeTimeout: const Duration(seconds: 25),
      factory: (root, generation) async {
        check(!workers.any((w) => !w.confirmedEmpty), 'Previous tree survived');
        check(sampler.allowed, 'Fresh startup admission denied');
        final worker = await NativeModelWorker.start(
          fixture,
          officialRoot: root,
        );
        workers.add(worker);
        starts++;
        worker.failures.stream.listen((_) {
          scheduler.invalidateGeneration(generation);
        });
        try {
          final status = await worker.officialRequest('status');
          check(
            status['rootConfigured'] == false &&
                status['diagnosticComplete'] == false,
            'Ready conflated with analysis',
          );
          check(
            sampler.allowed && failure == null,
            'Admission changed before analyzer initialization',
          );
          final watch = Stopwatch()..start();
          final response = await worker.officialRequest('initialize');
          timings.add({
            'operation': 'initialize',
            'elapsedMs': watch.elapsedMilliseconds,
          });
          check(
            response['ok'] == true &&
                response['rootConfigured'] == true &&
                response['diagnosticComplete'] == false,
            'Root setup failed: $response',
          );
          return worker;
        } catch (_) {
          try {
            await worker.close();
          } catch (error) {
            throw ModelStartupCleanupUnconfirmed(error);
          }
          rethrow;
        }
      },
    );
    schedulerStarted = true;
    ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final live = workers.where((w) => !w.confirmedEmpty).toList();
      if (samples.length < 4000) {
        samples.add({
          'ms': clock.elapsedMilliseconds,
          ...sampler.status,
          'peaks': [for (final w in live) w.peakPrivateCommitMiB],
        });
      }
      final memoryUnsafe =
          sampler.exited ||
          (sampler.ageMs ?? 99999) > 2000 ||
          (sampler.physicalMiB ?? 0) < 4096 ||
          (sampler.commitMiB ?? 0) < 4096;
      for (final worker in live) {
        if (memoryUnsafe ||
            (worker.peakPrivateCommitMiB ?? 0) > 4096 ||
            (worker.healthClock.elapsedMilliseconds > 2000 &&
                !worker.healthFresh)) {
          failure ??= StateError('Runtime resource guard');
          unawaited(
            worker.close().catchError((Object error) {
              failure ??= error;
            }),
          );
        }
      }
      scheduler.tick();
    });
    Future<ModelLease> acquire(String id, String root) => scheduler.acquire(
      id,
      root,
      deadlineMs: clock.elapsedMilliseconds + 170000,
    );
    NativeModelWorker getWorker() => workers.last;
    Future<void> builtin(int branch) async {
      final worker = getWorker();
      final watch = Stopwatch()..start();
      final result = await worker.officialRequest(
        'builtin-errors',
        fields: {
          'file':
              File.fromUri(
                Directory(roots[branch]).uri.resolve('probe.dart'),
              ).path,
        },
      );
      timings.add({
        'operation': 'builtin-errors',
        'elapsedMs': watch.elapsedMilliseconds,
      });
      check(
        result['ok'] == true &&
            result['builtinOnly'] == true &&
            result['diagnosticComplete'] == false &&
            (result['errors'] as List).any(
              (e) => '${e['message']}'.contains('missingBranch$branch'),
            ),
        'Built-in result mismatch: $result',
      );
    }

    await run(
      'invalid root startup confirms cleanup and releases slot',
      () async {
        var rejected = false;
        try {
          final lease = await acquire('bad-root', '${fixture.path}/absent');
          lease.release();
        } catch (error) {
          if (error is ModelStartupCleanupUnconfirmed) rethrow;
          rejected = true;
        }
        check(
          rejected &&
              scheduler.occupiedSlots == 0 &&
              scheduler.degraded == null,
          'Failed startup retained or lost ownership',
        );
      },
    );
    await run(
      'five same-root leases share one official tree and hot requests reuse analyzer',
      () async {
        final leases = await Future.wait([
          for (var i = 0; i < 5; i++) acquire('same$i', roots[0]),
        ]);
        try {
          check(starts == 1, 'Duplicate official startup');
          for (var i = 0; i < 3; i++) {
            await builtin(0);
          }
        } finally {
          for (final lease in leases) {
            lease.release();
          }
        }
      },
    );
    await run(
      'authentication overlays and outside-root requests fail without changing root state',
      () async {
        final lease = await acquire('auth', roots[0]);
        try {
          final worker = getWorker();
          final unauth = await sendOverlayFrame(worker.overlayPort, {
            'protocol': 1,
            'token': 'wrong',
            'root': roots[0],
            'id': 999,
            'op': 'initialize',
          });
          check(unauth['ok'] == false, 'Bad credential accepted');
          check(
            (await worker.officialRequest(
                  'initialize',
                  fields: {'overlays': {}},
                ))['ok'] ==
                false,
            'Overlay ignored',
          );
          check(
            (await worker.officialRequest(
                  'builtin-errors',
                  fields: {
                    'file':
                        File.fromUri(
                          Directory(roots[1]).uri.resolve('probe.dart'),
                        ).path,
                  },
                ))['ok'] ==
                false,
            'Outside-root result exposed',
          );
          await builtin(0);
        } finally {
          lease.release();
        }
      },
    );
    await run(
      'cross-root replacement confirms old Job zero before second official tree',
      () async {
        final previous = getWorker();
        final lease = await acquire('other', roots[1]);
        try {
          check(previous.confirmedEmpty && starts == 2, 'Cross-root overlap');
          await builtin(1);
        } finally {
          lease.release();
        }
      },
    );
    await run(
      'analyzer crash invalidates lease and replacement waits for Job zero',
      () async {
        final lease = await acquire('crash', roots[1]);
        final previous = getWorker();
        try {
          final status = await previous.officialRequest('status');
          final analyzerPid = status['analyzerPid'] as int;
          check(
            analyzerPid != pid && analyzerPid > 0,
            'Invalid owned analyzer PID',
          );
          check(
            Process.killPid(analyzerPid),
            'Owned analyzer crash injection failed',
          );
          final deadline = DateTime.now().add(const Duration(seconds: 12));
          while (lease.acceptsResults && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          check(!lease.acceptsResults, 'Crash left stale lease valid');
        } finally {
          lease.release();
        }
        final replacement = await acquire('recovered', roots[1]);
        try {
          check(
            previous.confirmedEmpty && starts == 3,
            'Recovery overlapped trees',
          );
          await builtin(1);
        } finally {
          replacement.release();
        }
      },
    );
    await run(
      'graceful shutdown exits analyzer then native owner confirms tree empty',
      () async {
        final lease = await acquire('graceful', roots[1]);
        try {
          final response = await getWorker().officialRequest('shutdown');
          check(
            response['ok'] == true && response['gracefulAnalyzerExit'] == true,
            'Graceful shutdown failed',
          );
        } finally {
          lease.release();
          scheduler.retire(roots[1]);
        }
        await getWorker().close();
        check(getWorker().confirmedEmpty, 'Job not empty');
      },
    );
    check(
      failure == null && scheduler.degraded == null,
      'Guard or cleanup failure',
    );
  } catch (error) {
    failure = error;
    rethrow;
  } finally {
    ticker?.cancel();
    if (schedulerStarted) scheduler.shutdown();
    for (final worker in workers) {
      try {
        await worker.close();
      } catch (error) {
        failure ??= error;
      }
    }
    await sampler.close();
    final report = {
      'fixture': fixture.path,
      'admission': admission,
      'skipped': skipped,
      'results': results,
      'failure': failure?.toString(),
      'allPassed': failure == null && results.length == 6,
      'starts': starts,
      'timings': timings,
      'allJobsEmpty': workers.every((w) => w.confirmedEmpty),
      'samples': samples,
    };
    await File(
      '${fixture.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    print(
      jsonEncode({
        'fixture': fixture.path,
        'allPassed': report['allPassed'],
        'failure': report['failure'],
        'allJobsEmpty': report['allJobsEmpty'],
      }),
    );
    if (failure != null) exitCode = 1;
  }
}
