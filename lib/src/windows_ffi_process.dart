// Windows SDK ABI bindings. No shipped native library or helper process.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'analyzer_process.dart';

/// Opt-in backend: atomic Job membership, native pipes, no helper executable.
/// Bounded pipe operations run on persistent isolates, never the protocol isolate.
class WindowsFfiAnalyzerProcess
    implements AnalyzerProcess, OwnedProcessMetrics {
  WindowsFfiAnalyzerProcess._(
    this._api,
    this._job,
    this._process,
    this.pid,
    int input,
    int output,
    int error,
  ) {
    _writer = _PipeWriter(input);
    stdin = IOSink(_writer);
    // IOSink exposes failures through both flush/close and done. Consumers of
    // AnalyzerProcess await flush/close, so observe the duplicate done channel.
    stdin.done.ignore();
    _output = _ReadPipe(output);
    _error = _ReadPipe(error);
    stdout = _output.stream();
    stderr = _error.stream();
    exitCode = _watchExit();
    // A dead analyzer must not leave a plugin tree running until session idle.
    // Keep pipe handles available for consumers to drain already written bytes.
    exitCode.then((_) => _emptyJob()).ignore();
  }

  final _WindowsApi _api;
  final Pointer<Void> _job;
  final Pointer<Void> _process;
  late final _PipeWriter _writer;
  late final _ReadPipe _output;
  late final _ReadPipe _error;
  @override
  final int pid;
  @override
  late final IOSink stdin;
  @override
  late final Stream<List<int>> stdout;
  @override
  late final Stream<List<int>> stderr;
  @override
  late final Future<int> exitCode;
  @override
  String get backend => 'windows-ffi-job';
  bool confirmedEmpty = false;
  Future<void>? _termination;
  Future<void>? _emptying;

  @override
  Map<String, Object?> sampleResources() {
    if (_termination != null) throw StateError('FFI Job is closing');
    final limits = _api.calloc(sizeOf<_WindowsJobExtendedLimits>());
    final members = _api.calloc(65536);
    final counters =
        _api
            .calloc(sizeOf<_ProcessMemoryCounters>())
            .cast<_ProcessMemoryCounters>();
    final member = _api.calloc(4).cast<Int32>();
    final memory = _ProcessMemoryApi();
    try {
      _api.check(
        _api.queryJob(
          _job,
          9,
          limits,
          sizeOf<_WindowsJobExtendedLimits>(),
          nullptr,
        ),
        'QueryInformationJobObject(limits)',
      );
      _api.check(
        _api.queryJob(_job, 3, members, 65536, nullptr),
        'QueryInformationJobObject(members)',
      );
      final assigned = members.cast<Uint32>()[0];
      final listed = members.cast<Uint32>()[1];
      var valid =
          assigned == listed && listed <= (65536 - 8) ~/ sizeOf<IntPtr>();
      var current = 0;
      var measured = 0;
      if (valid) {
        for (var i = 0; i < listed; i++) {
          final id = Pointer<IntPtr>.fromAddress(members.address + 8)[i];
          final process = memory.open(0x100410, 0, id);
          if (process == nullptr) {
            valid = false;
            continue;
          }
          try {
            counters.ref.cb = sizeOf<_ProcessMemoryCounters>();
            if (memory.inJob(process, _job, member) == 0 ||
                member.value == 0 ||
                _api.waitForSingleObject(process, 0) != 0x102 ||
                memory.query(
                      process,
                      counters,
                      sizeOf<_ProcessMemoryCounters>(),
                    ) ==
                    0 ||
                _api.waitForSingleObject(process, 0) != 0x102) {
              valid = false;
              continue;
            }
            current += counters.ref.privateUsage;
            measured++;
          } finally {
            _api.closeHandle(process);
          }
        }
      }
      return {
        'sampledAt': DateTime.now().toUtc().toIso8601String(),
        'rootPid': pid,
        'memberCount': listed,
        'measuredMembers': measured,
        'currentPrivateMiB': valid ? current / (1024 * 1024) : null,
        'peakPrivateMiB':
            limits.cast<_WindowsJobExtendedLimits>().ref.peakJobMemoryUsed /
            (1024 * 1024),
        'complete': valid,
      };
    } finally {
      _api.free(limits);
      _api.free(members);
      _api.free(counters.cast());
      _api.free(member.cast());
    }
  }

  static Future<WindowsFfiAnalyzerProcess> start(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    String? jobName,
    Map<String, String>? environment,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows FFI Job requires Windows');
    }
    if (!File(executable).isAbsolute ||
        executable.contains('\u0000') ||
        arguments.any((a) => a.contains('\u0000')) ||
        (jobName != null && (jobName.isEmpty || jobName.contains('\u0000'))) ||
        workingDirectory.contains('\u0000')) {
      throw ArgumentError(
        'Use an absolute executable path and NUL-free arguments',
      );
    }
    String? environmentBlock;
    if (environment != null) {
      final merged = <String, MapEntry<String, String>>{
        for (final entry in Platform.environment.entries)
          entry.key.toUpperCase(): entry,
      };
      for (final entry in environment.entries) {
        if (entry.key.isEmpty ||
            entry.key.contains('=') ||
            entry.key.contains('\u0000') ||
            entry.value.contains('\u0000')) {
          throw ArgumentError('Invalid Windows environment override');
        }
        merged[entry.key.toUpperCase()] = entry;
      }
      final keys = merged.keys.toList()..sort();
      // utf16 adds the final NUL; every entry below already has its own NUL.
      environmentBlock =
          '${keys.map((key) => '${merged[key]!.key}=${merged[key]!.value}\u0000').join()}\u0000';
    }
    final api = _WindowsApi();
    final io = _PipeApi();
    final memory = <Pointer<Void>>[];
    Pointer<Void> alloc(int bytes) {
      final value = api.calloc(bytes);
      memory.add(value);
      return value;
    }

    Pointer<Uint16> text(String value) {
      final result = api.utf16(value);
      memory.add(result.cast());
      return result;
    }

    final handles = <Pointer<Void>>[];
    Pointer<Void> job = nullptr;
    Pointer<Void> process = nullptr;
    Pointer<Void> thread = nullptr;
    Pointer<Void> attributes = nullptr;
    var initialized = false;
    try {
      job = api.createJob(nullptr, jobName == null ? nullptr : text(jobName));
      api.checkHandle(job, 'CreateJobObjectW');
      final limits = alloc(sizeOf<_WindowsJobExtendedLimits>());
      limits.cast<_WindowsJobExtendedLimits>().ref.basic.limitFlags = 0x2000;
      api.check(
        api.setJob(job, 9, limits, sizeOf<_WindowsJobExtendedLimits>()),
        'SetInformationJobObject',
      );
      final security =
          alloc(sizeOf<_SecurityAttributes>()).cast<_SecurityAttributes>();
      security.ref.length = sizeOf<_SecurityAttributes>();
      security.ref.inherit = 1;
      List<Pointer<Void>> pipe() {
        final pair = alloc(sizeOf<IntPtr>() * 2).cast<Pointer<Void>>();
        api.check(io.createPipe(pair, pair + 1, security, 65536), 'CreatePipe');
        handles.addAll([pair[0], pair[1]]);
        return [pair[0], pair[1]];
      }

      final input = pipe();
      final output = pipe();
      final error = pipe();
      for (final handle in [input[1], output[0], error[0]]) {
        api.check(
          io.setHandleInformation(handle, 1, 0),
          'SetHandleInformation',
        );
      }
      final bytes = alloc(sizeOf<IntPtr>()).cast<IntPtr>();
      api.initAttributes(nullptr, 2, 0, bytes);
      if (bytes.value <= 0 || bytes.value > 1048576) {
        throw StateError('Invalid attribute size');
      }
      attributes = alloc(bytes.value);
      api.check(
        api.initAttributes(attributes, 2, 0, bytes),
        'InitializeProcThreadAttributeList',
      );
      initialized = true;
      final jobs = alloc(sizeOf<IntPtr>()).cast<Pointer<Void>>()..value = job;
      api.check(
        api.updateAttribute(
          attributes,
          0,
          0x2000D,
          jobs.cast(),
          sizeOf<IntPtr>(),
          nullptr,
          nullptr,
        ),
        'UpdateProcThreadAttribute(JOB_LIST)',
      );
      final inherited = alloc(sizeOf<IntPtr>() * 3).cast<Pointer<Void>>();
      inherited[0] = input[0];
      inherited[1] = output[1];
      inherited[2] = error[1];
      api.check(
        api.updateAttribute(
          attributes,
          0,
          0x20002,
          inherited.cast(),
          sizeOf<IntPtr>() * 3,
          nullptr,
          nullptr,
        ),
        'UpdateProcThreadAttribute(HANDLE_LIST)',
      );
      final startup =
          alloc(sizeOf<_WindowsStartupInfoEx>()).cast<_WindowsStartupInfoEx>();
      startup.ref.startupInfo.cb = sizeOf<_WindowsStartupInfoEx>();
      startup.ref.startupInfo.flags = 0x100;
      startup.ref.startupInfo.stdInput = input[0];
      startup.ref.startupInfo.stdOutput = output[1];
      startup.ref.startupInfo.stdError = error[1];
      startup.ref.attributes = attributes;
      final info =
          alloc(sizeOf<_WindowsProcessInfo>()).cast<_WindowsProcessInfo>();
      api.check(
        api.createProcess(
          text(executable),
          text([executable, ...arguments].map(_quoteWindowsArgument).join(' ')),
          nullptr,
          nullptr,
          1,
          0x08080004 | (environmentBlock == null ? 0 : 0x400),
          environmentBlock == null ? nullptr : text(environmentBlock).cast(),
          text(workingDirectory),
          startup,
          info,
        ),
        'CreateProcessW',
      );
      process = info.ref.process;
      thread = info.ref.thread;
      final accounting = alloc(sizeOf<_WindowsJobAccounting>());
      api.check(
        api.queryJob(
          job,
          1,
          accounting,
          sizeOf<_WindowsJobAccounting>(),
          nullptr,
        ),
        'QueryInformationJobObject(startup)',
      );
      if (accounting.cast<_WindowsJobAccounting>().ref.activeProcesses != 1) {
        throw StateError('Suspended analyzer did not enter its Job');
      }
      for (final handle in [input[0], output[1], error[1]]) {
        api.closeHandle(handle);
        handles.remove(handle);
      }
      if (api.resumeThread(thread) == 0xFFFFFFFF) {
        throw api.lastError('ResumeThread');
      }
      api.closeHandle(thread);
      thread = nullptr;
      final result = WindowsFfiAnalyzerProcess._(
        api,
        job,
        process,
        info.ref.processId,
        input[1].address,
        output[0].address,
        error[0].address,
      );
      handles.clear(); // Ownership transferred to streams/writer.
      return result;
    } catch (_) {
      if (job != nullptr) {
        api.closeHandle(job); // Kill-on-close also covers startup failures.
      }
      if (thread != nullptr) api.closeHandle(thread);
      if (process != nullptr) api.closeHandle(process);
      for (final handle in handles) {
        api.closeHandle(handle);
      }
      rethrow;
    } finally {
      if (initialized) api.deleteAttributes(attributes);
      for (final value in memory.reversed) {
        api.free(value);
      }
    }
  }

  /// Successor recovery uses the exact journaled Job name, never a stale PID.
  /// Query handles are short-lived so they cannot keep an orphan tree alive.
  static Future<void> waitForEmptyNamedJob(
    String name, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final api = _WindowsApi();
    final kernel = DynamicLibrary.open('kernel32.dll');
    // Opening a named Job is short and does no pipe I/O. Keep this and
    // GetLastError leaf so the thread-local error survives the FFI transition.
    final open = kernel.lookupFunction<
      Pointer<Void> Function(Uint32, Int32, Pointer<Uint16>),
      Pointer<Void> Function(int, int, Pointer<Uint16>)
    >('OpenJobObjectW', isLeaf: true);
    final jobName = api.utf16(name);
    final info = api.calloc(sizeOf<_WindowsJobAccounting>());
    final deadline = DateTime.now().add(timeout);
    try {
      while (true) {
        final job = open(4, 0, jobName);
        if (job == nullptr) {
          final code = api.getLastError();
          if (code == 2) return; // Named Job no longer exists.
          throw OSError('OpenJobObjectW(previous global worker)', code);
        }
        try {
          api.check(
            api.queryJob(
              job,
              1,
              info,
              sizeOf<_WindowsJobAccounting>(),
              nullptr,
            ),
            'QueryInformationJobObject(previous worker)',
          );
          if (info.cast<_WindowsJobAccounting>().ref.activeProcesses == 0) {
            return;
          }
        } finally {
          api.closeHandle(job);
        }
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Previous global worker Job is still active');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    } finally {
      api.free(jobName.cast());
      api.free(info);
    }
  }

  Future<int> _watchExit() async {
    while (true) {
      final state = _api.waitForSingleObject(_process, 0);
      if (state == 0) {
        final code = _api.calloc(sizeOf<Uint32>()).cast<Uint32>();
        try {
          _api.check(
            _PipeApi().getExitCode(_process, code),
            'GetExitCodeProcess',
          );
          return code.value;
        } finally {
          _api.free(code.cast());
        }
      }
      if (state != 0x102) throw _api.lastError('WaitForSingleObject');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  @override
  Future<void> terminate() => _termination ??= _terminate();

  Future<void> _terminate() async {
    try {
      await _emptyJob();
      await exitCode.timeout(const Duration(seconds: 8));
      // Closing the sink ends the consumer stream, including when no input was sent.
      try {
        await stdin.close().timeout(const Duration(seconds: 8));
      } on OSError catch (error) {
        // A write already in progress may observe the terminated child's pipe.
        if (error.errorCode != 109 && error.errorCode != 232) rethrow;
      }
    } finally {
      try {
        await Future.wait([_output.close(), _error.close()]);
      } finally {
        _api.closeHandle(_job);
        // _watchExit owns reads of this handle until the root exits.
        exitCode.then(
          (_) => _api.closeHandle(_process),
          onError:
              (Object error, StackTrace stack) => _api.closeHandle(_process),
        );
      }
    }
  }

  Future<void> _emptyJob() => _emptying ??= _waitForEmptyJob();

  Future<void> _waitForEmptyJob() async {
    _api.check(_api.terminateJob(_job, 90), 'TerminateJobObject');
    final info = _api.calloc(sizeOf<_WindowsJobAccounting>());
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (true) {
        _api.check(
          _api.queryJob(
            _job,
            1,
            info,
            sizeOf<_WindowsJobAccounting>(),
            nullptr,
          ),
          'QueryInformationJobObject',
        );
        if (info.cast<_WindowsJobAccounting>().ref.activeProcesses == 0) {
          break;
        }
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('FFI Job did not become empty');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      confirmedEmpty = true;
    } finally {
      _api.free(info);
    }
  }
}

// Each pipe has at most one outstanding operation. Blocking Win32 I/O runs
// on a persistent isolate; pausing the output subscription stops read requests.
class _ReadPipe {
  _ReadPipe(int address) : _worker = _PipeWorker(address);
  final _PipeWorker _worker;
  bool _closed = false;
  Completer<void>? _resume;
  Future<void>? _pumping;
  Future<void> close() async {
    _closed = true;
    if (_resume != null && !_resume!.isCompleted) _resume!.complete();
    try {
      await _worker.close(cancel: true);
    } finally {
      await _pumping;
    }
  }

  Stream<List<int>> stream() {
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        _pumping = _pump(controller);
        // Observe cleanup failures now; close() still propagates them to callers.
        _pumping!.ignore();
      },
      onPause: () => _resume = Completer<void>(),
      onResume: () {
        _resume?.complete();
        _resume = null;
      },
      onCancel: close,
    );
    return controller.stream;
  }

  Future<void> _pump(StreamController<List<int>> controller) async {
    try {
      while (!_closed) {
        await _resume?.future;
        if (_closed) break;
        final bytes = await _worker.request(null);
        if (bytes == null || _closed) break;
        controller.add(bytes);
      }
    } catch (error, stack) {
      if (!_closed) controller.addError(error, stack);
    } finally {
      try {
        // Do not call close(): it joins this pump.
        await _worker.close(cancel: true);
      } catch (error, stack) {
        if (!_closed) controller.addError(error, stack);
        rethrow;
      } finally {
        _closed = true;
        // Stream completion can wait for onCancel, which itself joins the pump.
        unawaited(controller.close());
      }
    }
  }
}

