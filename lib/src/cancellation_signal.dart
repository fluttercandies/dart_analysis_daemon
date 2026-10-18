import 'dart:async';

/// Listeners detach when a request finishes, even if its client stays connected.
class CancellationSignal {
  final _events = StreamController<void>.broadcast(sync: true);
  bool isCancelled = false;
  Stream<void> get events => _events.stream;
  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    _events.add(null);
    unawaited(_events.close());
  }
}
