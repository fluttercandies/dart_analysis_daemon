import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/analyzer_pool.dart';
import 'package:dart_analysis_daemon/src/runtime.dart';
import 'package:dart_analysis_daemon/src/session_idle_policy.dart';
import 'global_budget_service.dart';
import 'global_budget_policy.dart';
import 'cancellation_signal.dart';
import 'system_memory.dart';

File endpointFile(String root) => File(
  '${Directory(root).path}${Platform.pathSeparator}.dart_tool'
  '${Platform.pathSeparator}ai-analyzer-session.json',
);

/// Maximum time allowed for the first analyzer/plugin initialization.
/// Large projects can spend several minutes compiling and resolving plugins.
/// The value is shared with analysis waits and can be disabled with
/// `DANA_ANALYSIS_TIMEOUT_SECONDS=0`.

Future<void> serveSession(
  String root, {
  String? startupToken,
  Duration? idleTimeout,
  AnalyzerDaemon? analyzer,
}) async {
  final effectiveIdleTimeout =
      idleTimeout ??
      parseSessionIdleTimeout(
        Platform.environment['DANA_SESSION_IDLE_TIMEOUT_SECONDS'],
      );
  if (effectiveIdleTimeout.isNegative) {
    throw ArgumentError.value(effectiveIdleTimeout, 'idleTimeout');
  }
  final endpoint = endpointFile(root);
  await endpoint.parent.create(recursive: true);
  final startupLock = await _acquireStartupLock(root);
  var startupLockReleased = false;
  Future<void> releaseStartupLock() async {
    if (startupLockReleased) return;
    startupLockReleased = true;
    await startupLock.unlock();
    await startupLock.close();
  }

  final startupMarker = _startupMarkerFile(root);
  if (startupToken != null) {
    if (await startupMarker.exists() &&
        (await startupMarker.readAsString()).trim() == startupToken) {
      await startupMarker.delete();
    }
  } else if (await startupMarker.exists()) {
    final age = DateTime.now().difference(await startupMarker.lastModified());
    if (age < _startupMarkerGrace) {
      await releaseStartupLock();
      for (var attempt = 0; attempt < 40; attempt++) {
        if (await endpoint.exists()) return;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      stderr.writeln('Another analyzer session is still starting for $root.');
      return;
    }
    await startupMarker.delete();
  }
  if (await _existingSessionIsReachable(root, endpoint)) {
    await releaseStartupLock();
    stderr.writeln('[dana] session already running: ${endpoint.path}');
    return;
  }
  final token = _randomToken();
  final daemon =
      analyzer ??
      (globalBudgetEnabled
          ? BudgetedAnalyzerDaemon(root)
          : multiRootEnabled
          // A shared pool admits other roots; give it the memory sampler and
          // admission policy so it can evict idle roots under pressure.
          ? AnalyzerDaemon(
            root,
            maxRoots: poolMaxRoots,
            memorySampler: platformMemorySampler(),
            budgetPolicy: GlobalBudgetPolicy.fromEnvironment(
              Platform.environment,
              ignoreWarnPressure: true,
            ),
          )
          : AnalyzerDaemon(root));
  late final ServerSocket server;
  ServerSocket? boundServer;
  var shuttingDown = false;
  // True only for the session that published the shared pool registry. Such a
  // session must keep the registry's root set in sync as peers join/leave via
  // addRoot/removeRoot, so a third project discovers the real root set.
  var registeredAsPool = false;
  Map<String, Object?>? poolIdentitySnapshot;
  final signalSubscriptions = <StreamSubscription<void>>[];

  try {
    try {
      await daemon.start();
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      boundServer = server;
    } catch (_) {
      await daemon.close();
      rethrow;
    }
    final endpointData = jsonEncode({
      'protocol': 1,
      'root': root,
      'address': InternetAddress.loopbackIPv4.address,
      'port': server.port,
      'token': token,
      'pid': pid,
      'owner': 'dart_analysis_daemon',
      'idleTimeoutSeconds': effectiveIdleTimeout.inSeconds,
      'identity': await sessionIdentity(root),
    });
    final temporaryEndpoint = File('${endpoint.path}.$pid.tmp');
    await temporaryEndpoint.writeAsString(endpointData);
    await temporaryEndpoint.rename(endpoint.path);
    // When auto-join is enabled, also advertise this session as the shared
    // pool so a later `dana check` for another project can discover and join
    // it instead of starting its own analyzer. Only register when no live pool
    // exists yet; otherwise this session simply joins the existing one later.
    if (multiRootEnabled && await discoverPool() == null) {
      final identity = await poolIdentity();
      poolIdentitySnapshot = identity;
      await writePoolRegistry(
        PoolRegistration(
          address: InternetAddress.loopbackIPv4.address,
          port: server.port,
          token: token,
          pid: pid,
          roots: daemon.activeRoots,
          identity: identity,
        ),
      );
      registeredAsPool = true;
    }
    await releaseStartupLock();
  } catch (_) {
    // Publishing can fail after the analyzer and socket have started (for
    // example, a read-only endpoint directory). Do not leave a hidden session.
    try {
      await boundServer?.close();
      if (boundServer != null) await daemon.close();
    } finally {
      await releaseStartupLock();
    }
    rethrow;
  }

  stderr.writeln('[dana] session ready: ${endpoint.path}');
  final clients = <Socket>{};
  Future<void> requestQueue = Future<void>.value();
  late final SessionIdlePolicy idlePolicy;
  final closeCompleted = Completer<void>();
  Object? closeFailure;
  StackTrace? closeStack;
  Completer<void>? shutdownResponseSent;
  Timer? memoryMonitor;
  var memoryMonitorQueued = false;

  Future<void> refreshPoolRegistry() async {
    final identitySnapshot = poolIdentitySnapshot;
    if (!registeredAsPool || identitySnapshot == null) return;
    try {
      await writePoolRegistry(
        PoolRegistration(
          address: InternetAddress.loopbackIPv4.address,
          port: server.port,
          token: token,
          pid: pid,
          roots: daemon.activeRoots,
          identity: identitySnapshot,
        ),
      );
    } catch (error) {
      stderr.writeln('[dana] pool registry refresh failed: $error');
    }
  }

  void queueMemoryMonitor() {
    if (memoryMonitorQueued || shuttingDown) return;
    memoryMonitorQueued = true;
    requestQueue = requestQueue
        .then((_) async {
          try {
            if (shuttingDown) return;
            final evicted = await daemon.monitorMemoryPressureOnce();
            if (evicted.isNotEmpty) {
              stderr.writeln(
                '[dana] reclaimed idle pool roots under memory pressure: '
                '${evicted.join(', ')}',
              );
              await refreshPoolRegistry();
            }
          } catch (error) {
            stderr.writeln('[dana] pool memory monitor failed: $error');
          } finally {
            memoryMonitorQueued = false;
          }
        })
        .catchError((Object error) {
          memoryMonitorQueued = false;
          stderr.writeln('[dana] pool memory monitor queue failed: $error');
        });
  }

  void rethrowCloseFailure() {
    if (closeFailure != null) {
      Error.throwWithStackTrace(closeFailure!, closeStack!);
    }
  }

  Future<void> closeSession({Socket? responseSocket}) async {
    if (shuttingDown) {
      await closeCompleted.future;
      rethrowCloseFailure();
      return;
    }
    shuttingDown = true;
    memoryMonitor?.cancel();
    memoryMonitor = null;
    idlePolicy.close();
    try {
      await server.close();
      for (final client in clients.toList()) {
        // Do not await Socket.close here: a peer can keep the half-closed
        // connection alive while the session is trying to shut down.
        if (!identical(client, responseSocket)) client.destroy();
      }
      await daemon.close();
    } catch (error, stack) {
      closeFailure = error;
      closeStack = stack;
    } finally {
      try {
        if (await endpoint.exists()) await endpoint.delete();
        if (multiRootEnabled) await deletePoolRegistryIfOwned();
        for (final subscription in signalSubscriptions) {
          await subscription.cancel();
        }
      } catch (error, stack) {
        closeFailure ??= error;
        closeStack ??= stack;
      } finally {
        closeCompleted.complete();
      }
    }
    rethrowCloseFailure();
  }

  idlePolicy = SessionIdlePolicy(
    timeout: effectiveIdleTimeout,
    onIdle: () {
      stderr.writeln('[dana] reclaiming idle session: $root');
      unawaited(
        closeSession().catchError((Object error) {
          stderr.writeln('[dana] idle session cleanup failed: $error');
        }),
      );
    },
  );

  if (registeredAsPool) {
    memoryMonitor = Timer.periodic(const Duration(seconds: 2), (_) {
      queueMemoryMonitor();
    });
  }

  server.listen((socket) {
    if (shuttingDown) {
      socket.destroy();
      return;
    }
    clients.add(socket);
    idlePolicy.clientConnected();
    final disconnected = CancellationSignal();
    void releaseClient() {
      disconnected.cancel();
      if (clients.remove(socket)) idlePolicy.clientDisconnected();
      socket.destroy();
    }

    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim().isEmpty) return;
            idlePolicy.requestQueued();
            requestQueue = requestQueue
                .then((_) async {
                  try {
                    Map<String, Object?> response;
                    try {
                      final input = jsonDecode(line);
                      if (input is! Map || input['token'] != token) {
                        response = {
                          'ok': false,
                          'error': 'Invalid session token',
                        };
                      } else {
                        final command = Map<String, Object?>.from(input)
                          ..remove('token');
                        if (command['op'] == 'shutdown') {
                          shutdownResponseSent ??= Completer<void>();
                          await closeSession(responseSocket: socket);
                          response = {'ok': true, 'shutdownComplete': true};
                        } else {
                          response =
                              daemon is BudgetedAnalyzerDaemon
                                  ? await daemon.handleCancellable(
                                    command,
                                    disconnected,
                                  )
                                  : await daemon.handle(command);
                          if (command['op'] == 'status') {
                            response = {
                              ...response,
                              'idleTimeoutSeconds':
                                  effectiveIdleTimeout.inSeconds,
                            };
                          }
                          // A pool-owning session republishes its registry when
                          // a peer joins or leaves, so the advertised root set
                          // matches the analyzer's actual roots.
                          if (poolRootsChanged(command, response)) {
                            // The analyzer already applied the root change;
                            // a registry write failure must not fail the check.
                            await refreshPoolRegistry();
                          }
                        }
                      }
                    } catch (error, stackTrace) {
                      response = {
                        'ok': false,
                        'error': '$error',
                        'stack': '$stackTrace',
                      };
                    }
                    socket.writeln(jsonEncode(response));
                    await socket.flush();
                  } finally {
                    idlePolicy.requestFinished();
                    if (shutdownResponseSent != null &&
                        !shutdownResponseSent!.isCompleted) {
                      shutdownResponseSent!.complete();
                      unawaited(
                        _shutdownAndExit(() => closeSession(), endpoint),
                      );
                    }
                  }
                })
                .catchError((Object error) {
                  // A disconnected caller must not poison subsequent exchanges.
                  releaseClient();
                  stderr.writeln('[dana] session exchange failed: $error');
                });
          },
          onDone: () {
            releaseClient();
          },
          onError: (_) {
            releaseClient();
          },
        );
  });

  signalSubscriptions.add(
    ProcessSignal.sigint.watch().listen((_) {
      unawaited(
        closeSession().catchError((Object error) {
          stderr.writeln('[dana] session cleanup failed: $error');
        }),
      );
    }),
  );
  if (!Platform.isWindows) {
    signalSubscriptions.add(
      ProcessSignal.sigterm.watch().listen((_) {
        unawaited(
          closeSession().catchError((Object error) {
            stderr.writeln('[dana] session cleanup failed: $error');
          }),
        );
      }),
    );
  }
  while (!shuttingDown) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  await closeCompleted.future;
  await shutdownResponseSent?.future;
  rethrowCloseFailure();
}