class _PipeWriter implements StreamConsumer<List<int>> {
  _PipeWriter(int address) : _worker = _PipeWorker(address);
  final _PipeWorker _worker;
  Future<void>? _writing;
  Future<void>? _closing;
  bool _closed = false;

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    if (_closed) return Future.error(StateError('Pipe closed'));
    return _writing = _write(stream);
  }

  Future<void> _write(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      for (var offset = 0; offset < chunk.length; offset += 65536) {
        final end = (offset + 65536).clamp(0, chunk.length);
        await _worker.request(Uint8List.fromList(chunk.sublist(offset, end)));
      }
    }
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    try {
      await _writing;
    } finally {
      await _worker.close();
    }
  }
}

class _PipeWorker {
  _PipeWorker(this.address);
  final int address;
  final _events = ReceivePort();
  final _ready = Completer<SendPort>();
  final _exited = Completer<void>();
  Completer<Uint8List?>? _pending;
  Future<void>? _starting;
  Future<void>? _closing;
  bool _closed = false;
  bool _transferred = false;
  Pointer<Void> _ioThread = nullptr;
  Pointer<_IoStatusBlock> _ioStatus = nullptr;

  Future<void> _start() async {
    _events.listen((dynamic message) {
      if (message is SendPort) {
        _ready.complete(message);
      } else if (message == null) {
        final error = StateError('Native pipe worker exited');
        if (!_ready.isCompleted) _ready.completeError(error);
        if (_pending != null && !_pending!.isCompleted) {
          _pending!.completeError(error);
        }
        _events.close();
        _exited.complete();
      } else {
        final values = message as List;
        if (values[0] == 'operation') {
          if (_ioThread != nullptr) _WindowsApi().closeHandle(_ioThread);
          _ioThread = Pointer<Void>.fromAddress(values[1] as int);
          _ioStatus = Pointer<_IoStatusBlock>.fromAddress(values[2] as int);
        } else if (values[0] == 'error') {
          _pending!.completeError(
            OSError(values[1] as String, values[2] as int),
          );
        } else {
          _pending!.complete(values[1] as Uint8List?);
        }
      }
    });
    try {
      await Isolate.spawn(
        _pipeWorkerMain,
        [address, _events.sendPort],
        onExit: _events.sendPort,
        errorsAreFatal: true,
      );
      _transferred = true;
      await _ready.future;
    } catch (error, stack) {
      _events.close();
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<Uint8List?> request(Uint8List? bytes) async {
    if (_closed) throw StateError('Pipe closed');
    await (_starting ??= _start());
    if (_closed) throw StateError('Pipe closed');
    if (_pending != null && !_pending!.isCompleted) {
      throw StateError('Overlapping native pipe operation');
    }
    _pending = Completer<Uint8List?>();
    (await _ready.future).send(['io', bytes]);
    return _pending!.future;
  }

  Future<void> close({bool cancel = false}) => _closing ??= _close(cancel);
  Future<void> _close(bool cancel) async {
    _closed = true;
    if (_starting == null) {
      _events.close();
      _WindowsApi().closeHandle(Pointer<Void>.fromAddress(address));
      return;
    }
    try {
      await _starting;
      // Sent after the pending operation. Job termination unblocks native I/O;
      // no handle is closed concurrently with a blocking ReadFile/WriteFile.
      (await _ready.future).send(['close']);
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (!_exited.isCompleted) {
        if (cancel &&
            _ioThread != nullptr &&
            _pending != null &&
            !_pending!.isCompleted) {
          final api = _WindowsApi();
          final result =
              api.calloc(sizeOf<_IoStatusBlock>()).cast<_IoStatusBlock>();
          try {
            _NativePipeIo().cancel(_ioThread, _ioStatus, result);
          } finally {
            api.free(result.cast());
          }
        }
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Pipe worker did not exit');
        }
        await Future.any([
          _exited.future,
          Future<void>.delayed(const Duration(milliseconds: 10)),
        ]);
      }
    } finally {
      if (_ioThread != nullptr) {
        _WindowsApi().closeHandle(_ioThread);
        _ioThread = nullptr;
      }
      if (!_transferred) {
        _WindowsApi().closeHandle(Pointer<Void>.fromAddress(address));
      }
    }
  }
}

Future<void> _pipeWorkerMain(List<Object> arguments) async {
  final address = arguments[0] as int;
  final parent = arguments[1] as SendPort;
  final commands = ReceivePort();
  final api = _WindowsApi();
  final io = _NativePipeIo();
  final handle = Pointer<Void>.fromAddress(address);
  // Keep the cancellation identity allocated until this worker exits. Its
  // address must not be recycled while an operation completion is in transit.
  final count = api.calloc(sizeOf<_IoStatusBlock>()).cast<_IoStatusBlock>();
  parent.send(commands.sendPort);
  try {
    await for (final dynamic command in commands) {
      final message = command as List;
      if (message[0] == 'close') break;
      try {
        final bytes = message[1] as Uint8List?;
        if (bytes != null) {
          _writeChunk(address, bytes, parent);
          parent.send(['ok', null]);
        } else {
          final data = api.calloc(65536);
          try {
            _publishOperation(parent, count);
            final status = io.read(
              handle,
              nullptr,
              nullptr,
              nullptr,
              count,
              data,
              65536,
              nullptr,
              nullptr,
            );
            if (status == 0x103) {
              throw StateError('Synchronous pipe returned STATUS_PENDING');
            }
            if (status < 0) {
              final error = io.toDosError(status);
              if (error != 109 && error != 232) {
                throw OSError('ReadFile', error);
              }
              parent.send(['ok', null]);
            } else {
              parent.send([
                'ok',
                count.ref.information == 0
                    ? null
                    : Uint8List.fromList(
                      data.cast<Uint8>().asTypedList(count.ref.information),
                    ),
              ]);
            }
          } finally {
            api.free(data);
          }
        }
      } on OSError catch (error) {
        parent.send(['error', error.message, error.errorCode]);
      } catch (error) {
        parent.send(['error', '$error', 0]);
      }
    }
  } finally {
    api.closeHandle(handle);
    api.free(count.cast());
    commands.close();
  }
}

void _writeChunk(int address, Uint8List bytes, SendPort parent) {
  final api = _WindowsApi();
  final io = _NativePipeIo();
  final data = api.calloc(bytes.length);
  final written = api.calloc(sizeOf<_IoStatusBlock>()).cast<_IoStatusBlock>();
  try {
    data.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    var offset = 0;
    while (offset < bytes.length) {
      _publishOperation(parent, written);
      final status = io.write(
        Pointer<Void>.fromAddress(address),
        nullptr,
        nullptr,
        nullptr,
        written,
        Pointer<Void>.fromAddress(data.address + offset),
        bytes.length - offset,
        nullptr,
        nullptr,
      );
      if (status == 0x103) {
        throw StateError('Synchronous pipe returned STATUS_PENDING');
      }
      if (status < 0) throw OSError('WriteFile', io.toDosError(status));
      if (written.ref.information == 0) {
        throw StateError('WriteFile made no progress');
      }
      offset += written.ref.information;
    }
  } finally {
    api.free(data);
    api.free(written.cast());
  }
}

// NT synchronous I/O returns its status directly. Win32 GetLastError is thread
// local and is not reliable across a blocking, non-leaf Dart FFI transition.
// These handles are synchronous CreatePipe handles; STATUS_PENDING is invalid.
final class _IoStatusBlock extends Struct {
  external Pointer<Void> status;
  @UintPtr()
  external int information;
}

class _NativePipeIo {
  final _dll = DynamicLibrary.open('ntdll.dll');
  late final read = _dll.lookupFunction<_NtIoNative, _NtIoDart>('NtReadFile');
  late final write = _dll.lookupFunction<_NtIoNative, _NtIoDart>('NtWriteFile');
  late final cancel = _dll.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Pointer<_IoStatusBlock>,
      Pointer<_IoStatusBlock>,
    ),
    int Function(
      Pointer<Void>,
      Pointer<_IoStatusBlock>,
      Pointer<_IoStatusBlock>,
    )
  >('NtCancelSynchronousIoFile');
  late final toDosError = _dll
      .lookupFunction<Uint32 Function(Int32), int Function(int)>(
        'RtlNtStatusToDosError',
        isLeaf: true,
      );
}

