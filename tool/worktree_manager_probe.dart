// Standalone research endpoint. Deliberately separate from dana's product entrypoints.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'worktree_native_worker_adapter.dart';
import 'worktree_environment_identity.dart';
import 'worktree_protocol_output.dart';
import 'worktree_resource_sampler.dart';
import 'worktree_root_identity.dart';
import 'worktree_scheduler_model.dart';
import 'worktree_overlay_model.dart';
import 'worktree_disk_snapshot.dart';
import 'worktree_disk_observation.dart';

class ProbeOverlayState {
  ProbeOverlayState(String root)
    : model = ResearchOverlayModel(root, maxBytes: 256 * 1024);
  final ResearchOverlayModel model;
  final owners = <String>{};
  NativeModelWorker? worker;
  int references = 0;
  int generation = 0;
  Map? acknowledgement;
}

class Pending {
  Pending(this.key);
  final String key;
  final cancelled = Completer<void>();
  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }
}

// Bound the bytes before decoding or waiting for a newline. LineSplitter alone
// can retain an arbitrarily large unterminated frame.
Stream<String> boundedLines(Stream<List<int>> input) async* {
  final bytes = <int>[];
  await for (final chunk in input) {
    for (final byte in chunk) {
      if (byte == 10) {
        yield utf8.decode(bytes);
        bytes.clear();
      } else {
        if (bytes.length >= 65536) {
          throw const FormatException('Frame exceeds 64 KiB');
        }
        bytes.add(byte);
      }
    }
  }
  if (bytes.isNotEmpty) throw const FormatException('Incomplete frame');
}

Future<Map?> boundedEndpointRecord(File file) async {
  final handle = await file.open();
  try {
    final bytes = await handle.read(4097);
    if (bytes.length > 4096) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes));
      return value is Map ? value : null;
    } on FormatException {
      return null;
    }
  } finally {
    await handle.close();
  }
}

