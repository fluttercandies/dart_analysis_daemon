import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  if (!Platform.isWindows) throw UnsupportedError('Windows test driver');
  final directory = await Directory.systemTemp.createTemp('dana ffi 单文件 ');
  stdout.writeln('artifactDirectory=${directory.path}');
  final source =
      '${Directory.current.path}/tool/ffi_process_ownership_poc.dart';
  final dart = Platform.resolvedExecutable;
  final exe = '${directory.path}/ownership 空格.exe';
  final records = <Map<String, Object?>>[];
  Future<Map<String, dynamic>> run(
    String label,
    String executable,
    List<String> args,
  ) async {
    final process = await Process.start(
      executable,
      args,
      workingDirectory: directory.path,
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 30));
      final out = await output;
      final err = await errors;
      if (code != 0 || err.isNotEmpty) {
        throw StateError('$label code=$code stdout=$out stderr=$err');
      }
      final value = jsonDecode(out.trim()) as Map<String, dynamic>;
      if (value['activeAfter'] != 0 || value['atomicJobList'] != true) {
        throw StateError('$label unexpected result: $value');
      }
      records.add({'label': label, ...value});
      stdout.writeln('$label passed');
      return value;
    } finally {
      process.kill();
    }
  }

  Future<void> gone(List<int> members) async {
    final clock = Stopwatch()..start();
    while (true) {
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '@(Get-Process -Id ${members.join(',')} -ErrorAction SilentlyContinue).Count',
      ]);
      if (result.exitCode != 0 || result.stdout.toString().trim() != '0') {
        if (clock.elapsed > const Duration(seconds: 8)) {
          throw StateError('Processes remain observable: $members');
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      } else {
        return;
      }
    }
  }

  final jit = await run('jit', dart, [source]);
  await gone((jit['jobProcessIdsBefore'] as List).cast<int>());
  final compiled = await Process.run(dart, [
    'compile',
    'exe',
    source,
    '-o',
    exe,
  ]);
  if (compiled.exitCode != 0) {
    throw StateError('AOT compilation failed: ${compiled.stderr}');
  }
  final artifacts = await directory.list().toList();
  if (artifacts.length != 1 ||
      !await FileSystemEntity.identical(artifacts.single.path, exe)) {
    throw StateError('Expected a single executable without native sidecars');
  }
  final aot = await run('aot-single-file', exe, []);
  await gone((aot['jobProcessIdsBefore'] as List).cast<int>());
  final rootExit = await run('aot-root-exits-first', exe, ['--test-root-exit']);
  if (rootExit['rootExitedBeforeCleanup'] != true) {
    throw StateError('Root exit scenario did not run');
  }
  await gone((rootExit['jobProcessIdsBefore'] as List).cast<int>());

  final owner = await Process.start(exe, [
    '--test-owner-crash',
  ], workingDirectory: directory.path);
  final errors = owner.stderr.transform(utf8.decoder).join();
  final lines = StreamIterator(
    owner.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  List<int> members = [];
  try {
    if (!await lines.moveNext().timeout(const Duration(seconds: 15))) {
      throw StateError('Crash owner exited before ready');
    }
    final ready = jsonDecode(lines.current) as Map<String, dynamic>;
    if (ready['ownerPid'] != owner.pid) {
      throw StateError('Owner PID mismatch');
    }
    members = (ready['members'] as List).cast<int>();
    if (!owner.kill()) throw StateError('Could not stop PoC owner');
    await owner.exitCode.timeout(const Duration(seconds: 8));
    await gone(members);
    if ((await errors).isNotEmpty) {
      throw StateError('Crash owner stderr not empty');
    }
    records.add({
      'label': 'aot-owner-crash',
      'membersGone': members,
      'observedJobZero': false,
    });
    stdout.writeln('aot-owner-crash passed');
  } finally {
    owner.kill();
    await lines.cancel();
  }
  await File(
    '${directory.path}/results.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(records));
  stdout.writeln('ffi-ownership-check passed');
}