class _ThreadIoApi {
  final _dll = DynamicLibrary.open('kernel32.dll');
  late final current = _dll.lookupFunction<Uint32 Function(), int Function()>(
    'GetCurrentThreadId',
    isLeaf: true,
  );
  late final open = _dll.lookupFunction<
    Pointer<Void> Function(Uint32, Int32, Uint32),
    Pointer<Void> Function(int, int, int)
  >('OpenThread');
}

void _publishOperation(SendPort parent, Pointer<_IoStatusBlock> status) {
  final threads = _ThreadIoApi();
  final thread = threads.open(1, 0, threads.current());
  _WindowsApi().checkHandle(thread, 'OpenThread(pipe cancellation)');
  // Match this IO_STATUS_BLOCK as well as the thread. The VM may reuse that
  // thread after completion, so thread-only cancellation could hit other I/O.
  parent.send(['operation', thread.address, status.address]);
}

typedef _NtIoNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<_IoStatusBlock>,
      Pointer<Void>,
      Uint32,
      Pointer<Void>,
      Pointer<Void>,
    );
typedef _NtIoDart =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<_IoStatusBlock>,
      Pointer<Void>,
      int,
      Pointer<Void>,
      Pointer<Void>,
    );

final class _SecurityAttributes extends Struct {
  @Uint32()
  external int length;
  external Pointer<Void> descriptor;
  @Int32()
  external int inherit;
}

