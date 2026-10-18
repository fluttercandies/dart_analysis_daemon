// Run with `dart tool/ffi_process_ownership_poc.dart`.
// The same file supports --root-child and --leaf-child as private test modes.
// This PoC only proves OS process ownership; it intentionally does not bridge
// analyzer stdin/stdout/stderr into Dart streams.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

const _childRoot = '--root-child';
const _leafChild = '--leaf-child';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == _leafChild) {
    await File(args[1]).writeAsString('$pid');
    Timer.periodic(const Duration(seconds: 1), (_) {});
    return;
  }
  if (args.isNotEmpty && args.first == _childRoot) {
    final childPidFile = args[1];
    final leafFile = File(childPidFile);
    final escapeGroup = args.length > 2 && args[2] == 'escape';
    final childArguments = _scriptArguments(_leafChild, childPidFile);
    final child = await Process.start(
      Platform.resolvedExecutable,
      childArguments,
      mode: escapeGroup ? ProcessStartMode.detached : ProcessStartMode.normal,
    );
    if (!escapeGroup) {
      child.stdout.drain<void>().ignore();
      child.stderr.drain<void>().ignore();
    }
    final childPid = child.pid;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await leafFile.exists()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Leaf did not start');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await File('$childPidFile.ready').writeAsString(
      jsonEncode({
        'rootPid': pid,
        'leafPid': childPid,
        'leafReportedPid': int.parse(await leafFile.readAsString()),
        'escapedGroup': escapeGroup,
        'arguments': args.skip(2).toList(),
      }),
    );
    if (args.contains('exit-root')) exit(42);
    Timer.periodic(const Duration(seconds: 1), (_) {});
    return;
  }

  if (Platform.isWindows) {
    await _runWindowsPoc(
      crashOwner: args.contains('--test-owner-crash'),
      rootExits: args.contains('--test-root-exit'),
    );
  } else if (Platform.isMacOS) {
    await _runMacPoc(escape: args.contains('--mac-test-escape'));
  } else {
    throw UnsupportedError('This PoC currently targets Windows and macOS.');
  }
}

List<String> _scriptArguments(String mode, String path) {
  final script = Platform.script;
  final executable = File(Platform.resolvedExecutable).uri;
  if (script.scheme == 'file' &&
      script.toFilePath() != executable.toFilePath()) {
    return [script.toFilePath(), mode, path];
  }
  return [mode, path];
}

