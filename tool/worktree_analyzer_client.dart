// Research protocol client. Caller must own the entire process tree (native Job).
// Root configuration readiness is distinct from diagnostic completion.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

// Notifications carry no document revision. This cache only tracks stream order
// and flush invalidation; it must not be interpreted as a version barrier.
class ProbeDiagnosticCache {
  final errors = <String, List>{};
  final errorSequence = <String, int>{};
  void receive(Map event, int sequence) {
    if (event['event'] == 'analysis.errors') {
      final file = event['params']['file'] as String;
      errors[file] = event['params']['errors'] as List;
      errorSequence[file] = sequence;
    } else if (event['event'] == 'analysis.flushResults') {
      for (final path in event['params']['files'] as List) {
        errors.remove(path);
        errorSequence.remove(path);
      }
    }
  }

  bool matches(String file, int since, bool Function(List) predicate) {
    final current = errors[file];
    return current != null &&
        (errorSequence[file] ?? 0) > since &&
        predicate(current);
  }
}

class ResearchAnalyzerClient {
  ResearchAnalyzerClient(
    this.root,
    this.log, {
    this.dartExecutable,
    this.launch,
    this.rootTimeout = const Duration(seconds: 150),
    this.maxLogBytes,
    this.maxRequestTimings,
    this.afterBuiltinWrite,
  });
  final String root;
  final File log;
  final String? dartExecutable;
  // Test seam for protocol faults; default launches the official analyzer.
  final Future<Process> Function()? launch;
  final Duration rootTimeout;
  final int? maxLogBytes;
  final int? maxRequestTimings;
  // Explicit research fault seam: pause response consumption after sending a
  // real getErrors request. Normal workers leave this null.
  final Future<void> Function(String id)? afterBuiltinWrite;
  StreamSubscription<String>? _output;
  int _logBytes = 0;
  bool rootConfigured = false;
  bool _started = false;
  bool _closing = false;
  Object? failure;
  Future<void>? _closeFuture;
  final failures = StreamController<Object>.broadcast();
  void _fail(Object error) {
    if (failure != null) return;
    failure = error;
    rootConfigured = false;
    diagnostics.errors.clear();
    diagnostics.errorSequence.clear();
    for (final done in pending.values.toList()) {
      if (!done.isCompleted) done.completeError(error);
    }
    pending.clear();
    if (!failures.isClosed) failures.add(error);
  }

  Process? process;
  final pending = <String, Completer<Map>>{};
  final diagnostics = ProbeDiagnosticCache();
  Map<String, List> get errors => diagnostics.errors;
  Map<String, int> get errorSequence => diagnostics.errorSequence;
  final problems = <Map>[];
  int sequence = 0;
  int eventSequence = 0;
  bool busy = true;
  bool exited = false;
  final clock = Stopwatch()..start();
  final requestTimings = <Map<String, Object?>>[];
  void record(Map event) {
    final line = '${jsonEncode({'ms': clock.elapsedMilliseconds, ...event})}\n';
    _logBytes += utf8.encode(line).length;
    if (maxLogBytes != null && _logBytes > maxLogBytes!) {
      throw StateError('Analyzer research log budget exceeded');
    }
    log.writeAsStringSync(line, mode: FileMode.append);
  }

  Future<Map> request(
    String method,
    Map params, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (failure != null ||
        process == null ||
        exited ||
        (_closing && method != 'server.shutdown')) {
      throw StateError('Analyzer unavailable: $failure');
    }
    if (pending.length >= 64) throw StateError('Analyzer request limit');
    final id = '${++sequence}';
    final done = pending[id] = Completer<Map>();
    final watch = Stopwatch()..start();
    var success = false;
    // Install the error listener before a write can fail and poison all pending.
    final responseFuture = done.future.timeout(timeout);
    final holdResponse =
        method == 'analysis.getErrors' && afterBuiltinWrite != null;
    var outputPaused = false;
    try {
      if (holdResponse) {
        _output!.pause();
        outputPaused = true;
      }
      record({
        'send': method,
        'id': id,
        'eventSequence': eventSequence,
        'timeoutMs': timeout.inMilliseconds,
      });
      process!.stdin.writeln(
        jsonEncode({'id': id, 'method': method, 'params': params}),
      );
      if (holdResponse) {
        await process!.stdin.flush();
        try {
          await afterBuiltinWrite!(id).timeout(const Duration(seconds: 8));
        } finally {
          _output!.resume();
          outputPaused = false;
        }
      }
      final response = await responseFuture;
      if (response['error'] != null) throw StateError('$method: $response');
      success = true;
      return response;
    } catch (error) {
      // A timed-out update may still be applied. Never reuse uncertain state.
      _fail(error);
      // Observe this request too if a synchronous write failed before awaiting.
      unawaited(responseFuture.then<void>((_) {}, onError: (Object _) {}));
      rethrow;
    } finally {
      if (outputPaused) _output!.resume();
      pending.remove(id);
      requestTimings.add({
        'method': method,
        'id': id,
        'elapsedMs': watch.elapsedMilliseconds,
        'timeoutMs': timeout.inMilliseconds,
        'success': success,
      });
      if (maxRequestTimings != null &&
          requestTimings.length > maxRequestTimings!) {
        requestTimings.removeAt(0);
      }
    }
  }