final class _ProcessMemoryCounters extends Struct {
  @Uint32()
  external int cb;
  @Uint32()
  external int pageFaultCount;
  @UintPtr()
  external int peakWorkingSetSize;
  @UintPtr()
  external int workingSetSize;
  @UintPtr()
  external int quotaPeakPagedPool;
  @UintPtr()
  external int quotaPagedPool;
  @UintPtr()
  external int quotaPeakNonPagedPool;
  @UintPtr()
  external int quotaNonPagedPool;
  @UintPtr()
  external int pagefileUsage;
  @UintPtr()
  external int peakPagefileUsage;
  @UintPtr()
  external int privateUsage;
}

class _ProcessMemoryApi {
  final _kernel = DynamicLibrary.open('kernel32.dll');
  final _psapi = DynamicLibrary.open('psapi.dll');
  late final open = _kernel.lookupFunction<
    Pointer<Void> Function(Uint32, Int32, Uint32),
    Pointer<Void> Function(int, int, int)
  >('OpenProcess');
  late final inJob = _kernel.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>),
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Int32>)
  >('IsProcessInJob');
  late final query = _psapi.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<_ProcessMemoryCounters>, Uint32),
    int Function(Pointer<Void>, Pointer<_ProcessMemoryCounters>, int)
  >('GetProcessMemoryInfo');
}