Future<void> _shutdownAndExit(
  Future<void> Function() closeSession,
  File endpoint,
) async {
  await Future<void>.delayed(const Duration(milliseconds: 100));
  var shutdownExitCode = 0;
  try {
    await closeSession().timeout(const Duration(seconds: 10));
  } catch (error) {
    shutdownExitCode = 1;
    stderr.writeln('[dana] shutdown did not complete: $error');
  } finally {
    exitCode = shutdownExitCode;
    exit(shutdownExitCode);
  }
}

Future<bool> _existingSessionIsReachable(String root, File endpoint) async {
  if (!await endpoint.exists()) return false;
  try {
    final metadata = jsonDecode(await endpoint.readAsString()) as Map;
    final identity = metadata['identity'];
    if (identity is! Map ||
        !_sameIdentity(identity, await sessionIdentity(root))) {
      await _shutdownStaleSession(metadata);
      if (await endpoint.exists()) await endpoint.delete();
      return false;
    }
    final socket = await Socket.connect(
      metadata['address'] as String,
      metadata['port'] as int,
      timeout: const Duration(milliseconds: 500),
    );
    await socket.close();
    return true;
  } catch (_) {
    if (await endpoint.exists()) await endpoint.delete();
    return false;
  }
}

Future<(Socket, String)?> connectOrStartSession(
  String root,
  File endpoint, {
  required bool autoStart,
  bool requireIdentity = true,
}) async {
  var starterStarted = false;
  final deadline = DateTime.now().add(
    autoStart ? (analysisTimeout ?? const Duration(days: 3650)) : Duration.zero,
  );
  do {
    // A crashed detached starter can leave this marker behind. It must not
    // turn an ordinary `dana check` into a wait for the full analysis timeout.
    if (autoStart && await _discardExpiredStartupMarker(root)) {
      // The one starter attempt was blocked by an orphan marker. Permit a
      // replacement process now that the marker has been removed.
      starterStarted = false;
    }
    try {
      if (await endpoint.exists()) {
        final metadata = jsonDecode(await endpoint.readAsString()) as Map;
        final actualIdentity = metadata['identity'];
        // A session started under another SDK or configuration must not
        // serve analysis, but it can still be stopped: shutdown is
        // authenticated by the endpoint token, not by the identity.
        if (requireIdentity &&
            (actualIdentity is! Map ||
                !_sameIdentity(actualIdentity, await sessionIdentity(root)))) {
          if (!autoStart) {
            stderr.writeln(
              'Analyzer session identity does not match the current SDK or project configuration.',
            );
            return null;
          }
          await _shutdownStaleSession(metadata);
          if (await endpoint.exists()) await endpoint.delete();
          continue;
        }
        final Socket socket;
        try {
          socket = await Socket.connect(
            metadata['address'] as String,
            metadata['port'] as int,
            timeout: const Duration(milliseconds: 500),
          );
        } on SocketException catch (error) {
          // Nothing listens on the endpoint's port: its session is gone (for
          // example killed with SIGKILL). The starter refuses to launch while
          // an endpoint exists, so a stale one must be removed here or every
          // check waits out the whole analysis timeout.
          // A session that is still closing also refuses connections but
          // keeps its endpoint until teardown ends; only a dead owner counts.
          if (_isStaleConnectionFailure(error) &&
              _processIsGone(metadata['pid'])) {
            await _deleteEndpointIfUnchanged(endpoint, metadata);
          }
          rethrow;
        }
        return (socket, metadata['token'] as String);
      }
    } catch (_) {
      // The endpoint can be stale while a previous session is exiting.
    }
    if (!autoStart) break;
    if (!starterStarted) {
      starterStarted = await _startSessionProcess(root, endpoint);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  } while (DateTime.now().isBefore(deadline));
  stderr.writeln('No analyzer session for $root.');
  return null;
}

/// Whether no process with [pid] exists. Conservative: false on a
/// non-integer pid or when the probe itself fails.
bool _processIsGone(Object? pid) {
  if (pid is! int || pid <= 0) return false;
  if (Platform.isWindows) return _windowsProcessIsGone(pid);
  try {
    // `kill -0` checks existence without signalling; it exits non-zero with
    // "No such process" only when the pid is free.
    final result = Process.runSync('/bin/kill', ['-0', '$pid']);
    return result.exitCode != 0 &&
        '${result.stderr}'.toLowerCase().contains('no such process');
  } on Object {
    return false;
  }
}

typedef _OpenProcessC = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);
typedef _ExitCodeC = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _ExitCodeDart = int Function(int, Pointer<Uint32>);
typedef _HandleC = Int32 Function(IntPtr);
typedef _HandleDart = int Function(int);
typedef _LastErrorC = Uint32 Function();
typedef _LastErrorDart = int Function();

