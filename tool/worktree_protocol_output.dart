// Research transport output budget, independent of kernel socket buffering.
import 'dart:async';
import 'dart:collection';

class ResearchOutputBuffer {
  ResearchOutputBuffer({
    required this.writeBytes,
    required this.onClose,
    this.limit = 65536,
    this.timeout = const Duration(seconds: 2),
  });
  final Future<void> Function(List<int>) writeBytes;
  final void Function() onClose;
  final int limit;
  final Duration timeout;
  final _queue = Queue<List<int>>();
  bool closed = false;
  bool _writing = false;
  int pendingBytes = 0;
  Object? error;
  Completer<void>? _idle;
  Future<void> get drained => _idle?.future ?? Future.value();

  void add(List<int> bytes) {
    if (closed) return;
    if (pendingBytes + bytes.length > limit) {
      close(StateError('Output budget exceeded'));
      return;
    }
    if (_idle == null || _idle!.isCompleted) _idle = Completer<void>();
    pendingBytes += bytes.length;
    _queue.add(bytes);
    unawaited(_pump());
  }

  void close([Object? cause]) {
    if (closed) return;
    closed = true;
    error = cause;
    _queue.clear();
    pendingBytes = 0;
    if (_idle != null && !_idle!.isCompleted) _idle!.complete();
    onClose();
  }

  Future<void> _pump() async {
    if (_writing || closed) return;
    _writing = true;
    try {
      while (_queue.isNotEmpty && !closed) {
        final bytes = _queue.removeFirst();
        await writeBytes(bytes).timeout(timeout);
        if (!closed) pendingBytes -= bytes.length;
      }
    } catch (failure) {
      close(failure);
    } finally {
      _writing = false;
      if (_idle != null && !_idle!.isCompleted) _idle!.complete();
    }
  }
}
