import 'dart:io';

import 'package:test/test.dart';

void main() {
  Future<ProcessResult> run(List<String> args) => Process.run(
    Platform.resolvedExecutable,
    ['bin/dart_analysis_daemon.dart', ...args],
  ).timeout(const Duration(seconds: 20));

  test('generated root and nested help describe registered commands', () async {
    for (final args in [
      <String>[],
      ['--help'],
      ['-h'],
    ]) {
      final result = await run(args);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('Available commands:'));
      for (final name in [
        'serve',
        'connect',
        'check',
        'status',
        'stop',
        'budget',
      ]) {
        expect(result.stdout, contains(name));
      }
    }
    for (final args in [
      ['check', '--help'],
      ['help', 'check'],
    ]) {
      final result = await run(args);
      expect(result.exitCode, 0);
      for (final flag in [
        '--root',
        '--reuse-ide',
        '--[no-]fatal-warnings',
        '--[no-]fatal-infos',
        '--bridge-settle-timeout',
      ]) {
        expect(result.stdout, contains(flag));
      }
    }
    final budget = await run(['help', 'budget', 'status']);
    expect(budget.exitCode, 0);
    expect(budget.stdout, contains('Show global worker budget status.'));
    expect((await run(['budget', '--help'])).exitCode, 0);
  });

  test('usage errors and version do not start a service', () async {
    for (final args in [
      ['budget', 'unknown'],
      ['check', '--unknown'],
      ['check', 'unexpected'],
      ['check'],
    ]) {
      final result = await run(args);
      expect(result.exitCode, 64, reason: '${result.stdout}${result.stderr}');
    }
    for (final (args, message) in [
      (['status'], 'Option --root is required.'),
      (['stop', '--root='], '--root must not be empty.'),
      (
        ['check', '--root', '${Directory.systemTemp.path}/dana-no-such-root'],
        '--root directory does not exist',
      ),
    ]) {
      final result = await run(args);
      expect(result.exitCode, 64, reason: '$args');
      expect('${result.stderr}', contains(message));
      expect('${result.stderr}', contains('Usage:'));
      expect('${result.stderr}', isNot(contains('Unhandled exception')));
    }
    final version = await run(['--version']);
    expect(version.exitCode, 0);
    expect('${version.stdout}'.trim(), '0.1.2');
  });
}