class _PipeApi {
  final _dll = DynamicLibrary.open('kernel32.dll');
  late final createPipe = _dll.lookupFunction<
    Int32 Function(
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<_SecurityAttributes>,
      Uint32,
    ),
    int Function(
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<_SecurityAttributes>,
      int,
    )
  >('CreatePipe');
  late final setHandleInformation = _dll.lookupFunction<
    Int32 Function(Pointer<Void>, Uint32, Uint32),
    int Function(Pointer<Void>, int, int)
  >('SetHandleInformation');
  late final read = _dll.lookupFunction<_PipeIoNative, _PipeIoDart>('ReadFile');
  late final write = _dll.lookupFunction<_PipeIoNative, _PipeIoDart>(
    'WriteFile',
  );
  late final peek = _dll.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
    ),
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
    )
  >('PeekNamedPipe');
  late final getExitCode = _dll.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Uint32>),
    int Function(Pointer<Void>, Pointer<Uint32>)
  >('GetExitCodeProcess');
}

typedef _PipeIoNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef _PipeIoDart =
    int Function(
      Pointer<Void>,
      Pointer<Void>,
      int,
      Pointer<Uint32>,
      Pointer<Void>,
    );

final class _WindowsStartupInfo extends Struct {
  @Uint32()
  external int cb;
  external Pointer<Uint16> reserved;
  external Pointer<Uint16> desktop;
  external Pointer<Uint16> title;
  @Uint32()
  external int x;
  @Uint32()
  external int y;
  @Uint32()
  external int xSize;
  @Uint32()
  external int ySize;
  @Uint32()
  external int xChars;
  @Uint32()
  external int yChars;
  @Uint32()
  external int fillAttribute;
  @Uint32()
  external int flags;
  @Uint16()
  external int showWindow;
  @Uint16()
  external int reservedSize;
  external Pointer<Uint8> reservedData;
  external Pointer<Void> stdInput;
  external Pointer<Void> stdOutput;
  external Pointer<Void> stdError;
}