/// Windows: the pid is gone when OpenProcess reports an invalid parameter
/// (no such process) or the process has an exit code other than
/// STILL_ACTIVE. Access-denied and any other failure count as alive.
bool _windowsProcessIsGone(int pid) {
  const processQueryLimitedInformation = 0x1000;
  const errorInvalidParameter = 87;
  const stillActive = 259;
  try {
    final kernel = DynamicLibrary.open('kernel32.dll');
    final openProcess = kernel.lookupFunction<_OpenProcessC, _OpenProcessDart>(
      'OpenProcess',
    );
    final getExitCode = kernel.lookupFunction<_ExitCodeC, _ExitCodeDart>(
      'GetExitCodeProcess',
    );
    final closeHandle = kernel.lookupFunction<_HandleC, _HandleDart>(
      'CloseHandle',
    );
    final getLastError = kernel.lookupFunction<_LastErrorC, _LastErrorDart>(
      'GetLastError',
    );
    final localAlloc = kernel.lookupFunction<
      Pointer<Uint32> Function(Uint32, IntPtr),
      Pointer<Uint32> Function(int, int)
    >('LocalAlloc');
    final localFree = kernel.lookupFunction<
      IntPtr Function(Pointer<Uint32>),
      int Function(Pointer<Uint32>)
    >('LocalFree');
    final handle = openProcess(processQueryLimitedInformation, 0, pid);
    if (handle == 0) return getLastError() == errorInvalidParameter;
    final code = localAlloc(0x40 /* LPTR */, sizeOf<Uint32>());
    try {
      if (code == nullptr) return false;
      if (getExitCode(handle, code) == 0) return false;
      return code.value != stillActive;
    } finally {
      if (code != nullptr) localFree(code);
      closeHandle(handle);
    }
  } on Object {
    return false;
  }
}

