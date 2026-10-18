// Compile the complete managed entry with a fake analyzer, then run in an
// isolated state directory. No actual analyzer/plugin or user install is used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'dana-global-single-aot-',
  );
  final executable = '${directory.path}/global_driver.exe';
  final root = await Directory('${directory.path}/project').create();
  final target = await File(
    '${root.path}/file.dart',
  ).writeAsString('int value = 1;');
  final environment = {
    'DANA_GLOBAL_BUDGET': '1',
    'DANA_GLOBAL_STATE_DIR': '${directory.path}/state',
    'DANA_GLOBAL_COOLDOWN_MS': '0',
    'DANA_DART_EXECUTABLE': Platform.resolvedExecutable,
    'DANA_ANALYSIS_TIMEOUT_SECONDS': '5',
  };
  final results = <String, Object?>{
    'sdk': Platform.version,
    'directory': directory.path,
  };
  Future<Map<String, Object?>> run(List<String> arguments) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
    );
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.transform(utf8.decoder).join();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 20));
      if (code != 0) {
        throw StateError(
          '$arguments: code=$code ${await errors} ${await output}',
        );
      }
      return Map<String, Object?>.from(jsonDecode(await output) as Map);
    } finally {
      process.kill();
    }
  }

  try {
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/fixtures/global_budget_driver.dart',
      '-o',
      executable,
    ]);
    if (compile.exitCode != 0) throw StateError('${compile.stderr}');
    final files =
        directory
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .toList();
    if (files.length != 1 || files.single != 'global_driver.exe') {
      throw StateError('Unexpected shipped files: $files');
    }
    results['shippedFiles'] = files;
    results['check'] = await run(['--api-check', root.path, target.path]);
    final status = await run(['budget', 'status']);
    results['running'] = status;
    if (status['workerCount'] != 1 ||
        (results['check'] as Map)['globalBudget'] != true) {
      throw StateError('Managed AOT entry was not used');
    }
    results['rootStop'] = await run(['stop', '--root', root.path]);
    final reclaimed = await run(['budget', 'status']);
    results['afterRootStop'] = reclaimed;
    if (reclaimed['workerCount'] != 0) {
      throw StateError('Root stop retained its analyzer');
    }
    results['ownerStop'] = await run(['budget', 'stop']);
    results['ok'] = true;
  } catch (error, stack) {
    results['ok'] = false;
    results['error'] = '$error';
    results['stack'] = '$stack';
    exitCode = 1;
  } finally {
    if (await File('${directory.path}/state/endpoint.json').exists()) {
      try {
        await run(['budget', 'stop']);
      } catch (error) {
        results['cleanupError'] = '$error';
      }
    }
    await File(
      '${directory.path}/results.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(results));
    stdout.writeln('results: ${directory.path}/results.json');
  }
}
