import 'dart:async';
import 'dart:convert';
import 'dart:io';

class Server {
  late Process process;
  final pending = <String, Completer<Map>>{};
  final diagnostics = <String, List>{};
  final diagnosticVersions = <String, int>{};
  final protocolProblems = <Map>[];
  void trace(String text) {
    final log = Platform.environment['DANA_PROBE_PLUGIN_LOG'];
    if (log != null) {
      File('$log.server').writeAsStringSync(
        '${DateTime.now().toUtc().toIso8601String()} $text\n',
        mode: FileMode.append,
      );
    }
  }

  bool busy = true;
  String coverageFile = 'unit_4999.dart';
  int sequence = 0;
  Future<Map> request(String method, Map params) async {
    final id = '${++sequence}';
    trace('request $id $method');
    final done = pending[id] = Completer<Map>();
    process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'params': params}),
    );
    final result = await done.future.timeout(const Duration(minutes: 4));
    trace('response $id $method');
    if (result['error'] != null) {
      throw StateError('$method: ${result['error']}');
    }
    return result;
  }

  Future<void> start(List<String> roots) async {
    process = await Process.start(Platform.resolvedExecutable, [
      'language-server',
      '--protocol=analyzer',
      '--client-id=worktree-memory-probe',
    ]);
    process.stderr.transform(utf8.decoder).listen(stderr.write);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final m = jsonDecode(line) as Map;
          if (m['id'] != null) pending.remove('${m['id']}')?.complete(m);
          if (m['event'] == 'server.status') {
            trace('status ${m['params']}');
            busy = m['params']['analysis']?['isAnalyzing'] ?? busy;
          }
          if (m['event'] == 'analysis.errors') {
            diagnostics[m['params']['file']] = m['params']['errors'];
            if ('${m['params']['file']}'.endsWith('probe.dart') ||
                '${m['params']['file']}'.endsWith('unit_4999.dart')) {
              trace('probe ${m['params']}');
            }
            diagnosticVersions.update(
              m['params']['file'],
              (v) => v + 1,
              ifAbsent: () => 1,
            );
          }
          if (m['event'] == 'server.error' || m['event'] == 'plugin.error') {
            protocolProblems.add(m);
          }
        });
    await request('server.getVersion', {});
    await request('server.setSubscriptions', {
      'subscriptions': ['STATUS'],
    });
    await request('analysis.setAnalysisRoots', {
      'included': roots,
      'excluded': [],
    });
    await idle(roots);
  }

  Future<void> idle(List<String> roots) async {
    final watch = Stopwatch()..start();
    while (busy ||
        roots.any(
          (root) =>
              !diagnostics.containsKey(
                '$root${Platform.pathSeparator}lib${Platform.pathSeparator}$coverageFile',
              ),
        )) {
      if (watch.elapsed > const Duration(minutes: 4)) {
        throw TimeoutException(
          'idle/coverage: busy=$busy files=${diagnostics.length} expected=$coverageFile problems=$protocolProblems',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (busy) await idle(roots);
  }

  Future<void> close() async {
    try {
      await request('server.shutdown', {});
      await process.exitCode.timeout(const Duration(seconds: 8));
    } catch (_) {
      await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    }
  }
}

Future<void> main(List<String> args) async {
  final base = Directory(args[1]).absolute;
  final mode = args[0];
  if (mode == 'prepare') {
    if (await base.exists()) throw StateError('Use a new research directory');
    await base.create(recursive: true);
    final repo = Directory('${base.path}/repo');
    await Directory('${repo.path}/lib').create(recursive: true);
    await File('${repo.path}/pubspec.yaml').writeAsString(
      'name: worktree_memory_fixture\nenvironment:\n  sdk: ^3.9.0\n',
    );
    final plugin = Directory(args[2]).absolute.path.replaceAll('\\', '/');
    await File(
      '${repo.path}/analysis_options.yaml',
    ).writeAsString('plugins:\n  minimal_plugin:\n    path: $plugin\n');
    final fileCount = args.length > 3 ? int.parse(args[3]) : 5000;
    for (var i = 0; i < fileCount; i++) {
      await File('${repo.path}/lib/unit_$i.dart').writeAsString(
        i == 0
            ? 'class Unit0 { int value0() => 0; }\n'
            : "import 'unit_0.dart';\nclass Unit$i extends Unit0 { int value$i() => $i; }\n",
      );
    }
    Future<void> git(List<String> arguments) async {
      final result = await Process.run(
        'git',
        arguments,
        workingDirectory: repo.path,
      );
      if (result.exitCode != 0) throw StateError('${result.stderr}');
    }

    await git(['init', '--quiet']);
    await git(['add', '.']);
    await git([
      '-c',
      'user.name=Benchmark',
      '-c',
      'user.email=benchmark@localhost',
      '-c',
      'commit.gpgsign=false',
      'commit',
      '--quiet',
      '-m',
      'Synthetic memory fixture',
    ]);
    for (var i = 0; i < 3; i++) {
      final root = '${base.path}/branch_$i';
      await git(['worktree', 'add', '--quiet', '-b', 'feature_$i', root]);
      final pub = await Process.run(Platform.resolvedExecutable, [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: root);
      if (pub.exitCode != 0) throw StateError('${pub.stderr}');
    }
    stdout.writeln('Prepared three real Git worktrees at ${base.path}');
    return;
  }
  final roots = [
    for (var i = 0; i < 3; i++)
      Directory('${base.path}/branch_$i').resolveSymbolicLinksSync(),
  ];
  final servers = <Server>[];
  final watch = Stopwatch()..start();
  final results = <Map>[];
  Future<void> verify(Server server, List<String> selected) async {
    final editWatch = Stopwatch()..start();
    await server.request('analysis.updateContent', {
      'files': {
        for (final root in selected)
          '$root${Platform.pathSeparator}lib${Platform.pathSeparator}unit_4999.dart':
              {
                'type': 'add',
                'content':
                    'int branchProbe = missingBranch${roots.indexOf(root)};\n',
              },
      },
    });
    for (final root in selected) {
      final path =
          '$root${Platform.pathSeparator}lib${Platform.pathSeparator}unit_4999.dart';
      final response = await server.request('analysis.getErrors', {
        'file': path,
      });
      final errors = response['result']['errors'] as List;
      if (errors.length != 1 ||
          !(errors.single['message'] as String).contains(
            'missingBranch${roots.indexOf(root)}',
          )) {
        throw StateError('Branch isolation mismatch: $errors');
      }
    }
    await server.idle(selected);
    results.add({
      'roots': selected.length,
      'editAndIdleMs': editWatch.elapsedMilliseconds,
      'cachedFiles': server.diagnostics.length,
      'branchIsolation': true,
    });
  }

  try {
    if (mode == 'serial') {
      for (final root in roots) {
        final server = Server();
        servers.add(server);
        await server.start([root]);
        await verify(server, [root]);
        await server.close();
        servers.remove(server);
      }
    } else if (mode == 'multi') {
      final server = Server();
      servers.add(server);
      await server.start(roots);
      await verify(server, roots);
    } else {
      final count = mode == 'single' ? 1 : 3;
      // Parallel initialization models three simultaneous AI tasks.
      await Future.wait([
        for (var i = 0; i < count; i++)
          () async {
            final server = Server();
            servers.add(server);
            await server.start([roots[i]]);
            await verify(server, [roots[i]]);
          }(),
      ]);
    }
    watch.stop();
    stdout.writeln(
      jsonEncode({
        'ready': true,
        'mode': mode,
        'workMs': watch.elapsedMilliseconds,
        'results': results,
        'analyzerPids': [for (final s in servers) s.process.pid],
      }),
    );
    await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  } finally {
    for (final server in servers) {
      await server.close();
    }
  }
}