Future<void> _runWindowsPoc({
  bool crashOwner = false,
  bool rootExits = false,
}) async {
  final directory = await Directory.systemTemp.createTemp('dana-ffi-job-poc-');
  final marker = File('${directory.path}/leaf.pid');
  final ready = File('${marker.path}.ready');
  final job = _WindowsJob.start(Platform.resolvedExecutable, [
    ..._scriptArguments(_childRoot, marker.path),
    '空 格',
    'quote"value',
    'trailing\\',
    if (rootExits) 'exit-root',
  ]);
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (!await ready.exists()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Child tree did not publish its ready marker');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final childIds =
        jsonDecode(await ready.readAsString()) as Map<String, dynamic>;
    if (jsonEncode(childIds['arguments']) !=
        jsonEncode([
          '空 格',
          'quote"value',
          'trailing\\',
          if (rootExits) 'exit-root',
        ])) {
      throw StateError('FFI command-line argument round trip failed');
    }
    final activeBefore = job.activeProcesses;
    if (activeBefore < (rootExits ? 1 : 2)) {
      throw StateError(
        'Expected root and descendant in Job; saw $activeBefore',
      );
    }
    final members = job.processIds;
    if ((!rootExits &&
            (!members.contains(job.rootPid) ||
                !members.contains(childIds['rootPid']))) ||
        !members.contains(childIds['leafReportedPid'])) {
      throw StateError('Job did not contain root and descendants: $members');
    }
    if (rootExits) {
      final clock = Stopwatch()..start();
      while (job._api.waitForSingleObject(job._process, 0) != 0) {
        if (clock.elapsed > const Duration(seconds: 8)) {
          throw TimeoutException('PoC root did not exit');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (!job.processIds.contains(childIds['leafReportedPid'])) {
        throw StateError('Expected leaf to survive root exit inside Job');
      }
    }
    if (crashOwner) {
      stdout.writeln(
        jsonEncode({
          'ownerPid': pid,
          'members': members,
          'controlDirectory': directory.path,
          'event': 'crash-ready',
        }),
      );
      await stdout.flush();
      // The driver kills this exact process; no finally or explicit terminate.
      Timer.periodic(const Duration(seconds: 1), (_) {});
      await Completer<void>().future;
    }
    await job.terminateAndWait();
    if (job.activeProcesses != 0) {
      throw StateError('Job active process count did not return to zero');
    }
    stdout.writeln(
      jsonEncode({
        'backend': 'windows-ffi-job-list',
        'rootPid': childIds['rootPid'],
        'leafPid': childIds['leafPid'],
        'leafReportedPid': childIds['leafReportedPid'],
        'jobProcessIdsBefore': members,
        'activeBefore': activeBefore,
        'activeAfter': job.activeProcesses,
        'atomicJobList': true,
        'rootExitedBeforeCleanup': rootExits,
        'nativeHelpersShipped': false,
      }),
    );
  } finally {
    await job.close();
    await directory.delete(recursive: true);
  }
}

Future<void> _runMacPoc({bool escape = false}) async {
  final directory = await Directory.systemTemp.createTemp(
    'dana-ffi-pgroup-poc-',
  );
  final marker = File('${directory.path}/leaf.pid');
  final ready = File('${marker.path}.ready');
  final group = _MacProcessGroup.start(Platform.resolvedExecutable, [
    ..._scriptArguments(_childRoot, marker.path),
    if (escape) 'escape',
  ], Platform.environment);
  int? escapedLeaf;
  try {
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (!await ready.exists()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Child tree did not publish its ready marker');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final childIds =
        jsonDecode(await ready.readAsString()) as Map<String, dynamic>;
    if (escape) escapedLeaf = childIds['leafReportedPid'] as int;
    final rootGroup = group._api.getProcessGroup(group.pid);
    final leafGroup = group._api.getProcessGroup(
      childIds['leafReportedPid'] as int,
    );
    if (rootGroup != group.pid ||
        (escape ? leafGroup == group.pid : leafGroup != group.pid)) {
      throw StateError(
        'Unexpected process groups root=$rootGroup leaf=$leafGroup',
      );
    }
    await group.terminateAndWait();
    var escapeSurvived = false;
    if (escape) {
      final escapedPid = childIds['leafReportedPid'] as int;
      escapeSurvived = group._api.kill(escapedPid, 0) == 0;
      if (escapeSurvived) {
        group._api.check(group._api.kill(escapedPid, 15), 'kill(escaped leaf)');
        final escapeDeadline = DateTime.now().add(const Duration(seconds: 5));
        while (group._api.kill(escapedPid, 0) == 0 || group._api.errno != 3) {
          if (DateTime.now().isAfter(escapeDeadline)) {
            throw TimeoutException('Escaped PoC leaf did not exit');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
    }
    stdout.writeln(
      jsonEncode({
        'backend': 'macos-ffi-posix-process-group',
        'rootPid': childIds['rootPid'],
        'leafPid': childIds['leafPid'],
        'groupAbsentAfterSignal': true,
        'setsidEscapeSurvivedGroupSignal': escapeSurvived,
        'rootProcessGroup': rootGroup,
        'leafProcessGroup': leafGroup,
        'setsidEscapeContained': false,
        'nativeHelpersShipped': false,
      }),
    );
  } finally {
    if (escapedLeaf != null && group._api.kill(escapedLeaf, 0) == 0) {
      group._api.kill(escapedLeaf, 9);
    }
    await group.close();
    await directory.delete(recursive: true);
  }
}

// ---- Windows FFI: CreateProcessW + PROC_THREAD_ATTRIBUTE_JOB_LIST ---------

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

final class _WindowsJob {
  _WindowsJob._(this._api, this._job, this._process, this.rootPid);

  final _WindowsApi _api;
  final Pointer<Void> _job;
  final Pointer<Void> _process;
  final int rootPid;
  bool _closed = false;

  int get activeProcesses {
    final information = _api.calloc(sizeOf<_WindowsJobAccounting>());
    try {
      _api.check(
        _api.queryJob(
          _job,
          1,
          information,
          sizeOf<_WindowsJobAccounting>(),
          nullptr,
        ),
        'QueryInformationJobObject',
      );
      return information.cast<_WindowsJobAccounting>().ref.activeProcesses;
    } finally {
      _api.free(information);
    }
  }

  List<int> get processIds {
    final information = _api.calloc(4096);
    try {
      _api.check(
        _api.queryJob(_job, 3, information, 4096, nullptr),
        'QueryInformationJobObject(BASIC_PROCESS_ID_LIST)',
      );
      final count = information.cast<Uint32>()[1];
      if (count > 400) throw StateError('Unexpected Job process count $count');
      return [
        for (var i = 0; i < count; i++) information.cast<IntPtr>()[1 + i],
      ];
    } finally {
      _api.free(information);
    }
  }

  static _WindowsJob start(String executable, List<String> arguments) {
    final api = _WindowsApi();
    final job = api.createJob(nullptr, nullptr);
    api.checkHandle(job, 'CreateJobObjectW');
    Pointer<Void> process = nullptr;
    Pointer<Void> thread = nullptr;
    Pointer<Void> attributes = nullptr;
    var initializedAttributes = false;
    final attributeBytes = api.calloc(sizeOf<IntPtr>()).cast<IntPtr>();
    final jobList = api.calloc(sizeOf<IntPtr>()).cast<Pointer<Void>>();
    Pointer<Uint16> appName = nullptr;
    Pointer<Uint16> commandLine = nullptr;
    try {
      final limits = api.calloc(sizeOf<_WindowsJobExtendedLimits>());
      try {
        limits.cast<_WindowsJobExtendedLimits>().ref.basic.limitFlags = 0x2000;
        api.check(
          api.setJob(job, 9, limits, sizeOf<_WindowsJobExtendedLimits>()),
          'SetInformationJobObject(KILL_ON_JOB_CLOSE)',
        );
      } finally {
        api.free(limits);
      }

      api.initAttributes(nullptr, 1, 0, attributeBytes);
      if (attributeBytes.value <= 0 || attributeBytes.value > 1048576) {
        throw StateError('Invalid attribute list size');
      }
      attributes = api.calloc(attributeBytes.value);
      api.check(
        api.initAttributes(attributes, 1, 0, attributeBytes),
        'InitializeProcThreadAttributeList',
      );
      initializedAttributes = true;
      jobList.value = job;
      api.check(
        api.updateAttribute(
          attributes,
          0,
          0x2000D,
          jobList.cast<Void>(),
          sizeOf<IntPtr>(),
          nullptr,
          nullptr,
        ),
        'UpdateProcThreadAttribute(JOB_LIST)',
      );

      appName = api.utf16(executable);
      commandLine = api.utf16(
        [executable, ...arguments].map(_quoteWindowsArgument).join(' '),
      );
      final startup = api.calloc(sizeOf<_WindowsStartupInfoEx>());
      final processInfo = api.calloc(sizeOf<_WindowsProcessInfo>());
      try {
        final extended = startup.cast<_WindowsStartupInfoEx>().ref;
        extended.startupInfo.cb = sizeOf<_WindowsStartupInfoEx>();
        extended.attributes = attributes;
        api.check(
          api.createProcess(
            appName,
            commandLine,
            nullptr,
            nullptr,
            0,
            0x08080004, // CREATE_NO_WINDOW | EXTENDED_STARTUPINFO | SUSPENDED
            nullptr,
            nullptr,
            startup.cast<_WindowsStartupInfoEx>(),
            processInfo.cast<_WindowsProcessInfo>(),
          ),
          'CreateProcessW(JOB_LIST, CREATE_SUSPENDED)',
        );
        process = processInfo.cast<_WindowsProcessInfo>().ref.process;
        thread = processInfo.cast<_WindowsProcessInfo>().ref.thread;
        final processId = processInfo.cast<_WindowsProcessInfo>().ref.processId;
        if (activeProcessesFor(api, job) != 1 ||
            !processIdsFor(api, job).contains(processId)) {
          throw StateError('Suspended process did not enter the Job');
        }
        if (api.resumeThread(thread) == 0xFFFFFFFF) {
          throw api.lastError('ResumeThread');
        }
        api.closeHandle(thread);
        thread = nullptr;
        return _WindowsJob._(api, job, process, processId);
      } finally {
        api.free(startup);
        api.free(processInfo);
      }
    } catch (_) {
      if (thread != nullptr) api.closeHandle(thread);
      if (process != nullptr) api.closeHandle(process);
      if (job != nullptr) api.closeHandle(job); // Crash-safe cleanup backstop.
      rethrow;
    } finally {
      if (initializedAttributes) api.deleteAttributes(attributes);
      if (attributes != nullptr) api.free(attributes);
      api.free(attributeBytes.cast<Void>());
      api.free(jobList.cast<Void>());
      for (final memory in [appName, commandLine]) {
        if (memory != nullptr) api.free(memory.cast<Void>());
      }
    }
  }

  static int activeProcessesFor(_WindowsApi api, Pointer<Void> job) {
    final information = api.calloc(sizeOf<_WindowsJobAccounting>());
    try {
      api.check(
        api.queryJob(
          job,
          1,
          information,
          sizeOf<_WindowsJobAccounting>(),
          nullptr,
        ),
        'QueryInformationJobObject',
      );
      return information.cast<_WindowsJobAccounting>().ref.activeProcesses;
    } finally {
      api.free(information);
    }
  }

  static List<int> processIdsFor(_WindowsApi api, Pointer<Void> job) {
    final information = api.calloc(4096);
    try {
      api.check(
        api.queryJob(job, 3, information, 4096, nullptr),
        'QueryInformationJobObject(BASIC_PROCESS_ID_LIST)',
      );
      final count = information.cast<Uint32>()[1];
      if (count > 400) throw StateError('Unexpected Job process count $count');
      return [
        for (var i = 0; i < count; i++) information.cast<IntPtr>()[i + 1],
      ];
    } finally {
      api.free(information);
    }
  }

  Future<void> terminateAndWait() async {
    _api.check(_api.terminateJob(_job, 90), 'TerminateJobObject');
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (activeProcesses != 0) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'Windows Job active process count did not reach zero',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    while (true) {
      final state = _api.waitForSingleObject(_process, 0);
      if (state == 0) break;
      if (state != 0x102) throw _api.lastError('WaitForSingleObject');
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('Job empty but root exit not yet confirmed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      if (activeProcesses != 0) await terminateAndWait();
    } finally {
      _api.closeHandle(_process);
      _api.closeHandle(_job);
    }
  }
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
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
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

  StateError lastError(String operation) =>
      StateError('$operation failed: Win32 error ${getLastError()}');
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

final class _MacProcessGroup {
  _MacProcessGroup._(this._api, this.pid);

  final _MacApi _api;
  final int pid;
  bool _closed = false;
  bool _terminated = false;

  static _MacProcessGroup start(
    String executable,
    List<String> arguments,
    Map<String, String> environment,
  ) {
    final api = _MacApi();
    // Darwin defines posix_spawnattr_t as void*. Every attr API (including
    // posix_spawn itself) receives the address of that opaque pointer.
    final attributes = api.calloc(sizeOf<IntPtr>());
    Pointer<Pointer<Uint8>>? argv;
    Pointer<Pointer<Uint8>>? envp;
    final allocatedStrings = <Pointer<Void>>[];
    var initialized = false;
    try {
      api.check(api.initAttributes(attributes), 'posix_spawnattr_init');
      initialized = true;
      api.check(api.setGroup(attributes, 0), 'posix_spawnattr_setpgroup');
      api.check(
        api.setFlags(attributes, 0x0002),
        'posix_spawnattr_setflags(SETPGROUP)',
      );

      argv = api.stringVector([executable, ...arguments], allocatedStrings);
      envp = api.stringVector(
        environment.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .toList(),
        allocatedStrings,
      );
      final path = api.utf8(executable);
      allocatedStrings.add(path.cast<Void>());
      final processId = api.calloc(sizeOf<Int32>()).cast<Int32>();
      try {
        api.check(
          api.spawn(processId, path, nullptr, attributes, argv, envp),
          'posix_spawn',
        );
        return _MacProcessGroup._(api, processId.value);
      } finally {
        api.free(processId.cast<Void>());
      }
    } finally {
      if (argv != null) api.free(argv.cast<Void>());
      if (envp != null) api.free(envp.cast<Void>());
      // argv/env strings remain valid until posix_spawn returns; free now.
      if (initialized) {
        api.destroyAttributes(attributes);
      }
      api.free(attributes);
      for (final pointer in allocatedStrings) {
        api.free(pointer);
      }
    }
  }

  Future<void> terminateAndWait() async {
    if (_terminated) return;
    final status = _api.calloc(sizeOf<Int32>()).cast<Int32>();
    try {
      _signal(15);
      final clock = Stopwatch()..start();
      var escalated = false;
      while (true) {
        // Reap the direct child without blocking the isolate. A zombie root
        // can otherwise keep its process group observable until timeout.
        final waited = _api.waitPid(pid, status, 1); // WNOHANG
        if (waited < 0 && _api.errno != 10 && _api.errno != 4) {
          throw StateError('waitpid failed: errno=${_api.errno}');
        }
        if (_api.kill(-pid, 0) != 0) {
          final error = _api.errno;
          if (error == 3) {
            _terminated = true;
            break; // ESRCH
          }
          throw StateError('Process group observation failed: errno=$error');
        }
        if (!escalated && clock.elapsed > const Duration(seconds: 3)) {
          _signal(9);
          escalated = true;
        }
        if (clock.elapsed > const Duration(seconds: 8)) {
          throw TimeoutException('macOS process group remained observable');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      _api.free(status.cast<Void>());
    }
  }

  void _signal(int signal) {
    if (_api.kill(-pid, signal) != 0 && _api.errno != 3) {
      throw StateError('kill(-pgid, $signal) failed: errno=${_api.errno}');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await terminateAndWait();
  }
}

final class _MacApi {
  _MacApi() : _system = DynamicLibrary.open('/usr/lib/libSystem.B.dylib') {
    _malloc = _system.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _free = _system.lookupFunction<_FreeNative, _FreeDart>('free');
    initAttributes = _system
        .lookupFunction<_SpawnAttrInitNative, _SpawnAttrInitDart>(
          'posix_spawnattr_init',
        );
    destroyAttributes = _system
        .lookupFunction<_SpawnAttrDestroyNative, _SpawnAttrDestroyDart>(
          'posix_spawnattr_destroy',
        );
    setFlags = _system
        .lookupFunction<_SpawnAttrFlagsNative, _SpawnAttrFlagsDart>(
          'posix_spawnattr_setflags',
        );
    setGroup = _system
        .lookupFunction<_SpawnAttrGroupNative, _SpawnAttrGroupDart>(
          'posix_spawnattr_setpgroup',
        );
    spawn = _system.lookupFunction<_SpawnNative, _SpawnDart>('posix_spawn');
    kill = _system.lookupFunction<_KillNative, _KillDart>('kill');
    getpgid = _system.lookupFunction<_GetPgidNative, _GetPgidDart>('getpgid');
    waitPid = _system.lookupFunction<_WaitPidNative, _WaitPidDart>('waitpid');
    _errno = _system.lookupFunction<_ErrnoNative, _ErrnoDart>('__error');
  }

  final DynamicLibrary _system;
  late final _MallocDart _malloc;
  late final _FreeDart _free;
  late final _ErrnoDart _errno;
  late final _SpawnAttrInitDart initAttributes;
  late final _SpawnAttrDestroyDart destroyAttributes;
  late final _SpawnAttrFlagsDart setFlags;
  late final _SpawnAttrGroupDart setGroup;
  late final _SpawnDart spawn;
  late final _KillDart kill;
  late final _GetPgidDart getpgid;
  late final _WaitPidDart waitPid;

  int get errno => _errno().value;
  int getProcessGroup(int processId) => getpgid(processId);

  Pointer<Void> calloc(int bytes) {
    final result = _malloc(bytes);
    if (result == nullptr) throw StateError('libSystem malloc failed');
    result.cast<Uint8>().asTypedList(bytes).fillRange(0, bytes, 0);
    return result;
  }

  void free(Pointer<Void> value) {
    if (value != nullptr) _free(value);
  }

  Pointer<Uint8> utf8(String value) {
    final bytes = utf8Encode(value);
    final result = calloc(bytes.length + 1).cast<Uint8>();
    result.asTypedList(bytes.length + 1).setRange(0, bytes.length, bytes);
    result[bytes.length] = 0;
    return result;
  }

  Pointer<Pointer<Uint8>> stringVector(
    List<String> values,
    List<Pointer<Void>> allocated,
  ) {
    final result =
        calloc((values.length + 1) * sizeOf<IntPtr>()).cast<Pointer<Uint8>>();
    for (var i = 0; i < values.length; i++) {
      final string = utf8(values[i]);
      allocated.add(string.cast<Void>());
      result[i] = string;
    }
    result[values.length] = nullptr;
    return result;
  }

  void check(int code, String operation) {
    if (code != 0) throw StateError('$operation failed with errno=$code');
  }
}

List<int> utf8Encode(String value) => utf8.encode(value);

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _MallocDart = Pointer<Void> Function(int);
typedef _SpawnAttrInitNative = Int32 Function(Pointer<Void>);
typedef _SpawnAttrInitDart = int Function(Pointer<Void>);
typedef _SpawnAttrDestroyNative = Int32 Function(Pointer<Void>);
typedef _SpawnAttrDestroyDart = int Function(Pointer<Void>);
typedef _SpawnAttrFlagsNative = Int32 Function(Pointer<Void>, Int16);
typedef _SpawnAttrFlagsDart = int Function(Pointer<Void>, int);
typedef _SpawnAttrGroupNative = Int32 Function(Pointer<Void>, Int32);
typedef _SpawnAttrGroupDart = int Function(Pointer<Void>, int);
typedef _SpawnNative =
    Int32 Function(
      Pointer<Int32>,
      Pointer<Uint8>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<Pointer<Uint8>>,
    );
typedef _SpawnDart =
    int Function(
      Pointer<Int32>,
      Pointer<Uint8>,
      Pointer<Void>,
      Pointer<Void>,
      Pointer<Pointer<Uint8>>,
      Pointer<Pointer<Uint8>>,
    );
typedef _KillNative = Int32 Function(Int32, Int32);
typedef _KillDart = int Function(int, int);
typedef _GetPgidNative = Int32 Function(Int32);
typedef _GetPgidDart = int Function(int);
typedef _WaitPidNative = Int32 Function(Int32, Pointer<Int32>, Int32);
typedef _WaitPidDart = int Function(int, Pointer<Int32>, int);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();