  Future<void> start() async {
    if (_started) throw StateError('Analyzer client cannot restart');
    _started = true;
    final dart = File(
      dartExecutable ??
          '${File(Platform.resolvedExecutable).parent.path}/dart.exe',
    );
    process =
        await (launch?.call() ??
            Process.start(dart.path, [
              'language-server',
              '--protocol=analyzer',
              '--client-id=overlay-research',
            ], workingDirectory: root));
    process!.stderr.transform(utf8.decoder).listen((text) {
      try {
        record({'stderr': text});
      } catch (error) {
        _fail(error);
      }
    }, onError: (Object error) => _fail(error));
    _output = process!.stdout
        .transform(const _AnalyzerLines())
        .listen(
          (line) {
            if (failure != null) return;
            try {
              final event = jsonDecode(line) as Map;
              eventSequence++;
              record({'sequence': eventSequence, 'receive': event});
              if (event['id'] != null) {
                pending.remove('${event['id']}')?.complete(event);
              }
              if (event['event'] == 'server.status') {
                busy = event['params']['analysis']?['isAnalyzing'] ?? busy;
              }
              diagnostics.receive(event, eventSequence);
              if (event['event'] == 'server.error' ||
                  event['event'] == 'server.pluginError' ||
                  event['event'] == 'plugin.error') {
                problems.add(event);
                _fail(StateError('Analyzer protocol failure: $event'));
              }
            } catch (error) {
              _fail(error);
            }
          },
          onError: (Object error) => _fail(error),
          onDone: () {
            if (!_closing) _fail(StateError('Analyzer stdout closed'));
          },
        );
    unawaited(
      process!.exitCode.then((code) {
        exited = true;
        if (!_closing || code != 0 || pending.isNotEmpty) {
          _fail(StateError('Analyzer exited: $code'));
        }
      }),
    );
    await request('server.getVersion', {});
    await request('server.setSubscriptions', {
      'subscriptions': ['STATUS'],
    });
    await request('analysis.setAnalysisRoots', {
      'included': [root],
      'excluded': [],
    }, timeout: rootTimeout);
    if (failure != null) throw StateError('Analyzer startup failed: $failure');
    rootConfigured = true;
  }

  Future<void> close() => _closeFuture ??= _close();
  Future<void> _close() async {
    _closing = true;
    rootConfigured = false;
    try {
      if (process == null || exited) return;
      if (failure != null) {
        throw StateError('Failed client requires owner Job cleanup: $failure');
      }
      await request(
        'server.shutdown',
        {},
        timeout: const Duration(seconds: 10),
      );
      await process!.exitCode.timeout(const Duration(seconds: 10));
    } finally {
      await failures.close();
    }
  }
}

// Bound a line before UTF-8/JSON decoding; an unterminated stream is bounded too.
class _AnalyzerLines extends StreamTransformerBase<List<int>, String> {
  const _AnalyzerLines();
  @override
  Stream<String> bind(Stream<List<int>> stream) async* {
    final bytes = <int>[];
    await for (final chunk in stream) {
      for (final byte in chunk) {
        if (byte == 10) {
          yield utf8.decode(bytes);
          bytes.clear();
        } else {
          if (bytes.length >= 4 * 1024 * 1024) {
            throw StateError('Analyzer frame limit');
          }
          bytes.add(byte);
        }
      }
    }
    if (bytes.isNotEmpty) throw StateError('Incomplete analyzer frame');
  }
}
