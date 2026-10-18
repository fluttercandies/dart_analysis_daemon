import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';
import 'package:test/test.dart';

void main() {
  if (!Platform.isWindows) return;
  final dart =
      Platform.environment['DANA_TEST_DART_EXECUTABLE'] ??
      Platform.resolvedExecutable;
  for (final phase in ['startup', 'check']) {
    for (final event in ['server.pluginError', 'server.error', 'malformed']) {
      test('$event during $phase fails and cannot reuse that worker', () async {
        final root = await Directory.systemTemp.createTemp(
          'dana-protocol-fault-',
        );
        final file = await File(
          '${root.path}/probe.dart',
        ).writeAsString('int v = 1;');
        final daemon = AnalyzerDaemon(
          root.path,
          ownedProcessStarter:
              () => WindowsFfiAnalyzerProcess.start(dart, [
                '${Directory.current.path}/test/fixtures/analyzer_fault_server.dart',
                phase,
                event,
              ], workingDirectory: root.path),
        );
        try {
          if (phase == 'startup') {
            await expectLater(daemon.start(), throwsA(anything));
          } else {
            await daemon.start();
            await expectLater(
              daemon.handle({
                'op': 'check',
                'files': [file.path],
              }),
              throwsA(anything),
            );
            await expectLater(
              daemon.handle({
                'op': 'check',
                'files': [file.path],
              }),
              throwsStateError,
            );
            await expectLater(
              daemon.handle({'op': 'fullCheck'}),
              throwsStateError,
            );
            expect((await daemon.handle({'op': 'status'}))['healthy'], false);
          }
        } finally {
          await daemon.close();
          await root.delete(recursive: true);
        }
      });
    }
  }
}
