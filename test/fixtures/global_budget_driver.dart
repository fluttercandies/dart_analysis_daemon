import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/cli.dart';
import 'package:dart_analysis_daemon/src/global_budget_service.dart';
import 'package:dart_analysis_daemon/src/system_memory.dart';
import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';
import 'package:dart_analysis_daemon/src/session_client.dart';
import 'package:dart_analysis_daemon/src/runtime.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--api-check') {
    final client = await SessionClient.connect(args[1]);
    try {
      stdout.writeln(jsonEncode(await client.checkFiles([args[2]])));
    } finally {
      await client.close();
    }
    return;
  }
  if (args.contains('--fake-analyzer')) {
    final sdkState = Platform.environment['ANALYZER_STATE_LOCATION_OVERRIDE'];
    if (sdkState == null) throw StateError('Missing managed SDK state');
    await File(
      '$sdkState/worker-environment.json',
    ).writeAsString(jsonEncode({'sdkState': sdkState, 'pid': pid}));
    await for (final line in stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final request = jsonDecode(line) as Map;
      if (request['method'] == 'analysis.getErrors') {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      stdout.writeln(
        jsonEncode({
          'id': request['id'],
          'result':
              request['method'] == 'analysis.getErrors'
                  ? {'errors': <Object>[]}
                  : <String, Object>{},
        }),
      );
      await stdout.flush();
      if (request['method'] == 'server.shutdown') return;
    }
    return;
  }
  if (args.length == 2 && args[0] == 'budget' && args[1] == 'serve') {
    await serveGlobalBudget(
      // Lightweight fixture tests ownership and routing, not machine admission.
      memorySampler:
          () => SystemMemorySnapshot(
            totalPhysicalBytes: 16384 * bytesPerMiB,
            availablePhysicalBytes: 12000 * bytesPerMiB,
            commitLimitBytes: 32768 * bytesPerMiB,
            availableCommitBytes: 12000 * bytesPerMiB,
          ),
      startOwnedWorker:
          (root, jobName, sdkState) => WindowsFfiAnalyzerProcess.start(
            Platform.resolvedExecutable,
            selfProcessArguments(['--fake-analyzer']),
            workingDirectory: root,
            jobName: jobName,
            environment: {'ANALYZER_STATE_LOCATION_OVERRIDE': sdkState},
          ),
    );
  } else {
    await cliMain(args);
  }
}
