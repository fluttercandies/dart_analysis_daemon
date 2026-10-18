import 'dart:async';
import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/global_analyzer_pool.dart';
import 'package:dart_analysis_daemon/src/global_budget_policy.dart';
import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:test/test.dart';

SystemMemorySnapshot memory({int available = 8192, DateTime? at}) =>
    SystemMemorySnapshot(
      totalPhysicalBytes: 16384 * bytesPerMiB,
      availablePhysicalBytes: available * bytesPerMiB,
      commitLimitBytes: 32768 * bytesPerMiB,
      availableCommitBytes: available * bytesPerMiB,
      sampledAt: at,
    );

class Worker extends AnalyzerDaemon {
  Worker(super.root, this.events, {this.block, this.closeFails = false});
  final List<String> events;
  final Completer<void>? block;
  final bool closeFails;
  @override
  Future<void> start() async {
    events.add('start:$root');
  }

  @override
  Future<Map<String, Object?>> handle(Map<String, Object?> command) async {
    events.add('check:$root');
    await block?.future;
    return {'ok': true};
  }

  @override
  Future<void> close() async {
    events.add('close:$root');
    if (closeFails) throw StateError('unconfirmed tree');
  }
}

void main() {
  test(
    'cache preparation cannot bypass fresh memory admission or cancellation',
    () async {
      final events = <String>[];
      var available = 8192;
      var cancelDuringPreparation = false;
      final cancel = Completer<void>();
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(
          cooldown: Duration.zero,
          queueTimeout: const Duration(milliseconds: 300),
        ),
        sampleMemory: () => memory(available: available),
        createWorker: (root) => Worker(root, events),
        prepareWorker: (root, identity) async {
          expect(identity, 'v1');
          if (cancelDuringPreparation) {
            cancel.complete();
            await Future<void>.delayed(Duration.zero);
          } else {
            available = 0;
          }
        },
      );
      try {
        await expectLater(
          pool.submit('A', 'v1', {'op': 'check'}),
          throwsStateError,
        );
        expect(events, isEmpty);
        available = 8192;
        cancelDuringPreparation = true;
        await expectLater(
          pool.submit('B', 'v1', {'op': 'check'}, cancelled: cancel.future),
          throwsStateError,
        );
        expect(events, isEmpty);
      } finally {
        await pool.close();
      }
    },
  );
  test(
    'policy rejects unknown/stale/invalid counters and uses recovery margin',
    () {
      final policy = GlobalBudgetPolicy(reserveBytes: 4096 * bytesPerMiB);
      final now = DateTime.now().toUtc();
      String? reason(SystemMemorySnapshot? value, {bool recovering = false}) =>
          policy.waitingReason(
            value,
            starting: true,
            recovering: recovering,
            now: now,
          );
      expect(reason(null), 'memory-sample-unavailable');
      expect(
        reason(memory(at: now.subtract(const Duration(seconds: 3)))),
        'memory-sample-unavailable',
      );
      expect(reason(memory(available: 4500, at: now)), 'physical-reserve');
      expect(reason(memory(available: 4700, at: now)), null);
      expect(
        reason(memory(available: 4700, at: now), recovering: true),
        'physical-reserve',
      );
      expect(reason(memory(available: 5000, at: now), recovering: true), null);
      expect(
        () => GlobalBudgetPolicy.fromEnvironment({
          'DANA_GLOBAL_RESERVE_MIB': '-1',
        }),
        throwsFormatException,
      );
    },
  );

  test('Windows sampler returns physical and commit counters', () {
    if (!Platform.isWindows) return;
    final sample = WindowsSystemMemorySampler().sample();
    expect(sample, isNotNull);
    expect(sample!.freshAt(DateTime.now().toUtc()), true);
    expect(sample.availableCommitBytes, greaterThan(0));
  });

  test('macOS sampler returns physical counters and feeds the policy', () {
    if (!Platform.isMacOS) return;
    final sample = MacSystemMemorySampler().sample();
    expect(sample, isNotNull);
    expect(sample!.freshAt(DateTime.now().toUtc()), true);
    // Real physical counters.
    expect(sample.totalPhysicalBytes, greaterThan(0));
    expect(sample.availablePhysicalBytes, greaterThan(0));
    expect(
      sample.availablePhysicalBytes,
      lessThanOrEqualTo(sample.totalPhysicalBytes),
    );
    // macOS has no fixed commit limit; commit mirrors physical, except that a
    // kernel pressure level of warn or worse reports no available commit (the
    // mapping itself is unit-tested in system_memory_test.dart). Which case
    // applies depends on the machine's state while the test runs.
    expect(sample.commitLimitBytes, sample.totalPhysicalBytes);
    expect(
      sample.availableCommitBytes,
      anyOf(sample.availablePhysicalBytes, 0),
    );
    // The real sample must be consumable by the admission policy.
    final policy = GlobalBudgetPolicy();
    final reason = policy.waitingReason(
      sample,
      starting: true,
      recovering: false,
      now: DateTime.now().toUtc(),
    );
    // Either admits (null) or defers for a real reserve reason, never crashes.
    expect(
      reason == null ||
          reason == 'physical-reserve' ||
          reason == 'commit-reserve',
      true,
    );
  });

  test(
    'FIFO across roots closes previous generation before starting the next',
    () async {
      final events = <String>[];
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(cooldown: Duration.zero),
        sampleMemory: memory,
        createWorker: (root) => Worker(root, events),
      );
      try {
        final results = await Future.wait([
          pool.submit('A', 'v1', {'op': 'check'}),
          pool.submit('A', 'v1', {'op': 'check'}),
          pool.submit('B', 'v1', {'op': 'check'}),
          pool.submit('B', 'v2', {'op': 'fullCheck'}),
        ]);
        expect(events, [
          'start:A',
          'check:A',
          'check:A',
          'close:A',
          'start:B',
          'check:B',
          'close:B',
          'start:B',
          'check:B',
        ]);
        expect(results.map((r) => r['workerGeneration']), [1, 1, 2, 3]);
        expect(pool.status['workerCount'], 1);
      } finally {
        await pool.close();
      }
    },
  );

  test(
    'admission expires without starting when memory sampling is unknown',
    () async {
      final events = <String>[];
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(
          queueTimeout: const Duration(milliseconds: 80),
        ),
        sampleMemory: () => null,
        createWorker: (root) => Worker(root, events),
      );
      try {
        await expectLater(
          pool.submit('A', 'v1', {'op': 'check'}),
          throwsStateError,
        );
        expect(events, isEmpty);
      } finally {
        await pool.close();
      }
    },
  );

  test(
    'queue cancellation never starts that root; active cancellation reclaims first',
    () async {
      final events = <String>[];
      final block = Completer<void>();
      final cancelA = Completer<void>();
      final cancelB = Completer<void>();
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(cooldown: Duration.zero),
        sampleMemory: memory,
        createWorker:
            (root) => Worker(root, events, block: root == 'A' ? block : null),
      );
      try {
        final a = pool.submit('A', 'v1', {
          'op': 'check',
        }, cancelled: cancelA.future);
        final aResult = expectLater(a, throwsStateError);
        final b = pool.submit('B', 'v1', {
          'op': 'check',
        }, cancelled: cancelB.future);
        final bResult = expectLater(b, throwsStateError);
        final c = pool.submit('C', 'v1', {'op': 'check'});
        while (!events.contains('check:A')) {
          await Future<void>.delayed(Duration.zero);
        }
        cancelB.complete();
        cancelA.complete();
        await Future.wait([aResult, bResult]);
        expect((await c)['ok'], true);
        expect(events, ['start:A', 'check:A', 'close:A', 'start:C', 'check:C']);
      } finally {
        block.complete();
        await pool.close();
      }
    },
  );

  test('unconfirmed cleanup keeps slot and forbids replacement', () async {
    final events = <String>[];
    final pool = GlobalAnalyzerPool(
      policy: GlobalBudgetPolicy(cooldown: Duration.zero),
      sampleMemory: memory,
      createWorker: (root) => Worker(root, events, closeFails: true),
    );
    await pool.submit('A', 'v1', {'op': 'check'});
    await expectLater(
      pool.submit('B', 'v1', {'op': 'check'}),
      throwsStateError,
    );
    expect(pool.status['workerCount'], 1);
    expect(pool.status['degraded'], isNotNull);
    expect(events.where((e) => e == 'start:B'), isEmpty);
    await expectLater(pool.close(), throwsStateError);
  });

  test(
    'configuration changed while queued never starts a stale worker',
    () async {
      final events = <String>[];
      var valid = false;
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(cooldown: Duration.zero),
        sampleMemory: memory,
        createWorker: (root) => Worker(root, events),
        validateIdentity: (root, identity) async => valid,
      );
      try {
        await expectLater(
          pool.submit('A', 'old', {'op': 'check'}),
          throwsStateError,
        );
        expect(events, isEmpty);
        valid = true;
        expect((await pool.submit('A', 'new', {'op': 'check'}))['ok'], true);
      } finally {
        await pool.close();
      }
    },
  );

  test(
    'idle TTL waits for active request and reclaims when it finishes',
    () async {
      final events = <String>[];
      final block = Completer<void>();
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(
          idleTimeout: const Duration(milliseconds: 40),
        ),
        sampleMemory: memory,
        createWorker: (root) => Worker(root, events, block: block),
      );
      try {
        final result = pool.submit('A', 'v1', {'op': 'check'});
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(events.contains('close:A'), false);
        block.complete();
        await result;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(events.contains('close:A'), true);
      } finally {
        await pool.close();
      }
    },
  );

  test('changed disk request is rejected before worker creation', () async {
    final events = <String>[];
    final pool = GlobalAnalyzerPool(
      policy: GlobalBudgetPolicy(cooldown: Duration.zero),
      sampleMemory: memory,
      createWorker: (root) => Worker(root, events),
    );
    try {
      await expectLater(
        pool.submit('A', 'v1', {
          'op': 'check',
        }, validateRequest: () async => throw StateError('target replaced')),
        throwsStateError,
      );
      expect(events, isEmpty);
    } finally {
      await pool.close();
    }
  });

  test(
    'rechecks memory and cancellation after asynchronous validation',
    () async {
      final events = <String>[];
      var available = 8192;
      final gate = Completer<void>();
      final validated = Completer<void>();
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(
          cooldown: Duration.zero,
          queueTimeout: const Duration(milliseconds: 300),
        ),
        sampleMemory: () => memory(available: available),
        createWorker: (root) => Worker(root, events),
      );
      try {
        final lowMemory = pool.submit(
          'A',
          'v1',
          {'op': 'check'},
          validateRequest: () async {
            available = 0;
          },
        );
        await expectLater(lowMemory, throwsStateError);
        expect(events, isEmpty);
        available = 8192;
        final cancel = Completer<void>();
        final cancelled = pool.submit(
          'B',
          'v1',
          {'op': 'check'},
          cancelled: cancel.future,
          validateRequest: () async {
            validated.complete();
            await gate.future;
          },
        );
        final rejected = expectLater(cancelled, throwsStateError);
        await validated.future;
        cancel.complete();
        await rejected;
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(events, isEmpty);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await pool.close();
      }
    },
  );

  test(
    'changed target after analysis discards result and reclaims worker',
    () async {
      final events = <String>[];
      var validations = 0;
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(cooldown: Duration.zero),
        sampleMemory: memory,
        createWorker: (root) => Worker(root, events),
      );
      try {
        await expectLater(
          pool.submit(
            'A',
            'v1',
            {'op': 'check'},
            validateRequest: () async {
              if (++validations == 3) throw StateError('target edited');
            },
          ),
          throwsStateError,
        );
        expect(events, ['start:A', 'check:A', 'close:A']);
        expect(pool.status['workerCount'], 0);
      } finally {
        await pool.close();
      }
    },
  );
}
