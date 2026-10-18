// Research containment only. Actual product auto-start/serve/client are used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/cli.dart';
import 'package:dart_analysis_daemon/src/session_client.dart';
import 'package:dart_analysis_daemon/src/session_server.dart';

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == 'serve') {
    await cliMain(args);
    return;
  }
  if (args.length != 4 || args.first != 'gated') {
    throw ArgumentError('Native gated launch required');
  }
  final token = args[2];
  final root = args[3];
  final input = StreamIterator(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  stdout.writeln(jsonEncode({'event': 'gated', 'pid': pid}));
  if (!await input.moveNext() || input.current != token) return;
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  SessionClient? client;
  var busy = false;
  server.listen((socket) async {
    try {
      final line = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 5));
      final request = jsonDecode(line) as Map;
      if (request['token'] != token || busy) {
        throw StateError('Invalid control');
      }
      busy = true;
      try {
        final watch = Stopwatch()..start();
        Map<String, Object?> response;
        if (request['op'] == 'initialize') {
          if (client != null) throw StateError('Session already held');
          client = await SessionClient.connect(root);
          final connectedMs = watch.elapsedMilliseconds;
          final target =
              File('$root/lib/probe.dart').resolveSymbolicLinksSync();
          final result = await client!.checkFiles([target]);
          final metadata =
              jsonDecode(await endpointFile(root).readAsString()) as Map;
          response = {
            'ok': result['ok'],
            'errors': result['errors'],
            'checkResponse': result,
            'connectedMs': connectedMs,
            'checkMs': watch.elapsedMilliseconds - connectedMs,
            'sessionPid': metadata['pid'],
            'idleTimeoutSeconds':
                (await client!.status())['idleTimeoutSeconds'],
          };
        } else if (request['op'] == 'release') {
          await client?.close();
          client = null;
          while (await endpointFile(root).exists()) {
            if (watch.elapsed > const Duration(seconds: 20)) {
              throw TimeoutException('Product idle reclaim');
            }
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          response = {
            'ok': true,
            'endpointRemovedMs': watch.elapsedMilliseconds,
          };
        } else {
          throw ArgumentError('Unknown operation');
        }
        socket.writeln(jsonEncode({...response, 'id': request['id']}));
        await socket.flush();
      } finally {
        busy = false;
      }
    } catch (error) {
      socket.writeln(jsonEncode({'ok': false, 'error': '$error'}));
      await socket.flush();
    } finally {
      socket.destroy();
    }
  });
  stdout.writeln(
    jsonEncode({
      'event': 'tree-ready',
      'leaf': 0,
      'runtimeVersion': Platform.version,
      'overlayPort': server.port,
    }),
  );
}
