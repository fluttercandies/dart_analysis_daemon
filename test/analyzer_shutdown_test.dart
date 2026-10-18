import 'dart:io';

import 'package:test/test.dart';

void main() {
  final dartExecutable =
      Platform.environment['DANA_TEST_DART_EXECUTABLE'] ??
      Platform.resolvedExecutable;
  for (final backend in ['direct', if (Platform.isWindows) 'windows-ffi-job']) {
    for (final mode in ['unanswered-shutdown', 'exit-during-check']) {
      test('$backend shutdown releases timers after $mode', () async {
        final root = await Directory.systemTemp.createTemp('dana-shutdown-');
        addTearDown(() => root.delete(recursive: true));
        final process = await Process.start(
          dartExecutable,
          [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            '${Directory.current.path}/test/fixtures/analyzer_shutdown_driver.dart',
            root.path,
            '${Directory.current.path}/.dart_tool/package_config.json',
            if (mode == 'exit-during-check') mode,
            if (backend != 'direct') backend,
          ],
          environment: {'DANA_ANALYSIS_TIMEOUT_SECONDS': '120'},
        );
        final output = process.stdout.toList();
        final errors = process.stderr.toList();
        try {
          expect(
            await process.exitCode.timeout(const Duration(seconds: 12)),
            0,
          );
          expect(
            String.fromCharCodes(
              (await output).expand((chunk) => chunk).toList(),
            ),
            contains('closed'),
          );
          expect(await errors, isEmpty);
        } finally {
          process.kill();
        }
      });
    }
  }
}