final class _WindowsBasicLimit extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;
  @Int64()
  external int perJobUserTimeLimit;
  @Uint32()
  external int limitFlags;
  @IntPtr()
  external int minimumWorkingSet;
  @IntPtr()
  external int maximumWorkingSet;
  @Uint32()
  external int activeProcessLimit;
  @IntPtr()
  external int affinity;
  @Uint32()
  external int priorityClass;
  @Uint32()
  external int schedulingClass;
}

final class _WindowsIoCounters extends Struct {
  @Uint64()
  external int readOperationCount;
  @Uint64()
  external int writeOperationCount;
  @Uint64()
  external int otherOperationCount;
  @Uint64()
  external int readTransferCount;
  @Uint64()
  external int writeTransferCount;
  @Uint64()
  external int otherTransferCount;
}

final class _WindowsJobExtendedLimits extends Struct {
  external _WindowsBasicLimit basic;
  external _WindowsIoCounters io;
  @IntPtr()
  external int processMemoryLimit;
  @IntPtr()
  external int jobMemoryLimit;
  @IntPtr()
  external int peakProcessMemoryUsed;
  @IntPtr()
  external int peakJobMemoryUsed;
}

final class _WindowsProcessInfo extends Struct {
  external Pointer<Void> process;
  external Pointer<Void> thread;
  @Uint32()
  external int processId;
  @Uint32()
  external int threadId;
}

