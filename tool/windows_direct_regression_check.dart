// Keep the default (non-managed) CLI regression under the outer resource guard.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> args) async {
  if (args.length < 2 || args.first != '--probe') {
    throw ArgumentError('Run through windows_guarded_check.dart');
  }
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:test/test.dart'),
  );
  final process = await Process.run(
    Platform.resolvedExecutable,
    [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      File.fromUri(library!.resolve('../bin/test.dart')).path,
      'test/integration_test.dart',
      'test/ide_bridge_test.dart',
      '--compiler',
      'source',
      '--concurrency',
      '1',
      '--reporter',
      'expanded',
    ],
    environment: {'DANA_GLOBAL_BUDGET': '0', 'DANA_PROCESS_BACKEND': 'direct'},
  );
  await File('${args[1]}/worker-results.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'sdk': Platform.version,
      'exitCode': process.exitCode,
      'stdout': process.stdout,
      'stderr': process.stderr,
    }),
  );
  exitCode = process.exitCode;
}
