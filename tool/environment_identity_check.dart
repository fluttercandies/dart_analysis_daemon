// Read-only configuration scan timing. Never starts an analyzer or writes roots.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_analysis_daemon/src/environment_identity.dart';

Future<void> main(List<String> args) async {
  final manifest =
      jsonDecode(
            await File(
              '../benchmarks/minimal-plugin/worktree-flutter-fixture1.json',
            ).readAsString(),
          )
          as Map;
  final roots =
      args.isEmpty
          ? [
            for (final record in manifest['roots'] as List)
              (record as Map)['root'] as String,
          ]
          : args;
  final directory = await Directory.systemTemp.createTemp('dana-config-scan-');
  final records = <Map<String, Object?>>[];
  try {
    for (final root in roots) {
      String? expected;
      for (var run = 0; run < 3; run++) {
        final clock = Stopwatch()..start();
        final key = await _capture(root);
        if (expected != null && expected != key) {
          throw StateError(
            'Configuration changed between read-only captures: $root',
          );
        }
        expected = key;
        records.add({
          'root': root,
          'run': run,
          'elapsedMs': clock.elapsedMilliseconds,
          'identity': key,
        });
      }
    }
  } catch (error) {
    records.add({'error': '$error'});
    exitCode = 1;
  } finally {
    final file = File('${directory.path}/results.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'sdk': Platform.version,
        'readOnly': true,
        'analyzerStarted': false,
        'records': records,
      }),
    );
    stdout.writeln('results: ${file.path}');
  }
}

Future<String> _capture(String root) =>
    Isolate.run(() => EnvironmentIdentity().capture(root));
