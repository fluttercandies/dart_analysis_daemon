import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'shared CLI scopes relative files and full checks to the caller root',
    () async {
      final scratch = await Directory.systemTemp.createTemp('dana pool cli-');
      final entry = File('bin/dart_analysis_daemon.dart').absolute.path;
      final packages = File('.dart_tool/package_config.json').absolute.path;
      final roots = <Directory>[];
      final environment = {
        'DANA_MULTI_ROOT': '1',
        'DANA_GLOBAL_BUDGET': '0',
        'DANA_GLOBAL_STATE_DIR': '${scratch.path}/state',
      };
      Future<ProcessResult> run(int index, List<String> arguments) =>
          Process.run(
            Platform.resolvedExecutable,
            [
              '--packages=$packages',
              entry,
              ...arguments,
              '--root',
              roots[index].path,
            ],
            workingDirectory: scratch.path,
            environment: environment,
          );
      try {
        for (var i = 0; i < 2; i++) {
          final root = await Directory(
            '${scratch.path}/project$i/lib',
          ).create(recursive: true);
          roots.add(root.parent);
          await File(
            '${root.parent.path}/pubspec.yaml',
          ).writeAsString('name: pool_cli_$i\nenvironment:\n  sdk: ^3.7.0\n');
          final get = await Process.run(Platform.resolvedExecutable, [
            'pub',
            'get',
            '--offline',
          ], workingDirectory: root.parent.path);
          expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
          await File('${root.path}/main.dart').writeAsString(
            i == 0 ? 'int value = 1;\n' : 'int value = "broken";\n',
          );
        }
        Future<void> check(int index, List<String> options, int code) async {
          final result = await run(index, [
            'check',
            '--reuse-ide',
            'never',
            ...options,
          ]);
          expect(
            result.exitCode,
            code,
            reason: '${result.stdout}${result.stderr}',
          );
          final response = jsonDecode(result.stdout as String) as Map;
          final files = (response['diagnostics'] as Map).keys.cast<String>();
          final root = roots[index].resolveSymbolicLinksSync();
          expect(files, isNotEmpty);
          expect(
            files.every(
              (file) => file.startsWith('$root${Platform.pathSeparator}'),
            ),
            isTrue,
            reason: 'diagnostics leaked across roots: $response',
          );
        }

        await check(0, ['--files', 'lib/main.dart'], 0);
        await check(1, ['--files', 'lib/main.dart'], 1);
        await check(1, ['--files', 'lib${Platform.pathSeparator}main.dart'], 1);
        await check(1, [
          '--files',
          File('${roots[1].path}/lib/main.dart').resolveSymbolicLinksSync(),
        ], 1);
        await check(1, ['--files', 'lib'], 1);
        await check(0, ['--mode', 'full'], 0);
        await check(1, ['--mode', 'full'], 1);
      } finally {
        for (var i = 0; i < roots.length; i++) {
          await run(i, ['stop']);
        }
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (await scratch.exists()) {
          try {
            await scratch.delete(recursive: true);
          } on PathAccessException {
            if (DateTime.now().isAfter(deadline)) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
