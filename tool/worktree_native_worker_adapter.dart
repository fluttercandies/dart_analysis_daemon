// Research bridge to the native Job owner; officialRoot explicitly selects an
// official worker. Callers must enforce fresh admission and runtime monitoring.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'worktree_scheduler_model.dart';
import 'worktree_overlay_model.dart';
import 'worktree_overlay_transport.dart';
import 'worktree_official_queue.dart';

class NativeModelWorker implements ModelWorker {
  NativeModelWorker._(
    this.owner,
    this.messages,
    this.errorDrain,
    this.controlFile,
  );
  final Process owner;
  final StreamIterator<String> messages;
  final Future<void> errorDrain;
  final File controlFile;
  late final int workerPid;
  late final int leafPid;
  late final String runtimeVersion;
  late final int overlayPort;
  late final String _overlayToken;
  String? officialRoot;
  int? officialInitializationMs;
  int? schedulerGeneration;
  int _controlSequence = 0;
  final _officialQueue = ResearchOfficialQueue();
  Future<Map> officialRequest(
    String op, {
    Map<String, Object?> fields = const {},
    Future<void>? cancelled,
    Duration? budget,
  }) {
    if (officialRoot == null) throw StateError('Not an official worker');
    return _officialQueue.run(
      () => _officialExchange(op, fields),
      cancelled: cancelled,
      budget: budget,
    );
  }

