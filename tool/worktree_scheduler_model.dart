// Research-only lifecycle model. No analyzer, socket, filesystem, or process API.
import 'dart:async';
import 'dart:collection';

abstract interface class ModelWorker {
  Future<void> close();
}

typedef ModelWorkerFactory =
    Future<ModelWorker> Function(String root, int generation);

// A failed start may release its slot only after cleanup confirms process exit.
class ModelStartupCleanupUnconfirmed implements Exception {
  ModelStartupCleanupUnconfirmed(this.cause);
  final Object cause;
  @override
  String toString() => 'Startup cleanup unconfirmed: $cause';
}

class ModelLease {
  ModelLease._(this._owner, this.root, this.generation);
  final WorktreeSchedulerModel _owner;
  final String root;
  final int generation;
  bool _released = false;

  bool get acceptsResults => !_released && _owner._isCurrent(this);

  void release() {
    if (_released) return;
    _released = true;
    _owner._release(this);
  }
}

class _Request {
  _Request(this.id, this.root, this.deadline);
  final String id;
  final String root;
  final int deadline;
  final result = Completer<ModelLease>();
}

class _Slot {
  _Slot(this.root, this.generation);
  final String root;
  final int generation;
  ModelWorker? worker;
  int leases = 0;
  bool draining = false;
  bool resultsInvalid = false;
  bool closing = false;
}

class WorktreeSchedulerModel {
  WorktreeSchedulerModel({
    required this.factory,
    required this.nowMs,
    required this.canStart,
    this.closeTimeout = const Duration(seconds: 10),
    this.canLease,
  });

  final ModelWorkerFactory factory;
  final int Function() nowMs;
  final bool Function() canStart;
  final Duration closeTimeout;
  final bool Function()? canLease;
  final _queue = Queue<_Request>();
  final _ids = <String>{};
  _Slot? _slot;
  bool _pumping = false;
  bool _closed = false;
  int _generation = 0;
  Object? degraded;

  int get queued => _queue.length;
  int get occupiedSlots => _slot == null ? 0 : 1;
  int get activeLeases => _slot?.leases ?? 0;
  String? get residentRoot => _slot?.root;

  Future<ModelLease> acquire(
    String id,
    String root, {
    required int deadlineMs,
  }) {
    if (_closed || degraded != null) {
      return Future.error(StateError('Scheduler unavailable: $degraded'));
    }
    if (!_ids.add(id)) {
      return Future.error(StateError('Duplicate request ID: $id'));
    }
    final request = _Request(id, root, deadlineMs);
    _queue.add(request);
    tick();
    return request.result.future;
  }

  // Called by the eventual clock/resource adapter; tests advance a virtual clock.
  void tick() {
    for (final request in _queue.toList()) {
      if (request.deadline <= nowMs()) {
        _fail(request, TimeoutException('Admission deadline: ${request.id}'));
      }
    }
    unawaited(_pump());
  }

  void cancel(String id) {
    for (final request in _queue.toList()) {
      if (request.id == id) _fail(request, StateError('Cancelled: $id'));
    }
    tick();
  }

  void invalidate(String root) {
    if (_slot?.root == root) {
      _slot!.draining = true;
      _slot!.resultsInvalid = true;
    }
    tick();
  }

  // Soft memory/idle retirement stops new leases but preserves valid in-flight
  // results. Configuration changes and worker failure use invalidate instead.
  void retire(String root) {
    if (_slot?.root == root) _slot!.draining = true;
    tick();
  }

  void invalidateGeneration(int generation) {
    if (_slot?.generation == generation) {
      _slot!.draining = true;
      _slot!.resultsInvalid = true;
    }
    tick();
  }

  // Exit notification must carry a generation; stale exits cannot remove a replacement.
  void workerExited(int generation) {
    if (_slot?.generation != generation) return;
    _slot = null;
    tick();
  }

  bool _isCurrent(ModelLease lease) =>
      _slot?.generation == lease.generation &&
      _slot?.root == lease.root &&
      _slot?.worker != null &&
      !_slot!.resultsInvalid &&
      !_slot!.closing;

  // Owner loss does not prove Job zero. Keep the slot and reject late results.
  void workerOwnershipLost(int generation, Object error) {
    if (_slot?.generation != generation) return;
    _slot!.draining = true;
    _slot!.resultsInvalid = true;
    degraded = error;
    for (final request in _queue.toList()) {
      _fail(request, StateError('Worker ownership lost: $error'));
    }
  }

  void _release(ModelLease lease) {
    if (_slot?.generation == lease.generation) {
      _slot!.leases--;
    }
    tick();
  }

  void _fail(_Request request, Object error) {
    _queue.remove(request);
    _ids.remove(request.id);
    request.result.completeError(error);
  }

  Future<bool> _stop(_Slot slot) async {
    slot.closing = true;
    try {
      await slot.worker!.close().timeout(closeTimeout);
      if (identical(_slot, slot)) _slot = null;
      return true;
    } catch (error) {
      // A failed close does not prove process exit: keep the slot and stop expansion.
      degraded = error;
      for (final request in _queue.toList()) {
        _fail(request, StateError('Worker closure not confirmed: $error'));
      }
      return false;
    }
  }

  Future<void> _pump() async {
    if (_pumping || degraded != null) return;
    _pumping = true;
    try {
      while (degraded == null) {
        final slot = _slot;
        if (slot != null &&
            slot.leases == 0 &&
            (slot.draining ||
                _closed ||
                (_queue.isNotEmpty && _queue.first.root != slot.root))) {
          if (!await _stop(slot)) return;
          continue;
        }
        if (_queue.isEmpty || _closed) return;
        final request = _queue.first;
        if (request.deadline <= nowMs()) {
          _fail(request, TimeoutException('Admission deadline: ${request.id}'));
          continue;
        }
        if (slot == null) {
          if (!canStart()) return;
          final starting = _slot = _Slot(request.root, ++_generation);
          try {
            starting.worker = await factory(starting.root, starting.generation);
          } catch (error) {
            if (error is ModelStartupCleanupUnconfirmed) {
              degraded = error;
              for (final pending in _queue.toList()) {
                _fail(pending, error);
              }
              return;
            }
            // Factory errors must mean no owned worker survived the failed start.
            if (identical(_slot, starting)) _slot = null;
            for (final pending
                in _queue.where((r) => r.root == starting.root).toList()) {
              _fail(pending, error);
            }
            continue;
          }
          if (!identical(_slot, starting)) {
            // A generation exit notification raced startup completion.
            if (!await _stop(starting)) return;
            continue;
          }
          tick();
          if (!_queue.any((r) => r.root == starting.root)) {
            starting.draining = true;
          }
          continue;
        }
        if (slot.draining || slot.closing || slot.root != request.root) return;
        if (canLease != null && !canLease!()) return;
        _queue.removeFirst();
        _ids.remove(request.id);
        slot.leases++;
        request.result.complete(ModelLease._(this, slot.root, slot.generation));
      }
    } finally {
      _pumping = false;
    }
  }

  void shutdown() {
    _closed = true;
    for (final request in _queue.toList()) {
      _fail(request, StateError('Scheduler shutting down'));
    }
    if (_slot != null) {
      _slot!.draining = true;
      _slot!.resultsInvalid = true;
    }
    tick();
  }
}
