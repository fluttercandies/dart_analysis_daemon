import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_analysis_daemon/src/session_client.dart';
import 'package:dart_analysis_daemon/src/session_server.dart';
import 'package:test/test.dart';

void main() {
  if (!Platform.isWindows) return;
  if (Platform.environment['DANA_GLOBAL_BUDGET'] != '1') {
    test(
      'managed entry uses a child environment without changing user settings',
      () async {
        final testLibrary = await Isolate.resolvePackageUri(
          Uri.parse('package:test/test.dart'),
        );
        final runner = File.fromUri(testLibrary!.resolve('../bin/test.dart'));
        final result = await Process.run(
          Platform.resolvedExecutable,
          [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            runner.path,
            'test/global_budget_entry_test.dart',
            '--compiler',
            'source',
            '--reporter',
            'expanded',
          ],
          environment: {'DANA_GLOBAL_BUDGET': '1'},
        ).timeout(const Duration(seconds: 110));
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      },
      // This wraps a separate runner with multiple worker generations and
      // crash recovery. Keep individual request/startup deadlines unchanged.
      timeout: const Timeout(Duration(minutes: 2)),
    );
    return;
  }
  test(
    'public serve and SessionClient route new worktrees through one global FFI worker',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'dana-global-entry-',
      );
      final environment = {
        'DANA_GLOBAL_BUDGET': '1',
        'DANA_GLOBAL_STATE_DIR': '${temporary.path}/state',
        'DANA_GLOBAL_COOLDOWN_MS': '0',
        'DANA_ANALYSIS_TIMEOUT_SECONDS': '5',
      };
      final driver =
          '${Directory.current.path}/test/fixtures/global_budget_driver.dart';
      final processes = <Process>[];
      final errors = <Future<String>>[];
      final clients = <SessionClient>[];
      Future<Process> launch(List<String> args) async {
        final process = await Process.start(Platform.resolvedExecutable, [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          driver,
          ...args,
        ], environment: environment);
        process.stdout.drain<void>().ignore();
        errors.add(process.stderr.transform(utf8.decoder).join());
        processes.add(process);
        return process;
      }

      Future<Map> budget(String op) async {
        final result = await Process.run(Platform.resolvedExecutable, [
          '--packages=${Directory.current.path}/.dart_tool/package_config.json',
          driver,
          'budget',
          op,
        ], environment: environment).timeout(const Duration(seconds: 10));
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return jsonDecode(result.stdout as String) as Map;
      }

      try {
        for (final name in ['A', 'B', 'C']) {
          final root = await Directory('${temporary.path}/$name').create();
          final target = await File(
            '${root.path}/file.dart',
          ).writeAsString('int value = 1;');
          if (name == 'C') {
            final checked = await Process.run(Platform.resolvedExecutable, [
              '--packages=${Directory.current.path}/.dart_tool/package_config.json',
              driver,
              '--api-check',
              root.path,
              target.path,
            ], environment: environment).timeout(const Duration(seconds: 10));
            expect(checked.exitCode, 0, reason: '${checked.stderr}');
            expect(
              (jsonDecode(checked.stdout as String) as Map)['globalBudget'],
              true,
            );
          } else {
            await launch(['serve', '--root', root.path]);
          }
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (!await endpointFile(root.path).exists()) {
            if (DateTime.now().isAfter(deadline)) {
              fail('Root session did not start: $name');
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          final client = await SessionClient.connect(
            root.path,
            autoStart: false,
          );
          clients.add(client);
          final response = await client
              .checkFiles([target.path])
              .timeout(const Duration(seconds: 10));
          expect(response['ok'], true, reason: '$response');
          expect(response['globalBudget'], true);
          expect(response['workerGeneration'], clients.length);
          final status = await budget('status');
          expect(status['workerCount'], 1);
          expect(status['starts'], clients.length);
          if (name == 'A') {
            final overlay = await client.checkFiles(
              [target.path],
              overlays: {target.path: 'bad overlay'},
            );
            expect(overlay['ok'], false);
          }
        }
        // Keep all three root clients connected: the old root must still release
        // its analyzer, while the lightweight root endpoints remain available.
        expect((await clients.first.status())['workerCount'], 1);
        // Actual broker/pool path: include and nested configuration edits must
        // replace the warm worker even though root options themselves are stable.
        final cRoot = '${temporary.path}/C';
        final included = await File(
          '$cRoot/shared.yaml',
        ).writeAsString('analyzer: {}');
        await File(
          '$cRoot/analysis_options.yaml',
        ).writeAsString('include: shared.yaml');
        final cFiles = ['$cRoot/file.dart'];
        expect((await clients.last.checkFiles(cFiles))['workerGeneration'], 4);
        await included.writeAsString('linter: {}');
        expect((await clients.last.checkFiles(cFiles))['workerGeneration'], 5);
        expect((await clients.last.checkFiles(cFiles))['workerGeneration'], 5);
        await Directory('$cRoot/lib').create();
        await File(
          '$cRoot/lib/analysis_options.yaml',
        ).writeAsString('analyzer: {}');
        expect((await clients.last.checkFiles(cFiles))['workerGeneration'], 6);
        final pluginRoot = '${temporary.path}/path-plugin';
        await Directory('$pluginRoot/lib').create(recursive: true);
        await File('$pluginRoot/pubspec.yaml').writeAsString('name: sample\n');
        final pluginSource = await File(
          '$pluginRoot/lib/sample.dart',
        ).writeAsString('void f() {}');
        await File(
          '$cRoot/analysis_options.yaml',
        ).writeAsString('plugins:\n  sample:\n    path: ../path-plugin\n');
        expect((await clients.last.checkFiles(cFiles))['workerGeneration'], 7);
        await pluginSource.writeAsString('void edited() {}');
        expect((await clients.last.checkFiles(cFiles))['workerGeneration'], 8);
        expect((await clients.last.checkFiles(cFiles))['workerGeneration'], 8);
        final oldOwner = await budget('status');
        final oldJournal =
            jsonDecode(
                  await File(
                    '${temporary.path}/state/worker-job.json',
                  ).readAsString(),
                )
                as Map;
        final oldCache = Directory(
          '${temporary.path}/state/${oldJournal['cacheName']}',
        );
        final cached =
            await oldCache.list().where((entry) => entry is Directory).toList();
        expect(cached.length, 3);
        for (final entry in cached) {
          final observed =
              jsonDecode(
                    await File(
                      '${entry.path}/worker-environment.json',
                    ).readAsString(),
                  )
                  as Map;
          expect(
            await Directory(
              observed['sdkState'] as String,
            ).resolveSymbolicLinks(),
            await Directory(entry.path).resolveSymbolicLinks(),
          );
        }
        final competing = await launch(['budget', 'serve']);
        expect(await competing.exitCode.timeout(const Duration(seconds: 5)), 0);
        expect((await budget('status'))['pid'], oldOwner['pid']);
        // Only the exact owner created by this isolated test is terminated.
        expect(Process.killPid(oldOwner['pid'] as int), true);
        final recovered = await clients.first
            .checkFiles(['${temporary.path}/A/file.dart'])
            .timeout(const Duration(seconds: 15));
        expect(recovered['ok'], true, reason: '$recovered');
        expect(recovered['workerGeneration'], 1);
        expect(await oldCache.exists(), false);
        expect((await budget('status'))['pid'], isNot(oldOwner['pid']));
        expect((await budget('stop'))['shutdownComplete'], true);
        final stoppedState = Directory('${temporary.path}/state');
        expect(
          await File('${stoppedState.path}/endpoint.json').exists(),
          false,
        );
        expect(
          await stoppedState
              .list()
              .where(
                (entry) =>
                    entry is Directory && entry.path.contains('sdk-cache-'),
              )
              .length,
          0,
        );
        final releasedLock = await File(
          '${stoppedState.path}/owner.lock',
        ).open(mode: FileMode.append);
        try {
          await releasedLock.lock(FileLock.exclusive);
          await releasedLock.unlock();
        } finally {
          await releasedLock.close();
        }
        for (final client in clients) {
          await client.shutdown();
        }
        for (final process in processes) {
          expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
        }
        for (final error in errors) {
          expect(await error, isNot(contains('Unhandled exception')));
        }
      } finally {
        for (final client in clients) {
          try {
            await client.shutdown().timeout(const Duration(seconds: 5));
          } catch (_) {
            // A successful path already closed these sessions; a failed
            // assertion must still stop the auto-started third root.
          }
          await client.close();
        }
        for (final process in processes) {
          process.kill();
        }
        final endpoint = File('${temporary.path}/state/endpoint.json');
        if (await endpoint.exists()) {
          final result = await Process.run(Platform.resolvedExecutable, [
            '--packages=${Directory.current.path}/.dart_tool/package_config.json',
            driver,
            'budget',
            'stop',
          ], environment: environment);
          if (result.exitCode != 0) {
            stderr.writeln('Test cleanup owner unavailable: ${result.stderr}');
          }
        }
        final cleanupDeadline = DateTime.now().add(const Duration(seconds: 8));
        while (true) {
          try {
            await temporary.delete(recursive: true);
            break;
          } on FileSystemException {
            if (DateTime.now().isAfter(cleanupDeadline)) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
