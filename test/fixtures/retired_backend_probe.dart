import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_process_start.dart';

Future<void> main() async {
  try {
    await startAnalyzerProcess('must-not-launch', [], workingDirectory: '.');
    exitCode = 1;
  } on FormatException catch (error) {
    stdout.writeln(error.message);
  }
}