Future<void> main(List<String> args) async {
  if (!Platform.isWindows) {
    throw UnsupportedError('Windows research probe only');
  }
  final systemMemory = args.contains('--system-memory');
  final officialMode = args.contains('--official-worker');
  final requestOverlayMode = args.contains('--official-request-overlays');
  if (requestOverlayMode && !officialMode) {
    throw ArgumentError(
      'Official request overlays require official worker mode',
    );
  }
  final officialFaultGates = args.contains('--official-fault-gates');
  if (officialFaultGates && !officialMode) {
    throw ArgumentError('Official fault gates require official worker mode');
  }
  if (officialMode &&
      (!systemMemory ||
          args.contains('--overlays') ||
          args.contains('--lifecycle-injections'))) {
    throw ArgumentError(
      'Official worker requires real memory and rejects overlay/injection modes',
    );
  }
  final failPublish = args.contains('--fail-publish');
  final failAfterPublish = args.contains('--fail-after-publish');
  final shortConnections = args.contains('--short-connections');
  final environmentIdentity =
      officialMode || args.contains('--environment-identity');
  final lifecycleInjections = args.contains('--lifecycle-injections');
  final overlayMode = args.contains('--overlays');
  final fixture =
      Directory(args.where((arg) => !arg.startsWith('--')).single).absolute;
  if (!fixture.existsSync()) {
    throw ArgumentError('Use an existing dedicated fixture');
  }
  final lock = await File(
    '${fixture.path}/manager.lock',
  ).open(mode: FileMode.append);
  try {
    await lock.lock(FileLock.exclusive);
  } on FileSystemException {
    await lock.close();
    stdout.writeln(jsonEncode({'event': 'already-running'}));
    return;
  }
  ResearchResourceSampler? resources;
  ServerSocket? ownedServer;
  Timer? ownedTicker;
  StreamSubscription<List<int>>? ownedInput;
  File? ownedEndpoint;
  File? ownedTemporary;
  String? ownedGeneration;
  try {
    final token =
        List.generate(
          24,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
    final generation = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final endpoint = File('${fixture.path}/manager.json');
    ownedEndpoint = endpoint;
    ownedGeneration = generation;
    final clock = Stopwatch()..start();
    final workers = <NativeModelWorker>[];
    final environmentCollector = ResearchEnvironmentCollector();
    final environments = <String, ResearchEnvironment>{};
    final environmentUsers = <String, int>{};
    var workerStarts = 0;
    var preparingRequests = 0;
    var outstandingRequests = 0;
    var nativeAttempts = 0;
    var preparationDelayMs = 0;
    var startupDelayMs = 0;
    var overlayDelayMs = 0;
    var overlayReplays = 0;
    Map<String, Object?>? lastResourceStop;
    final overlays = <String, ProbeOverlayState>{};
    ProbeOverlayState overlayState(String root) {
      for (final entry in overlays.entries.toList()) {
        if (entry.key != root &&
            entry.value.owners.isEmpty &&
            entry.value.references == 0 &&
            (entry.value.worker == null ||
                entry.value.worker!.confirmedEmpty)) {
          overlays.remove(entry.key);
        }
      }
      if (!overlays.containsKey(root) && overlays.length >= 16) {
        throw StateError('Overlay root limit');
      }
      return overlays.putIfAbsent(root, () => ProbeOverlayState(root));
    }

    final clients = <Socket>{};
    final clientDisconnects = <Socket, void Function()>{};
    if (systemMemory) {
      resources = await ResearchResourceSampler.start();
    }
    var memoryAllowed =
        true; // Injected control for protocol tests, not a real sampler.
    var shuttingDown = false;
    var injectedPressure = false;
    var idleTimeoutMs = 60000;
    var jobPeakLimitMiB = 4096.0;
    NativeModelWorker? idleWorker;
    int? idleSince;
    bool runtimeAllowed() {
      if (injectedPressure) return false;
      final worker = workers.where((w) => !w.confirmedEmpty).lastOrNull;
      if (worker != null &&
          ((worker.peakPrivateCommitMiB ?? 0) > jobPeakLimitMiB ||
              (worker.healthClock.elapsedMilliseconds > 2000 &&
                  !worker.healthFresh))) {
        return false;
      }
      if (!systemMemory) return true;
      final sample = resources!;
      return !sample.exited &&
          sample.ageMs != null &&
          sample.ageMs! <= 2000 &&
          (sample.physicalMiB?.isFinite ?? false) &&
          (sample.commitMiB?.isFinite ?? false) &&
          (sample.physicalMiB ?? -1) >= 4096 &&
          (sample.commitMiB ?? -1) >= 4096;
    }

    var clientSequence = 0;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    ownedServer = server;
    late final WorktreeSchedulerModel scheduler;
    scheduler = WorktreeSchedulerModel(
      factory: (workerKey, workerGeneration) async {
        if (workers.any((worker) => !worker.confirmedEmpty)) {
          throw ModelStartupCleanupUnconfirmed(
            StateError('Previous Job not empty'),
          );
        }
        final environment = environments[workerKey];
        if (environment != null &&
            (await environmentCollector.capture(
                  environment.root,
                  environment.runtime,
                )).key !=
                environment.key) {
          throw StateError('Environment changed before worker startup');
        }
        nativeAttempts++;
        final worker = await NativeModelWorker.start(
          fixture,
          dartExecutable: environment?.runtime,
          officialRoot: officialMode ? environment!.root : null,
          officialFaultGates: officialFaultGates,
          readyDelayMs: startupDelayMs,
        );
        if (environment != null) {
          try {
            if ((await environmentCollector.capture(
                  environment.root,
                  environment.runtime,
                )).key !=
                environment.key) {
              throw StateError('Environment changed during worker startup');
            }
          } catch (error) {
            try {
              await worker.close();
            } catch (cleanup) {
              throw ModelStartupCleanupUnconfirmed(cleanup);
            }
            rethrow;
          }
        }
        workers.add(worker);
        worker.schedulerGeneration = workerGeneration;
        workerStarts++;
        unawaited(
          worker.stopped.future.then((_) {
            if (worker.confirmedEmpty) workers.remove(worker);
          }),
        );
        worker.failures.stream.listen((error) {
          scheduler.invalidateGeneration(workerGeneration);
        });
        if (worker.lastFailure != null) {
          scheduler.invalidateGeneration(workerGeneration);
        }
        unawaited(
          worker.owner.exitCode.then((code) async {
            // Windows can signal owner exit before the already-written final
            // Job-zero event has been consumed from stdout. Drain it first.
            try {
              await worker.stopped.future.timeout(const Duration(seconds: 2));
            } on TimeoutException {
              /* Remain unconfirmed and fail closed below. */
            }
            if (!worker.confirmedEmpty) {
              scheduler.workerOwnershipLost(
                workerGeneration,
                StateError('Native owner exited unexpectedly: $code'),
              );
            }
          }),
        );
        if (officialMode) {
          try {
            if (shuttingDown || !resources!.allowed || !runtimeAllowed()) {
              throw StateError(
                'Fresh official initialization admission denied',
              );
            }
            final watch = Stopwatch()..start();
            final initialized = await worker.officialRequest('initialize');
            worker.officialInitializationMs = watch.elapsedMilliseconds;
            if (initialized['ok'] != true ||
                initialized['rootConfigured'] != true ||
                worker.lastFailure != null ||
                !runtimeAllowed()) {
              throw StateError('Official initialization failed');
            }
            if ((await environmentCollector.capture(
                  environment!.root,
                  environment.runtime,
                )).key !=
                environment.key) {
              throw StateError(
                'Environment changed during official initialization',
              );
            }
          } catch (_) {
            try {
              await worker.close();
            } catch (cleanup) {
              throw ModelStartupCleanupUnconfirmed(cleanup);
            }
            if (worker.resourceFailure != null) throw worker.resourceFailure!;
            rethrow;
          }
        }
        return worker;
      },
      nowMs: () => clock.elapsedMilliseconds,
      canStart:
          () =>
              runtimeAllowed() &&
              (systemMemory ? resources!.allowed : memoryAllowed),
      canLease: runtimeAllowed,
      closeTimeout: const Duration(seconds: 20),
    );
    Future<void>? shutdownFuture;
    Future<void> performShutdown() async {
      if (shuttingDown) return;
      shuttingDown = true;
      scheduler.shutdown();
      if (officialMode) {
        // Shutdown invalidates results; do not wait for cold initialization.
        for (final worker in workers.toList()) {
          unawaited(
            worker.close().catchError((Object error) {
              scheduler.workerOwnershipLost(worker.schedulerGeneration!, error);
            }),
          );
        }
      }
      ownedServer = null;
      await server.close();
      for (final client in clients.toList()) {
        clientDisconnects[client]?.call();
      }
    }

    Future<void> shutdown() => shutdownFuture ??= performShutdown();

    final ticker = Timer.periodic(const Duration(milliseconds: 25), (_) {
      final resident = scheduler.residentRoot;
      final current = workers.where((w) => !w.confirmedEmpty).lastOrNull;
      if (resident != null && !runtimeAllowed()) {
        if (officialMode && current != null) {
          if (current.resourceFailure == null) {
            lastResourceStop = {
              'ms': clock.elapsedMilliseconds,
              'workerGeneration': current.schedulerGeneration,
              'worker': current.workerPid,
              'memory': resources?.status,
              'peakPrivateCommitMiB': current.peakPrivateCommitMiB,
              'healthFresh': current.healthFresh,
              'peakLimitMiB': jobPeakLimitMiB,
            };
            current.resourceFailure = StateError(
              'Official worker runtime resource guard: ${jsonEncode(lastResourceStop)}',
            );
          }
          scheduler.invalidate(resident);
          unawaited(
            current.close().catchError((Object error) {
              scheduler.workerOwnershipLost(
                current.schedulerGeneration!,
                error,
              );
            }),
          );
        } else {
          scheduler.retire(resident);
        }
      }
      if (scheduler.activeLeases == 0 &&
          resident != null &&
          current != null &&
          (!officialMode || current.officialInitializationMs != null)) {
        if (!identical(idleWorker, current)) idleSince = null;
        idleWorker = current;
        idleSince ??= clock.elapsedMilliseconds;
        if (clock.elapsedMilliseconds - idleSince! >= idleTimeoutMs) {
          scheduler.retire(resident);
        }
      } else {
        idleSince = null;
        idleWorker = null;
      }
      scheduler.tick();
    });
    ownedTicker = ticker;
    final metadata = {
      'protocol': 1,
      'generation': generation,
      'owner': 'dana-manager-research',
      'pid': pid,
      'address': '127.0.0.1',
      'port': server.port,
      'token': token,
    };
    final temporary = File('${endpoint.path}.$pid.tmp');
    ownedTemporary = temporary;
    await temporary.writeAsString(jsonEncode(metadata), flush: true);
    if (failPublish) {
      stdout.writeln(
        jsonEncode({
          'event': 'publish-failure',
          'port': server.port,
          'samplerPid': resources?.process.pid,
        }),
      );
      throw StateError('Injected endpoint publication failure');
    }
    // Lifetime lock prevents another probe from replacing a live endpoint.
    if (await endpoint.exists()) await endpoint.delete();
    await temporary.rename(endpoint.path);
    if (failAfterPublish) {
      stdout.writeln(
        jsonEncode({
          'event': 'publish-failure',
          'port': server.port,
          'samplerPid': resources?.process.pid,
        }),
      );
      throw StateError('Injected failure after endpoint publication');
    }
    stdout.writeln(
      jsonEncode({'event': 'ready', 'pid': pid, 'generation': generation}),
    );

    server.listen((socket) {
      if (clients.length >= 32) {
        socket.destroy();
        return;
      }
      clients.add(socket);
      final clientId = ++clientSequence;
      final requests = <String, Pending>{};
      final seenIds = <String>{};
      var disconnected = false;
      var authenticated = false;
      final connectionClock = Stopwatch()..start();
      var lastAcceptedMs = 0;
      late final Timer connectionTimer;
      late final ResearchOutputBuffer output;
      void disconnect() {
        if (disconnected) return;
        disconnected = true;
        clients.remove(socket);
        clientDisconnects.remove(socket);
        connectionTimer.cancel();
        output.close();
        for (final request in requests.values) {
          request.cancel();
          scheduler.cancel(request.key);
        }
        for (final state in overlays.values) {
          state.model.disconnect('$clientId');
          state.owners.remove('$clientId');
        }
        socket.destroy();
      }

      clientDisconnects[socket] = disconnect;

      output = ResearchOutputBuffer(
        writeBytes: (bytes) async {
          socket.add(bytes);
          await socket.flush();
        },
        onClose: disconnect,
      );
      connectionTimer = Timer.periodic(const Duration(milliseconds: 25), (_) {
        final elapsed = connectionClock.elapsedMilliseconds;
        if ((!authenticated && elapsed >= (shortConnections ? 300 : 5000)) ||
            (authenticated &&
                requests.isEmpty &&
                elapsed - lastAcceptedMs >= (shortConnections ? 400 : 60000))) {
          disconnect();
        }
      });

      void send(Map message) {
        if (disconnected) return;
        final responseId = message['id'];
        if (responseId is String && responseId.length > 128) {
          message = {...message, 'id': null};
        }
        var encoded = utf8.encode('${jsonEncode(message)}\n');
        if (encoded.length > 8192) {
          encoded = utf8.encode(
            '${jsonEncode({'id': message['id'], 'ok': false, 'error': 'Response exceeds research limit'})}\n',
          );
        }
        output.add(encoded);
      }

      Future<void> handle(String line) async {
        final receivedAt = clock.elapsedMilliseconds;
        String? id;
        try {
          final input = jsonDecode(line) as Map;
          id = input['id'] as String?;
          if (id == null || id.isEmpty || id.length > 128) {
            throw StateError('Invalid request ID');
          }
          if (input['protocol'] != 1 ||
              input['token'] != token ||
              input['generation'] != generation) {
            throw StateError('Protocol, token or generation mismatch');
          }
          authenticated = true;
          lastAcceptedMs = connectionClock.elapsedMilliseconds;
          // A second response with the same ID would violate the terminal contract.
          // Close this malformed connection and cancel its outstanding work instead.
          if (seenIds.length >= 1024 || !seenIds.add(id)) {
            disconnect();
            return;
          }
          final op = input['op'];
          if (op == 'hello' || op == 'status') {
            send({
              'id': id,
              'ok': true,
              'protocol': 1,
              'officialWorker': officialMode,
              'officialRequestOverlays': requestOverlayMode,
              'lastResourceStop': lastResourceStop,
              'generation': generation,
              'queued': scheduler.queued,
              'slots': scheduler.occupiedSlots,
              'leases': scheduler.activeLeases,
              'starts': workerStarts,
              'nativeAttempts': nativeAttempts,
              'preparing': preparingRequests,
              'outstanding': outstandingRequests,
              'overlayReplays': overlayReplays,
              'overlayRoots': overlays.length,
              'overlayBytes': overlays.values.fold<int>(
                0,
                (n, s) => n + s.model.retainedBytes,
              ),
              'trackedWorkers': workers.length,
              'degraded': scheduler.degraded?.toString(),
              'memory': resources?.status,
              'runtimeAllowed': runtimeAllowed(),
              'clients': clients.length,
              'pids': [
                for (final worker in workers.where((w) => !w.confirmedEmpty))
                  {
                    'owner': worker.owner.pid,
                    'worker': worker.workerPid,
                    'leaf': worker.leafPid,
                    'peakPrivateCommitMiB': worker.peakPrivateCommitMiB,
                    'currentPrivateCommitMiB':
                        worker.healthFresh
                            ? worker.currentPrivateCommitMiB
                            : null,
                    'currentWorkingSetMiB':
                        worker.healthFresh ? worker.currentWorkingSetMiB : null,
                    'healthFresh': worker.healthFresh,
                    if (officialMode)
                      'initializationMs': worker.officialInitializationMs,
                  },
              ],
            });
            return;
          }
          if (op == 'memory') {
            if (systemMemory) {
              throw StateError('Real admission cannot be overridden');
            }
            if (input['allowed'] is! bool) {
              throw StateError('Invalid injected admission');
            }
            memoryAllowed = input['allowed'] as bool;
            scheduler.tick();
            send({'id': id, 'ok': true});
            return;
          }
          if (op == 'research-policy') {
            if (systemMemory) {
              throw StateError('Real policy cannot be overridden');
            }
            final idle = input['idleMs'];
            final pressure = input['pressure'];
            final cap = input['peakLimitMiB'];
            final pause = input['pauseHealth'];
            if (idle is! int ||
                idle < 100 ||
                idle > 60000 ||
                pressure is! bool) {
              throw StateError('Invalid research policy');
            }
            if (cap != null && (cap is! num || !cap.isFinite || cap <= 0)) {
              throw StateError('Invalid Job peak limit');
            }
            if (pause != null && pause is! bool) {
              throw StateError('Invalid health injection');
            }
            idleTimeoutMs = idle;
            injectedPressure = pressure;
            if (cap is num) jobPeakLimitMiB = cap.toDouble();
            if (pause is bool) {
              final current =
                  workers.where((w) => !w.confirmedEmpty).lastOrNull;
              if (current == null) throw StateError('No worker to pause');
              final marker = File('${current.controlFile.path}.pause-health');
              if (pause) {
                await marker.writeAsString('pause', flush: true);
              } else if (await marker.exists()) {
                await marker.delete();
              }
            }
            send({'id': id, 'ok': true});
            return;
          }
          if (op == 'research-lifecycle') {
            if (!lifecycleInjections || systemMemory) {
              throw StateError('Lifecycle injection disabled');
            }
            final prepare = input['preparationDelayMs'];
            final start = input['startupDelayMs'];
            if (prepare is! int ||
                prepare < 0 ||
                prepare > 5000 ||
                start is! int ||
                start < 0 ||
                start > 5000) {
              throw StateError('Invalid lifecycle delay');
            }
            final delay = input['overlayDelayMs'] ?? 0;
            if (delay is! int || delay < 0 || delay > 2000) {
              throw StateError('Invalid overlay delay');
            }
            preparationDelayMs = prepare;
            startupDelayMs = start;
            overlayDelayMs = delay;
            send({'id': id, 'ok': true});
            return;
          }
          if (op == 'cancel') {
            final pending = requests[input['target']];
            pending?.cancel();
            if (pending != null) scheduler.cancel(pending.key);
            send({'id': id, 'ok': true, 'found': pending != null});
            return;
          }
          if (op == 'shutdown') {
            send({'id': id, 'ok': true});
            try {
              await output.drained.timeout(const Duration(seconds: 2));
            } on TimeoutException {
              disconnect();
            }
            unawaited(shutdown());
            return;
          }
          if (op == 'overlay') {
            if (!overlayMode) throw StateError('Overlay research disabled');
            final identity = researchRootIdentity(input['root'] as String);
            final path = input['path'];
            final version = input['version'];
            final content = input['content'];
            // Logical synthetic file keys only; no filesystem IO or symlink claim.
            if (path is! String ||
                path.length > 4096 ||
                !RegExp(r'^[a-zA-Z0-9_\-/]+\.dart$').hasMatch(path) ||
                path.startsWith('/') ||
                path.split('/').any((p) => p.isEmpty) ||
                version is! int ||
                (content != null && content is! String)) {
              throw StateError('Invalid overlay update');
            }
            final state = overlayState(identity.key);
            state.model.update(
              '$clientId',
              path.toLowerCase(),
              version,
              content as String?,
            );
            state.owners.add('$clientId');
            send({'id': id, 'ok': true, 'revision': state.model.revision});
            return;
          }
          final overlayObservation = officialMode && op == 'observe-overlay';
          if (overlayObservation && !requestOverlayMode) {
            throw StateError('Official request overlay research disabled');
          }
          final observation =
              officialMode && (op == 'observe-disk' || overlayObservation);
          if (op != (officialMode ? 'builtin-errors' : 'check') &&
              !observation) {
            throw StateError('Unknown operation');
          }
          if (officialMode &&
              ((!overlayObservation && input.containsKey('overlays')) ||
                  input.containsKey('content'))) {
            throw StateError('Official overlay input unsupported');
          }
          if (requests.length >= 64 || outstandingRequests >= 256) {
            throw StateError('Too many outstanding requests');
          }
          final timeout = input['timeoutMs'];
          final work = officialMode ? 0 : input['workMs'];
          if (timeout is! int ||
              timeout < 1 ||
              timeout > (officialMode ? 180000 : 30000) ||
              work is! int ||
              work < 0 ||
              work > 10000) {
            throw StateError('Invalid request durations');
          }
          final identity = researchRootIdentity(input['root'] as String);
          final root = identity.path;
          final target =
              officialMode
                  ? ResearchDiskSnapshot.capture(root, input['file'] as String)
                  : null;
          final bundle =
              observation
                  ? ResearchDiskBundle.capture(
                    root,
                    target!.path,
                    input['dependencies'],
                  )
                  : null;
          final expectedCodes =
              observation
                  ? researchExpectedCodes(input['expectedCodes'])
                  : null;
          final requestOverlay =
              overlayObservation
                  ? ResearchRequestOverlay.capture(bundle!, input['overlays'])
                  : null;
          ResearchEnvironment? environment;
          var workerKey = identity.key;
          var environmentRegistered = false;
          final overlay = overlayMode ? overlayState(identity.key) : null;
          overlay?.references++;
          final pending = Pending('$clientId:$id');
          requests[id] = pending;
          outstandingRequests++;
          ModelLease? lease;
          Timer? completedWork;
          Timer? deadline;
          StreamSubscription<Object>? workerFailure;
          Future<Map>? officialExchange;
          Map? officialResult;
          int? officialAnalysisMs;
          int? admissionWaitMs;
          int? officialExchangeMs;
          final interrupted = Completer<void>();
          final expires = receivedAt + timeout;
          void checkPending() {
            if (pending.cancelled.isCompleted || disconnected || shuttingDown) {
              throw StateError('Cancelled or disconnected');
            }
            if (clock.elapsedMilliseconds >= expires) {
              throw TimeoutException('Preparation deadline');
            }
          }

          try {
            if (environmentIdentity) {
              preparingRequests++;
              try {
                if (preparationDelayMs > 0) {
                  await Future.any<void>([
                    Future<void>.delayed(
                      Duration(milliseconds: preparationDelayMs),
                    ),
                    pending.cancelled.future,
                  ]).timeout(
                    Duration(
                      milliseconds: (expires - clock.elapsedMilliseconds).clamp(
                        0,
                        timeout,
                      ),
                    ),
                  );
                }
                checkPending();
                try {
                  environment = await environmentCollector.capture(
                    root,
                    input['dartExecutable'] as String? ??
                        Platform.resolvedExecutable,
                  );
                } catch (_) {
                  final resident = scheduler.residentRoot;
                  if (environments[resident]?.rootKey == identity.key) {
                    scheduler.invalidate(resident!);
                  }
                  rethrow;
                }
              } finally {
                preparingRequests--;
              }
              checkPending();
              workerKey = '${identity.key}:${environment.key}';
              final resident = scheduler.residentRoot;
              final previous = environments[resident];
              if (previous != null &&
                  previous.rootKey == identity.key &&
                  previous.key != environment.key) {
                scheduler.invalidate(resident!);
              }
              environments[workerKey] = environment;
              environmentUsers.update(
                workerKey,
                (n) => n + 1,
                ifAbsent: () => 1,
              );
              environmentRegistered = true;
            }
            checkPending();
            final admissionWatch = Stopwatch()..start();
            lease = await scheduler.acquire(
              pending.key,
              workerKey,
              deadlineMs: expires,
            );
            admissionWaitMs = admissionWatch.elapsedMilliseconds;
            if (pending.cancelled.isCompleted) throw StateError('Cancelled');
            final native = workers.last;
            if (native.lastFailure != null) throw native.lastFailure!;
            OverlayTicket? overlayTicket;
            Map? overlayAck;
            if (overlay != null) {
              overlayTicket = await native.serializeOverlays(() async {
                checkPending();
                if (!lease!.acceptsResults) {
                  throw StateError('Lease invalid before replay');
                }
                if (overlay.generation != lease.generation) {
                  overlay.model.bind(identity.key, lease.generation);
                  overlay.generation = lease.generation;
                  overlay.worker = native;
                  overlay.acknowledgement = null;
                }
                try {
                  final ticket = overlay.model.ticket();
                  overlayAck = overlay.acknowledgement;
                  return ticket;
                } on StateError {
                  // Current state has not yet been acknowledged by this worker.
                }
                final replay = overlay.model.replay();
                overlayReplays++;
                Map ack;
                try {
                  ack = await native.applyOverlays(
                    identity.key,
                    replay,
                    delayMs: overlayDelayMs,
                  );
                } catch (_) {
                  scheduler.invalidate(workerKey);
                  rethrow;
                }
                if (!overlay.model.acknowledge(replay)) {
                  throw StateError('Overlay changed during replay');
                }
                overlay.acknowledgement = overlayAck = ack;
                checkPending();
                return overlay.model.ticket();
              });
            }
            workerFailure = native.failures.stream.listen((error) {
              if (!interrupted.isCompleted) interrupted.completeError(error);
            });
            if (!officialMode) {
              completedWork = Timer(Duration(milliseconds: work), () {
                if (!interrupted.isCompleted) interrupted.complete();
              });
            }
            deadline = Timer(
              Duration(
                milliseconds: (expires - clock.elapsedMilliseconds).clamp(
                  0,
                  timeout,
                ),
              ),
              () {
                if (!interrupted.isCompleted) {
                  interrupted.completeError(TimeoutException('Work deadline'));
                }
              },
            );
            unawaited(
              pending.cancelled.future.then((_) {
                if (!interrupted.isCompleted) {
                  interrupted.completeError(
                    StateError('Cancelled or disconnected'),
                  );
                }
              }),
            );
            if (officialMode) {
              final watch = Stopwatch()..start();
              officialExchange = native.officialRequest(
                overlayObservation
                    ? 'observe-overlay'
                    : observation
                    ? 'observe-disk'
                    : 'builtin-errors',
                fields: {
                  'file': target!.path,
                  'targetDigest': target.digest,
                  if (bundle != null)
                    'dependencies':
                        bundle.inputs.skip(1).map((i) => i.path).toList(),
                  if (bundle != null) 'inputDigests': bundle.digests,
                  if (observation) 'expectedCodes': expectedCodes,
                  if (requestOverlay != null)
                    'overlays': requestOverlay.overrides,
                  if (requestOverlay != null)
                    'overlaySnapshotDigest': requestOverlay.digest,
                },
                cancelled: pending.cancelled.future,
                budget: Duration(
                  milliseconds: (expires - clock.elapsedMilliseconds).clamp(
                    0,
                    timeout,
                  ),
                ),
              );
              officialResult = await Future.any<Map>([
                officialExchange,
                interrupted.future.then<Map>(
                  (_) => throw StateError('Official work interrupted'),
                ),
              ]).catchError((Object error) {
                throw native.resourceFailure ?? error;
              });
              officialExchangeMs = watch.elapsedMilliseconds;
              officialAnalysisMs = officialResult['executionMs'] as int?;
              if (officialResult['ok'] != true) {
                throw StateError('Official query failed: $officialResult');
              }
              target.validate(root);
              if (officialResult['targetDigest'] != target.digest ||
                  officialResult['targetPinned'] != true) {
                throw StateError('Official target confirmation mismatch');
              }
            } else {
              await interrupted.future;
            }
            if (environment != null) {
              try {
                if ((await environmentCollector.capture(
                      root,
                      environment.runtime,
                    )).key !=
                    environment.key) {
                  throw StateError(
                    'Environment changed before result publication',
                  );
                }
              } catch (_) {
                scheduler.invalidate(workerKey);
                rethrow;
              }
            }
            if (clock.elapsedMilliseconds >= expires) {
              throw TimeoutException('Result validation deadline');
            }
            checkPending();
            if (!lease.acceptsResults) {
              throw StateError('Lease generation invalid');
            }
            if (overlayTicket != null &&
                !overlay!.model.accepts(overlayTicket)) {
              throw StateError('Overlay changed before result publication');
            }
            target?.validate(root);
            bundle?.validate(root);
            if (bundle != null &&
                (officialResult!['observationOnly'] != true ||
                    officialResult['inputDigests'] is! Map ||
                    (officialResult['inputDigests'] as Map).length !=
                        bundle.digests.length ||
                    bundle.digests.entries.any(
                      (e) => officialResult!['inputDigests'][e.key] != e.value,
                    ))) {
              throw StateError('Disk observation confirmation mismatch');
            }
            if (requestOverlay != null &&
                (officialResult!['overlaySnapshotDigest'] !=
                        requestOverlay.digest ||
                    officialResult['effectiveInputDigest'] !=
                        requestOverlay.effectiveDigest ||
                    officialResult['overlayScope'] != 'request-only' ||
                    officialResult['targetContentSource'] !=
                        (requestOverlay.overrides.containsKey(target!.path)
                            ? 'overlay'
                            : 'disk'))) {
              throw StateError('Request overlay confirmation mismatch');
            }
            send({
              'id': id,
              'ok': true,
              'root': root,
              'workerGeneration': lease.generation,
              'synthetic': !officialMode,
              if (officialMode) 'builtinOnly': !observation,
              if (observation) 'observationOnly': true,
              if (observation)
                'completionBasis': officialResult!['completionBasis'],
              if (observation) 'directErrors': officialResult!['directErrors'],
              if (observation) 'inputDigests': officialResult!['inputDigests'],
              if (observation)
                'sinceSequence': officialResult!['sinceSequence'],
              if (observation) 'pushSequence': officialResult!['pushSequence'],
              if (requestOverlay != null)
                'overlaySnapshotDigest': requestOverlay.digest,
              if (requestOverlay != null)
                'effectiveInputDigest': requestOverlay.effectiveDigest,
              if (requestOverlay != null) 'overlayScope': 'request-only',
              if (requestOverlay != null)
                'targetContentSource': officialResult!['targetContentSource'],
              if (officialMode) 'diagnosticComplete': false,
              if (officialMode) 'errors': officialResult!['errors'],
              if (officialMode) 'targetDigest': target!.digest,
              if (officialMode) 'targetPinned': true,
              if (officialMode) 'analysisMs': officialAnalysisMs,
              if (officialMode) 'officialExchangeMs': officialExchangeMs,
              if (officialMode) 'admissionWaitMs': admissionWaitMs,
              if (officialMode)
                'initializationMs': native.officialInitializationMs,
              if (overlayTicket != null)
                'overlayRevision': overlayTicket.revision,
              if (overlayTicket != null) 'overlayDigest': overlayAck!['digest'],
              if (overlayTicket != null)
                'overlayFileCount': overlayAck!['fileCount'],
              if (environment != null) 'environment': environment.key,
              if (environment != null) 'runtimeVersion': environment.version,
              if (environment != null)
                'workerRuntimeVersion': native.runtimeVersion,
            });
          } finally {
            // Cancellation invalidates publication immediately, but the lease
            // must outlive the bounded official exchange still in progress.
            if (officialExchange != null) {
              try {
                await officialExchange;
              } catch (_) {}
            }
            completedWork?.cancel();
            deadline?.cancel();
            await workerFailure?.cancel();
            lease?.release();
            requests.remove(id);
            outstandingRequests--;
            if (overlay != null) overlay.references--;
            lastAcceptedMs = connectionClock.elapsedMilliseconds;
            if (environmentRegistered) {
              environmentUsers[workerKey] = environmentUsers[workerKey]! - 1;
              for (final key in environments.keys.toList()) {
                if ((environmentUsers[key] ?? 0) == 0 &&
                    scheduler.residentRoot != key) {
                  environments.remove(key);
                  environmentUsers.remove(key);
                }
              }
            }
          }
        } catch (error) {
          send({'id': id, 'ok': false, 'error': '$error'});
        }
      }

      boundedLines(socket.cast<List<int>>()).listen(
        (line) => unawaited(handle(line)),
        onDone: disconnect,
        onError: (_) => disconnect(),
      );
    });

    // Parent controller EOF asks this research manager to shut down too.
    ownedInput = stdin.listen((_) {}, onDone: () => unawaited(shutdown()));
    while (!shuttingDown) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await shutdownFuture;
    final stopWatch = Stopwatch()..start();
    while ((scheduler.occupiedSlots != 0 || outstandingRequests != 0) &&
        scheduler.degraded == null) {
      if (stopWatch.elapsed > const Duration(seconds: 25)) {
        throw TimeoutException('Scheduler shutdown');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (scheduler.degraded != null) {
      throw StateError('Cleanup degraded: ${scheduler.degraded}');
    }
  } finally {
    // The lifetime lock must be released even if setup/publication or cleanup
    // itself fails. No workers are accepted before endpoint publication.
    final cleanupErrors = <Object>[];
    Future<void> clean(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        cleanupErrors.add(error);
      }
    }

    try {
      ownedTicker?.cancel();
      await clean(() async {
        await ownedServer?.close();
      });
      await clean(() async {
        await ownedInput?.cancel();
      });
      await clean(() async {
        await resources?.close();
      });
      await clean(() async {
        final temporary = ownedTemporary;
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      });
      await clean(() async {
        final endpoint = ownedEndpoint;
        if (endpoint != null && await endpoint.exists()) {
          final current = await boundedEndpointRecord(endpoint);
          if (current?['generation'] == ownedGeneration &&
              current?['owner'] == 'dana-manager-research' &&
              current?['protocol'] == 1) {
            await endpoint.delete();
          }
        }
      });
    } finally {
      try {
        await lock.unlock();
      } finally {
        await lock.close();
      }
    }
    if (cleanupErrors.isNotEmpty) {
      throw StateError('Research cleanup failed: $cleanupErrors');
    }
  }
  if (lifecycleInjections) {
    stdout.writeln(jsonEncode({'event': 'research-cleaned', 'pid': pid}));
  }
  // Windows stdin cancellation can leave the runtime alive after all owned
  // resources are closed. This is a standalone endpoint, not a library entry.
  // Reach here only after requests finish, Job zero and successful finally.
  await stdout.flush().timeout(const Duration(seconds: 2));
  exit(0);
}
