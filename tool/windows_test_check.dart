// Run source tests sequentially inside windows_guarded_check.dart's owned Job.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

Future<void> main(List<String> args) async {
  if (args.length < 3 || args.first != '--probe') {
    throw ArgumentError(
      'Run through windows_guarded_check.dart with a repository path '
      'and optional test paths',
    );
  }
  final repository = Directory(args[2]).absolute;
  final library = await Isolate.resolvePackageUri(
    Uri.parse('package:test/test.dart'),
  );
  final supplied = args.skip(3).toList();
  final suites =
      supplied.isNotEmpty
          ? [supplied]
          : [
            for (final file in Directory('${repository.path}/test')
                .listSync(recursive: true)
                .whereType<File>()
                .where((file) => file.path.endsWith('_test.dart')))
              [file.path],
          ];
  suites.sort((a, b) => a.first.compareTo(b.first));
  final records = <Map<String, Object?>>[];
  final testDirectory = Directory('${repository.path}/test');
  Set<String> bootstraps() =>
      testDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.bootstrap.isolate.dart'))
          .map((file) => file.path)
          .toSet();
  for (final suite in suites) {
    final previousBootstraps = bootstraps();
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        // Collect short-lived test/compiler objects sooner on busy desktops.
        // This does not relax the outer system-memory protection.
        '--old_gen_heap_size=512',
        '--packages=${repository.path}/.dart_tool/package_config.json',
        File.fromUri(library!.resolve('../bin/test.dart')).path,
        ...suite,
        '--compiler',
        'source',
        '--concurrency',
        '1',
        '--reporter',
        'expanded',
      ],
      workingDirectory: repository.path,
      environment: {
        'DANA_GLOBAL_BUDGET': '0',
        'DANA_MULTI_ROOT': '0',
        'DANA_PROCESS_BACKEND': 'direct',
      },
    );
    records.add({
      'tests': suite,
      'exitCode': result.exitCode,
      'stdout': result.stdout,
      'stderr': result.stderr,
    });
    if (result.exitCode != 0) exitCode = 1;
    await File('${args[1]}/worker-results.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'repository': repository.path,
        'exitCode': exitCode,
        'records': records,
      }),
    );
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    // Source compilation leaves generated launchers beside the tests. Only
    // remove files created by this invocation, preserving pre-existing files.
    for (final path in bootstraps().difference(previousBootstraps)) {
      await File(path).delete();
    }
  }
}
