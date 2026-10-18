import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';

Future<void> main(List<String> args) async {
  final process = await WindowsFfiAnalyzerProcess.start(
    Platform.resolvedExecutable,
    [args[0], 'root', '${args[1]}/leaf'],
    workingDirectory: args[1],
    jobName: args.length > 2 ? args[2] : null,
  );
  process.stderr.drain<void>().ignore();
  final lines = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  if (!await lines.moveNext()) throw StateError('Child failed before ready');
  stdout.writeln(lines.current);
  await stdout.flush();
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
