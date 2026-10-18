import 'dart:io';
import 'package:test/test.dart';

void main() {
  test(
    'retired helper backend fails with migration advice before launch',
    () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['test/fixtures/retired_backend_probe.dart'],
        environment: {'DANA_PROCESS_BACKEND': 'windows-job'},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('use windows-ffi-job instead'));
    },
  );
}