  Future<Map> _officialExchange(String op, Map<String, Object?> fields) async {
    if (lastFailure != null || confirmedEmpty) {
      throw StateError('Official worker unavailable');
    }
    final id = ++_controlSequence;
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      overlayPort,
      timeout: const Duration(seconds: 2),
    );
    try {
      Future<Map> exchange() async {
        socket.writeln(
          jsonEncode({
            ...fields,
            'protocol': 1,
            'token': _overlayToken,
            'root': officialRoot,
            'id': id,
            'op': op,
          }),
        );
        await socket.flush();
        return readOverlayFrame(socket);
      }

      final seconds = switch (op) {
        'initialize' => 155,
        'shutdown' => 25,
        'status' => 5,
        _ => 50,
      };
      final result = await exchange().timeout(Duration(seconds: seconds));
      if (result['id'] != id) throw StateError('Control response ID mismatch');
      return result;
    } catch (error) {
      _fail(error);
      rethrow;
    } finally {
      socket.destroy();
    }
  }

  Future<void> _overlayTail = Future<void>.value();
  Future<T> serializeOverlays<T>(Future<T> Function() action) {
    final result = _overlayTail.then((_) => action());
    _overlayTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Map> applyOverlays(
    String scope,
    OverlayReplay replay, {
    int delayMs = 0,
  }) async {
    final response = await sendOverlayFrame(overlayPort, {
      'token': _overlayToken,
      'scope': scope,
      'generation': replay.generation,
      'revision': replay.revision,
      'serial': replay.serial,
      'files': replay.files,
      'removes': replay.removes.toList(),
      'delayMs': delayMs,
    });
    if (response['ok'] != true ||
        response['generation'] != replay.generation ||
        response['revision'] != replay.revision ||
        response['serial'] != replay.serial ||
        response['digest'] != overlayDigest(replay.files) ||
        response['fileCount'] != replay.files.length) {
      throw StateError('Worker overlay acknowledgement mismatch');
    }
    return response;
  }

  bool confirmedEmpty = false;
  Future<bool>? _pendingMove;
  Future<void>? _closeFuture;
  final stopped = Completer<void>();
  final failures = StreamController<Object>.broadcast(sync: true);
  Object? lastFailure;
  // Set by the supervising research manager before resource-driven closure.
  Object? resourceFailure;
  void _fail(Object error) {
    if (lastFailure != null) return;
    lastFailure = error;
    failures.add(error);
  }

  double? peakPrivateCommitMiB;
  double? currentPrivateCommitMiB;
  double? currentWorkingSetMiB;
  final healthClock = Stopwatch()..start();
  int? healthAt;
  int? activeProcesses;
  List<int> jobPids = const [];
  bool get healthFresh =>
      healthAt != null && healthClock.elapsedMilliseconds - healthAt! <= 2000;

  static Future<NativeModelWorker> start(
    Directory fixture, {
    Duration readyTimeout = const Duration(seconds: 20),
    int readyDelayMs = 0,
    String? dartExecutable,
    String? officialRoot,
    bool officialFaultGates = false,
    String? workerScriptPath,
    Map<String, String> workerEnvironment = const {},
  }) async {
    final scripts = Directory.fromUri(
      Platform.script.resolve('../../benchmarks/minimal-plugin/'),
    );
    final ownerScript = File('${scripts.path}/worktree-native-job-owner.ps1');
    var runtime = File(
      '${File(dartExecutable ?? Platform.resolvedExecutable).parent.path}/dartvm.exe',
    );
    // Older SDKs embed the VM in dart.exe and have no dartvm.exe.
    if (!runtime.existsSync()) {
      runtime = File(dartExecutable ?? Platform.resolvedExecutable);
    }
    if (!runtime.existsSync()) throw StateError('Selected runtime unavailable');
    final workerScript =
        workerScriptPath == null
            ? File.fromUri(
              Platform.script.resolve(
                officialRoot == null
                    ? 'worktree_job_worker.dart'
                    : 'worktree_official_worker.dart',
              ),
            )
            : File(workerScriptPath);
    final token =
        List.generate(
          16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
    final shell =
        '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    final process = await Process.start(
      shell,
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        ownerScript.path,
        '-DartVm',
        runtime.path,
        '-WorkerScript',
        workerScript.path,
        '-LogPath',
        '${fixture.path}/worker-$token.jsonl',
        '-Token',
        token,
        '-ControlFile',
        '${fixture.path}/close-$token',
        '-ParentProcessId',
        '$pid',
        '-ReadyDelayMs',
        '$readyDelayMs',
        if (officialRoot != null) ...['-WorkerRoot', officialRoot],
      ],
      environment: {
        ...workerEnvironment,
        'DANA_RESEARCH_OFFICIAL_GATES':
            officialFaultGates ? fixture.absolute.path : '',
      },
    );
    final errorDrain = process.stderr.drain<void>();
    final messages = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final worker = NativeModelWorker._(
      process,
      messages,
      errorDrain,
      File('${fixture.path}/close-$token'),
    );
    try {
      final suspended = await worker._read();
      if (suspended['event'] != 'suspended' ||
          suspended['owner'] != process.pid ||
          suspended['active'] != 1 ||
          suspended['resumed'] != false) {
        throw StateError('Suspended owner handshake failed');
      }
      await File(
        '${worker.controlFile.path}.resume',
      ).writeAsString('resume', flush: true);
      final ready = await worker._read(timeout: readyTimeout);
      if (ready['event'] != 'ready' ||
          ready['owner'] != process.pid ||
          ready['worker'] != suspended['worker']) {
        throw StateError('Owner ready handshake failed');
      }
      worker.workerPid = ready['worker'] as int;
      worker.leafPid = ready['leaf'] as int;
      worker.runtimeVersion = ready['runtimeVersion'] as String;
      worker.overlayPort = ready['overlayPort'] as int;
      worker._overlayToken = token;
      worker.officialRoot = officialRoot;
      unawaited(worker._monitor());
      return worker;
    } catch (error) {
      // Closing stdin asks the owner to clear the Job even during suspended setup.
      try {
        await worker.controlFile.writeAsString('close', flush: true);
        await process.stdin.close();
        final cleanupClock = Stopwatch()..start();
        while (await worker._moveNext(
          const Duration(seconds: 12) - cleanupClock.elapsed,
        )) {
          final message = jsonDecode(messages.current) as Map;
          if (message['event'] == 'tree-stopped' && message['active'] == 0) {
            worker.confirmedEmpty = true;
          }
        }
        await process.exitCode.timeout(const Duration(seconds: 12));
        await messages.cancel();
        if (!worker.confirmedEmpty) throw StateError('Job exit unconfirmed');
      } catch (cleanup) {
        process.kill(); // Crash-safe Job closure; do not claim observed zero.
        throw ModelStartupCleanupUnconfirmed(cleanup);
      }
      rethrow;
    }
  }

  Future<Map> _read({Duration timeout = const Duration(seconds: 20)}) async {
    if (!await _moveNext(timeout)) {
      throw StateError('Owner disconnected');
    }
    final message = jsonDecode(messages.current) as Map;
    // Startup can fail before ready: preserve the owner's zero confirmation
    // even when it arrives in place of the expected handshake.
    if (message['event'] == 'tree-stopped' && message['active'] == 0) {
      confirmedEmpty = true;
    }
    return message;
  }

  Future<bool> _moveNext(Duration timeout) async {
    // Future.timeout does not cancel StreamIterator.moveNext. Retain that exact
    // pending read so startup cleanup never starts a second concurrent read.
    final pending = _pendingMove ??= messages.moveNext();
    final available = await pending.timeout(timeout);
    _pendingMove = null;
    return available;
  }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _monitor() async {
    try {
      while (await _moveNext(const Duration(days: 1))) {
        final message = jsonDecode(messages.current) as Map;
        if (message['event'] == 'health') {
          activeProcesses = message['active'] as int;
          jobPids = List<int>.unmodifiable(
            (message['jobPids'] as List? ?? const []).cast<int>(),
          );
          final peak = (message['peakPrivateCommitMiB'] as num).toDouble();
          if (!peak.isFinite || peak < 0) {
            throw StateError('Invalid Job sample');
          }
          peakPrivateCommitMiB = peak;
          double? current(String key) {
            final value = message[key];
            if (message['currentMemoryComplete'] != true) return null;
            if (value is! num || !value.isFinite || value < 0) {
              throw StateError('Invalid current Job sample');
            }
            return value.toDouble();
          }

          currentPrivateCommitMiB = current('currentPrivateCommitMiB');
          currentWorkingSetMiB = current('currentWorkingSetMiB');
          healthAt = healthClock.elapsedMilliseconds;
        } else if (message['event'] == 'worker-exited') {
          _fail(StateError('Worker exited with descendants potentially alive'));
        } else if (message['event'] == 'tree-stopped' &&
            message['active'] == 0) {
          confirmedEmpty = true;
          break;
        } else {
          throw StateError('Unexpected owner event: $message');
        }
      }
      if (!confirmedEmpty) {
        throw StateError('Owner disconnected before Job zero');
      }
      await messages.cancel();
      await owner.exitCode.timeout(const Duration(seconds: 12));
      await errorDrain;
      stopped.complete();
    } catch (error) {
      _fail(error);
      // Complete normally: close checks confirmedEmpty after monitor termination.
      if (!stopped.isCompleted) stopped.complete();
    } finally {
      await failures.close();
    }
  }

  Future<void> _close() async {
    await controlFile.writeAsString('close', flush: true);
    await stopped.future.timeout(const Duration(seconds: 20));
    if (!confirmedEmpty) {
      throw StateError('Job zero not confirmed');
    }
  }
}
