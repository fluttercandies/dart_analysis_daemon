// Research adapter for the dedicated fake worker only. No public PID attachment.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'worktree_scheduler_model.dart';

class ProbeProcessWorker implements ModelWorker {
  ProbeProcessWorker._(this.process, this.token, this.generation) {
    exited = process.exitCode.then((code) {
      exitObserved = true;
      return code;
    });
    process.stderr.transform(utf8.decoder).listen(stderrBuffer.write);
    lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
  }

  final Process process;
  final String token;
  final int generation;
  final stderrBuffer = StringBuffer();
  late final Future<int> exited;
  late final StreamIterator<String> lines;
  bool exitObserved = false;
  bool forced = false;
  Future<void>? _closing;
  int get processId => process.pid;

  static Future<ProbeProcessWorker> start(
    int generation, {
    String mode = 'normal',
    Duration startupTimeout = const Duration(seconds: 8),
    void Function(ProbeProcessWorker)? onSpawn,
  }) async {
    final token =
        List.generate(
          24,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
    final script =
        File.fromUri(Platform.script.resolve('worktree_fake_worker.dart')).path;
    final process = await Process.start(Platform.resolvedExecutable, [
      script,
      mode,
      token,
      '$generation',
    ], runInShell: false);
    final worker = ProbeProcessWorker._(process, token, generation);
    try {
      onSpawn?.call(worker);
      final ready = await worker.lines.moveNext().timeout(startupTimeout);
      if (!ready) throw StateError('Worker exited before readiness');
      final message = jsonDecode(worker.lines.current) as Map;
      if (message['event'] != 'ready' ||
          message['token'] != token ||
          message['generation'] != generation ||
          message['pid'] is! int) {
        throw StateError('Worker readiness identity mismatch');
      }
      if (worker.exitObserved) {
        throw StateError('Worker exited during readiness');
      }
      // This fake protocol emits only readiness. Cancel the paused iterator so
      // a later crash cannot leave a stdout subscription keeping the parent alive.
      await worker.lines.cancel();
      return worker;
    } catch (error, stack) {
      try {
        await worker.forceStop();
        await worker.lines.cancel();
      } catch (cleanupError) {
        throw ModelStartupCleanupUnconfirmed(cleanupError);
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  void send(
    String operation, {
    String? suppliedToken,
    int? suppliedGeneration,
  }) {
    process.stdin.writeln(
      jsonEncode({
        'op': operation,
        'token': suppliedToken ?? token,
        'generation': suppliedGeneration ?? generation,
      }),
    );
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (!exitObserved) {
      send('shutdown');
      try {
        await exited.timeout(const Duration(milliseconds: 300));
      } on TimeoutException {
        await forceStop();
      }
    }
    await exited;
    await lines.cancel();
  }

  Future<void> forceStop() async {
    if (exitObserved) return;
    forced = true;
    // The PID comes exclusively from the Process handle created above; never from input.
    if (Platform.isWindows) {
      await Process.run('taskkill', [
        '/PID',
        '$processId',
        '/T',
        '/F',
      ]).timeout(const Duration(seconds: 5));
    } else {
      process.kill(ProcessSignal.sigkill);
    }
    await exited.timeout(const Duration(seconds: 5));
  }
}
