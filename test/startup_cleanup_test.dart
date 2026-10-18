import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/analyzer_process.dart';
import 'package:dart_analysis_daemon/src/global_analyzer_pool.dart';
import 'package:dart_analysis_daemon/src/global_budget_policy.dart';
import 'package:test/test.dart';

import 'global_budget_test.dart' show memory, Worker;

class _Process implements AnalyzerProcess {
  _Process({this.failCleanup = false, this.protocolFailure = false}) {
    stdin = IOSink(_input.sink);
    _input.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!received.isCompleted) received.complete();
          if (protocolFailure) {
            _output.add(
              utf8.encode(
                '${jsonEncode({
                  'event': 'server.error',
                  'params': {'message': 'startup fault'},
                })}\n',
              ),
            );
          }
        });
  }
  final bool failCleanup, protocolFailure;
  final received = Completer<void>();
  final _input = StreamController<List<int>>();
  final _output = StreamController<List<int>>();
  final _error = StreamController<List<int>>();
  final _exit = Completer<int>();
  int terminations = 0;
  @override
  late final IOSink stdin;
  @override
  Stream<List<int>> get stdout => _output.stream;
  @override
  Stream<List<int>> get stderr => _error.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 1;
  @override
  String get backend => 'test-owned';
  @override
  Future<void> terminate() async {
    terminations++;
    if (failCleanup) throw StateError('unconfirmed cleanup');
    await release();
  }

  Future<void> release() async {
    await stdin.close();
    await _output.close();
    await _error.close();
    if (!_exit.isCompleted) _exit.complete(0);
  }
}

void main() {
  test(
    'disconnect during execution validation never starts analysis',
    () async {
      final events = <String>[];
      final validating = Completer<void>();
      final release = Completer<void>();
      final cancellation = Completer<void>();
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(cooldown: Duration.zero),
        sampleMemory: memory,
        createWorker: (root) => Worker(root, events),
        validateExecution: (_, _) async {
          validating.complete();
          await release.future;
        },
      );
      final rejected = expectLater(
        pool.submit('A', 'v1', {'op': 'check'}, cancelled: cancellation.future),
        throwsStateError,
      );
      try {
        await validating.future.timeout(const Duration(seconds: 2));
        cancellation.complete();
        await rejected;
        release.complete();
        await pool.close().timeout(const Duration(seconds: 2));
        expect(events, ['start:A', 'close:A']);
        expect(pool.status['workerCount'], 0);
      } finally {
        if (!release.isCompleted) release.complete();
        await pool.close();
      }
    },
  );

  test(
    'failed startup plus failed termination never frees the pool slot',
    () async {
      final process = _Process(failCleanup: true, protocolFailure: true);
      final daemon = AnalyzerDaemon(
        'A',
        ownedProcessStarter: () async => process,
      );
      var starts = 0;
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(cooldown: Duration.zero),
        sampleMemory: memory,
        createWorker: (_) {
          starts++;
          return daemon;
        },
      );
      try {
        await expectLater(
          pool.submit('A', 'v1', {'op': 'check'}),
          throwsStateError,
        );
        expect(pool.status['workerCount'], 1);
        expect(pool.status['degraded'], contains('unconfirmed cleanup'));
        await expectLater(
          pool.submit('B', 'v1', {'op': 'check'}),
          throwsStateError,
        );
        expect(starts, 1);
        expect(process.terminations, 1);
        await expectLater(daemon.close(), throwsStateError);
      } finally {
        await expectLater(pool.close(), throwsStateError);
        await process.release();
      }
    },
  );

  for (final stop in [false, true]) {
    test(
      '${stop ? 'stop' : 'disconnect'} during silent startup joins termination',
      () async {
        final process = _Process();
        final cancellation = Completer<void>();
        final pool = GlobalAnalyzerPool(
          policy: GlobalBudgetPolicy(cooldown: Duration.zero),
          sampleMemory: memory,
          createWorker:
              (_) =>
                  AnalyzerDaemon('A', ownedProcessStarter: () async => process),
        );
        final result = pool.submit('A', 'v1', {
          'op': 'check',
        }, cancelled: cancellation.future);
        final rejected = expectLater(result, throwsStateError);
        await process.received.future.timeout(const Duration(seconds: 2));
        if (stop) {
          await pool.close().timeout(const Duration(seconds: 2));
        } else {
          cancellation.complete();
        }
        await rejected;
        await pool.close().timeout(const Duration(seconds: 2));
        expect(process.terminations, 1);
        expect(pool.status['workerCount'], 0);
      },
    );
  }

  test(
    'identity change during cache preparation prevents launch and invalidates',
    () async {
      final events = <String>[];
      var valid = true;
      final pool = GlobalAnalyzerPool(
        policy: GlobalBudgetPolicy(cooldown: Duration.zero),
        sampleMemory: memory,
        validateIdentity: (_, _) async => valid,
        prepareWorker: (_, _) async {
          valid = false;
        },
        invalidateWorkerCache: (root, identity) async {
          events.add('invalidate:$root:$identity');
        },
        createWorker: (root) => Worker(root, events),
      );
      try {
        await expectLater(
          pool.submit('A', 'v1', {'op': 'check'}),
          throwsStateError,
        );
        expect(events, ['invalidate:A:v1']);
        expect(pool.status['workerCount'], 0);
      } finally {
        await pool.close();
      }
    },
  );
}
