// Lightweight ownership/transport validation; never launches an analyzer.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_analysis_daemon/src/analyzer_process.dart';
import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';
import 'package:dart_analysis_daemon/src/system_memory.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--echo')) {
    await for (final bytes in stdin) {
      stdout.add(bytes);
      await stdout.flush();
    }
    return;
  }
  if (!Platform.isWindows) throw UnsupportedError('Windows validation only');
  final destination = args.indexOf('--output');
  final batchIndex = args.indexOf('--lifecycle-batches');
  final batches = batchIndex < 0 ? 5 : int.parse(args[batchIndex + 1]);
  if (batches < 1 || batches > 100) {
    throw ArgumentError('lifecycle-batches must be between 1 and 100');
  }
  final resultFile =
      destination < 0
          ? File(
            '${(await Directory.systemTemp.createTemp('dana-ffi-validation-')).path}/results.json',
          )
          : File(args[destination + 1]);
  final result = <String, Object?>{
    'sdk': Platform.version,
    'executable': Platform.resolvedExecutable,
    'lightweightOnly': true,
    'systemMemory': WindowsSystemMemorySampler().sample()?.toJson(),
    'started': DateTime.now().toIso8601String(),
  };
  try {
    if (!args.contains('--bench-only') && !args.contains('--memory-only')) {
      result['lifecycle'] = await _lifecycle(batches);
    }
    if (!args.contains('--lifecycle-only') && !args.contains('--memory-only')) {
      final rounds = <Object?>[];
      result['transport'] = rounds;
      for (var round = 0; round < 2; round++) {
        final order = ['direct', 'windows-ffi-job'];
        for (final backend in round == 0 ? order : order.reversed) {
          final sample = await _benchmark(backend);
          rounds.add({'round': round, ...sample});
          stdout.writeln(jsonEncode(sample));
        }
      }
    }
    result['ok'] = true;
  } catch (error, stack) {
    result['ok'] = false;
    result['error'] = '$error';
    result['stack'] = '$stack';
    exitCode = 1;
  } finally {
    await resultFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
    );
    stdout.writeln('results: ${resultFile.path}');
  }
}

List<String> _childArguments() {
  final script = File.fromUri(Platform.script).absolute.path;
  return [
    if (script != File(Platform.resolvedExecutable).absolute.path) ...[
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      script,
    ],
    '--echo',
  ];
}

Future<AnalyzerProcess> _start(String backend) async {
  switch (backend) {
    case 'direct':
      return DirectAnalyzerProcess(
        await Process.start(Platform.resolvedExecutable, _childArguments()),
      );
    default:
      return WindowsFfiAnalyzerProcess.start(
        Platform.resolvedExecutable,
        _childArguments(),
        workingDirectory: Directory.current.path,
      );
  }
}

Future<Map<String, Object?>> _benchmark(String backend) async {
  final startup = Stopwatch()..start();
  final process = await _start(backend);
  final received = _Receiver(process.stdout);
  final errors = process.stderr.transform(utf8.decoder).join();
  final small = Uint8List.fromList(List.generate(256, (i) => i));
  Future<void> echo(List<int> bytes) async {
    final completed = received.expect(bytes);
    process.stdin.add(bytes);
    await process.stdin.flush();
    await completed.timeout(const Duration(seconds: 15));
  }

  try {
    await echo(small);
    startup.stop();
    for (var i = 0; i < 5; i++) {
      await echo(small);
    }
    final latencies = <int>[];
    for (var i = 0; i < 100; i++) {
      final clock = Stopwatch()..start();
      await echo(small);
      latencies.add(clock.elapsedMicroseconds);
    }
    latencies.sort();
    final payload = Uint8List.fromList(
      List.generate(4 * 1024 * 1024, (i) => i % 251),
    );
    final transfer = Stopwatch()..start();
    await echo(payload);
    transfer.stop();
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 10));
    if (code != 0) {
      throw StateError(
        'Echo child failed ($backend, code=$code): ${await errors}',
      );
    }
    await received.done;
    await errors;
    return {
      'backend': backend,
      'startupMs': startup.elapsedMicroseconds / 1000,
      'roundTripMedianMs': latencies[50] / 1000,
      'roundTripP95Ms': latencies[95] / 1000,
      'bulkMiB': 4,
      'bulkMs': transfer.elapsedMicroseconds / 1000,
      'bulkMiBPerSecond': 4 * 1000000 / transfer.elapsedMicroseconds,
      'bytesVerified': received.total,
    };
  } finally {
    await process.terminate();
  }
}

