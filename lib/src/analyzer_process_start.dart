import 'dart:io';

import 'analyzer_process.dart';
import 'windows_ffi_process.dart';

Future<AnalyzerProcess> startAnalyzerProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  final backend = Platform.environment['DANA_PROCESS_BACKEND'] ?? 'direct';
  switch (backend) {
    case 'direct':
      return DirectAnalyzerProcess(
        await Process.start(
          executable,
          arguments,
          workingDirectory: workingDirectory,
        ),
      );
    case 'windows-job':
      throw FormatException(
        'DANA_PROCESS_BACKEND=windows-job was removed; use windows-ffi-job instead.',
      );
    case 'windows-ffi-job':
      return WindowsFfiAnalyzerProcess.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
    default:
      throw FormatException('Unknown DANA_PROCESS_BACKEND: $backend');
  }
}
