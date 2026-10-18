import 'dart:async';
import 'dart:collection';

class _OfficialJob {
  _OfficialJob(this.action);
  final Future<Map> Function() action;
  final done = Completer<Map>();
  Timer? timer;
  bool running = false;
  Object? invalid;
}

// Queued cancellation skips transport immediately. Active cancellation waits
// for the bounded exchange to drain before releasing the caller's lease.
class ResearchOfficialQueue {
  final _queue = Queue<_OfficialJob>();
  _OfficialJob? _active;
  Future<Map> run(
    Future<Map> Function() action, {
    Future<void>? cancelled,
    Duration? budget,
  }) {
    if (budget != null && budget <= Duration.zero) {
      return Future.error(TimeoutException('Official queue deadline'));
    }
    if (_queue.length + (_active == null ? 0 : 1) >= 8) {
      return Future.error(StateError('Official control queue full'));
    }
    final job = _OfficialJob(action);
    void invalidate(Object error) {
      if (job.done.isCompleted) return;
      job.invalid ??= error;
      if (!job.running) {
        _queue.remove(job);
        job.timer?.cancel();
        job.done.completeError(job.invalid!);
      }
    }

    _queue.add(job);
    if (cancelled != null) {
      unawaited(
        cancelled.then(
          (_) => invalidate(StateError('Official queued work cancelled')),
        ),
      );
    }
    if (budget != null) {
      job.timer = Timer(
        budget,
        () => invalidate(TimeoutException('Official queue deadline')),
      );
    }
    scheduleMicrotask(_pump);
    return job.done.future;
  }

  Future<void> _pump() async {
    if (_active != null) return;
    while (_queue.isNotEmpty) {
      final job = _active = _queue.removeFirst();
      job.running = true;
      try {
        final result = await job.action();
        if (job.invalid != null) throw job.invalid!;
        job.done.complete(result);
      } catch (error, stack) {
        job.done.completeError(error, stack);
      } finally {
        job.timer?.cancel();
        _active = null;
      }
    }
  }
}