final class _WindowsStartupInfoEx extends Struct {
  external _WindowsStartupInfo startupInfo;
  external Pointer<Void> attributes;
}

final class _WindowsJobAccounting extends Struct {
  @Int64()
  external int totalUserTime;
  @Int64()
  external int totalKernelTime;
  @Int64()
  external int periodUserTime;
  @Int64()
  external int periodKernelTime;
  @Uint32()
  external int pageFaults;
  @Uint32()
  external int totalProcesses;
  @Uint32()
  external int activeProcesses;
  @Uint32()
  external int terminatedProcesses;
}

final class _WindowsApi {
  _WindowsApi()
    : _kernel = DynamicLibrary.open('kernel32.dll'),
      _allocator = DynamicLibrary.open('msvcrt.dll') {
    _calloc = _allocator.lookupFunction<_CallocNative, _CallocDart>('calloc');
    free = _allocator.lookupFunction<_FreeNative, _FreeDart>('free');
    createJob = _kernel.lookupFunction<_CreateJobNative, _CreateJobDart>(
      'CreateJobObjectW',
    );
    setJob = _kernel.lookupFunction<_SetJobNative, _SetJobDart>(
      'SetInformationJobObject',
    );
    queryJob = _kernel.lookupFunction<_QueryJobNative, _QueryJobDart>(
      'QueryInformationJobObject',
    );
    initAttributes = _kernel.lookupFunction<_InitNative, _InitDart>(
      'InitializeProcThreadAttributeList',
    );
    updateAttribute = _kernel.lookupFunction<_UpdateNative, _UpdateDart>(
      'UpdateProcThreadAttribute',
    );
    deleteAttributes = _kernel.lookupFunction<_DeleteNative, _DeleteDart>(
      'DeleteProcThreadAttributeList',
    );
    createProcess = _kernel
        .lookupFunction<_CreateProcessNative, _CreateProcessDart>(
          'CreateProcessW',
        );
    resumeThread = _kernel
        .lookupFunction<_ResumeThreadNative, _ResumeThreadDart>('ResumeThread');
    terminateJob = _kernel
        .lookupFunction<_TerminateJobNative, _TerminateJobDart>(
          'TerminateJobObject',
        );
    waitForSingleObject = _kernel.lookupFunction<_WaitNative, _WaitDart>(
      'WaitForSingleObject',
    );
    closeHandle = _kernel.lookupFunction<_CloseHandleNative, _CloseHandleDart>(
      'CloseHandle',
    );
    getLastError = _kernel
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
          'GetLastError',
          isLeaf: true,
        );
  }

  final DynamicLibrary _kernel;
  final DynamicLibrary _allocator;
  late final _CallocDart _calloc;
  late final _FreeDart free;
  late final _CreateJobDart createJob;
  late final _SetJobDart setJob;
  late final _QueryJobDart queryJob;
  late final _InitDart initAttributes;
  late final _UpdateDart updateAttribute;
  late final _DeleteDart deleteAttributes;
  late final _CreateProcessDart createProcess;
  late final _ResumeThreadDart resumeThread;
  late final _TerminateJobDart terminateJob;
  late final _WaitDart waitForSingleObject;
  late final _CloseHandleDart closeHandle;
  late final _GetLastErrorDart getLastError;

  Pointer<Void> calloc(int bytes) {
    final memory = _calloc(1, bytes);
    if (memory == nullptr) throw StateError('Native allocation failed');
    return memory;
  }

  Pointer<Uint16> utf16(String value) {
    final units = value.codeUnits;
    final allocation =
        calloc((units.length + 1) * sizeOf<Uint16>()).cast<Uint16>();
    for (var i = 0; i < units.length; i++) {
      allocation[i] = units[i];
    }
    allocation[units.length] = 0;
    return allocation;
  }

  void check(int result, String operation) {
    if (result == 0) throw lastError(operation);
  }

  void checkHandle(Pointer<Void> handle, String operation) {
    if (handle == nullptr) throw lastError(operation);
  }

  OSError lastError(String operation) => OSError(operation, getLastError());
}

