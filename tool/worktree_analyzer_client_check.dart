import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'worktree_analyzer_client.dart';

Future<void> fake(String mode) async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final input = jsonDecode(line) as Map;
    final method = input['method'];
    if (method == 'probe') {
      if (mode == 'exit') exit(7);
      if (mode == 'malformed') {
        stdout.writeln('{bad');
        continue;
      }
      if (mode == 'oversized') {
        stdout.write(List.filled(4 * 1024 * 1024 + 1, 'x').join());
        await stdout.flush();
        continue;
      }
      if (mode == 'timeout') continue;
      if (mode == 'late') {
        Timer(const Duration(milliseconds: 850), () {
          stdout.writeln(jsonEncode({'id': input['id'], 'result': {}}));
          stdout.writeln(
            jsonEncode({
              'event': 'analysis.errors',
              'params': {'file': 'stale.dart', 'errors': []},
            }),
          );
        });
        continue;
      }
      if (mode == 'error') {
        stdout.writeln(
          jsonEncode({
            'id': input['id'],
            'error': {'code': 'FAKE'},
          }),
        );
        continue;
      }
      if (mode == 'plugin-error') {
        stdout.writeln(
          jsonEncode({
            'event': 'plugin.error',
            'params': {'message': 'fault'},
          }),
        );
        continue;
      }
    }
    if (method == 'analysis.setAnalysisRoots' && mode == 'startup-timeout') {
      continue;
    }
    stdout.writeln(jsonEncode({'id': input['id'], 'result': {}}));
    if (method == 'server.shutdown') {
      await stdout.flush();
      exit(0);
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty) {
    await fake(args.single);
    return;
  }
  final fixture = await Directory.systemTemp.createTemp(
    'dana-analyzer-client-',
  );
  final results = <Map>[];
  Future<void> run(String mode) async {
    Process? owned;
    final client = ResearchAnalyzerClient(
      fixture.path,
      File('${fixture.path}/$mode.jsonl'),
      rootTimeout: const Duration(milliseconds: 250),
      maxLogBytes: mode == 'log-budget' ? 1 : null,
      maxRequestTimings: mode == 'healthy' ? 3 : null,
      launch:
          () async =>
              owned = await Process.start(Platform.resolvedExecutable, [
                Platform.script.toFilePath(),
                mode,
              ]),
    );
    try {
      if (mode == 'log-budget') {
        var rejected = false;
        try {
          await client.start();
        } catch (_) {
          rejected = true;
        }
        if (!rejected || client.failure == null || client.rootConfigured) {
          throw StateError('Log budget did not invalidate client');
        }
      } else if (mode == 'startup-timeout') {
        var rejected = false;
        try {
          await client.start();
        } on TimeoutException {
          rejected = true;
        }
        if (!rejected || client.rootConfigured || client.failure == null) {
          throw StateError('Startup timeout reused');
        }
      } else {
        await client.start();
        if (!client.rootConfigured) throw StateError('Missing root ready');
        if (mode == 'healthy') {
          await Future.wait([
            for (var i = 0; i < 8; i++) client.request('probe', {}),
          ]);
          if (client.pending.isNotEmpty) throw StateError('Pending leaked');
          if (client.requestTimings.length != 3) {
            throw StateError('History limit ignored');
          }
          await client.close();
          await client.close();
          if (!client.exited ||
              client.rootConfigured ||
              client.failure != null) {
            throw StateError('Healthy close invalid');
          }
        } else {
          var rejected = false;
          try {
            await client.request(
              'probe',
              {},
              timeout: const Duration(milliseconds: 700),
            );
          } catch (_) {
            rejected = true;
          }
          if (!rejected ||
              client.failure == null ||
              client.rootConfigured ||
              client.pending.isNotEmpty) {
            throw StateError('Fault not latched: $mode');
          }
          var reuseRejected = false;
          try {
            await client.request('probe', {});
          } catch (_) {
            reuseRejected = true;
          }
          if (!reuseRejected) throw StateError('Poisoned client reused');
          if (mode == 'late') {
            await Future<void>.delayed(const Duration(milliseconds: 350));
            if (client.errors.isNotEmpty || client.errorSequence.isNotEmpty) {
              throw StateError('Late diagnostics revived failed state');
            }
          }
        }
      }
      results.add({'name': mode, 'passed': true});
      print('PASS $mode');
    } finally {
      // Only this fake peer is killed; it has no descendants or analyzer.
      owned?.kill();
      if (owned != null) {
        await owned!.exitCode.timeout(const Duration(seconds: 5));
      }
      try {
        await client.close();
      } catch (_) {
        /* Failed client needs external owner cleanup. */
      }
    }
  }

  for (final mode in [
    'healthy',
    'exit',
    'malformed',
    'oversized',
    'timeout',
    'late',
    'error',
    'plugin-error',
    'startup-timeout',
    'log-budget',
  ]) {
    await run(mode).timeout(const Duration(seconds: 12));
  }
  final report = {
    'allPassed': true,
    'results': results,
    'fixture': fixture.path,
    'fakePeersOnly': true,
  };
  await File(
    '${fixture.path}/results.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  print(jsonEncode(report));
}
