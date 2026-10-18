import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:isolate';

import 'analyzer_daemon.dart';
import 'analyzer_process.dart';
import 'global_analyzer_pool.dart';
import 'global_budget_policy.dart';
import 'runtime.dart';
import 'system_memory.dart';
import 'windows_ffi_process.dart';
import 'cancellation_signal.dart';
import 'windows_disk_snapshot.dart';
import 'environment_identity.dart';
import 'managed_plugin_cache.dart';

bool get globalBudgetEnabled {
  final value = Platform.environment['DANA_GLOBAL_BUDGET'];
  if (value == null || value == '0') return false;
  if (value != '1') throw FormatException('DANA_GLOBAL_BUDGET must be 0 or 1');
  return true;
}

Directory globalBudgetDirectory() {
  final explicit = Platform.environment['DANA_GLOBAL_STATE_DIR'];
  if (explicit != null && explicit.isNotEmpty) {
    return Directory(explicit).absolute;
  }
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('HOME is unavailable; set DANA_GLOBAL_STATE_DIR');
    }
    return Directory(
      '$home/Library/Application Support/dart_analysis_daemon/global-v1',
    );
  }
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null || local.isEmpty) {
    throw StateError('LOCALAPPDATA is unavailable; set DANA_GLOBAL_STATE_DIR');
  }
  return Directory('$local/dart_analysis_daemon/global-v1');
}

Future<Map<String, Object?>> _runtimeIdentity() async => {
  'protocol': 1,
  'implementation': 6,
  'dartExecutable': await identityDartExecutable(),
  'hostExecutable': Platform.resolvedExecutable.toLowerCase(),
  'hostVersion': Platform.version,
  'entryScript': Platform.script.toString(),
  'policy': GlobalBudgetPolicy.fromEnvironment(
    Platform.environment,
  ).toJson(null),
};

