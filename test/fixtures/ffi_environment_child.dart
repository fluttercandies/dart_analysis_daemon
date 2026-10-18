import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    final child = await Process.run(
      Platform.resolvedExecutable,
      [Platform.script.toFilePath(), 'child'],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (child.exitCode != 0) throw StateError('${child.stderr}');
    stdout.write(child.stdout);
    return;
  }
  stdout.writeln(
    jsonEncode({
      'probe': Platform.environment['DANA_FFI_ENV_PROBE'],
      'pathPresent': Platform.environment['PATH']?.isNotEmpty,
      'sdkState': Platform.environment['ANALYZER_STATE_LOCATION_OVERRIDE'],
    }),
  );
}
