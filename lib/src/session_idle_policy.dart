import 'dart:async';

/// Reclaims a root session only when no client or queued exchange owns it.
class SessionIdlePolicy {
  SessionIdlePolicy({required this.timeout, required this.onIdle}) {
    if (timeout.isNegative) throw ArgumentError.value(timeout, 'timeout');
    _arm();
  }

  final Duration timeout;
  final void Function() onIdle;
  Timer? _timer;
  int _clients = 0;
  int _requests = 0;
  bool _closed = false;

  void clientConnected() {
    _clients++;
    _timer?.cancel();
  }

  void clientDisconnected() {
    if (_clients == 0) throw StateError('No client to release');
    _clients--;
    _arm();
  }

  void requestQueued() {
    _requests++;
    _timer?.cancel();
  }

  void requestFinished() {
    if (_requests == 0) throw StateError('No request to release');
    _requests--;
    _arm();
  }

  void _arm() {
    if (_closed ||
        timeout == Duration.zero ||
        _clients != 0 ||
        _requests != 0) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(timeout, () {
      _closed = true;
      onIdle();
    });
  }

  void close() {
    _closed = true;
    _timer?.cancel();
  }
}

/// Zero disables reclamation. Invalid configuration must not silently disable it.
Duration parseSessionIdleTimeout(String? value) {
  if (value == null) return Duration.zero;
  final seconds = int.tryParse(value);
  if (seconds == null || seconds < 0 || seconds > 2147483) {
    throw FormatException(
      'Session idle timeout must be an integer from 0 to 2147483 seconds.',
      value,
    );
  }
  return Duration(seconds: seconds);
}
