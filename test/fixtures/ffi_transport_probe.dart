import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_analysis_daemon/src/analyzer_process_start.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--child')) {
    stdout.writeln(
      jsonEncode({
        'cwd': Directory.current.path,
        'args': args.skip(1).toList(),
      }),
    );
    await for (final chunk in stdin) {
      stdout.add(chunk);
      stderr.add(chunk);
      await Future.wait([stdout.flush(), stderr.flush()]);
    }
    exit(42);
  }
  final directory = await Directory.systemTemp.createTemp('dana ffi 管道 ');
  final script = File.fromUri(Platform.script).path;
  final isAot = script == Platform.resolvedExecutable;
  final process = await startAnalyzerProcess(Platform.resolvedExecutable, [
    if (!isAot)
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
    if (!isAot) script,
    '--child',
    '空 格',
    'quote"value',
    'trailing\\',
  ], workingDirectory: directory.path);
  final output = BytesBuilder();
  final errors = BytesBuilder();
  final outputDone = process.stdout.forEach(output.add);
  final errorDone = process.stderr.forEach(errors.add);
  final payload = utf8.encode(List.filled(65536, '协议😀\n').join());
  try {
    if (process.backend != 'windows-ffi-job') throw StateError('Wrong backend');
    process.stdin.add(payload);
    await process.stdin.flush().timeout(const Duration(seconds: 20));
    await process.stdin.close();
    if (await process.exitCode.timeout(const Duration(seconds: 10)) != 42) {
      throw StateError('Exit code lost');
    }
    await Future.wait([
      outputDone,
      errorDone,
    ]).timeout(const Duration(seconds: 10));
    final all = output.takeBytes();
    final newline = all.indexOf(10);
    final ready = jsonDecode(utf8.decode(all.sublist(0, newline))) as Map;
    if (ready['cwd'] != directory.path ||
        jsonEncode(ready['args']) !=
            jsonEncode(['空 格', 'quote"value', 'trailing\\'])) {
      throw StateError('Arguments/cwd lost: $ready');
    }
    if (base64Encode(all.sublist(newline + 1)) != base64Encode(payload) ||
        base64Encode(errors.takeBytes()) != base64Encode(payload)) {
      throw StateError('Byte transport mismatch');
    }
    final close = process.terminate();
    if (!identical(close, process.terminate())) {
      throw StateError('Close not shared');
    }
    await close;
    stdout.writeln(
      jsonEncode({
        'backend': process.backend,
        'bytesPerStream': payload.length,
        'exitCode': 42,
        'singleAot': isAot,
        'ok': true,
      }),
    );
  } finally {
    await process.terminate();
    await directory.delete(recursive: true);
  }
}
