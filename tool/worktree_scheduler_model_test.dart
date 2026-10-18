import 'dart:async';

import 'package:test/test.dart';

import 'worktree_scheduler_model.dart';

class FakeWorker implements ModelWorker {
  FakeWorker(this.onClose);
  final Future<void> Function() onClose;
  @override
  Future<void> close() => onClose();
}

Future<void> settle() async {
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late WorktreeSchedulerModel model;
  late int clock;
  late bool enoughMemory;
  late List<String> events;
  late int alive;
  late int peak;

  setUp(() {
    clock = 0;
    enoughMemory = true;
    events = [];
    alive = 0;
    peak = 0;
    model = WorktreeSchedulerModel(
      nowMs: () => clock,
      canStart: () => enoughMemory,
      factory: (root, generation) async {
        events.add('start:$root:$generation');
        alive++;
        if (alive > peak) peak = alive;
        return FakeWorker(() async {
          events.add('close:$root:$generation');
          alive--;
        });
      },
    );
  });

  tearDown(() async {
    model.shutdown();
    await settle();
  });

  Future<ModelLease> acquire(String id, String root) =>
      model.acquire(id, root, deadlineMs: 100);

  test('ten concurrent requests for one root share one startup', () async {
    final leases = await Future.wait([
      for (var i = 0; i < 10; i++) acquire('$i', 'A'),
    ]);
    expect(events, ['start:A:1']);
    expect(model.activeLeases, 10);
    for (final lease in leases) {
      lease.release();
    }
    expect(model.activeLeases, 0);
    expect(peak, 1);
  });

  test('three roots run FIFO with closure before each new startup', () async {
    final a = await acquire('a', 'A');
    final bFuture = acquire('b', 'B');
    final cFuture = acquire('c', 'C');
    await settle();
    expect(model.queued, 2);
    expect(events, ['start:A:1']);
    a.release();
    final b = await bFuture;
    b.release();
    final c = await cFuture;
    expect(events, [
      'start:A:1',
      'close:A:1',
      'start:B:2',
      'close:B:2',
      'start:C:3',
    ]);
    expect(peak, 1);
    c.release();
  });

  test('queued cancellation and deadline do not start workers', () async {
    enoughMemory = false;
    final cancelled = expectLater(acquire('a', 'A'), throwsStateError);
    final expired = expectLater(
      acquire('b', 'B'),
      throwsA(isA<TimeoutException>()),
    );
    model.cancel('a');
    clock = 100;
    model.tick();
    await Future.wait([cancelled, expired]);
    expect(model.queued, 0);
    expect(events, isEmpty);
  });

  test('resource recovery progresses the queue', () async {
    enoughMemory = false;
    final future = acquire('a', 'A');
    expect(model.occupiedSlots, 0);
    enoughMemory = true;
    model.tick();
    final lease = await future;
    expect(lease.acceptsResults, isTrue);
    lease.release();
  });

  test(
    'invalidation rejects old results and waits for active lease release',
    () async {
      final a = await acquire('a', 'A');
      model.invalidate('A');
      final next = acquire('b', 'A');
      await settle();
      expect(a.acceptsResults, isFalse);
      expect(events, ['start:A:1']);
      a.release();
      a.release();
      final b = await next;
      expect(b.generation, 2);
      expect(b.acceptsResults, isTrue);
      expect(model.activeLeases, 1);
      b.release();
    },
  );

  test(
    'stale exits and releases cannot alter replacement generation',
    () async {
      final old = await acquire('old', 'A');
      model.workerExited(old.generation);
      alive--; // Fake OS confirms the old process exited.
      final replacement = await acquire('new', 'A');
      old.release();
      model.workerExited(old.generation);
      expect(old.acceptsResults, isFalse);
      expect(replacement.acceptsResults, isTrue);
      expect(model.activeLeases, 1);
      replacement.release();
    },
  );

  test(
    'all startup waiters cancelled causes the eventual worker to close',
    () async {
      final started = Completer<ModelWorker>();
      model = WorktreeSchedulerModel(
        factory: (_, _) => started.future,
        nowMs: () => clock,
        canStart: () => true,
      );
      final cancelled = expectLater(acquire('a', 'A'), throwsStateError);
      expect(model.occupiedSlots, 1);
      model.cancel('a');
      var closed = false;
      started.complete(
        FakeWorker(() async {
          closed = true;
        }),
      );
      await cancelled;
      await settle();
      expect(closed, isTrue);
      expect(model.occupiedSlots, 0);
    },
  );

  test('deadline expiring during startup does not issue a lease', () async {
    final started = Completer<ModelWorker>();
    model = WorktreeSchedulerModel(
      factory: (_, _) => started.future,
      nowMs: () => clock,
      canStart: () => true,
    );
    final expired = expectLater(
      acquire('a', 'A'),
      throwsA(isA<TimeoutException>()),
    );
    clock = 100;
    started.complete(FakeWorker(() async {}));
    await expired;
    await settle();
    expect(model.occupiedSlots, 0);
    expect(model.activeLeases, 0);
  });

  test(
    'startup failure fails same-root waiters and lets another root progress',
    () async {
      final started = Completer<ModelWorker>();
      var attempts = 0;
      model = WorktreeSchedulerModel(
        factory: (_, _) async {
          if (++attempts == 1) return started.future;
          return FakeWorker(() async {});
        },
        nowMs: () => clock,
        canStart: () => true,
      );
      final a = expectLater(acquire('a', 'A'), throwsStateError);
      final a2 = expectLater(acquire('a2', 'A'), throwsStateError);
      final b = acquire('b', 'B');
      started.completeError(StateError('startup failed, no surviving worker'));
      await Future.wait([a, a2]);
      final lease = await b;
      expect(lease.root, 'B');
      lease.release();
    },
  );

  test('unconfirmed close retains slot and refuses expansion', () async {
    model = WorktreeSchedulerModel(
      factory:
          (_, _) async => FakeWorker(() async {
            throw TimeoutException('exit not confirmed');
          }),
      nowMs: () => clock,
      canStart: () => true,
    );
    final a = await acquire('a', 'A');
    final b = expectLater(acquire('b', 'B'), throwsStateError);
    a.release();
    await b;
    expect(model.degraded, isA<TimeoutException>());
    expect(model.occupiedSlots, 1);
    await expectLater(acquire('c', 'C'), throwsStateError);
  });

  test(
    'shutdown fails queued requests but protects active leases until release',
    () async {
      final a = await acquire('a', 'A');
      final b = expectLater(acquire('b', 'B'), throwsStateError);
      model.shutdown();
      await b;
      expect(events, ['start:A:1']);
      expect(a.acceptsResults, isFalse);
      a.release();
      await settle();
      expect(model.occupiedSlots, 0);
      expect(alive, 0);
    },
  );

  test(
    'duplicate pending IDs fail without changing the original request',
    () async {
      enoughMemory = false;
      final first = acquire('same', 'A');
      await expectLater(acquire('same', 'B'), throwsStateError);
      enoughMemory = true;
      model.tick();
      final a = await first;
      expect(a.root, 'A');
      a.release();
    },
  );
}