class _Receiver {
  _Receiver(Stream<List<int>> stream) {
    stream.listen(
      (bytes) {
        try {
          final expected = _expected;
          if (expected == null || _offset + bytes.length > expected.length) {
            throw StateError('Unexpected echo bytes');
          }
          for (var i = 0; i < bytes.length; i++) {
            if (bytes[i] != expected[_offset + i]) {
              throw StateError('Echo mismatch');
            }
          }
          _offset += bytes.length;
          total += bytes.length;
          if (_offset == expected.length) {
            _expected = null;
            _pending!.complete();
          }
        } catch (error, stack) {
          _fail(error, stack);
        }
      },
      onError: _fail,
      onDone: () {
        if (_expected != null) {
          _fail(StateError('Truncated echo'), StackTrace.current);
        }
        _done.complete();
      },
    );
  }
  List<int>? _expected;
  int _offset = 0;
  int total = 0;
  Completer<void>? _pending;
  final _done = Completer<void>();
  Future<void> get done => _done.future;
  Future<void> expect(List<int> bytes) {
    if (_expected != null) throw StateError('Overlapping echo');
    _expected = bytes;
    _offset = 0;
    _pending = Completer<void>();
    return _pending!.future;
  }

  void _fail(Object error, StackTrace stack) {
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.completeError(error, stack);
    }
  }
}

Future<Map<String, Object?>> _lifecycle(int batches) async {
  // Warm VM/isolate infrastructure before comparing OS handles in this process.
  await _cycle();
  final counts = <int>[_handleCount()];
  final clock = Stopwatch()..start();
  final memory = WindowsSystemMemorySampler();
  for (var batch = 0; batch < batches; batch++) {
    final sample = memory.sample();
    if (sample == null ||
        !sample.freshAt(DateTime.now().toUtc()) ||
        sample.availablePhysicalBytes < 4096 * bytesPerMiB ||
        sample.availableCommitBytes < 4096 * bytesPerMiB) {
      throw StateError('Lifecycle resource protection: ${sample?.toJson()}');
    }
    for (var i = 0; i < 10; i++) {
      for (final invalid in [
        'C:/missing-dana-ffi.exe',
        Platform.resolvedExecutable,
      ]) {
        try {
          final unexpected = await WindowsFfiAnalyzerProcess.start(
            invalid,
            [],
            workingDirectory: 'C:/missing-dana-ffi-directory',
          );
          await unexpected.terminate();
          throw StateError('Invalid startup accepted');
        } on OSError {
          /* Expected before ownership transfer. */
        }
      }
      await _cycle();
    }
    // Each batch includes three simultaneous owners with no output consumers.
    final processes = <AnalyzerProcess>[];
    try {
      for (var i = 0; i < 3; i++) {
        processes.add(await _start('windows-ffi-job'));
      }
    } finally {
      await Future.wait(processes.map((p) => p.terminate()));
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    counts.add(_handleCount());
    stdout.writeln(
      'lifecycle batch ${batch + 1}/$batches: handles=${counts.last}',
    );
  }
  if (counts.last > counts.first + 4) {
    throw StateError('Growing native handle count: $counts');
  }
  return {
    'successfulCycles': 1 + batches * 13,
    'failedStartups': batches * 20,
    'concurrentOwners': 3,
    'handleSamples': counts,
    'allowedHandleGrowth': 4,
    'elapsedMs': clock.elapsedMilliseconds,
  };
}

Future<void> _cycle() async {
  final process = await _start('windows-ffi-job');
  final output = process.stdout.drain<void>();
  final errors = process.stderr.drain<void>();
  try {
    process.stdin.add([0, 1, 2, 255]);
    await process.stdin.flush();
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 10));
    await Future.wait([output, errors]);
  } finally {
    await process.terminate();
  }
}

int _handleCount() {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final allocator = DynamicLibrary.open('msvcrt.dll');
  final allocate = allocator.lookupFunction<
    Pointer<Void> Function(IntPtr, IntPtr),
    Pointer<Void> Function(int, int)
  >('calloc');
  final free = allocator.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)
  >('free');
  final current = kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      );
  final count = kernel.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Uint32>),
    int Function(Pointer<Void>, Pointer<Uint32>)
  >('GetProcessHandleCount');
  final value = allocate(1, 4).cast<Uint32>();
  if (value == nullptr) throw StateError('Allocation failed');
  try {
    if (count(current(), value) == 0) {
      throw StateError('GetProcessHandleCount failed');
    }
    return value.value;
  } finally {
    free(value.cast());
  }
}