/// Lifetime lock is held until owned worker cleanup finishes. An unreachable
/// but live owner cannot be replaced just by deleting an endpoint or stale PID.
Future<void> serveGlobalBudget({
  Directory? directory,
  GlobalAnalyzerPool? pool,
  SystemMemorySnapshot? Function()? memorySampler,
  Future<AnalyzerProcess> Function(
    String root,
    String jobName,
    String sdkState,
  )?
  startOwnedWorker,
}) async {
  if (!Platform.isWindows && !Platform.isMacOS && pool == null) {
    throw UnsupportedError('Global budget requires verified Windows ownership');
  }
  final policy = GlobalBudgetPolicy.fromEnvironment(Platform.environment);
  final executable = await resolveDartExecutable();
  // macOS has no Job Object. It reuses the single-worker rotation and memory
  // admission of the production path, but starts the owned worker with the
  // cross-platform `direct` backend (eviction is a process-tree kill) instead
  // of the Windows FFI+Job backend. A caller-supplied starter still wins.
  final effectiveStartOwnedWorker =
      startOwnedWorker ??
      (Platform.isMacOS && pool == null
          ? (String root, String jobName, String sdkState) async =>
              DirectAnalyzerProcess(
                await Process.start(
                  executable,
                  [
                    'language-server',
                    '--protocol=analyzer',
                    '--client-id=dana-global-budget',
                  ],
                  workingDirectory: root,
                  environment: {'ANALYZER_STATE_LOCATION_OVERRIDE': sdkState},
                ),
              )
          : null);
  final identity = await _runtimeIdentity();
  final state = directory ?? globalBudgetDirectory();
  await state.create(recursive: true);
  final lock = await File(
    '${state.path}/owner.lock',
  ).open(mode: FileMode.append);
  if (!await _acquireOwnerLock(lock, state)) {
    await lock.close();
    return;
  }
  final previousWorker = File('${state.path}/worker-job.json');
  try {
    if (pool == null && await previousWorker.exists()) {
      if (await previousWorker.length() > 65536) {
        throw StateError('Invalid previous worker journal');
      }
      final record = jsonDecode(await previousWorker.readAsString()) as Map;
      if (record['protocol'] != 1 ||
          record['jobName'] is! String ||
          !(record['jobName'] as String).startsWith('Local\\dana-global-')) {
        throw StateError('Unknown previous worker identity');
      }
      // Windows waits for the named Job to drain. macOS has no Job Object: the
      // owner lock we already hold guarantees no other budget owner is live,
      // so a previous worker is a dead process tree and the only cleanup owed
      // is the managed cache below.
      if (!Platform.isMacOS) {
        await WindowsFfiAnalyzerProcess.waitForEmptyNamedJob(
          record['jobName'] as String,
        );
      }
      await ManagedPluginCache.removeOwned(state, record['cacheName']);
    }
  } catch (_) {
    await lock.unlock();
    await lock.close();
    rethrow;
  }
  ServerSocket? server;
  final connections = <Socket>{};
  final stopped = Completer<void>();
  final endpoint = File('${state.path}/endpoint.json');
  final token =
      List.generate(
        32,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
  // System sampler for the owned worker path, selected per platform.
  final SystemMemorySnapshot? Function()? sampler =
      pool != null
          ? null
          : (Platform.isMacOS
              ? MacSystemMemorySampler().sample
              : WindowsSystemMemorySampler().sample);
  final cache = ManagedPluginCache(
    state,
    'sdk-cache-${token.substring(0, 16)}',
  );
  Directory? preparedCache;
  String? preparedJobName;
  final owned =
      pool ??
      GlobalAnalyzerPool(
        policy: policy,
        sampleMemory: memorySampler ?? sampler!,
        validateIdentity:
            (root, expected) async => await _rootIdentity(root) == expected,
        invalidateWorkerCache: cache.invalidate,
        workerStarted: cache.recordExecution,
        validateExecution: cache.validateExecution,
        prepareWorker: (root, observedIdentity) async {
          final name =
              'Local\\dana-global-$token-${DateTime.now().microsecondsSinceEpoch}';
          // Journal intent before creating cache data or a worker. Recovery
          // waits for this exact Job to be empty before removing this cache.
          final temporary = File('${previousWorker.path}.$pid.tmp');
          await temporary.writeAsString(
            jsonEncode({
              'protocol': 1,
              'jobName': name,
              'cacheName': cache.name,
            }),
            flush: true,
          );
          await temporary.rename(previousWorker.path);
          preparedCache = await cache.prepare(root, observedIdentity);
          preparedJobName = name;
        },
        createWorker:
            (root) => AnalyzerDaemon(
              root,
              ownedProcessStarter: () async {
                final name = preparedJobName;
                final sdkState = preparedCache;
                if (name == null || sdkState == null) {
                  throw StateError('Managed worker state was not prepared');
                }
                if (effectiveStartOwnedWorker != null) {
                  return effectiveStartOwnedWorker(root, name, sdkState.path);
                }
                return WindowsFfiAnalyzerProcess.start(
                  executable,
                  [
                    'language-server',
                    '--protocol=analyzer',
                    '--client-id=dana-global-budget',
                  ],
                  workingDirectory: root,
                  jobName: name,
                  environment: {
                    'ANALYZER_STATE_LOCATION_OVERRIDE': sdkState.path,
                  },
                );
              },
            ),
      );
  var stopping = false;
  var diskSnapshotLeases = 0;
  final signals = <StreamSubscription<ProcessSignal>>[];
  Future<void>? releaseFuture;
  Future<void> releaseOwnership() =>
      releaseFuture ??= () async {
        try {
          await owned.close();
          if (pool == null) {
            await ManagedPluginCache.removeOwned(state, cache.name);
          }
        } finally {
          try {
            if (await endpoint.exists()) {
              try {
                final metadata =
                    jsonDecode(await endpoint.readAsString()) as Map;
                if (metadata['token'] == token) await endpoint.delete();
              } on FormatException {
                // An unknown replacement record is never ours to delete.
              }
            }
          } finally {
            await lock.unlock();
            await lock.close();
          }
        }
      }();
  Future<void>? stopFuture;
  Future<void> stop({bool signalCompletion = true}) {
    return stopFuture ??= () async {
      stopping = true;
      try {
        await server?.close();
        await releaseOwnership();
      } finally {
        if (signalCompletion && !stopped.isCompleted) stopped.complete();
      }
    }();
  }

  try {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final data = {
      'protocol': 1,
      'owner': 'dana-global-budget',
      'pid': pid,
      'port': server.port,
      'token': token,
      'identity': identity,
    };
    final temp = File('${endpoint.path}.$pid.tmp');
    await temp.writeAsString(jsonEncode(data), flush: true);
    await temp.rename(endpoint.path);
    server.listen((socket) {
      if (stopping || connections.length >= 128) {
        socket.destroy();
        return;
      }
      connections.add(socket);
      final disconnected = Completer<void>();
      final handshake = Timer(
        const Duration(seconds: 5),
        () => socket.destroy(),
      );
      void disconnect() {
        handshake.cancel();
        connections.remove(socket);
        if (!disconnected.isCompleted) disconnected.complete();
      }

      var used = false;
      _boundedLines(socket).listen(
        (line) async {
          if (used) {
            socket.destroy();
            return;
          }
          used = true;
          handshake.cancel();
          var stopRequested = false;
          Map<String, Object?> response;
          try {
            final request = jsonDecode(line);
            if (request is! Map ||
                request['token'] != token ||
                request['protocol'] != 1) {
              throw StateError('Invalid global budget credentials/protocol');
            }
            final compatible =
                jsonEncode(request['identity']) == jsonEncode(identity);
            if (request['op'] == 'check' && !compatible) {
              throw StateError(
                'Global budget runtime/policy differs; stop the existing budget owner before switching',
              );
            }
            switch (request['op']) {
              case 'status':
                response = {
                  'ok': true,
                  'compatible': compatible,
                  'pid': pid,
                  ...owned.status,
                };
              case 'stop':
                stopRequested = true;
                await stop(signalCompletion: false);
                response = {'ok': true, 'shutdownComplete': true};
              case 'check':
                final root =
                    await Directory(
                      request['root'] as String,
                    ).resolveSymbolicLinks();
                final command = Map<String, Object?>.from(
                  request['command'] as Map,
                );
                await _validateDiskTargets(root, command);
                if (diskSnapshotLeases >= 16) {
                  throw StateError(
                    'Global disk snapshot budget is full; retry later',
                  );
                }
                diskSnapshotLeases++;
                try {
                  final before = await _rootIdentity(root);
                  final targets = (command['files'] as List).cast<String>();
                  // Windows copies each target into a disk snapshot so the
                  // analyzed bytes cannot change mid-analysis. macOS has no
                  // equivalent FFI snapshot; analyze the on-disk files
                  // directly, matching the trust model of ordinary fast
                  // checks, and rely on the before/after root-identity guard
                  // below to detect configuration changes.
                  if (Platform.isMacOS) {
                    response = await owned.submit(
                      root,
                      before,
                      command,
                      cancelled: disconnected.future,
                    );
                  } else {
                    final snapshots = await _captureInIsolate(root, targets);
                    command['files'] = snapshots.map((s) => s.path).toList();
                    response = await owned.submit(
                      root,
                      before,
                      command,
                      cancelled: disconnected.future,
                      validateRequest:
                          () => _validateInIsolate(root, targets, snapshots),
                    );
                  }
                  // The real pool validates immediately before and after the
                  // analysis. Injected test pools may not supply that callback.
                  if (pool != null && before != await _rootIdentity(root)) {
                    throw StateError(
                      'Root configuration changed during analysis; result discarded',
                    );
                  }
                  response = {
                    ...response,
                    'targetVersionChecked': true,
                    'dependenciesFrozen': false,
                    'environmentIdentityComplete': false,
                  };
                } finally {
                  diskSnapshotLeases--;
                }
              case 'releaseRoot':
                final root =
                    await Directory(
                      request['root'] as String,
                    ).resolveSymbolicLinks();
                await owned.releaseRoot(root);
                response = {'ok': true, 'released': true};
              default:
                throw UnsupportedError('Unknown global budget operation');
            }
          } catch (error) {
            response = {'ok': false, 'error': '$error'};
          }
          try {
            socket.writeln(jsonEncode(response));
            await socket.flush();
          } catch (_) {
            /* Disconnected caller does not invalidate another lease. */
          } finally {
            socket.destroy();
            disconnect();
            if (stopRequested && !stopped.isCompleted) stopped.complete();
          }
        },
        onDone: disconnect,
        onError: (Object error) {
          socket.destroy();
          disconnect();
        },
      );
    });
    signals.add(ProcessSignal.sigint.watch().listen((_) => stop().ignore()));
    if (!Platform.isWindows) {
      signals.add(ProcessSignal.sigterm.watch().listen((_) => stop().ignore()));
    }
    await stopped.future;
  } finally {
    try {
      await releaseOwnership();
    } finally {
      for (final socket in connections) {
        socket.destroy();
      }
      for (final signal in signals) {
        await signal.cancel();
      }
      await server?.close();
    }
  }
}

Future<bool> _acquireOwnerLock(RandomAccessFile lock, Directory state) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    try {
      await lock.lock(FileLock.exclusive);
      return true;
    } on FileSystemException {
      try {
        final status = await globalBudgetRequest(
          {'op': 'status'},
          autoStart: false,
          directory: state,
        );
        if (status['ok'] == true) {
          return false; // A reachable owner already won.
        }
      } catch (_) {
        /* A dying owner can still hold its lock briefly. */
      }
      if (DateTime.now().isAfter(deadline)) {
        await lock.close();
        throw StateError(
          'Global owner lock is held but its endpoint is unavailable',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

Future<void> _validateDiskTargets(
  String root,
  Map<String, Object?> command,
) async {
  if (command['op'] == 'fullCheck') {
    throw UnsupportedError(
      'Global full gates require a verified plugin diagnostic barrier; use disk fast checks for observations',
    );
  }
  if (command['op'] != 'check' ||
      command['files'] is! List ||
      (command['files'] as List).isEmpty) {
    throw ArgumentError('Expected disk check files');
  }
  if ((command['files'] as List).length > 128) {
    throw ArgumentError('Managed disk request exceeds 128 targets');
  }
  final targets = <String>[];
  for (final target in command['files'] as List) {
    if (target is! String) {
      throw UnsupportedError('Managed checks do not accept overlays');
    }
    final candidate = File(target).isAbsolute ? target : '$root/$target';
    final entity = await FileSystemEntity.type(candidate);
    final canonical =
        entity == FileSystemEntityType.directory
            ? await Directory(candidate).resolveSymbolicLinks()
            : await File(candidate).resolveSymbolicLinks();
    final key = canonical.toLowerCase();
    if (key != root.toLowerCase() &&
        !key.startsWith('${root.toLowerCase()}${Platform.pathSeparator}')) {
      throw ArgumentError('Target escapes its worktree: $target');
    }
    targets.add(canonical);
  }
  command['files'] = targets;
}

// Bound parser/isolate memory when several roots arrive at once. Waiting calls
// retain only their root path, not an already parsed configuration graph.
Future<void> _identityTail = Future<void>.value();

Future<String> _rootIdentity(String root) {
  final result = _identityTail.then((_) => _captureEnvironment(root));
  _identityTail = result.then<void>(
    (_) {},
    onError: (Object error, StackTrace stack) {},
  );
  return result;
}

Future<String> _captureEnvironment(String root) =>
    Isolate.run(() => EnvironmentIdentity().capture(root));

// Keep isolate closures outside the connection handler's captured context.
Future<List<WindowsDiskSnapshot>> _captureInIsolate(
  String root,
  List<String> targets,
) => Isolate.run(() => _captureDiskTargets(root, targets));

Future<void> _validateInIsolate(
  String root,
  List<String> targets,
  List<WindowsDiskSnapshot> snapshots,
) => Isolate.run(() async {
  final current = await _captureDiskTargets(root, targets);
  final byPath = {for (final snapshot in current) snapshot.path: snapshot};
  if (current.length != snapshots.length) {
    throw StateError('Target directory changed; result discarded');
  }
  for (final snapshot in snapshots) {
    final observed = byPath[snapshot.path];
    if (observed == null || !snapshot.same(observed)) {
      throw StateError(
        'Target changed while queued or analyzed; result discarded: ${snapshot.path}',
      );
    }
  }
});

Future<List<WindowsDiskSnapshot>> _captureDiskTargets(
  String root,
  List<String> targets,
) async {
  final files = <String>{};
  var entries = 0;
  for (final target in targets) {
    if (Directory(target).existsSync()) {
      await for (final entity in Directory(
        target,
      ).list(recursive: true, followLinks: false)) {
        if (++entries > 4096) {
          throw StateError('Disk target expansion exceeds 4096 entries');
        }
        if (entity is File && entity.path.endsWith('.dart')) {
          files.add(entity.path);
        }
        if (files.length > 128) {
          throw StateError('Managed disk request exceeds 128 targets');
        }
      }
    } else {
      files.add(target);
    }
    if (files.length > 128) {
      throw StateError('Managed disk request exceeds 128 targets');
    }
  }
  if (files.isEmpty) {
    throw StateError('Managed disk request contains no targets');
  }
  var total = 0;
  final snapshots = <WindowsDiskSnapshot>[];
  for (final path in files) {
    final snapshot = WindowsDiskSnapshot.read(path);
    if (!snapshot.path.toLowerCase().startsWith(
      '${root.toLowerCase()}${Platform.pathSeparator}',
    )) {
      throw StateError('Expanded disk target escapes worktree');
    }
    total += snapshot.bytes.length;
    if (total > 1024 * 1024) {
      throw StateError('Managed disk snapshot exceeds 1MiB');
    }
    snapshots.add(snapshot);
  }
  return snapshots;
}

Stream<String> _boundedLines(Stream<List<int>> input) async* {
  final pending = <int>[];
  await for (final chunk in input) {
    for (final byte in chunk) {
      if (byte == 10) {
        yield utf8.decode(pending);
        pending.clear();
      } else {
        pending.add(byte);
        if (pending.length > 1024 * 1024) {
          throw FormatException('Global budget frame exceeds 1MiB');
        }
      }
    }
  }
  if (pending.isNotEmpty) {
    throw FormatException('Truncated global budget frame');
  }
}

Future<Map<String, Object?>> globalBudgetRequest(
  Map<String, Object?> request, {
  bool autoStart = true,
  CancellationSignal? cancelled,
  Directory? directory,
}) async {
  Socket? current;
  final cancellation = cancelled?.events.listen((_) => current?.destroy());
  try {
    return await _globalBudgetRequest(
      request,
      autoStart: autoStart,
      cancelled: cancelled,
      directory: directory,
      connected: (socket) => current = socket,
    );
  } finally {
    current = null;
    await cancellation?.cancel();
  }
}

Future<Map<String, Object?>> _globalBudgetRequest(
  Map<String, Object?> request, {
  required bool autoStart,
  required CancellationSignal? cancelled,
  required Directory? directory,
  required void Function(Socket? socket) connected,
}) async {
  GlobalBudgetPolicy.fromEnvironment(Platform.environment);
  final endpoint = File(
    '${(directory ?? globalBudgetDirectory()).path}/endpoint.json',
  );
  final identity = await _runtimeIdentity();
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  var launched = false;
  while (true) {
    if (cancelled?.isCancelled ?? false) {
      throw StateError('Global budget request cancelled before connection');
    }
    Socket? socket;
    try {
      if (await endpoint.exists() && await endpoint.length() < 65536) {
        final metadata = jsonDecode(await endpoint.readAsString()) as Map;
        if (metadata['protocol'] != 1 ||
            metadata['owner'] != 'dana-global-budget') {
          throw StateError('Incompatible global budget endpoint');
        }
        socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          metadata['port'] as int,
          timeout: const Duration(milliseconds: 500),
        );
        final connection = socket;
        connected(connection);
        try {
          connection.writeln(
            jsonEncode({
              ...request,
              'protocol': 1,
              'token': metadata['token'],
              'identity': identity,
            }),
          );
          await connection.flush();
          final line = await _boundedLines(
            connection,
          ).first.timeout(const Duration(minutes: 35));
          return Map<String, Object?>.from(jsonDecode(line) as Map);
        } finally {
          connected(null);
        }
      }
    } on SocketException {
      if (socket != null) rethrow;
    } on FormatException {
      if (socket != null) rethrow;
    } finally {
      socket?.destroy();
    }
    if (!autoStart || DateTime.now().isAfter(deadline)) {
      throw StateError(
        'Global budget owner is unavailable; a live lifetime lock is never forcibly replaced',
      );
    }
    if (!launched) {
      launched = true;
      await Process.start(
        Platform.resolvedExecutable,
        selfProcessArguments(['budget', 'serve']),
        mode: ProcessStartMode.detached,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Root sessions are lightweight adapters; only the global owner starts workers.
class BudgetedAnalyzerDaemon extends AnalyzerDaemon {
  BudgetedAnalyzerDaemon(super.root);
  final _closed = CancellationSignal();
  Future<void>? _closing;
  @override
  Future<void> start() async {
    final status = await globalBudgetRequest({'op': 'status'});
    if (status['ok'] != true) throw StateError('${status['error']}');
    if (status['compatible'] != true) {
      throw StateError(
        'Existing global budget runtime/policy differs; use dana budget stop before switching',
      );
    }
  }

  @override
  Future<Map<String, Object?>> handle(Map<String, Object?> command) =>
      handleCancellable(command, _closed);

  Future<Map<String, Object?>> handleCancellable(
    Map<String, Object?> command,
    CancellationSignal disconnected,
  ) async {
    if (_closed.isCancelled) throw StateError('Managed root session is closed');
    final operation = command['op'] == 'status' ? 'status' : 'check';
    final combined = CancellationSignal();
    if (disconnected.isCancelled || _closed.isCancelled) combined.cancel();
    final subscriptions = [
      disconnected.events.listen((_) => combined.cancel()),
      _closed.events.listen((_) => combined.cancel()),
    ];
    try {
      return await globalBudgetRequest({
        'op': operation,
        'root': root,
        'command': command,
      }, cancelled: combined);
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed.cancel();
    if (!await File('${globalBudgetDirectory().path}/endpoint.json').exists()) {
      return;
    }
    try {
      final response = await globalBudgetRequest({
        'op': 'releaseRoot',
        'root': root,
      }, autoStart: false);
      if (response['ok'] != true) throw StateError('${response['error']}');
    } on StateError catch (error) {
      if (!'$error'.contains('owner is unavailable')) rethrow;
      final journal =
          jsonDecode(
                await File(
                  '${globalBudgetDirectory().path}/worker-job.json',
                ).readAsString(),
              )
              as Map;
      await WindowsFfiAnalyzerProcess.waitForEmptyNamedJob(
        journal['jobName'] as String,
      );
    }
  }
}
