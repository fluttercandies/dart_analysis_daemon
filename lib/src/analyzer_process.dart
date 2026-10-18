import 'dart:async';
import 'dart:io';

/// The protocol transport and its owner must share one lifecycle. A backend
/// may own a process tree even after the analyzer root process has exited.
abstract interface class AnalyzerProcess {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  IOSink get stdin;
  int get pid;
  Future<int> get exitCode;
  String get backend;
  Future<void> terminate();
}

abstract interface class OwnedProcessMetrics {
  Map<String, Object?> sampleResources();
}

class DirectAnalyzerProcess implements AnalyzerProcess {
  DirectAnalyzerProcess(this.process);
  final Process process;
  Future<void>? _termination;

  @override
  Stream<List<int>> get stdout => process.stdout;
  @override
  Stream<List<int>> get stderr => process.stderr;
  @override
  IOSink get stdin => process.stdin;
  @override
  int get pid => process.pid;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  String get backend => 'direct';

  @override
  Future<void> terminate() => _termination ??= _terminate();

  Future<void> _terminate() async {
    if (Platform.isWindows) {
      await Process.run('taskkill', [
        '/PID',
        '$pid',
        '/T',
        '/F',
      ]).timeout(const Duration(seconds: 5));
    } else {
      process.kill(ProcessSignal.sigterm);
    }
    await exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout:
          () => throw StateError('Analysis server exit was not confirmed.'),
    );
  }
}
