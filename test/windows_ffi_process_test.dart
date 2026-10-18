import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_analysis_daemon/src/windows_ffi_process.dart';
import 'package:test/test.dart';

void main() {
  if (!Platform.isWindows) return;
  final dart =
      Platform.environment['DANA_TEST_DART_EXECUTABLE'] ??
      Platform.resolvedExecutable;
  final fixtures = '${Directory.current.path}/test/fixtures';
  test(
    'FFI environment overrides reach descendants without changing the parent',
    () async {
      final original = Platform.environment['DANA_FFI_ENV_PROBE'];
      final process = await WindowsFfiAnalyzerProcess.start(
        dart,
        ['$fixtures/ffi_environment_child.dart'],
        workingDirectory: Directory.current.path,
        environment: {
          'dana_ffi_env_probe': 'old',
          'DANA_FFI_ENV_PROBE': '规则 空格=abc',
          'ANALYZER_STATE_LOCATION_OVERRIDE': 'C:\\isolated cache\\规则',
        },
      );
      final output = process.stdout.transform(utf8.decoder).join();
      final errors = process.stderr.transform(utf8.decoder).join();
      try {
        expect(await process.exitCode.timeout(const Duration(seconds: 10)), 0);
        expect(await errors, isEmpty);
        expect(jsonDecode(await output), {
          'probe': '规则 空格=abc',
          'pathPresent': true,
          'sdkState': 'C:\\isolated cache\\规则',
        });
        expect(Platform.environment['DANA_FFI_ENV_PROBE'], original);
      } finally {
        await process.terminate();
      }
      for (final environment in [
        {'bad=key': 'value'},
        {'bad\u0000key': 'value'},
        {'key': 'bad\u0000value'},
      ]) {
        await expectLater(
          WindowsFfiAnalyzerProcess.start(
            dart,
            [],
            workingDirectory: Directory.current.path,
            environment: environment,
          ),
          throwsArgumentError,
        );
      }
    },
  );
  Future<void> gone(List<int> pids) async {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '@(Get-Process -Id ${pids.join(',')} -ErrorAction SilentlyContinue).Count',
    ]);
    expect(result.exitCode, 0);
    expect(result.stdout.toString().trim(), '0');
  }

  test('FFI owner crash kills its analyzer and plugin tree', () async {
    final dir = await Directory.systemTemp.createTemp('dana ffi owner ');
    final owner = await Process.start(dart, [
      '--packages=${Directory.current.path}/.dart_tool/package_config.json',
      '$fixtures/ffi_owner_crash_driver.dart',
      '$fixtures/job_process_driver.dart',
      dir.path,
      'Local\\dana-global-test-${DateTime.now().microsecondsSinceEpoch}',
    ]);
    final errors = owner.stderr.drain<void>();
    final lines = StreamIterator(
      owner.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    try {
      expect(await lines.moveNext().timeout(const Duration(seconds: 10)), true);
      final ready = jsonDecode(lines.current) as Map;
      expect(owner.kill(), true);
      await owner.exitCode.timeout(const Duration(seconds: 8));
      final pids = [
        ready['pid'] as int,
        ready['childPid'] as int,
        ready['leafPid'] as int,
      ];
      // Kill-on-close termination is asynchronous in the kernel.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await gone(pids);
    } finally {
      owner.kill();
      await lines.cancel();
      await errors;
      await dir.delete(recursive: true);
    }
  });

  test('named Job recovery never treats an active tree as empty', () async {
    final name =
        'Local\\dana-global-test-${DateTime.now().microsecondsSinceEpoch}';
    final process = await WindowsFfiAnalyzerProcess.start(
      dart,
      ['$fixtures/ffi_blocked_child.dart'],
      workingDirectory: Directory.current.path,
      jobName: name,
    );
    try {
      await expectLater(
        WindowsFfiAnalyzerProcess.waitForEmptyNamedJob(
          name,
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await process.terminate();
      await WindowsFfiAnalyzerProcess.waitForEmptyNamedJob(name);
      await WindowsFfiAnalyzerProcess.waitForEmptyNamedJob('$name-missing');
    } finally {
      await process.terminate();
    }
  });

  test('product selector transports binary streams and EOF', () async {
    final result = await Process.run(
      dart,
      [
        '--packages=${Directory.current.path}/.dart_tool/package_config.json',
        '$fixtures/ffi_transport_probe.dart',
      ],
      environment: {'DANA_PROCESS_BACKEND': 'windows-ffi-job'},
    ).timeout(const Duration(seconds: 30));
    expect(result.stderr, isEmpty);
    expect(result.exitCode, 0);
    expect(jsonDecode(result.stdout as String)['ok'], true);
  });

  for (final rootExits in [false, true]) {
    test('FFI tree owns descendants, rootExits=$rootExits', () async {
      final dir = await Directory.systemTemp.createTemp('dana ffi tree ');
      final process = await WindowsFfiAnalyzerProcess.start(dart, [
        '$fixtures/job_process_driver.dart',
        'root',
        '${dir.path}/leaf',
        '空 格',
        'quote"value',
        'trailing\\',
      ], workingDirectory: dir.path);
      final errors = process.stderr.drain<void>();
      final lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      try {
        expect(
          await lines.moveNext().timeout(const Duration(seconds: 10)),
          true,
        );
        final ready = jsonDecode(lines.current) as Map;
        final resources = process.sampleResources();
        expect(resources['complete'], true);
        expect(resources['currentPrivateMiB'], greaterThan(0));
        expect(resources['peakPrivateMiB'], greaterThan(0));
        expect(ready['cwd'], dir.path);
        expect(ready['arguments'], ['空 格', 'quote"value', 'trailing\\']);
        process.stdin.writeln(rootExits ? 'exit-root' : 'hello');
        await process.stdin.flush();
        if (rootExits) {
          expect(await process.exitCode.timeout(const Duration(seconds: 8)), 0);
          final deadline = DateTime.now().add(const Duration(seconds: 8));
          while (!process.confirmedEmpty && DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(process.confirmedEmpty, true);
        } else {
          expect(
            await lines.moveNext().timeout(const Duration(seconds: 5)),
            true,
          );
          expect(jsonDecode(lines.current)['echo'], 'hello');
        }
        final close = process.terminate();
        expect(identical(close, process.terminate()), true);
        await close.timeout(const Duration(seconds: 10));
        expect(process.confirmedEmpty, true);
        await gone([
          process.pid,
          ready['pid'] as int,
          ready['childPid'] as int,
          ready['leafPid'] as int,
        ]);
      } finally {
        await process.terminate();
        await lines.cancel();
        await errors;
        await dir.delete(recursive: true);
      }
    });
  }

  test('startup failure does not fall back', () async {
    await expectLater(
      WindowsFfiAnalyzerProcess.start(
        'C:/missing-dana-ffi.exe',
        [],
        workingDirectory: Directory.current.path,
      ),
      throwsA(isA<OSError>()),
    );
  });

  test('canceling an idle read does not kill its analyzer', () async {
    final process = await WindowsFfiAnalyzerProcess.start(dart, [
      '$fixtures/ffi_blocked_child.dart',
    ], workingDirectory: Directory.current.path);
    var exited = false;
    process.exitCode.then((_) => exited = true);
    final subscription = process.stdout.listen((_) {});
    try {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await subscription.cancel().timeout(const Duration(seconds: 3));
      expect(exited, false);
      final errors = process.stderr.listen((_) {});
      errors.pause();
      await errors.cancel().timeout(const Duration(seconds: 3));
      expect(exited, false);
    } finally {
      await process.terminate();
    }
  });

  test(
    'paused output resumes without byte loss and cancellation leaves child alive',
    () async {
      final process = await WindowsFfiAnalyzerProcess.start(dart, [
        '$fixtures/ffi_blocked_child.dart',
        '--emit',
      ], workingDirectory: Directory.current.path);
      final paused = Completer<void>();
      final completed = Completer<void>();
      var count = 0;
      late StreamSubscription<List<int>> subscription;
      subscription = process.stdout.listen((bytes) {
        for (final byte in bytes) {
          expect(byte, count++ % 251);
        }
        if (!paused.isCompleted) {
          subscription.pause();
          paused.complete();
        }
        if (count == 4 * 1024 * 1024) completed.complete();
      }, onError: completed.completeError);
      try {
        await paused.future.timeout(const Duration(seconds: 5));
        final before = count;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(count, before);
        subscription.resume();
        await completed.future.timeout(const Duration(seconds: 10));
        await subscription.cancel().timeout(const Duration(seconds: 3));
      } finally {
        await process.terminate();
      }
    },
  );

  test('termination releases blocked writer and unconsumed pipes', () async {
    final dir = await Directory.systemTemp.createTemp('dana ffi blocked ');
    final process = await WindowsFfiAnalyzerProcess.start(dart, [
      '$fixtures/ffi_blocked_child.dart',
    ], workingDirectory: dir.path);
    try {
      final errors = <Object>[];
      process.stdin.done.catchError((Object error) {
        errors.add(error);
      });
      process.stdin.add(List.filled(2 * 1024 * 1024, 65));
      final flush = process.stdin.flush().then<void>(
        (_) {},
        onError: (Object error) {
          errors.add(error);
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await process.terminate().timeout(const Duration(seconds: 12));
      await flush;
      expect(process.confirmedEmpty, true);
      await gone([process.pid]);
    } finally {
      await process.terminate();
      await dir.delete(recursive: true);
    }
  });
}