typedef _CallocNative = Pointer<Void> Function(IntPtr, IntPtr);
typedef _CallocDart = Pointer<Void> Function(int, int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _CreateJobNative =
    Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>);
typedef _CreateJobDart = Pointer<Void> Function(Pointer<Void>, Pointer<Uint16>);
typedef _SetJobNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32);
typedef _SetJobDart = int Function(Pointer<Void>, int, Pointer<Void>, int);
typedef _QueryJobNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32, Pointer<Void>);
typedef _QueryJobDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Void>);
typedef _InitNative =
    Int32 Function(Pointer<Void>, Uint32, Uint32, Pointer<IntPtr>);
typedef _InitDart = int Function(Pointer<Void>, int, int, Pointer<IntPtr>);
typedef _UpdateNative =
    Int32 Function(
      Pointer<Void>,
      Uint32,
      IntPtr,
      Pointer<Void>,
      IntPtr,
      Pointer<Void>,
      Pointer<IntPtr>,
    );
typedef _UpdateDart =
    int Function(
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
      int,
      Pointer<Void>,
      Pointer<IntPtr>,
    );
typedef _DeleteNative = Void Function(Pointer<Void>);
typedef _DeleteDart = void Function(Pointer<Void>);
typedef _CreateProcessNative =
    Int32 Function(
      Pointer<Uint16>,
      Pointer<Uint16>,
      Pointer<Void>,
      Pointer<Void>,
      Int32,
      Uint32,
      Pointer<Void>,
      Pointer<Uint16>,
      Pointer<_WindowsStartupInfoEx>,
      Pointer<_WindowsProcessInfo>,
    );
typedef _CreateProcessDart =
    int Function(
      Pointer<Uint16>,
      Pointer<Uint16>,
      Pointer<Void>,
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
      Pointer<Uint16>,
      Pointer<_WindowsStartupInfoEx>,
      Pointer<_WindowsProcessInfo>,
    );
typedef _ResumeThreadNative = Uint32 Function(Pointer<Void>);
typedef _ResumeThreadDart = int Function(Pointer<Void>);
typedef _TerminateJobNative = Int32 Function(Pointer<Void>, Uint32);
typedef _TerminateJobDart = int Function(Pointer<Void>, int);
typedef _WaitNative = Uint32 Function(Pointer<Void>, Uint32);
typedef _WaitDart = int Function(Pointer<Void>, int);
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandleDart = int Function(Pointer<Void>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

String _quoteWindowsArgument(String value) {
  if (value.contains('\u0000')) throw ArgumentError('NUL in process argument');
  final result = StringBuffer('"');
  var slashes = 0;
  for (final unit in value.codeUnits) {
    if (unit == 0x5C) {
      slashes++;
      continue;
    }
    if (unit == 0x22) {
      result.write('\\' * (slashes * 2 + 1));
    } else {
      result.write('\\' * slashes);
    }
    slashes = 0;
    result.writeCharCode(unit);
  }
  result.write('\\' * (slashes * 2));
  result.write('"');
  return result.toString();
}

// ---- macOS FFI: posix_spawn + a new process group --------------------------