bool _isStaleConnectionFailure(SocketException error) {
  final code = error.osError?.errorCode;
  // ECONNREFUSED: 61 on macOS, 111 on Linux, 10061 (WSAECONNREFUSED) on
  // Windows may report Win32 ERROR_CONNECTION_REFUSED (1225) instead of the
  // Winsock code, or WSAETIMEDOUT (10060) at our short connection deadline.
  // These only permit deletion after the owner is independently proven gone.
  return code == 61 ||
      code == 111 ||
      code == 10061 ||
      (Platform.isWindows && (code == 1225 || code == 10060));
}

/// Deletes [endpoint] only if it still holds [metadata], so a session that
/// published a fresh endpoint in the meantime is left alone.
Future<void> _deleteEndpointIfUnchanged(File endpoint, Map metadata) async {
  try {
    final current = jsonDecode(await endpoint.readAsString());
    if (current is Map &&
        current['pid'] == metadata['pid'] &&
        current['port'] == metadata['port'] &&
        current['token'] == metadata['token']) {
      await endpoint.delete();
    }
  } on Object {
    // Already gone or unreadable; the next attempt re-reads it.
  }
}

Future<RandomAccessFile> _acquireStartupLock(String root) async {
  final lockFile = File(
    '${Directory(root).path}${Platform.pathSeparator}.dart_tool'
    '${Platform.pathSeparator}ai-analyzer-session.lock',
  );
  await lockFile.parent.create(recursive: true);
  Object? lastError;
  final deadline = DateTime.now().add(_startupWaitLimit);
  while (DateTime.now().isBefore(deadline)) {
    final handle = await lockFile.open(mode: FileMode.write);
    try {
      await handle.lock(FileLock.exclusive);
      return handle;
    } catch (error) {
      lastError = error;
      await handle.close();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
  throw StateError(
    'Could not acquire analyzer session startup lock: $lastError',
  );
}

Duration get _startupWaitLimit => analysisTimeout ?? const Duration(days: 3650);

/// A real detached starter removes its marker as soon as its Dart process has
/// entered [serveSession]. Anything older than this is an orphan, not a long
/// analyzer initialization (which happens after marker removal).
const _startupMarkerGrace = Duration(seconds: 10);

File _startupMarkerFile(String root) => File(
  '${Directory(root).path}${Platform.pathSeparator}.dart_tool'
  '${Platform.pathSeparator}ai-analyzer-session.starting',
);

Future<bool> _discardExpiredStartupMarker(String root) async {
  final marker = _startupMarkerFile(root);
  final stat = await marker.stat();
  if (stat.type == FileSystemEntityType.notFound) return false;
  final age = DateTime.now().difference(stat.modified);
  if (age >= _startupMarkerGrace && await marker.exists()) {
    try {
      await marker.delete();
    } on PathNotFoundException {
      // The detached starter removes its marker when it enters serveSession.
      return false;
    }
    return true;
  }
  return false;
}

Future<bool> _startSessionProcess(String root, File endpoint) async {
  if (globalBudgetEnabled) {
    GlobalBudgetPolicy.fromEnvironment(Platform.environment);
  }
  // Fail in the caller before detaching, rather than leaving it waiting for
  // an endpoint that a misconfigured child can never publish.
  parseSessionIdleTimeout(
    Platform.environment['DANA_SESSION_IDLE_TIMEOUT_SECONDS'],
  );
  final lock = await _acquireStartupLock(root);
  try {
    // The old session may still be draining its close operation. No starter
    // was launched: retry after its endpoint disappears.
    if (await endpoint.exists()) return false;
    final marker = _startupMarkerFile(root);
    final stat = await marker.stat();
    if (stat.type != FileSystemEntityType.notFound) {
      final age = DateTime.now().difference(stat.modified);
      if (age < _startupMarkerGrace) return true;
      try {
        await marker.delete();
      } on PathNotFoundException {
        // A starter can enter serveSession while this lock is held.
      }
    }
    final startupToken = _randomToken();
    await marker.writeAsString(startupToken);
    try {
      await Process.start(
        Platform.resolvedExecutable,
        selfProcessArguments([
          'serve',
          '--root',
          root,
          '--startup-token',
          startupToken,
        ]),
        workingDirectory: root,
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      if (await marker.exists() &&
          (await marker.readAsString()).trim() == startupToken) {
        await marker.delete();
      }
      rethrow;
    }
    return true;
  } finally {
    await lock.unlock();
    await lock.close();
  }
}

Future<void> _shutdownStaleSession(Map metadata) async {
  try {
    final socket = await Socket.connect(
      metadata['address'] as String,
      metadata['port'] as int,
      timeout: const Duration(milliseconds: 500),
    );
    socket.writeln(jsonEncode({'op': 'shutdown', 'token': metadata['token']}));
    await socket.flush();
    await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 2));
    await socket.close();
  } catch (_) {
    // A dead process is safe to replace; a live process will remove its own
    // endpoint after receiving shutdown.
  }
}

Future<Map<String, Object?>> sessionIdentity(String root) async {
  const configNames = [
    'analysis_options.yaml',
    'pubspec.yaml',
    'pubspec.lock',
    '.dart_tool/package_config.json',
    '.dart_tool/extension_discovery/vs_code.json',
  ];
  return {
    'dartExecutable': await identityDartExecutable(),
    'dartVersion': Platform.version,
    'globalBudget': globalBudgetEnabled,
    'config': {
      for (final name in configNames)
        name: await _configFingerprint(
          File('${Directory(root).path}${Platform.pathSeparator}$name'),
        ),
    },
  };
}

Future<String> _configFingerprint(File file) async {
  if (!await file.exists()) return 'missing';
  final bytes = await file.readAsBytes();
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return '${bytes.length}:$hash';
}

String _randomToken() {
  final random = Random.secure();
  return List<String>.generate(
    32,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
}

bool _sameIdentity(Map actual, Map<String, Object?> expected) =>
    jsonEncode(actual) == jsonEncode(expected);
