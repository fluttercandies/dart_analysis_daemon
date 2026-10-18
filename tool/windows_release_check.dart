// Real installation and protocol acceptance. Always run via the Windows guard.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length != 3 || args.first != '--probe') {
    throw ArgumentError('Run through windows_guarded_check.dart with a phase.');
  }
  final output = Directory(args[1]);
  final phase = args[2];
  final daemon = Directory.current;
  final proxy = Directory('${daemon.parent.path}/analysis_server_proxy');
  final dart = Platform.resolvedExecutable;
  final records = <Map<String, Object?>>[];
  final cache = '${output.path}/pub-cache';
  final environment = {
    'PUB_CACHE': cache,
    'PATH':
        '$cache/bin;${File(dart).parent.path};${Platform.environment['PATH']}',
    'DANA_GLOBAL_STATE_DIR': '${output.path}/state',
    'DANA_GLOBAL_BUDGET': '0',
    'DANA_MULTI_ROOT': '0',
    'DANA_PROCESS_BACKEND': 'windows-ffi-job',
  };
  Future<void> save() =>
      File('${output.path}/worker-results.json').writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'phase': phase, 'records': records}),
      );
  Future<ProcessResult> run(
    String label,
    List<String> arguments, {
    String? executable,
    String? cwd,
    Map<String, String>? env,
    bool shell = false,
    int expected = 0,
  }) async {
    final watch = Stopwatch()..start();
    final child = await Process.start(
      executable ?? dart,
      arguments,
      workingDirectory: cwd ?? daemon.path,
      environment: {...environment, ...?env},
      runInShell: shell,
    );
    final stdoutFuture = child.stdout.transform(utf8.decoder).join();
    final stderrFuture = child.stderr.transform(utf8.decoder).join();
    var timedOut = false;
    final code = await child.exitCode.timeout(
      const Duration(minutes: 3),
      onTimeout: () async {
        timedOut = true;
        await Process.run('taskkill', ['/PID', '${child.pid}', '/T', '/F']);
        return child.exitCode;
      },
    );
    final result = ProcessResult(
      child.pid,
      code,
      await stdoutFuture,
      await stderrFuture,
    );
    records.add({
      'label': label,
      'exitCode': code,
      'expected': expected,
      'timedOut': timedOut,
      'elapsedMs': watch.elapsedMilliseconds,
      'stdout': result.stdout,
      'stderr': result.stderr,
    });
    await save();
    stdout.writeln('$label: $code');
    if (code != expected || timedOut) {
      throw StateError('$label failed: ${result.stdout}\n${result.stderr}');
    }
    return result;
  }

  if (phase == 'artifacts') {
    for (final script in [
      'global_budget_aot_check.dart',
      'windows_cli_aot_check.dart',
      'worktree_job_install_check.dart',
    ]) {
      await run(script, ['tool/$script']);
    }
    return;
  }
  if (phase != 'activation') throw ArgumentError('Unknown phase: $phase');
  for (final repo in [daemon, proxy]) {
    await run(
      'activate-${repo.uri.pathSegments.where((s) => s.isNotEmpty).last}',
      ['pub', 'global', 'activate', '--source', 'path', repo.path],
    );
  }
  final dana = '$cache/bin/dana.bat';
  final proxyCommand = '$cache/bin/dana_analysis_server.bat';
  await run('dana-help', ['--help'], executable: dana, shell: true);
  await run('proxy-help', ['--help'], executable: proxyCommand, shell: true);
  final project = await Directory(
    '${output.path}/project/lib',
  ).create(recursive: true);
  final root = project.parent.path;
  await File(
    '$root/pubspec.yaml',
  ).writeAsString('name: activation_probe\nenvironment:\n  sdk: ^3.7.0\n');
  final file = File('${project.path}/main.dart');
  await file.writeAsString('int value = 1;\n');
  await run('project-get', ['pub', 'get', '--offline'], cwd: root);
  try {
    await run(
      'dana-clean',
      ['check', '--root', root, '--files', 'lib/main.dart'],
      executable: dana,
      shell: true,
    );
    await file.writeAsString('int value = "broken";\n');
    for (final options in [
      ['--files', 'lib/main.dart'],
      ['--files', 'lib'],
      ['--mode', 'full'],
    ]) {
      await run(
        'dana-broken-${options.last}',
        ['check', '--root', root, ...options],
        executable: dana,
        shell: true,
        expected: 1,
      );
    }
    await run(
      'dana-status',
      ['status', '--root', root],
      executable: dana,
      shell: true,
    );
  } finally {
    await run(
      'dana-stop',
      ['stop', '--root', root],
      executable: dana,
      shell: true,
    );
  }

  final analyzerPath = '${output.path}/proxy.dill';
  await run(
    'proxy-analyzer-path',
    ['analyzer-path', '--output', analyzerPath],
    executable: proxyCommand,
    shell: true,
  );
  await run(
    'proxy-e2e-analyzer-path',
    ['tool/end_to_end_smoke.dart'],
    cwd: proxy.path,
    env: {
      'DANA_SMOKE_ANALYZER_PATH': analyzerPath,
      'DANA_ENTRYPOINT': '${daemon.path}/bin/dart_analysis_daemon.dart',
    },
  );
}
