import 'dart:async';
import 'dart:collection';

import 'analyzer_daemon.dart';
import 'global_budget_policy.dart';
import 'system_memory.dart';

/// One owned root at a time, across all clients of a global broker.
/// The caller supplies canonical roots and a configuration identity.
class GlobalAnalyzerPool {
  GlobalAnalyzerPool({
    required this.policy,
    required this.sampleMemory,
    required this.createWorker,
    this.validateIdentity,
    this.prepareWorker,
    this.invalidateWorkerCache,
    this.workerStarted,
    this.validateExecution,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc()) {
    _monitor = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _monitorResources(),
    );
  }

  final GlobalBudgetPolicy policy;
  final SystemMemorySnapshot? Function() sampleMemory;
  final AnalyzerDaemon Function(String root) createWorker;
  final Future<bool> Function(String root, String identity)? validateIdentity;
  final Future<void> Function(String root, String identity)? prepareWorker;
  final Future<void> Function(String root, String identity)?
  invalidateWorkerCache;
  final Future<void> Function(String root, String identity)? workerStarted;
  final Future<void> Function(String root, String identity)? validateExecution;
  final DateTime Function() _now;
  final _queue = ListQueue<_BudgetRequest>();
  final _closed = Completer<void>();
  AnalyzerDaemon? _worker;
  _BudgetRequest? _active;
  String? _root;
  String? _identity;
  String? _degraded;
  String? _waitingReason;
  SystemMemorySnapshot? _sample;
  DateTime? _lastUsed;
  DateTime? _lastClosed;
  bool _recovering = false;
  bool _stopping = false;
  int _generation = 0;
  int _starts = 0;
  int _reclaims = 0;
  Future<void>? _draining;
  Timer? _idleTimer;
  Future<void>? _closing;
  late final Timer _monitor;
  Map<String, Object?>? _workerResources;

  void _monitorResources() {
    if (_stopping) return;
    try {
      _sample = sampleMemory();
    } catch (_) {
      _sample = null;
    }
    try {
      _workerResources = _worker?.sampleOwnedResources();
    } catch (_) {
      _workerResources = null;
    }
    if (_worker == null || _draining != null || _degraded != null) return;
    if (policy.waitingReason(
          _sample,
          starting: false,
          recovering: false,
          now: _now(),
        ) !=
        null) {
      _recovering = true;
      _idleTimer?.cancel();
      _draining = _reclaim()
          .catchError((Object error) {
            _degraded = '$error';
          })
          .whenComplete(() {
            _draining = null;
            if (_queue.isNotEmpty && !_stopping) _kick();
          });
    }
  }

  Map<String, Object?> get status => {
    'protocol': 1,
    'maxWorkers': 1,
    'root': _root,
    'generation': _generation,
    'workerCount': _worker == null ? 0 : 1,
    'activeRequests': _active == null ? 0 : 1,
    'queuedRequests': _queue.where((r) => !r.result.isCompleted).length,
    'waitingReason': _waitingReason,
    'degraded': _degraded,
    'starts': _starts,
    'reclaims': _reclaims,
    'lastUsed': _lastUsed?.toIso8601String(),
    'memory': _sample?.toJson(),
    'workerResources': _workerResources,
    'policy': policy.toJson(_sample),
  };

  Future<Map<String, Object?>> submit(
    String root,
    String identity,
    Map<String, Object?> command, {
    Future<void>? cancelled,
    Future<void> Function()? validateRequest,
  }) {
    if (_stopping) return Future.error(StateError('Global budget is stopping'));
    if (_degraded != null) return Future.error(StateError(_degraded!));
    // First managed slice is explicitly disk-only. Persistent overlays cannot
    // silently disappear when another worktree evicts this worker.
    if (!['check', 'fullCheck'].contains(command['op']) ||
        (command['files'] is List &&
            (command['files'] as List).any((f) => f is! String))) {
      return Future.error(
        UnsupportedError(
          'Global budget currently supports disk checks only; overlays are not accepted',
        ),
      );
    }
    if (_queue.length >= 128) {
      return Future.error(StateError('Global budget queue is full'));
    }
    final request = _BudgetRequest(root, identity, command)
      ..validateRequest = validateRequest;
    request.timer = Timer(
      policy.queueTimeout,
      () => _cancel(request, 'Global budget admission timed out'),
    );
    cancelled?.then(
      (_) => _cancel(request, 'Global budget request disconnected'),
      onError:
          (Object error, StackTrace stack) =>
              _cancel(request, 'Global budget request cancelled'),
    );
    _queue.add(request);
    _idleTimer?.cancel();
    _kick();
    return request.result.future;
  }

  void _cancel(_BudgetRequest request, String reason) {
    if (request.result.isCompleted) return;
    request.timer?.cancel();
    request.result.completeError(StateError(reason));
    if (!request.cancelled.isCompleted) request.cancelled.complete();
    _queue.remove(request);
  }

  Future<void> releaseRoot(String root) async {
    if (_stopping) return;
    if (_root != root && _active?.root != root) return;
    final request = _BudgetRequest(root, '', {'op': 'releaseRoot'});
    request.timer = Timer(
      policy.queueTimeout,
      () => _cancel(request, 'Root release timed out'),
    );
    _queue.add(request);
    _idleTimer?.cancel();
    _kick();
    await request.result.future;
  }

