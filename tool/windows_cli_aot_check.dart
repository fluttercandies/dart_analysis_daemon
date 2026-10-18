// Build the actual CLI, not the fake-analyzer fixture. Exercise owner control
// only: this check never starts an analyzer or touches the user's installation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  if (!Platform.isWindows) throw UnsupportedError('Windows CLI artifact');
  final directory = await Directory.systemTemp.createTemp('dana-cli-aot-');
  final executable = '${directory.path}/dana.exe';
  final state = Directory('${directory.path}/state');
  final environment = {
    'DANA_GLOBAL_BUDGET': '1',
    'DANA_GLOBAL_STATE_DIR': state.path,
    'DANA_DART_EXECUTABLE': Platform.resolvedExecutable,
  };
  final results = <String, Object?>{
    'sdk': Platform.version,
    'executable': executable,
    'scope': 'actual CLI help/version/global owner control; no analyzer',
  };
  Process? owner;
  Future<void>? ownerOutput;
  Future<String>? ownerErrors;
  Future<String> run(List<String> arguments) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 15));
      final text = await output;
      if (code != 0) {
        throw StateError('$arguments: code=$code ${await errors} $text');
      }
      await errors;
      return text;
    } finally {
      process.kill();
    }
  }

  try {
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/dart_analysis_daemon.dart',
      '-o',
      executable,
    ]).timeout(const Duration(seconds: 60));
    if (compiled.exitCode != 0) throw StateError('${compiled.stderr}');
    results['shippedFiles'] = [
      for (final file in directory.listSync().whereType<File>())
        file.uri.pathSegments.last,
    ];
    results['sizeBytes'] = await File(executable).length();
    results['version'] = (await run(['--version'])).trim();
    final help = await run(['--help']);
    if (!help.contains('dana budget serve|status|stop')) {
      throw StateError('Global owner command is absent from CLI help');
    }
    results['helpIncludesBudget'] = true;
    owner = await Process.start(executable, [
      'budget',
      'serve',
    ], environment: environment);
    ownerOutput = owner.stdout.drain<void>();
    ownerErrors = owner.stderr.transform(utf8.decoder).join();
    final endpoint = File('${state.path}/endpoint.json');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await endpoint.exists()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('CLI owner');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final status = jsonDecode(await run(['budget', 'status'])) as Map;
    results['status'] = status;
    if (status['ok'] != true ||
        status['workerCount'] != 0 ||
        status['compatible'] != true) {
      throw StateError('Unexpected owner status: $status');
    }
    final stopped = jsonDecode(await run(['budget', 'stop'])) as Map;
    results['stop'] = stopped;
    if (stopped['shutdownComplete'] != true) {
      throw StateError('CLI owner cleanup not confirmed');
    }
    if (await owner.exitCode.timeout(const Duration(seconds: 5)) != 0) {
      throw StateError('CLI owner failed: ${await ownerErrors}');
    }
    results['endpointRemoved'] = !await endpoint.exists();
    if (results['endpointRemoved'] != true) {
      throw StateError('Endpoint retained');
    }
    results['ok'] = true;
  } catch (error, stack) {
    results['ok'] = false;
    results['error'] = '$error';
    results['stack'] = '$stack';
    exitCode = 1;
  } finally {
    if (owner != null) {
      if (await File('${state.path}/endpoint.json').exists()) {
        try {
          await run(['budget', 'stop']);
        } catch (_) {
          // No analyzer was requested; only this exact owner is in scope.
          owner.kill();
        }
      }
      owner.kill();
      await owner.exitCode.timeout(const Duration(seconds: 5));
      await ownerOutput;
      results['ownerStderr'] = await ownerErrors;
    }
    final record = File('${directory.path}/results.json');
    await record.writeAsString(
      const JsonEncoder.withIndent('  ').convert(results),
    );
    stdout.writeln('results: ${record.path}');
  }
}
