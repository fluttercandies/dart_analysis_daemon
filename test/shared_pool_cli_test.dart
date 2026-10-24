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
        ...Platform.environment,
        'DANA_MULTI_ROOT': '1',
        'DANA_GLOBAL_BUDGET': '0',
        'DANA_GLOBAL_RESERVE_MIB': '1',
        'DANA_GLOBAL_STARTUP_MIB': '0',
        'DANA_GLOBAL_RECOVERY_MIB': '0',
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
        Future<bool> check(int index, List<String> options, int code) async {
          final result = await run(index, [
            'check',
            '--reuse-ide',
            'never',
            ...options,
          ]);
          if (result.exitCode == 75) {
            final output = '${result.stdout}';
            final response = jsonDecode(output) as Map;
            if (response['reason'] == 'memory-pressure' ||
                response['reason'] == 'memory-sample-unavailable') {
              markTestSkipped(
                'Host memory policy refused the integration fixture: '
                '${response['reason']}',
              );
              return false;
            }
          }
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
          return true;
        }

        if (!await check(0, ['--files', 'lib/main.dart'], 0)) {
          return;
        }
        if (!await check(1, ['--files', 'lib/main.dart'], 1)) {
          return;
        }
        if (!await check(1, [
          '--files',
          'lib${Platform.pathSeparator}main.dart',
        ], 1)) {
          return;
        }
        if (!await check(1, [
          '--files',
          File('${roots[1].path}/lib/main.dart').resolveSymbolicLinksSync(),
        ], 1)) {
          return;
        }
        if (!await check(1, ['--files', 'lib'], 1)) {
          return;
        }
        if (!await check(0, ['--mode', 'full'], 0)) {
          return;
        }
        if (!await check(1, ['--mode', 'full'], 1)) {
          return;
        }
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

  test(
    'pool admission denial is reported and does not start another session',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'dana pool admission-',
      );
      final entry = File('bin/dart_analysis_daemon.dart').absolute.path;
      final packages = File('.dart_tool/package_config.json').absolute.path;
      final roots = <Directory>[];
      final environment = {
        ...Platform.environment,
        'DANA_MULTI_ROOT': '1',
        'DANA_GLOBAL_BUDGET': '0',
        'DANA_POOL_MAX_ROOTS': '1',
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
          final lib = await Directory(
            '${scratch.path}/admission$i/lib',
          ).create(recursive: true);
          roots.add(lib.parent);
          await File(
            '${lib.parent.path}/pubspec.yaml',
          ).writeAsString('name: admission_$i\nenvironment:\n  sdk: ^3.7.0\n');
          final get = await Process.run(Platform.resolvedExecutable, [
            'pub',
            'get',
            '--offline',
          ], workingDirectory: lib.parent.path);
          expect(get.exitCode, 0, reason: '${get.stdout}${get.stderr}');
          await File('${lib.path}/main.dart').writeAsString('void main() {}\n');
        }

        final first = await run(0, [
          'check',
          '--reuse-ide',
          'never',
          '--files',
          'lib/main.dart',
        ]);
        expect(first.exitCode, 0, reason: '${first.stdout}${first.stderr}');

        final denied = await run(1, [
          'check',
          '--reuse-ide',
          'never',
          '--files',
          'lib/main.dart',
        ]);
        expect(denied.exitCode, 75, reason: '${denied.stdout}${denied.stderr}');
        final response = jsonDecode(denied.stdout as String) as Map;
        expect(response['code'], 'pool-admission-denied');
        expect(response['reason'], 'root-limit');
        expect(response['fallbackStarted'], isFalse);
        expect(denied.stderr, contains('root limit'));
        expect(denied.stderr, contains('No separate analyzer was started'));
        expect(
          await File(
            '${roots[1].path}/.dart_tool/ai-analyzer-session.json',
          ).exists(),
          isFalse,
          reason: 'denial must not start a separate analyzer session',
        );
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