  void _kick() {
    if (_draining != null) return;
    _draining = _drain().whenComplete(() {
      _draining = null;
      if (_queue.isNotEmpty && !_stopping && _degraded == null) {
        _kick();
      } else if (_worker != null &&
          !_stopping &&
          policy.idleTimeout > Duration.zero) {
        _idleTimer = Timer(policy.idleTimeout, () {
          // Reclamation joins the same serial owner as startup and requests.
          _draining = _reclaim()
              .catchError((Object error) {
                _degraded = '$error';
              })
              .whenComplete(() {
                _draining = null;
                if (_queue.isNotEmpty && !_stopping) _kick();
              });
        });
      }
    });
    _draining!.ignore();
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty && !_stopping && _degraded == null) {
      final request = _queue.removeFirst();
      if (request.result.isCompleted) continue;
      _active = request;
      Future<void>? startup;
      try {
        if (request.command['op'] == 'releaseRoot') {
          if (_root == request.root) await _reclaim();
          request.result.complete({'ok': true});
          continue;
        }
        if (_root != request.root || _identity != request.identity) {
          await _reclaim();
        }
        while (!request.result.isCompleted && !_stopping) {
          _sample = sampleMemory();
          _waitingReason = policy.waitingReason(
            _sample,
            starting: _worker == null,
            recovering: _recovering,
            now: _now(),
          );
          final cooling =
              _lastClosed != null &&
              _now().difference(_lastClosed!) < policy.cooldown;
          if (_waitingReason == null && !cooling) {
            await request.validateRequest?.call();
            if (validateIdentity != null &&
                !await validateIdentity!(request.root, request.identity)) {
              throw StateError(
                'Root configuration changed while queued; retry the disk check',
              );
            }
            if (request.result.isCompleted || _stopping) break;
            if (_worker == null) {
              await prepareWorker?.call(request.root, request.identity);
              await request.validateRequest?.call();
              if (validateIdentity != null &&
                  !await validateIdentity!(request.root, request.identity)) {
                throw StateError(
                  'Root configuration changed during cache preparation',
                );
              }
            }
            if (request.result.isCompleted || _stopping) break;
            // Disk/config checks can be slow. Admission must use a fresh
            // sample after them, with no further awaited work before start.
            _sample = sampleMemory();
            _waitingReason = policy.waitingReason(
              _sample,
              starting: _worker == null,
              recovering: _recovering,
              now: _now(),
            );
            if (_waitingReason == null) break;
          }
          _recovering = true;
          _waitingReason ??= 'reclaim-cooldown';
          // No request is executing yet, so reclaiming this idle worker is safe.
          if (_worker != null) await _reclaim();
          await Future.any([
            Future<void>.delayed(const Duration(milliseconds: 100)),
            request.cancelled.future,
          ]);
        }
        if (request.result.isCompleted || _stopping) continue;
        _waitingReason = null;
        _recovering = false;
        request.timer?.cancel(); // Analysis has its own runtime timeout.
        if (_worker == null) {
          _worker = createWorker(request.root);
          _root = request.root;
          _identity = request.identity;
          _generation++;
          _starts++;
          startup = _worker!.start();
          startup.ignore();
          await Future.any([
            startup.timeout(const Duration(seconds: 150)),
            request.cancelled.future.then(
              (_) => throw StateError('Analyzer startup cancelled'),
            ),
          ]);
          await workerStarted?.call(request.root, request.identity);
        }
        if (request.result.isCompleted || _stopping) {
          await _reclaim();
          continue;
        }
        await validateExecution?.call(request.root, request.identity);
        if (request.result.isCompleted || _stopping) {
          await _reclaim();
          continue;
        }
        final result = _worker!.handle(request.command);
        result.ignore();
        final response = await Future.any<Map<String, Object?>>([
          result,
          request.cancelled.future.then(
            (_) => throw StateError('Active request cancelled'),
          ),
        ]);
        await request.validateRequest?.call();
        await validateExecution?.call(request.root, request.identity);
        if (validateIdentity != null &&
            !await validateIdentity!(request.root, request.identity)) {
          throw StateError(
            'Root configuration changed during analysis; result discarded',
          );
        }
        if (!request.result.isCompleted) {
          request.result.complete({
            ...response,
            'globalBudget': true,
            'workerGeneration': _generation,
            'diagnosticComplete': false,
          });
        } else {
          await _reclaim();
        }
        _lastUsed = _now();
      } catch (error, stack) {
        try {
          await _reclaim();
          await startup?.then<void>((_) {}, onError: (Object _) {});
          await invalidateWorkerCache?.call(request.root, request.identity);
        } catch (cleanupError) {
          _degraded = '$cleanupError';
        }
        if (!request.result.isCompleted) {
          request.result.completeError(error, stack);
        }
      } finally {
        request.timer?.cancel();
        _active = null;
      }
    }
    _waitingReason = null;
    if (_degraded != null) {
      for (final request in _queue.toList()) {
        _cancel(request, 'Global budget degraded: $_degraded');
      }
    }
  }

  Future<void> _reclaim() async {
    if (_worker == null) return;
    try {
      await _worker!.close();
    } catch (error) {
      // Keep the slot occupied: a failed close is not evidence of a dead tree.
      _degraded = 'Owned worker cleanup was not confirmed: $error';
      rethrow;
    }
    _worker = null;
    _root = null;
    _identity = null;
    _reclaims++;
    _workerResources = null;
    _lastClosed = _now();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _stopping = true;
    _monitor.cancel();
    _idleTimer?.cancel();
    for (final request in [..._queue, if (_active != null) _active!]) {
      _cancel(request, 'Global budget stopped');
    }
    try {
      await _draining;
      await _reclaim();
      if (_degraded != null) throw StateError(_degraded!);
    } finally {
      if (!_closed.isCompleted) _closed.complete();
    }
  }
}

class _BudgetRequest {
  _BudgetRequest(this.root, this.identity, this.command);
  final String root;
  final String identity;
  final Map<String, Object?> command;
  final result = Completer<Map<String, Object?>>();
  final cancelled = Completer<void>();
  Timer? timer;
  Future<void> Function()? validateRequest;
}
