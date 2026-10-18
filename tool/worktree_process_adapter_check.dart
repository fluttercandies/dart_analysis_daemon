import 'dart:async';
import 'dart:convert';

import 'worktree_process_adapter.dart';
import 'worktree_scheduler_model.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<Object> failure(Future<Object?> future) async {
  try {
    await future;
  } catch (error) {
    return error;
  }
  throw StateError('Expected failure');
}

Future<void> eventually(bool Function() predicate) async {
  final clock = Stopwatch()..start();
  while (!predicate()) {
    if (clock.elapsed > const Duration(seconds: 12)) {
      throw TimeoutException('Condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> main() async {
  final owned = <ProbeProcessWorker>[];
  final results = <Map<String, Object?>>[];
  Future<ProbeProcessWorker> start(
    int generation, {
    String mode = 'normal',
    Duration? timeout,
  }) => ProbeProcessWorker.start(
    generation,
    mode: mode,
    startupTimeout: timeout ?? const Duration(seconds: 8),
    onSpawn: owned.add,
  );
  Future<void> run(String name, Future<void> Function() body) async {
    final clock = Stopwatch()..start();
    await body().timeout(const Duration(seconds: 25));
    results.add({
      'name': name,
      'passed': true,
      'durationMs': clock.elapsedMilliseconds,
    });
    print('PASS $name');
  }

  try {
    await run(
      'ready identity, invalid credentials ignored, idempotent close',
      () async {
        final worker = await start(1);
        worker.send('shutdown', suppliedToken: 'invalid');
        worker.send('shutdown', suppliedGeneration: 0);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        check(!worker.exitObserved, 'Unauthenticated shutdown accepted');
        await Future.wait([worker.close(), worker.close()]);
        check(worker.exitObserved && !worker.forced, 'Graceful close failed');
      },
    );
    for (final mode in [
      'bad-token',
      'bad-generation',
      'exit-before-ready',
      'slow-ready',
    ]) {
      await run('$mode cleans owned process before factory failure', () async {
        final before = owned.length;
        final error = await failure(
          start(
            2,
            mode: mode,
            timeout: mode == 'slow-ready' ? const Duration(seconds: 1) : null,
          ),
        );
        check(
          error is! ModelStartupCleanupUnconfirmed,
          'Cleanup not confirmed',
        );
        check(
          owned.length == before + 1 && owned.last.exitObserved,
          'Failed startup leaked',
        );
      });
    }
    await run('ignored shutdown forces owned tree exit', () async {
      final worker = await start(3, mode: 'ignore-shutdown');
      await worker.close();
      check(worker.exitObserved && worker.forced, 'Shutdown fallback failed');
    });
    await run(
      'three scheduled roots close previous process before spawning next',
      () async {
        final workers = <ProbeProcessWorker>[];
        final clock = Stopwatch()..start();
        late WorktreeSchedulerModel model;
        model = WorktreeSchedulerModel(
          nowMs: () => clock.elapsedMilliseconds,
          canStart: () => true,
          factory: (_, generation) async {
            check(
              workers.every((worker) => worker.exitObserved),
              'New process overlapped previous tree',
            );
            final worker = await start(generation);
            workers.add(worker);
            unawaited(
              worker.exited.then((_) => model.workerExited(generation)),
            );
            return worker;
          },
        );
        final a = await model.acquire('a', 'A', deadlineMs: 15000);
        final bFuture = model.acquire('b', 'B', deadlineMs: 15000);
        final cFuture = model.acquire('c', 'C', deadlineMs: 15000);
        a.release();
        final b = await bFuture;
        b.release();
        final c = await cFuture;
        c.release();
        model.shutdown();
        await eventually(
          () =>
              model.occupiedSlots == 0 && workers.every((w) => w.exitObserved),
        );
        check(workers.length == 3, 'Wrong worker count');
      },
    );
    await run(
      'confirmed process crash invalidates lease and replaces generation',
      () async {
        final clock = Stopwatch()..start();
        ProbeProcessWorker? current;
        late WorktreeSchedulerModel model;
        model = WorktreeSchedulerModel(
          nowMs: () => clock.elapsedMilliseconds,
          canStart: () => true,
          factory: (_, generation) async {
            final worker = await start(generation);
            current = worker;
            unawaited(
              worker.exited.then((_) => model.workerExited(generation)),
            );
            return worker;
          },
        );
        final old = await model.acquire('old', 'A', deadlineMs: 15000);
        current!.send('crash');
        await current!.exited;
        await eventually(() => !old.acceptsResults);
        final replacement = await model.acquire('new', 'A', deadlineMs: 15000);
        old.release();
        model.workerExited(old.generation);
        check(
          replacement.acceptsResults && model.activeLeases == 1,
          'Stale exit affected replacement',
        );
        replacement.release();
        model.shutdown();
        await eventually(() => model.occupiedSlots == 0);
      },
    );
    await run(
      'unconfirmed startup cleanup retains slot and refuses expansion',
      () async {
        var starts = 0;
        final model = WorktreeSchedulerModel(
          nowMs: () => 0,
          canStart: () => true,
          factory: (_, _) async {
            starts++;
            throw ModelStartupCleanupUnconfirmed(
              StateError('injected exit uncertainty'),
            );
          },
        );
        check(
          await failure(model.acquire('a', 'A', deadlineMs: 100))
              is ModelStartupCleanupUnconfirmed,
          'Startup uncertainty lost',
        );
        check(
          model.occupiedSlots == 1 && model.degraded != null,
          'Uncertain startup freed slot',
        );
        await failure(model.acquire('b', 'B', deadlineMs: 100));
        check(starts == 1, 'Expanded after uncertain cleanup');
      },
    );
  } finally {
    for (final worker in owned) {
      if (!worker.exitObserved) await worker.forceStop();
    }
    print(
      jsonEncode({
        'scenarios': results,
        'ownedProcessCount': owned.length,
        'allOwnedExitObserved': owned.every((w) => w.exitObserved),
        'pids': [for (final worker in owned) worker.processId],
      }),
    );
  }
}
