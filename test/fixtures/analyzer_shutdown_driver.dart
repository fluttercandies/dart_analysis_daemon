import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';

Future<void> main(List<String> args) async {
  if (args.contains('fake-server')) {
    await for (final line in stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final request = jsonDecode(line) as Map;
      if (args.contains('exit-during-check') &&
          request['method'] == 'analysis.getErrors') {
        exit(42);
      }
      if (request['method'] == 'server.shutdown') continue;
      stdout.writeln(
        jsonEncode({'id': request['id'], 'result': <String, Object?>{}}),
      );
      await stdout.flush();
    }
    return;
  }
  final serverArguments = [
    '--packages=${args[1]}',
    File.fromUri(Platform.script).path,
    'fake-server',
    if (args.contains('exit-during-check')) 'exit-during-check',
  ];
  final daemon = AnalyzerDaemon(
    args.first,
    processStarter:
        args.contains('windows-ffi-job')
            ? null
            : () => Process.start(Platform.resolvedExecutable, serverArguments),
    ownedProcessStarter:
        args.contains('windows-ffi-job')
            ? () => WindowsFfiAnalyzerProcess.start(
              Platform.resolvedExecutable,
              serverArguments,
              workingDirectory: args.first,
            )
            : null,
  );
  await daemon.start();
  if (args.contains('exit-during-check')) {
    final target = File('${args.first}/probe.dart');
    await target.writeAsString('int value = missing;');
    try {
      await daemon
          .handle({
            'op': 'check',
            'files': [target.path],
          })
          .timeout(const Duration(seconds: 3));
      throw StateError('Abrupt server exit did not fail the check');
    } on StateError catch (error) {
      if (!error.toString().contains('exited with code 42') &&
          !error.toString().contains('stdout closed')) {
        rethrow;
      }
      stdout.writeln('request-failed');
    }
  }
  final firstClose = daemon.close();
  final secondClose = daemon.close();
  if (!identical(firstClose, secondClose)) {
    throw StateError('Concurrent close calls did not share completion');
  }
  await Future.wait([firstClose, secondClose]);
  stdout.writeln('closed');
}
