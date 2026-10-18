// Dependency-free executable checks: no analyzer or external test runner.
import 'dart:async';
import 'worktree_scheduler_model.dart';

class Worker implements ModelWorker {
  Worker(this.stop);
  final Future<void> Function() stop;
  @override
  Future<void> close() => stop();
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<Object> failure(Future<Object?> future) async {
  try {
    await future;
  } catch (error) {
    return error;
  }
  throw StateError('Expected failure');
}

Future<void> main() async {
  var passed = 0;
  Future<void> run(String name, Future<void> Function() body) async {
    await body().timeout(const Duration(seconds: 3));
    passed++;
    print('PASS $name');
  }

  await run(
    'deduplication, FIFO eviction, no overlap, idempotent release',
    () async {
      var alive = 0;
      var peak = 0;
      var starts = 0;
      final model = WorktreeSchedulerModel(
        nowMs: () => 0,
        canStart: () => true,
        factory: (_, _) async {
          starts++;
          alive++;
          if (alive > peak) peak = alive;
          return Worker(() async {
            alive--;
          });
        },
      );
      final leases = await Future.wait([
        for (var i = 0; i < 10; i++) model.acquire('$i', 'A', deadlineMs: 100),
      ]);
      check(
        starts == 1 && model.activeLeases == 10,
        'Same-root startup duplicated',
      );
      final bFuture = model.acquire('b', 'B', deadlineMs: 100);
      final cFuture = model.acquire('c', 'C', deadlineMs: 100);
      for (final lease in leases) {
        lease.release();
        lease.release();
      }
      final b = await bFuture;
      check(b.root == 'B' && model.queued == 1, 'FIFO violation');
      b.release();
      final c = await cFuture;
      check(peak == 1 && starts == 3, 'Worker overlap');
      c.release();
      model.shutdown();
      await settle();
      check(alive == 0 && model.occupiedSlots == 0, 'Shutdown leak');
    },
  );

  await run('resource denial, cancellation, deadlines and recovery', () async {
    var now = 0;
    var memory = false;
    var starts = 0;
    final model = WorktreeSchedulerModel(
      nowMs: () => now,
      canStart: () => memory,
      factory: (_, _) async {
        starts++;
        return Worker(() async {});
      },
    );
    final a = failure(model.acquire('a', 'A', deadlineMs: 10));
    final b = failure(model.acquire('b', 'B', deadlineMs: 10));
    model.cancel('a');
    now = 10;
    model.tick();
    check(
      await a is StateError && await b is TimeoutException && starts == 0,
      'Admission termination failed',
    );
    final c = model.acquire('c', 'C', deadlineMs: 20);
    memory = true;
    model.tick();
    final lease = await c;
    check(starts == 1 && lease.acceptsResults, 'Recovery failed');
    lease.release();
    model.shutdown();
    await settle();
  });

  await run(
    'configuration invalidation protects leases and rejects old generations',
    () async {
      final model = WorktreeSchedulerModel(
        nowMs: () => 0,
        canStart: () => true,
        factory: (_, _) async => Worker(() async {}),
      );
      final old = await model.acquire('old', 'A', deadlineMs: 100);
      model.invalidate('A');
      final future = model.acquire('new', 'A', deadlineMs: 100);
      await settle();
      check(
        !old.acceptsResults && model.activeLeases == 1,
        'Invalidation broke lease protection',
      );
      old.release();
      final replacement = await future;
      model.workerExited(old.generation);
      old.release();
      check(
        replacement.generation != old.generation &&
            replacement.acceptsResults &&
            model.activeLeases == 1,
        'Stale generation corrupted replacement',
      );
      replacement.release();
      model.shutdown();
      await settle();
    },
  );

  for (final expire in [false, true]) {
    await run(
      'startup waiter ${expire ? 'expiry' : 'cancellation'} closes eventual worker',
      () async {
        var now = 0;
        var closed = false;
        final start = Completer<ModelWorker>();
        final model = WorktreeSchedulerModel(
          nowMs: () => now,
          canStart: () => true,
          factory: (_, _) => start.future,
        );
        final result = failure(model.acquire('a', 'A', deadlineMs: 10));
        if (expire) {
          now = 10;
        } else {
          model.cancel('a');
        }
        start.complete(
          Worker(() async {
            closed = true;
          }),
        );
        final error = await result;
        await settle();
        check(
          (expire ? error is TimeoutException : error is StateError) &&
              closed &&
              model.occupiedSlots == 0,
          'Abandoned startup leaked',
        );
        model.shutdown();
      },
    );
  }

  await run(
    'failed startup releases slot and progresses another root',
    () async {
      final start = Completer<ModelWorker>();
      var attempts = 0;
      final model = WorktreeSchedulerModel(
        nowMs: () => 0,
        canStart: () => true,
        factory: (_, _) async {
          if (++attempts == 1) return start.future;
          return Worker(() async {});
        },
      );
      final a = failure(model.acquire('a', 'A', deadlineMs: 100));
      final a2 = failure(model.acquire('a2', 'A', deadlineMs: 100));
      final b = model.acquire('b', 'B', deadlineMs: 100);
      start.completeError(StateError('No surviving worker'));
      check(
        await a is StateError && await a2 is StateError,
        'Startup errors lost',
      );
      final lease = await b;
      check(lease.root == 'B' && attempts == 2, 'Next root blocked');
      lease.release();
      model.shutdown();
      await settle();
    },
  );

  await run(
    'actual close timeout retains occupied slot and refuses expansion',
    () async {
      final close = Completer<void>();
      final model = WorktreeSchedulerModel(
        nowMs: () => 0,
        canStart: () => true,
        closeTimeout: const Duration(milliseconds: 10),
        factory: (_, _) async => Worker(() => close.future),
      );
      final a = await model.acquire('a', 'A', deadlineMs: 100);
      final b = failure(model.acquire('b', 'B', deadlineMs: 100));
      a.release();
      check(
        await b is StateError &&
            model.degraded is TimeoutException &&
            model.occupiedSlots == 1,
        'Unconfirmed exit freed slot',
      );
      check(
        await failure(model.acquire('c', 'C', deadlineMs: 100)) is StateError,
        'Degraded scheduler expanded',
      );
      close.complete();
      model.shutdown();
    },
  );

  await run('shutdown cancels queue and waits for active release', () async {
    var closed = false;
    final model = WorktreeSchedulerModel(
      nowMs: () => 0,
      canStart: () => true,
      factory:
          (_, _) async => Worker(() async {
            closed = true;
          }),
    );
    final a = await model.acquire('a', 'A', deadlineMs: 100);
    final b = failure(model.acquire('b', 'B', deadlineMs: 100));
    model.shutdown();
    check(
      await b is StateError && !closed && !a.acceptsResults,
      'Active shutdown unsafe',
    );
    a.release();
    await settle();
    check(closed && model.occupiedSlots == 0, 'Shutdown did not drain');
  });
  await run(
    'confirmed crash invalidates old lease and permits replacement',
    () async {
      final model = WorktreeSchedulerModel(
        nowMs: () => 0,
        canStart: () => true,
        factory: (_, _) async => Worker(() async {}),
      );
      final old = await model.acquire('old', 'A', deadlineMs: 100);
      model.workerExited(old.generation);
      final next = await model.acquire('next', 'A', deadlineMs: 100);
      old.release();
      check(
        !old.acceptsResults && next.acceptsResults && model.activeLeases == 1,
        'Crash generation leaked',
      );
      next.release();
      model.shutdown();
      await settle();
    },
  );
  await run('duplicate pending IDs cannot replace queued requests', () async {
    var allowed = false;
    final model = WorktreeSchedulerModel(
      nowMs: () => 0,
      canStart: () => allowed,
      factory: (_, _) async => Worker(() async {}),
    );
    final first = model.acquire('same', 'A', deadlineMs: 100);
    check(
      await failure(model.acquire('same', 'B', deadlineMs: 100))
              is StateError &&
          model.queued == 1,
      'Duplicate request changed queue',
    );
    allowed = true;
    model.tick();
    final lease = await first;
    check(lease.root == 'A', 'Original request lost');
    lease.release();
    model.shutdown();
    await settle();
  });
  await run(
    'soft retirement preserves results while stale generation cannot invalidate replacement',
    () async {
      final model = WorktreeSchedulerModel(
        nowMs: () => 0,
        canStart: () => true,
        factory: (_, _) async => Worker(() async {}),
      );
      final first = await model.acquire('a', 'A', deadlineMs: 100);
      model.retire('A');
      check(first.acceptsResults, 'Soft retirement invalidated active results');
      first.release();
      await settle();
      final second = await model.acquire('b', 'A', deadlineMs: 100);
      model.invalidateGeneration(first.generation);
      check(second.acceptsResults, 'Stale failure invalidated replacement');
      model.invalidateGeneration(second.generation);
      check(!second.acceptsResults, 'Current worker failure accepted results');
      second.release();
      model.shutdown();
      await settle();
    },
  );
  print('PASS $passed lifecycle scenarios; no analyzer processes started');
}
