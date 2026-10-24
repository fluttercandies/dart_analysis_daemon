import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/global_budget_policy.dart';
import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:test/test.dart';

SystemMemorySnapshot _memory(int availableMiB, DateTime at) =>
    SystemMemorySnapshot(
      totalPhysicalBytes: 24576 * bytesPerMiB,
      availablePhysicalBytes: availableMiB * bytesPerMiB,
      commitLimitBytes: 24576 * bytesPerMiB,
      availableCommitBytes: availableMiB * bytesPerMiB,
      sampledAt: at,
    );

/// Creates a minimal, pub-got Dart package with one broken library so checks
/// produce a deterministic error.
Future<Directory> _fixture(String name) async {
  final dir = await Directory.systemTemp.createTemp('dana-mroot-$name-');
  await File(
    '${dir.path}/pubspec.yaml',
  ).writeAsString('name: $name\nenvironment:\n  sdk: ">=3.7.0 <4.0.0"\n');
  final pubGet = await Process.run(Platform.resolvedExecutable, [
    'pub',
    'get',
    '--offline',
  ], workingDirectory: dir.path);
  if (pubGet.exitCode != 0) {
    throw StateError('pub get failed: ${pubGet.stdout}${pubGet.stderr}');
  }
  final lib = Directory('${dir.path}/lib')..createSync();
  await File('${lib.path}/broken.dart').writeAsString('int x = "nope";\n');
  return dir;
}

// Analyzer notifications use canonical native paths. Match their file identity
// instead of mixing native root separators with a forward-slash suffix.
String _brokenFile(String root) =>
    File('$root/lib/broken.dart').resolveSymbolicLinksSync();

