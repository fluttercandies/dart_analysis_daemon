// Subprocess fixture exercising the real detached session startup path.
// The analyzer is controlled; this never launches a language server.
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/analyzer_daemon.dart';
import 'package:dart_analysis_daemon/src/session_client.dart';
import 'package:dart_analysis_daemon/src/session_server.dart';

class _Analyzer extends AnalyzerDaemon {
  _Analyzer(super.root);

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, Object?>> handle(Map<String, Object?> command) async => {
    'ok': true,
    'sessionPid': pid,
  };

  @override
  Future<void> close() async {
    if (Platform.environment['DANA_TEST_CLOSE_FAILURE'] == '1') {
      throw StateError('Injected subprocess close failure');
    }
    final closing = File('$root/closing-$pid');
    await closing.writeAsString('closing');
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (!await File('$root/release-close').exists() &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.first == 'serve') {
    final root = args[args.indexOf('--root') + 1];
    await serveSession(
      root,
      startupToken: args[args.indexOf('--startup-token') + 1],
      analyzer: _Analyzer(root),
    );
    return;
  }
  await File('${args[1]}/client-entered').writeAsString('$pid');
  final client = await SessionClient.connect(args[1]);
  try {
    stdout.writeln(jsonEncode(await client.status()));
  } finally {
    await client.close();
  }
}
