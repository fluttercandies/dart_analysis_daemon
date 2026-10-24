import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/session_server.dart';
import 'package:dart_analysis_daemon/src/session_client.dart';
import 'package:test/test.dart';

void main() {
  final packageRoot = Directory.current.path;
  final driver = '$packageRoot/test/fixtures/idle_session_driver.dart';
  final config = '$packageRoot/.dart_tool/package_config.json';

  Future<ProcessResult> invoke(String root, String timeout) => Process.run(
    Platform.resolvedExecutable,
    ['--packages=$config', driver, 'client', root],
    workingDirectory: packageRoot,
    environment: {
      ...Platform.environment,
      'DANA_MULTI_ROOT': '0',
      'DANA_POOL_MAX_ROOTS': '3',
      'DANA_GLOBAL_BUDGET': '0',
      'DANA_SESSION_IDLE_TIMEOUT_SECONDS': timeout,
      'DANA_ANALYSIS_TIMEOUT_SECONDS': '12',
      'DANA_DART_EXECUTABLE': Platform.resolvedExecutable,
    },
  ).timeout(const Duration(seconds: 20));

  Future<void> waitFor(Future<bool> Function() predicate) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!await predicate()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('Lifecycle condition did not become true');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  for (final scenario in ['api-success', 'api-failure', 'cli-failure']) {
    test('explicit shutdown reports actual cleanup: $scenario', () async {
      final fails = scenario.endsWith('failure');
      final project = await Directory.systemTemp.createTemp(
        'dana-stop-failure-',
      );
      final root = await project.resolveSymbolicLinks();
      addTearDown(() => project.delete(recursive: true));
      await File('$root/release-close').writeAsString('release');
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '--packages=$config',
          driver,
          'serve',
          '--root',
          root,
          '--startup-token',
          'fixture-token',
        ],
        environment: {
          ...Platform.environment,
          'DANA_MULTI_ROOT': '0',
          'DANA_POOL_MAX_ROOTS': '3',
          'DANA_GLOBAL_BUDGET': '0',
          'DANA_SESSION_IDLE_TIMEOUT_SECONDS': '0',
          'DANA_TEST_CLOSE_FAILURE': fails ? '1' : '0',
          'DANA_DART_EXECUTABLE': Platform.resolvedExecutable,
        },
      );
      final output = process.stdout.drain<void>();
      final errors = process.stderr.transform(utf8.decoder).join();
      try {
        await waitFor(() => endpointFile(root).exists());
        if (scenario == 'cli-failure') {
          final result = await Process.run(
            Platform.resolvedExecutable,
            [
              '--packages=$config',
              '$packageRoot/bin/dart_analysis_daemon.dart',
              'stop',
              '--root',
              root,
            ],
            environment: {
              ...Platform.environment,
              'DANA_MULTI_ROOT': '0',
              'DANA_GLOBAL_BUDGET': '0',
              'DANA_DART_EXECUTABLE': Platform.resolvedExecutable,
            },
          );
          expect(result.exitCode, 1);
          expect((jsonDecode('${result.stdout}') as Map)['ok'], false);
        } else {
          final client = await SessionClient.connect(root, autoStart: false);
          try {
            final response = await client.shutdown();
            expect(response['ok'], !fails);
            if (fails) {
              expect(
                response['error'],
                contains('Injected subprocess close failure'),
              );
            } else {
              expect(response['shutdownComplete'], true);
            }
          } finally {
            await client.close();
          }
        }
        expect(
          await process.exitCode.timeout(const Duration(seconds: 5)),
          fails ? isNot(0) : equals(0),
        );
        if (fails) {
          expect(await errors, contains('Injected subprocess close failure'));
        } else {
          await errors;
        }
        await output;
      } finally {
        process.kill();
      }
    });
  }

  test('auto-start inherits timeout and retries during idle teardown', () async {
    final project = await Directory.systemTemp.createTemp('dana-idle-startup-');
    final root = await project.resolveSymbolicLinks();
    final ownedPids = <int>{};
    addTearDown(() async {
      // Only these fixture-owned session PIDs can be terminated on failure.
      for (final ownedPid in ownedPids) {
        try {
          Process.killPid(ownedPid);
        } on ProcessException {
          // Already exited after idle cleanup.
        }
      }
      // Windows can retain the detached process's working-directory handle
      // briefly after endpoint removal. Wait for that handle, not just metadata.
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (await project.exists()) {
        try {
          await project.delete(recursive: true);
        } on PathAccessException {
          if (DateTime.now().isAfter(deadline)) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }
    });

    final first = await invoke(root, '1');
    expect(first.exitCode, 0, reason: '${first.stderr}');
    final before = jsonDecode('${first.stdout}') as Map;
    final firstPid = before['sessionPid'] as int;
    ownedPids.add(firstPid);
    expect(before['idleTimeoutSeconds'], 1);
    await waitFor(() => File('$root/closing-$firstPid').exists());
    // Endpoint deliberately remains while the analyzer is closing.
    expect(await endpointFile(root).exists(), true);

    await File('$root/client-entered').delete();
    final restarting = invoke(root, '1');
    await waitFor(() => File('$root/client-entered').exists());
    // Force the new caller to observe an unreachable, still-published endpoint
    // before allowing teardown to finish.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(await endpointFile(root).exists(), true);
    await File('$root/release-close').writeAsString('release');
    final second = await restarting;
    expect(second.exitCode, 0, reason: '${second.stderr}');
    final after = jsonDecode('${second.stdout}') as Map;
    final secondPid = after['sessionPid'] as int;
    ownedPids.add(secondPid);
    expect(secondPid, isNot(firstPid));
    expect(after['idleTimeoutSeconds'], 1);
    await waitFor(() async => !await endpointFile(root).exists());
    ownedPids.clear();
  });

  test(
    'invalid auto-start configuration fails without leaving a marker',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'dana-idle-invalid-',
      );
      addTearDown(() => project.delete(recursive: true));
      final result = await invoke(project.path, '-1');
      expect(result.exitCode, isNot(0));
      expect('${result.stderr}', contains('Session idle timeout'));
      expect(await endpointFile(project.path).exists(), false);
      expect(
        await File(
          '${project.path}/.dart_tool/ai-analyzer-session.starting',
        ).exists(),
        false,
      );
    },
  );

  test(
    'CLI auto-start reports invalid idle configuration as usage error',
    () async {
      final project = await Directory.systemTemp.createTemp('dana-idle-cli-');
      addTearDown(() => project.delete(recursive: true));
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=$config',
          '$packageRoot/bin/dart_analysis_daemon.dart',
          'check',
          '--root',
          project.path,
          '--reuse-ide',
          'never',
          '--files',
          'probe.dart',
        ],
        environment: {
          ...Platform.environment,
          'DANA_MULTI_ROOT': '0',
          'DANA_GLOBAL_BUDGET': '0',
          'DANA_SESSION_IDLE_TIMEOUT_SECONDS': 'invalid',
        },
      ).timeout(const Duration(seconds: 10));
      expect(result.exitCode, 64, reason: '${result.stderr}');
      expect('${result.stderr}', contains('Session idle timeout'));
      expect('${result.stderr}', isNot(contains('Unhandled exception')));
      expect(await endpointFile(project.path).exists(), false);
    },
  );
}