void main() {
  late Directory a;
  late Directory b;
  late AnalyzerDaemon daemon;

  setUp(() async {
    a = await _fixture('a');
    b = await _fixture('b');
    daemon = AnalyzerDaemon(a.resolveSymbolicLinksSync());
  });

  tearDown(() async {
    await daemon.close();
    for (final d in [a, b]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  Future<int> errorsFor(String file) async {
    final result = await daemon.handle({
      'op': 'check',
      'files': [file],
    });
    return (result['errors'] as int?) ?? -1;
  }

  test('one server analyzes multiple roots and can drop one', () async {
    await daemon.start();
    final rootA = a.resolveSymbolicLinksSync();
    final rootB = b.resolveSymbolicLinksSync();
    final fileA = _brokenFile(rootA);
    final fileB = _brokenFile(rootB);

    // Only root A is active initially.
    expect(daemon.activeRoots, [rootA]);
    expect(await errorsFor(fileA), greaterThan(0));

    // Add root B: one server now analyzes both worktrees.
    expect(await daemon.addRoot(rootB), true);
    expect(daemon.activeRoots, containsAll([rootA, rootB]));
    expect(await errorsFor(fileA), greaterThan(0));
    expect(await errorsFor(fileB), greaterThan(0));

    // Adding the same root again is a no-op.
    expect(await daemon.addRoot(rootB), false);

    // Remove root B: its analysis context is released; A still works.
    expect(await daemon.removeRoot(rootB), true);
    expect(daemon.activeRoots, [rootA]);
    expect(await errorsFor(fileA), greaterThan(0));

    // The last remaining root cannot be removed.
    expect(await daemon.removeRoot(rootA), false);
    expect(daemon.activeRoots, [rootA]);
  });

  test('ensureRoot evicts the LRU idle root under memory pressure', () async {
    final c = await _fixture('c');
    final e = await _fixture('e');
    addTearDown(() async {
      for (final d in [c, e]) {
        if (await d.exists()) await d.delete(recursive: true);
      }
    });
    final rootA = a.resolveSymbolicLinksSync(); // primary, never evicted
    final rootB = b.resolveSymbolicLinksSync();
    final rootC = c.resolveSymbolicLinksSync();
    final rootE = e.resolveSymbolicLinksSync();

    var clock = DateTime.utc(2026, 1, 1);
    DateTime tick() => clock = clock.add(const Duration(seconds: 1));

    // Memory model: each active root costs ~3000 MiB (as measured on real
    // worktrees). Reserve is 8000 MiB. At 3 roots available=6000 (tight);
    // evicting one root frees 3000 -> 9000 (above reserve) so admission stops
    // after freeing *just enough*, proving eviction is not greedy.
    late AnalyzerDaemon managed;
    int available() => 15000 - managed.activeRoots.length * 3000;

    managed = AnalyzerDaemon(
      rootA,
      memorySampler: () => _memory(available(), clock),
      budgetPolicy: GlobalBudgetPolicy(
        reserveBytes: 8000 * bytesPerMiB,
        startupBytes: 0,
        recoveryBytes: 0,
      ),
      now: () => clock,
    );
    await managed.start();
    addTearDown(managed.close);

    // Warm B then C (plenty of room at 1-2 roots).
    tick();
    await managed.ensureRoot(rootB);
    tick();
    await managed.ensureRoot(rootC);
    expect(managed.activeRoots, containsAll([rootA, rootB, rootC]));

    // Ensure a fourth root E. With 3 roots available()=6000 < reserve 8000, so
    // admission is tight -> evict the single LRU idle root (B). After evicting
    // B we have 3 roots again (A,C,E) with available()=6000... still tight?
    // No: eviction drops to 2 roots momentarily (A,C) -> available()=9000 >=
    // 8000 -> admit E. So B (LRU) is evicted, C (newer) survives.
    tick();
    await managed.ensureRoot(rootE);

    expect(managed.activeRoots.contains(rootB), false, reason: 'B is LRU');
    expect(managed.activeRoots.contains(rootC), true, reason: 'C newer than B');
    expect(managed.activeRoots.contains(rootA), true, reason: 'A is primary');
    expect(managed.activeRoots.contains(rootE), true, reason: 'E requested');
  });

  test(
    'the addRoot op admits through ensureRoot and reports evictions',
    () async {
      final c = await _fixture('c');
      addTearDown(() async {
        if (await c.exists()) await c.delete(recursive: true);
      });
      final rootA = a.resolveSymbolicLinksSync();
      final rootB = b.resolveSymbolicLinksSync();
      final rootC = c.resolveSymbolicLinksSync();

      var clock = DateTime.utc(2026, 1, 1);
      DateTime tick() => clock = clock.add(const Duration(seconds: 1));
      // Each active root costs 3000 MiB; reserve 5000. With one root
      // available()=7000 admits B; with two it is 4000 < 5000, so admitting C
      // evicts the LRU non-primary root (B) first.
      late AnalyzerDaemon managed;
      int available() => 10000 - managed.activeRoots.length * 3000;
      managed = AnalyzerDaemon(
        rootA,
        memorySampler: () => _memory(available(), clock),
        budgetPolicy: GlobalBudgetPolicy(
          reserveBytes: 5000 * bytesPerMiB,
          startupBytes: 0,
          recoveryBytes: 0,
        ),
        now: () => clock,
      );
      await managed.start();
      addTearDown(managed.close);

      tick();
      final first = await managed.handle({'op': 'addRoot', 'root': rootB});
      expect(first, {'ok': true, 'changed': true, 'evicted': <String>[]});

      tick();
      final second = await managed.handle({'op': 'addRoot', 'root': rootC});
      expect(second['ok'], true);
      expect(second['changed'], true);
      expect(second['evicted'], [
        rootB,
      ], reason: 'B is the LRU non-primary root');
      expect(managed.activeRoots, unorderedEquals([rootA, rootC]));

      final again = await managed.handle({'op': 'addRoot', 'root': rootC});
      expect(again, {'ok': true, 'changed': false, 'evicted': <String>[]});
    },
  );

  test(
    'memory eviction returns promptly and preserves other roots during recovery',
    () async {
      final c = await _fixture('settle_c');
      final e = await _fixture('settle_e');
      addTearDown(() async {
        for (final d in [c, e]) {
          if (await d.exists()) await d.delete(recursive: true);
        }
      });
      final rootA = a.resolveSymbolicLinksSync();
      final rootB = b.resolveSymbolicLinksSync();
      final rootC = c.resolveSymbolicLinksSync();
      final rootE = e.resolveSymbolicLinksSync();
      var clock = DateTime.utc(2026, 1, 1);
      DateTime tick() => clock = clock.add(const Duration(seconds: 1));

      // Each root costs 3000 MiB, reserve 8000. Adding a root takes memory at
      // once; a removed root's memory only comes back after two polls, like a
      // real analyzer returning pages (measured ~5 s for ~7 GiB on macOS).
      late AnalyzerDaemon managed;
      var memoryRoots = 0;
      var pressured = false;
      int available() {
        final active = managed.activeRoots.length;
        if (active > memoryRoots) memoryRoots = active;
        return pressured ? 15000 - memoryRoots * 3000 : 20000;
      }

      managed = AnalyzerDaemon(
        rootA,
        memorySampler: () => _memory(available(), clock),
        budgetPolicy: GlobalBudgetPolicy(
          reserveBytes: 8000 * bytesPerMiB,
          startupBytes: 0,
          recoveryBytes: 0,
        ),
        now: () => clock,
      );
      await managed.start();
      addTearDown(managed.close);

      tick();
      await managed.ensureRoot(rootB);
      tick();
      await managed.ensureRoot(rootC);
      expect(managed.activeRoots, hasLength(3));

      // 3 roots in memory: 6000 < 8000. Evicting B is enough once its memory
      // is back (9000); resampling before that would also evict C.
      pressured = true;
      tick();
      final admitted = await managed.ensureRoot(rootE);
      expect(admitted.evicted, [rootB], reason: 'only the LRU root goes');
      expect(admitted.deniedReason, 'memory-pressure');
      expect(managed.activeRoots, unorderedEquals([rootA, rootC]));
      final retry = await managed.ensureRoot(rootE);
      expect(retry.evicted, isEmpty, reason: 'cooldown preserves C');
      expect(retry.deniedReason, 'memory-pressure');
      memoryRoots--;
      clock = clock.add(const Duration(seconds: 10));
      expect((await managed.ensureRoot(rootE)).added, isTrue);
      expect(managed.activeRoots, unorderedEquals([rootA, rootC, rootE]));
    },
  );

  test(
    'maxRoots caps the pool through LRU eviction, without a sampler',
    () async {
      final c = await _fixture('cap_c');
      final e = await _fixture('cap_e');
      addTearDown(() async {
        for (final d in [c, e]) {
          if (await d.exists()) await d.delete(recursive: true);
        }
      });
      final rootA = a.resolveSymbolicLinksSync();
      final rootB = b.resolveSymbolicLinksSync();
      final rootC = c.resolveSymbolicLinksSync();
      final rootE = e.resolveSymbolicLinksSync();
      var clock = DateTime.utc(2026, 1, 1);
      DateTime tick() => clock = clock.add(const Duration(seconds: 1));
      final capped = AnalyzerDaemon(rootA, maxRoots: 3, now: () => clock);
      await capped.start();
      addTearDown(capped.close);

      tick();
      expect((await capped.ensureRoot(rootB)).evicted, isEmpty);
      tick();
      expect((await capped.ensureRoot(rootC)).evicted, isEmpty);
      expect(capped.activeRoots, hasLength(3));

      // A check on B refreshes it, so C becomes the least recently used.
      tick();
      await capped.handle({
        'op': 'check',
        'files': [_brokenFile(rootB)],
      });
      tick();
      final admitted = await capped.ensureRoot(rootE);
      expect(admitted.added, isTrue);
      expect(admitted.evicted, [rootC]);
      expect(capped.activeRoots, unorderedEquals([rootA, rootB, rootE]));
    },
  );

  test('maxRoots never evicts the primary root', () async {
    final rootA = a.resolveSymbolicLinksSync();
    final rootB = b.resolveSymbolicLinksSync();
    final single = AnalyzerDaemon(rootA, maxRoots: 1);
    await single.start();
    addTearDown(single.close);
    final admitted = await single.ensureRoot(rootB);
    expect(admitted.evicted, isEmpty, reason: 'only the primary is active');
    expect(admitted.added, isFalse);
    expect(admitted.deniedReason, 'root-limit');
    expect(single.activeRoots, [rootA]);
  });

  test('root-cap denial is immediate even while analysis is active', () async {
    final rootA = a.resolveSymbolicLinksSync();
    final rootB = b.resolveSymbolicLinksSync();
    var clock = DateTime.utc(2026, 1, 1);
    final managed = AnalyzerDaemon(
      rootA,
      maxRoots: 1,
      now: () => clock,
      analysisInProgress: () => true,
    );
    await managed.start();
    addTearDown(managed.close);

    final result = await managed.ensureRoot(rootB);
    expect(result.added, isFalse);
    expect(result.deniedReason, 'root-limit');
    expect(result.evicted, isEmpty);
    expect(managed.activeRoots, [rootA]);
  });

  test(
    'memory pressure rejects a root when no recoverable root exists',
    () async {
      final rootA = a.resolveSymbolicLinksSync();
      final rootB = b.resolveSymbolicLinksSync();
      var clock = DateTime.utc(2026, 1, 1);
      final managed = AnalyzerDaemon(
        rootA,
        memorySampler: () => _memory(500, clock),
        budgetPolicy: GlobalBudgetPolicy(
          reserveBytes: 1000 * bytesPerMiB,
          startupBytes: 0,
        ),
        now: () => clock,
      );
      await managed.start();
      addTearDown(managed.close);

      final result = await managed.ensureRoot(rootB);
      expect(result.added, isFalse);
      expect(result.deniedReason, 'memory-pressure');
      expect(managed.activeRoots, [rootA]);
    },
  );

  test(
    'memory policy fails closed when the system sampler is unavailable',
    () async {
      final rootA = a.resolveSymbolicLinksSync();
      final rootB = b.resolveSymbolicLinksSync();
      final managed = AnalyzerDaemon(rootA, budgetPolicy: GlobalBudgetPolicy());
      await managed.start();
      addTearDown(managed.close);

      final result = await managed.ensureRoot(rootB);
      expect(result.added, isFalse);
      expect(result.deniedReason, 'memory-sample-unavailable');
      expect(managed.activeRoots, [rootA]);
    },
  );

  test(
    'denied admission reports roots evicted while seeking headroom',
    () async {
      final c = await _fixture('denied_c');
      addTearDown(() async {
        if (await c.exists()) await c.delete(recursive: true);
      });
      final rootA = a.resolveSymbolicLinksSync();
      final rootB = b.resolveSymbolicLinksSync();
      final rootC = c.resolveSymbolicLinksSync();
      var clock = DateTime.utc(2026, 1, 1);
      var availableMiB = 5000;
      final managed = AnalyzerDaemon(
        rootA,
        memorySampler: () => _memory(availableMiB, clock),
        budgetPolicy: GlobalBudgetPolicy(
          reserveBytes: 1000 * bytesPerMiB,
          startupBytes: 0,
        ),
        evictionSettleLimit: Duration.zero,
        now: () => clock,
      );
      await managed.start();
      addTearDown(managed.close);
      expect((await managed.ensureRoot(rootB)).added, isTrue);
      await managed.handle({'op': 'fullCheck', 'root': rootB});

      availableMiB = 500;
      final response = await managed.handle({'op': 'addRoot', 'root': rootC});
      expect(response['ok'], isFalse);
      expect(response['reason'], 'memory-pressure');
      expect(response['evicted'], [rootB]);
      expect(managed.activeRoots, [rootA]);
    },
  );

  test(
    'runtime monitor reclaims idle LRU roots with pressure hysteresis',
    () async {
      final c = await _fixture('monitor_c');
      addTearDown(() async {
        if (await c.exists()) await c.delete(recursive: true);
      });
      final rootA = a.resolveSymbolicLinksSync();
      final rootB = b.resolveSymbolicLinksSync();
      final rootC = c.resolveSymbolicLinksSync();
      var clock = DateTime.utc(2026, 1, 1);
      var availableMiB = 5000;
      var analysisActive = false;
      final managed = AnalyzerDaemon(
        rootA,
        memorySampler: () => _memory(availableMiB, clock),
        budgetPolicy: GlobalBudgetPolicy(
          reserveBytes: 1000 * bytesPerMiB,
          startupBytes: 0,
          recoveryBytes: 500 * bytesPerMiB,
        ),
        runtimeIdleGrace: const Duration(seconds: 1),
        now: () => clock,
        analysisInProgress: () => analysisActive,
      );
      await managed.start();
      addTearDown(managed.close);
      expect((await managed.ensureRoot(rootB)).added, isTrue);
      expect((await managed.ensureRoot(rootC)).added, isTrue);
      await managed.handle({'op': 'fullCheck', 'root': rootC});

      availableMiB = 500;
      clock = clock.add(const Duration(seconds: 2));
      analysisActive = true;
      expect(await managed.monitorMemoryPressureOnce(), isEmpty);
      expect(await managed.monitorMemoryPressureOnce(), isEmpty);
      expect(managed.activeRoots, contains(rootB));

      analysisActive = false;
      expect(await managed.monitorMemoryPressureOnce(), isEmpty);
      expect(await managed.monitorMemoryPressureOnce(), [rootB]);
      expect(managed.activeRoots, contains(rootC));
      expect(await managed.monitorMemoryPressureOnce(), isEmpty);
      clock = clock.add(const Duration(seconds: 10));
      availableMiB = 5000;
      expect(await managed.monitorMemoryPressureOnce(), isEmpty);
      availableMiB = 500;
      clock = clock.add(const Duration(seconds: 2));
      expect(await managed.monitorMemoryPressureOnce(), isEmpty);
      expect(await managed.monitorMemoryPressureOnce(), [rootC]);
      expect(managed.activeRoots, [rootA]);
    },
  );

  test('multi-root monitor ignores warn and reclaims on critical', () async {
    final rootA = a.resolveSymbolicLinksSync();
    final rootB = b.resolveSymbolicLinksSync();
    var clock = DateTime.utc(2026, 1, 1);
    var pressureLevel = 2;
    final managed = AnalyzerDaemon(
      rootA,
      memorySampler:
          () => macSnapshot(
            totalPhysicalBytes: 24576 * bytesPerMiB,
            availablePhysicalBytes: 5000 * bytesPerMiB,
            pressureLevel: pressureLevel,
            sampledAt: clock,
          ),
      budgetPolicy: GlobalBudgetPolicy(
        reserveBytes: 1000 * bytesPerMiB,
        startupBytes: 0,
        recoveryBytes: 500 * bytesPerMiB,
        ignoreWarnPressure: true,
      ),
      runtimeIdleGrace: const Duration(seconds: 1),
      now: () => clock,
    );
    await managed.start();
    addTearDown(managed.close);
    expect((await managed.ensureRoot(rootB)).added, isTrue);

    clock = clock.add(const Duration(seconds: 2));
    expect(await managed.monitorMemoryPressureOnce(), isEmpty);
    expect(await managed.monitorMemoryPressureOnce(), isEmpty);
    expect(managed.activeRoots, contains(rootB));

    pressureLevel = 4;
    expect(await managed.monitorMemoryPressureOnce(), isEmpty);
    expect(await managed.monitorMemoryPressureOnce(), [rootB]);
    expect(managed.activeRoots, [rootA]);
  });

  test(
    'multi-root monitor treats warn as pressure without the opt-in rule',
    () async {
      final rootA = a.resolveSymbolicLinksSync();
      final rootB = b.resolveSymbolicLinksSync();
      var clock = DateTime.utc(2026, 1, 1);
      var pressureLevel = 1;
      final managed = AnalyzerDaemon(
        rootA,
        memorySampler:
            () => macSnapshot(
              totalPhysicalBytes: 24576 * bytesPerMiB,
              availablePhysicalBytes: 5000 * bytesPerMiB,
              pressureLevel: pressureLevel,
              sampledAt: clock,
            ),
        budgetPolicy: GlobalBudgetPolicy(
          reserveBytes: 1000 * bytesPerMiB,
          startupBytes: 0,
          recoveryBytes: 500 * bytesPerMiB,
        ),
        runtimeIdleGrace: const Duration(seconds: 1),
        now: () => clock,
      );
      await managed.start();
      addTearDown(managed.close);
      expect((await managed.ensureRoot(rootB)).added, isTrue);

      pressureLevel = 2;
      clock = clock.add(const Duration(seconds: 2));
      expect(await managed.monitorMemoryPressureOnce(), isEmpty);
      expect(await managed.monitorMemoryPressureOnce(), [rootB]);
      expect(managed.activeRoots, [rootA]);
    },
  );

  test('addRoot operation reports structured admission denial', () async {
    final rootA = a.resolveSymbolicLinksSync();
    final rootB = b.resolveSymbolicLinksSync();
    final managed = AnalyzerDaemon(rootA, maxRoots: 1);
    await managed.start();
    addTearDown(managed.close);

    final response = await managed.handle({'op': 'addRoot', 'root': rootB});
    expect(response['ok'], isFalse);
    expect(response['code'], 'pool-admission-denied');
    expect(response['reason'], 'root-limit');
    expect(response['evicted'], isEmpty);
    expect(managed.activeRoots, [rootA]);
  });

  test('fullCheck with root answers only for that root', () async {
    await daemon.start();
    final rootA = a.resolveSymbolicLinksSync();
    final rootB = b.resolveSymbolicLinksSync();
    await daemon.handle({'op': 'addRoot', 'root': rootB});
    await daemon.handle({
      'op': 'check',
      'files': [_brokenFile(rootB)],
    });

    final all = await daemon.handle({'op': 'fullCheck'});
    final allFiles = (all['diagnostics'] as Map).keys.cast<String>();
    expect(allFiles.any((f) => f.startsWith(rootA)), isTrue);
    expect(allFiles.any((f) => f.startsWith(rootB)), isTrue);

    final scoped = await daemon.handle({'op': 'fullCheck', 'root': rootB});
    expect(scoped['ok'], isTrue, reason: '$scoped');
    final scopedFiles = (scoped['diagnostics'] as Map).keys.cast<String>();
    expect(scopedFiles, isNotEmpty);
    expect(
      scopedFiles.every((f) => f.startsWith('$rootB${Platform.pathSeparator}')),
      isTrue,
    );
    expect(scoped['errors'], greaterThan(0));

    final unknown = await daemon.handle({
      'op': 'fullCheck',
      'root': '${Directory.systemTemp.path}/not-a-pool-root',
    });
    expect(unknown['ok'], isFalse);
    final invalid = await daemon.handle({'op': 'fullCheck', 'root': 7});
    expect(invalid['ok'], isFalse);
  });

  test('without a sampler the addRoot op never evicts', () async {
    await daemon.start();
    final c = await _fixture('c2');
    addTearDown(() async {
      if (await c.exists()) await c.delete(recursive: true);
    });
    final rootB = b.resolveSymbolicLinksSync();
    final rootC = c.resolveSymbolicLinksSync();
    await daemon.handle({'op': 'addRoot', 'root': rootB});
    final added = await daemon.handle({'op': 'addRoot', 'root': rootC});
    expect(added['evicted'], isEmpty);
    expect(daemon.activeRoots, containsAll([rootB, rootC]));
  });

  test('addRoot adds the new root and analyzes its files', () async {
    await daemon.start();
    final rootA = a.resolveSymbolicLinksSync();
    final rootB = b.resolveSymbolicLinksSync();
    final fileB = _brokenFile(rootB);

    expect(await daemon.addRoot(rootB), true);
    expect(daemon.activeRoots, containsAll([rootA, rootB]));
    expect(await errorsFor(fileB), greaterThan(0));
  });

  test('addRoot via handle op adds the root', () async {
    await daemon.start();
    final rootB = b.resolveSymbolicLinksSync();
    final added = await daemon.handle({'op': 'addRoot', 'root': rootB});
    expect(added['ok'], true);
    expect(added['changed'], true);
    final fileB = _brokenFile(rootB);
    expect(await errorsFor(fileB), greaterThan(0));
  });

  test('addRoot/removeRoot via handle ops report changed flag', () async {
    await daemon.start();
    final rootB = b.resolveSymbolicLinksSync();
    final added = await daemon.handle({'op': 'addRoot', 'root': rootB});
    expect(added['ok'], true);
    expect(added['changed'], true);

    final status = await daemon.handle({'op': 'status'});
    expect((status['roots'] as List).length, 2);

    final removed = await daemon.handle({'op': 'removeRoot', 'root': rootB});
    expect(removed['ok'], true);
    expect(removed['changed'], true);
  });
}
